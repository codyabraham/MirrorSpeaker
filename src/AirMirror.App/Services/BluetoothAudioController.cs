using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;
using Windows.Media.Audio;

namespace AirMirror.App.Services;

internal sealed record BluetoothAudioDevice(
    string Id,
    string Name,
    bool IsWindowsConnected)
{
    public override string ToString() => IsWindowsConnected ? $"{Name} — Connected" : $"{Name} — Paired";
}

internal sealed class BluetoothAudioController : IAsyncDisposable
{
    private const string ContainerIdProperty = "System.Devices.ContainerId";
    private const string AepContainerIdProperty = "System.Devices.Aep.ContainerId";
    private const string AepIsConnectedProperty = "System.Devices.Aep.IsConnected";
    private static readonly TimeSpan[] ReconnectDelays =
    [
        TimeSpan.FromMilliseconds(250),
        TimeSpan.FromMilliseconds(750),
        TimeSpan.FromSeconds(2)
    ];
    private static readonly TimeSpan[] InitialOpenRetryDelays =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(3),
        TimeSpan.FromSeconds(6)
    ];

    private readonly SemaphoreSlim _lifecycleLock = new(1, 1);
    private readonly object _connectionGate = new();
    private AudioPlaybackConnection? _connection;
    private BluetoothAudioDevice? _activeDevice;
    private CancellationTokenSource? _sessionCancellation;
    private Task? _recoveryTask;
    private long _sessionGeneration;
    private bool _desiredRunning;
    private bool _hasOpened;
    private bool _everOpened;
    private bool _recoveryRunning;
    private ReceiverState _state = ReceiverState.Stopped;

    public event EventHandler<string>? OutputReceived;

    public event EventHandler<ReceiverState>? StateChanged;

    public bool IsRunning
    {
        get
        {
            lock (_connectionGate)
            {
                return _desiredRunning;
            }
        }
    }

    public ReceiverState CurrentState
    {
        get
        {
            lock (_connectionGate)
            {
                return _state;
            }
        }
    }

    public static async Task<IReadOnlyList<BluetoothAudioDevice>> FindDevicesAsync()
    {
        var audioDevices = await DeviceInformation.FindAllAsync(
            AudioPlaybackConnection.GetDeviceSelector(),
            [ContainerIdProperty]);
        var pairedClassicDevices = await DeviceInformation.FindAllAsync(
            BluetoothDevice.GetDeviceSelectorFromPairingState(true),
            [AepContainerIdProperty, AepIsConnectedProperty]);
        var connectedLowEnergyDevices = await DeviceInformation.FindAllAsync(
            BluetoothLEDevice.GetDeviceSelectorFromConnectionStatus(BluetoothConnectionStatus.Connected),
            [AepContainerIdProperty]);

        var connectedLowEnergyContainers = connectedLowEnergyDevices
            .Select(device => GetContainerId(device, AepContainerIdProperty))
            .Where(containerId => containerId.HasValue)
            .Select(containerId => containerId!.Value)
            .ToHashSet();

        return audioDevices
            // The selector already returns interfaces that Windows can use for
            // AudioPlaybackConnection. DeviceInformation.Pairing.IsPaired is
            // unreliable for these A2DP interface records: it can be false
            // while the parent iPhone is visibly Connected in Settings.
            .Where(device => device.IsEnabled)
            .Select(device =>
            {
                var containerId = GetContainerId(device, ContainerIdProperty);
                var parentDevice = containerId.HasValue
                    ? pairedClassicDevices.FirstOrDefault(candidate =>
                        GetContainerId(candidate, AepContainerIdProperty) == containerId)
                    : null;
                var classicConnected = parentDevice is not null
                                       && GetBoolean(parentDevice, AepIsConnectedProperty);
                var lowEnergyConnected = containerId.HasValue
                                         && connectedLowEnergyContainers.Contains(containerId.Value);

                return new BluetoothAudioDevice(
                    device.Id,
                    string.IsNullOrWhiteSpace(parentDevice?.Name)
                        ? string.IsNullOrWhiteSpace(device.Name) ? "Bluetooth phone" : device.Name.Trim()
                        : parentDevice.Name.Trim(),
                    classicConnected || lowEnergyConnected);
            })
            .OrderByDescending(device => device.IsWindowsConnected)
            .ThenBy(device => device.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    public async Task StartAsync(BluetoothAudioDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        ArgumentException.ThrowIfNullOrWhiteSpace(device.Id);

        await _lifecycleLock.WaitAsync().ConfigureAwait(false);
        long generation = 0;
        AudioPlaybackConnection? connection = null;
        CancellationToken sessionCancellationToken = default;
        try
        {
            lock (_connectionGate)
            {
                if (_desiredRunning)
                {
                    return;
                }

                _desiredRunning = true;
                _activeDevice = device;
                _sessionCancellation = new CancellationTokenSource();
                sessionCancellationToken = _sessionCancellation.Token;
                generation = ++_sessionGeneration;
                _hasOpened = false;
                _everOpened = false;
                _recoveryRunning = false;
            }

            PublishState(generation, ReceiverState.Starting);
            OutputReceived?.Invoke(
                this,
                device.IsWindowsConnected
                    ? $"Windows reports {device.Name} is already connected; reusing that device without pairing again."
                    : $"Windows reports {device.Name} is paired but not currently connected; opening its audio transport.");
            if (device.IsWindowsConnected)
            {
                OutputReceived?.Invoke(
                    this,
                    "Connected describes the phone's general Bluetooth link; Windows still needs to open its separate audio receiver profile.");
            }

            connection = CreateAndInstallConnection(device, generation);
            OutputReceived?.Invoke(this, "Enabling Windows Bluetooth speaker mode for the selected phone.");

            // Keep these calls adjacent. Some Bluetooth adapters time out if
            // OpenAsync is delayed after StartAsync.
            await connection.StartAsync();
            var openResult = await connection.OpenAsync();

            if (openResult.Status == AudioPlaybackConnectionOpenResultStatus.Success
                || IsConnectionStateOpened(connection))
            {
                if (!TransitionToOpened(connection, generation, out var newlyOpened))
                {
                    throw new InvalidOperationException(
                        "The Bluetooth speaker session changed before Windows finished confirming the connection.");
                }

                if (newlyOpened)
                {
                    OutputReceived?.Invoke(this, "Bluetooth audio connection opened.");
                }
                ScheduleOpenStateVerification(connection, generation);
                return;
            }

            LogOpenFailure(openResult, "Initial Bluetooth connection");
            if (!IsRetryableOpenFailure(openResult))
            {
                throw new BluetoothAudioOpenException(
                    BuildOpenFailureMessage(device, openResult));
            }

            PublishState(generation, ReceiverState.Ready);
            OutputReceived?.Invoke(
                this,
                "Windows enabled the Bluetooth receiver but has not opened the iPhone audio link yet. Keeping it enabled and retrying in the background.");
            BeginInitialOpenRecovery(
                connection,
                device,
                generation,
                sessionCancellationToken);
        }
        catch (Exception exception)
        {
            if (generation != 0)
            {
                EndSessionWithError(generation, connection);
            }

            if (exception is BluetoothAudioOpenException)
            {
                throw;
            }

            throw new BluetoothAudioOpenException(
                BuildOpenFailureMessage(device),
                exception);
        }
        finally
        {
            _lifecycleLock.Release();
        }
    }

    public async Task StopAsync()
    {
        Task? recoveryTask;
        await _lifecycleLock.WaitAsync().ConfigureAwait(false);
        try
        {
            AudioPlaybackConnection? connection;
            CancellationTokenSource? cancellation;
            bool stateChanged;
            lock (_connectionGate)
            {
                connection = _connection;
                cancellation = _sessionCancellation;
                recoveryTask = _recoveryTask;
                _connection = null;
                _activeDevice = null;
                _sessionCancellation = null;
                _recoveryTask = null;
                _desiredRunning = false;
                _hasOpened = false;
                _everOpened = false;
                _recoveryRunning = false;
                _sessionGeneration++;
                stateChanged = _state != ReceiverState.Stopped;
                _state = ReceiverState.Stopped;
            }

            CancelAndDispose(cancellation);
            DisposeConnection(connection);
            if (connection is not null)
            {
                OutputReceived?.Invoke(this, "Bluetooth speaker mode stopped.");
            }

            if (stateChanged)
            {
                StateChanged?.Invoke(this, ReceiverState.Stopped);
            }
        }
        finally
        {
            _lifecycleLock.Release();
        }

        if (recoveryTask is not null)
        {
            try
            {
                await recoveryTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // An explicit stop is the expected way to cancel recovery.
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        _lifecycleLock.Dispose();
    }

    private void Connection_StateChanged(AudioPlaybackConnection sender, object args)
    {
        var state = sender.State;
        if (state == AudioPlaybackConnectionState.Opened)
        {
            long generation;
            lock (_connectionGate)
            {
                if (!ReferenceEquals(_connection, sender) || !_desiredRunning)
                {
                    return;
                }

                generation = _sessionGeneration;
            }

            if (TransitionToOpened(sender, generation, out var newlyOpened))
            {
                if (newlyOpened)
                {
                    OutputReceived?.Invoke(
                        this,
                        "Windows reported that the iPhone Bluetooth audio link opened.");
                }
                ScheduleOpenStateVerification(sender, generation);
            }
            return;
        }

        if (state != AudioPlaybackConnectionState.Closed)
        {
            return;
        }

        BeginRecoveryIfNeeded(sender);
    }

    private void BeginInitialOpenRecovery(
        AudioPlaybackConnection connection,
        BluetoothAudioDevice device,
        long generation,
        CancellationToken cancellationToken)
    {
        lock (_connectionGate)
        {
            if (!ReferenceEquals(_connection, connection)
                || !_desiredRunning
                || _everOpened
                || _recoveryRunning
                || generation != _sessionGeneration)
            {
                return;
            }

            _recoveryRunning = true;
        }

        var recoveryTask = RecoverInitialOpenAsync(
            connection,
            device,
            generation,
            cancellationToken);
        lock (_connectionGate)
        {
            if (_desiredRunning && generation == _sessionGeneration)
            {
                _recoveryTask = recoveryTask;
            }
        }
    }

    private async Task RecoverInitialOpenAsync(
        AudioPlaybackConnection connection,
        BluetoothAudioDevice device,
        long generation,
        CancellationToken cancellationToken)
    {
        try
        {
            for (var attempt = 0; attempt < InitialOpenRetryDelays.Length; attempt++)
            {
                await Task.Delay(
                    InitialOpenRetryDelays[attempt],
                    cancellationToken).ConfigureAwait(false);
                await _lifecycleLock.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    if (!IsCurrentConnection(connection, generation)
                        || HasCurrentConnectionEverOpened(connection, generation))
                    {
                        return;
                    }

                    OutputReceived?.Invoke(
                        this,
                        $"Retrying the enabled Bluetooth audio link (attempt {attempt + 1} of {InitialOpenRetryDelays.Length}).");
                    var openResult = await connection.OpenAsync();
                    if (openResult.Status == AudioPlaybackConnectionOpenResultStatus.Success
                        || IsConnectionStateOpened(connection))
                    {
                        if (TransitionToOpened(connection, generation, out var newlyOpened))
                        {
                            if (newlyOpened)
                            {
                                OutputReceived?.Invoke(
                                    this,
                                    $"Bluetooth audio opened on background attempt {attempt + 1}.");
                            }
                            ScheduleOpenStateVerification(connection, generation);
                        }
                        return;
                    }

                    LogOpenFailure(
                        openResult,
                        $"Bluetooth background attempt {attempt + 1}");
                    if (!IsRetryableOpenFailure(openResult))
                    {
                        OutputReceived?.Invoke(
                            this,
                            BuildOpenFailureMessage(device, openResult));
                        EndSessionWithError(generation, connection);
                        return;
                    }
                }
                finally
                {
                    _lifecycleLock.Release();
                }
            }

            lock (_connectionGate)
            {
                if (_desiredRunning
                    && generation == _sessionGeneration
                    && ReferenceEquals(_connection, connection)
                    && !_everOpened)
                {
                    _recoveryRunning = false;
                }
            }

            if (IsCurrentConnection(connection, generation)
                && !HasCurrentConnectionEverOpened(connection, generation))
            {
                OutputReceived?.Invoke(
                    this,
                    "Windows still has the Bluetooth receiver enabled, but the audio link remains closed. Keep the iPhone awake and playing audio. If it stays closed, toggle Bluetooth off and on, then stop and restart Bluetooth mode.");
            }
        }
        catch (OperationCanceledException)
        {
            // The user stopped Bluetooth mode while an initial retry was waiting.
        }
        catch (Exception exception)
        {
            OutputReceived?.Invoke(
                this,
                $"Bluetooth background opening stopped unexpectedly: {exception}");
            await _lifecycleLock.WaitAsync().ConfigureAwait(false);
            try
            {
                if (IsCurrentConnection(connection, generation)
                    && !HasCurrentConnectionEverOpened(connection, generation))
                {
                    EndSessionWithError(generation, connection);
                }
            }
            finally
            {
                _lifecycleLock.Release();
            }
        }
    }

    private void BeginRecoveryIfNeeded(AudioPlaybackConnection sender)
    {
        BluetoothAudioDevice? device;
        CancellationToken cancellationToken;
        long generation;
        bool stateChanged;
        lock (_connectionGate)
        {
            if (!ReferenceEquals(_connection, sender)
                || !_desiredRunning
                || !_hasOpened
                || _recoveryRunning
                || _activeDevice is null
                || _sessionCancellation is null)
            {
                // Windows can report an initial Closed state between
                // StartAsync and OpenAsync. It is not a disconnect.
                return;
            }

            _hasOpened = false;
            _recoveryRunning = true;
            device = _activeDevice;
            cancellationToken = _sessionCancellation.Token;
            generation = _sessionGeneration;
            stateChanged = _state != ReceiverState.Reconnecting;
            _state = ReceiverState.Reconnecting;
        }

        OutputReceived?.Invoke(
            this,
            "The Bluetooth audio profile briefly closed. MirrorSpeaker is reconnecting automatically.");
        if (stateChanged)
        {
            StateChanged?.Invoke(this, ReceiverState.Reconnecting);
        }

        var recoveryTask = RecoverConnectionAsync(sender, device, generation, cancellationToken);
        lock (_connectionGate)
        {
            if (_desiredRunning && generation == _sessionGeneration)
            {
                _recoveryTask = recoveryTask;
            }
        }
    }

    private void ScheduleOpenStateVerification(
        AudioPlaybackConnection connection,
        long generation)
    {
        _ = VerifyOpenStateAsync(connection, generation);
    }

    private async Task VerifyOpenStateAsync(
        AudioPlaybackConnection connection,
        long generation)
    {
        await Task.Delay(500).ConfigureAwait(false);
        try
        {
            if (IsCurrentConnection(connection, generation)
                && connection.State == AudioPlaybackConnectionState.Closed)
            {
                BeginRecoveryIfNeeded(connection);
            }
        }
        catch (ObjectDisposedException)
        {
            // Stop or a newer retry already replaced this connection.
        }
    }

    private async Task RecoverConnectionAsync(
        AudioPlaybackConnection closedConnection,
        BluetoothAudioDevice device,
        long generation,
        CancellationToken cancellationToken)
    {
        try
        {
            for (var attempt = 0; attempt < ReconnectDelays.Length; attempt++)
            {
                await Task.Delay(ReconnectDelays[attempt], cancellationToken).ConfigureAwait(false);
                await _lifecycleLock.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    if (!IsCurrentSession(generation))
                    {
                        return;
                    }

                    AudioPlaybackConnection connection;
                    if (attempt == 0 && IsCurrentConnection(closedConnection, generation))
                    {
                        connection = closedConnection;
                        OutputReceived?.Invoke(
                            this,
                            "Reopening the existing Bluetooth audio link (attempt 1 of 3).");
                    }
                    else
                    {
                        connection = CreateAndInstallConnection(device, generation);
                        OutputReceived?.Invoke(
                            this,
                            $"Recreating the Bluetooth audio link (attempt {attempt + 1} of 3).");

                        // As on initial startup, do not add a delay between
                        // enabling a fresh connection and opening it.
                        await connection.StartAsync();
                    }

                    var openResult = await connection.OpenAsync();
                    if ((openResult.Status == AudioPlaybackConnectionOpenResultStatus.Success
                         || IsConnectionStateOpened(connection))
                        && TransitionToOpened(
                            connection,
                            generation,
                            out _))
                    {
                        OutputReceived?.Invoke(
                            this,
                            $"Bluetooth audio recovered on attempt {attempt + 1}.");
                        ScheduleOpenStateVerification(connection, generation);
                        return;
                    }

                    LogOpenFailure(openResult, $"Bluetooth recovery attempt {attempt + 1}");
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception exception)
                {
                    OutputReceived?.Invoke(
                        this,
                        $"Bluetooth recovery attempt {attempt + 1} failed: {exception.Message}");
                }
                finally
                {
                    _lifecycleLock.Release();
                }
            }

            await _lifecycleLock.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (IsCurrentSession(generation))
                {
                    OutputReceived?.Invoke(
                        this,
                        "Bluetooth recovery did not succeed after three attempts.");
                    EndSessionWithError(generation);
                }
            }
            finally
            {
                _lifecycleLock.Release();
            }
        }
        catch (OperationCanceledException)
        {
            // The user stopped the receiver while a retry was waiting.
        }
        catch (Exception exception)
        {
            OutputReceived?.Invoke(this, $"Bluetooth recovery stopped unexpectedly: {exception}");
            await _lifecycleLock.WaitAsync().ConfigureAwait(false);
            try
            {
                if (IsCurrentSession(generation))
                {
                    EndSessionWithError(generation);
                }
            }
            finally
            {
                _lifecycleLock.Release();
            }
        }
    }

    private AudioPlaybackConnection CreateAndInstallConnection(
        BluetoothAudioDevice device,
        long generation)
    {
        var newConnection = AudioPlaybackConnection.TryCreateFromId(device.Id)
            ?? throw new BluetoothAudioOpenException(BuildOpenFailureMessage(device));
        newConnection.StateChanged += Connection_StateChanged;

        AudioPlaybackConnection? previousConnection;
        lock (_connectionGate)
        {
            if (!_desiredRunning || generation != _sessionGeneration)
            {
                newConnection.StateChanged -= Connection_StateChanged;
                newConnection.Dispose();
                throw new OperationCanceledException("The Bluetooth speaker session was stopped.");
            }

            previousConnection = _connection;
            _connection = newConnection;
            _hasOpened = false;
        }

        if (previousConnection is not null)
        {
            DisposeConnection(previousConnection);
        }

        return newConnection;
    }

    private bool TransitionToOpened(
        AudioPlaybackConnection connection,
        long generation,
        out bool newlyOpened)
    {
        bool stateChanged;
        newlyOpened = false;
        lock (_connectionGate)
        {
            if (!_desiredRunning
                || generation != _sessionGeneration
                || !ReferenceEquals(_connection, connection))
            {
                return false;
            }

            newlyOpened = !_hasOpened;
            _hasOpened = true;
            _everOpened = true;
            _recoveryRunning = false;
            stateChanged = _state != ReceiverState.Mirroring;
            _state = ReceiverState.Mirroring;
        }

        if (stateChanged)
        {
            StateChanged?.Invoke(this, ReceiverState.Mirroring);
        }

        return true;
    }

    private void PublishState(long generation, ReceiverState state)
    {
        bool stateChanged;
        lock (_connectionGate)
        {
            if (!_desiredRunning || generation != _sessionGeneration)
            {
                return;
            }

            stateChanged = _state != state;
            _state = state;
        }

        if (stateChanged)
        {
            StateChanged?.Invoke(this, state);
        }
    }

    private void EndSessionWithError(
        long generation,
        AudioPlaybackConnection? expectedConnection = null)
    {
        AudioPlaybackConnection? connection;
        CancellationTokenSource? cancellation;
        bool stateChanged;
        lock (_connectionGate)
        {
            if (generation != _sessionGeneration
                || (expectedConnection is not null
                    && _connection is not null
                    && !ReferenceEquals(_connection, expectedConnection)))
            {
                return;
            }

            connection = _connection;
            cancellation = _sessionCancellation;
            _connection = null;
            _activeDevice = null;
            _sessionCancellation = null;
            _recoveryTask = null;
            _desiredRunning = false;
            _hasOpened = false;
            _everOpened = false;
            _recoveryRunning = false;
            stateChanged = _state != ReceiverState.Error;
            _state = ReceiverState.Error;
        }

        CancelAndDispose(cancellation);
        DisposeConnection(connection);
        if (stateChanged)
        {
            StateChanged?.Invoke(this, ReceiverState.Error);
        }
    }

    private bool IsCurrentSession(long generation)
    {
        lock (_connectionGate)
        {
            return _desiredRunning && generation == _sessionGeneration;
        }
    }

    private bool IsCurrentConnection(AudioPlaybackConnection connection, long generation)
    {
        lock (_connectionGate)
        {
            return _desiredRunning
                   && generation == _sessionGeneration
                   && ReferenceEquals(_connection, connection);
        }
    }

    private bool IsCurrentConnectionOpened(
        AudioPlaybackConnection connection,
        long generation)
    {
        lock (_connectionGate)
        {
            return _desiredRunning
                   && generation == _sessionGeneration
                   && ReferenceEquals(_connection, connection)
                   && _hasOpened;
        }
    }

    private bool HasCurrentConnectionEverOpened(
        AudioPlaybackConnection connection,
        long generation)
    {
        lock (_connectionGate)
        {
            return _desiredRunning
                   && generation == _sessionGeneration
                   && ReferenceEquals(_connection, connection)
                   && _everOpened;
        }
    }

    private static bool IsConnectionStateOpened(
        AudioPlaybackConnection connection)
    {
        try
        {
            return connection.State == AudioPlaybackConnectionState.Opened;
        }
        catch (ObjectDisposedException)
        {
            return false;
        }
    }

    private static bool IsRetryableOpenFailure(
        AudioPlaybackConnectionOpenResult openResult) =>
        openResult.Status is AudioPlaybackConnectionOpenResultStatus.RequestTimedOut
            or AudioPlaybackConnectionOpenResultStatus.UnknownFailure;

    private void LogOpenFailure(
        AudioPlaybackConnectionOpenResult openResult,
        string operation)
    {
        var extendedError = openResult.ExtendedError;
        OutputReceived?.Invoke(
            this,
            $"{operation} returned {openResult.Status}; Windows code 0x{extendedError.HResult:X8}.");
    }

    private void DisposeConnection(AudioPlaybackConnection? connection)
    {
        if (connection is null)
        {
            return;
        }

        connection.StateChanged -= Connection_StateChanged;
        connection.Dispose();
    }

    private static void CancelAndDispose(CancellationTokenSource? cancellation)
    {
        if (cancellation is null)
        {
            return;
        }

        try
        {
            cancellation.Cancel();
        }
        catch (ObjectDisposedException)
        {
            return;
        }
        finally
        {
            cancellation.Dispose();
        }
    }

    private static string BuildOpenFailureMessage(
        BluetoothAudioDevice device,
        AudioPlaybackConnectionOpenResult? openResult = null)
    {
        if (openResult?.ExtendedError.HResult == unchecked((int)0x8007001F))
        {
            return "Windows found the iPhone audio endpoint, but the Bluetooth/audio device stack returned 0x8007001F (device not functioning). MirrorSpeaker kept the receiver enabled and retried. Toggle Bluetooth off and on in Windows and on the iPhone, then stop and restart Bluetooth mode. If it continues, update the PC's Bluetooth driver and restart Windows. The iPhone remains paired; do not remove it first.";
        }

        if (openResult is not null)
        {
            return $"Windows found the iPhone audio endpoint but returned {openResult.Status} (0x{openResult.ExtendedError.HResult:X8}) while opening it. Keep the iPhone awake, confirm Bluetooth is on, and try again. The iPhone remains paired; do not remove it first.";
        }

        return device.IsWindowsConnected
            ? "Windows shows the iPhone's general Bluetooth connection, but its audio link could not be enabled. Toggle Bluetooth off and on in Windows and on the iPhone, then try again. The iPhone remains paired; do not remove it first."
            : "Windows found the paired iPhone but could not enable its Bluetooth audio link. Make sure Bluetooth is on and the iPhone is awake, then try again.";
    }

    private sealed class BluetoothAudioOpenException : InvalidOperationException
    {
        public BluetoothAudioOpenException(string message)
            : base(message)
        {
        }

        public BluetoothAudioOpenException(string message, Exception innerException)
            : base(message, innerException)
        {
        }
    }

    private static Guid? GetContainerId(DeviceInformation device, string propertyName)
    {
        if (!device.Properties.TryGetValue(propertyName, out var value) || value is null)
        {
            return null;
        }

        if (value is Guid guid)
        {
            return guid;
        }

        return Guid.TryParse(value.ToString(), out guid) ? guid : null;
    }

    private static bool GetBoolean(DeviceInformation device, string propertyName) =>
        device.Properties.TryGetValue(propertyName, out var value)
        && value is bool boolean
        && boolean;
}
