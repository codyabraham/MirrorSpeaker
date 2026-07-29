using System.Diagnostics;
using System.IO;
using AirMirror.Core;

namespace AirMirror.App.Services;

internal enum ReceiverState
{
    Stopped,
    Starting,
    Reconnecting,
    Ready,
    Mirroring,
    Error
}

internal sealed class ReceiverController : IAsyncDisposable
{
    private const int BasePort = 35000;
    private readonly SemaphoreSlim _lifecycleLock = new(1, 1);
    private readonly ReceiverLogInterpreter _logInterpreter = new();
    private readonly object _processGate = new();
    private Process? _process;
    private EventWaitHandle? _stopEvent;

    public event EventHandler<string>? OutputReceived;

    public event EventHandler<ReceiverState>? StateChanged;

    public event EventHandler<string>? PairingCodeReceived;

    public bool IsRunning
    {
        get
        {
            lock (_processGate)
            {
                var process = _process;
                if (process is null)
                {
                    return false;
                }

                try
                {
                    return !process.HasExited;
                }
                catch (InvalidOperationException)
                {
                    return false;
                }
            }
        }
    }

    public async Task StartAsync(string executablePath, ReceiverOptions settings)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(settings.DeviceName);

        await _lifecycleLock.WaitAsync();
        try
        {
            if (IsRunning)
            {
                return;
            }

            var startInfo = UxPlayCommandBuilder.CreateStartInfo(executablePath, settings);
            startInfo.WorkingDirectory = Path.GetDirectoryName(executablePath) ?? AppContext.BaseDirectory;
            var networkRoute = ConfigureRuntimeEnvironment(startInfo, executablePath);
            var stopEventName = $"Local\\AirMirror.Stop.{Guid.NewGuid():N}";
            var stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, stopEventName);
            startInfo.Environment["AIRMIRROR_STOP_EVENT"] = stopEventName;
            var process = new Process
            {
                StartInfo = startInfo,
                EnableRaisingEvents = true
            };

            process.OutputDataReceived += Process_OutputDataReceived;
            process.ErrorDataReceived += Process_OutputDataReceived;
            process.Exited += Process_Exited;

            StateChanged?.Invoke(this, ReceiverState.Starting);
            lock (_processGate)
            {
                _process = process;
                _stopEvent = stopEvent;
                try
                {
                    if (!process.Start())
                    {
                        throw new InvalidOperationException("The receiver engine could not be started.");
                    }

                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                }
                catch
                {
                    _process = null;
                    _stopEvent = null;
                    stopEvent.Dispose();
                    DetachAndDispose(process);
                    throw;
                }
            }

            OutputReceived?.Invoke(this, $"Started receiver engine on TCP/UDP ports {BasePort}-{BasePort + 2}.");
            if (settings.ContentMode == ReceiverContentMode.AudioOnly)
            {
                OutputReceived?.Invoke(this, "AirPlay speaker mode is active; video service advertising and rendering are disabled.");
            }
            if (networkRoute is not null)
            {
                OutputReceived?.Invoke(
                    this,
                    $"Advertising AirPlay on {networkRoute.Address} through {networkRoute.InterfaceName}.");
            }
            else
            {
                OutputReceived?.Invoke(this, "No preferred IPv4 adapter was found; receiver discovery is using its safe fallback.");
            }
        }
        catch
        {
            StateChanged?.Invoke(this, ReceiverState.Error);
            throw;
        }
        finally
        {
            _lifecycleLock.Release();
        }
    }

    public async Task StopAsync()
    {
        await _lifecycleLock.WaitAsync();
        try
        {
            Process? process;
            EventWaitHandle? stopEvent;
            lock (_processGate)
            {
                process = _process;
                _process = null;
                stopEvent = _stopEvent;
                _stopEvent = null;
                if (process is not null)
                {
                    process.Exited -= Process_Exited;
                }
            }

            if (process is null)
            {
                stopEvent?.Dispose();
                StateChanged?.Invoke(this, ReceiverState.Stopped);
                return;
            }

            if (!process.HasExited)
            {
                try
                {
                    if (stopEvent is not null)
                    {
                        stopEvent.Set();
                        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                        try
                        {
                            await process.WaitForExitAsync(timeout.Token);
                        }
                        catch (OperationCanceledException)
                        {
                            process.Kill(entireProcessTree: true);
                        }
                    }
                    else if (!process.CloseMainWindow())
                    {
                        process.Kill(entireProcessTree: true);
                    }

                    await process.WaitForExitAsync();
                }
                catch (InvalidOperationException)
                {
                    // The process exited between the state check and shutdown request.
                }
            }

            stopEvent?.Dispose();
            DetachAndDispose(process);
            OutputReceived?.Invoke(this, "Receiver stopped.");
            StateChanged?.Invoke(this, ReceiverState.Stopped);
        }
        finally
        {
            _lifecycleLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        _lifecycleLock.Dispose();
    }

    private static NetworkRouteSelection? ConfigureRuntimeEnvironment(ProcessStartInfo startInfo, string executablePath)
    {
        var binDirectory = Path.GetDirectoryName(executablePath) ?? AppContext.BaseDirectory;
        var ucrtDirectory = Directory.GetParent(binDirectory)?.FullName;
        var existingPath = startInfo.Environment.TryGetValue("PATH", out var path) ? path : null;
        startInfo.Environment["PATH"] = string.IsNullOrEmpty(existingPath)
            ? binDirectory
            : binDirectory + Path.PathSeparator + existingPath;

        // UxPlay keeps trusted-iPhone registration beneath HOME. Installed
        // releases retain the legacy folder so existing pairings survive the
        // rename; portable releases keep all user data beside the app.
        var appData = AppStorage.UserDataRoot;
        Directory.CreateDirectory(appData);
        startInfo.Environment["HOME"] = appData;

        var networkRoute = NetworkRouteSelector.FindPreferredIpv4();
        if (networkRoute is not null)
        {
            startInfo.Environment["UXPLAY_MDNS_IPV4"] = networkRoute.Address.ToString();
        }

        if (ucrtDirectory is not null)
        {
            var pluginDirectory = Path.Combine(ucrtDirectory, "lib", "gstreamer-1.0");
            if (Directory.Exists(pluginDirectory))
            {
                startInfo.Environment["GST_PLUGIN_PATH_1_0"] = pluginDirectory;
                startInfo.Environment["GST_PLUGIN_SYSTEM_PATH_1_0"] = pluginDirectory;
            }
        }

        return networkRoute;
    }

    private void Process_OutputDataReceived(object sender, DataReceivedEventArgs eventArgs)
    {
        var line = eventArgs.Data;
        if (string.IsNullOrWhiteSpace(line))
        {
            return;
        }

        OutputReceived?.Invoke(this, line);
        InterpretLine(line);
    }

    private void InterpretLine(string line)
    {
        var logEvent = _logInterpreter.Interpret(line);
        if (logEvent is null)
        {
            if (line.Contains("stopping mirroring", StringComparison.OrdinalIgnoreCase)
                || line.Contains("connection closed", StringComparison.OrdinalIgnoreCase))
            {
                StateChanged?.Invoke(this, ReceiverState.Ready);
            }

            return;
        }

        switch (logEvent.State)
        {
            case AirMirror.Core.ReceiverState.Ready:
                StateChanged?.Invoke(this, ReceiverState.Ready);
                break;
            case AirMirror.Core.ReceiverState.Mirroring:
                StateChanged?.Invoke(this, ReceiverState.Mirroring);
                break;
            case AirMirror.Core.ReceiverState.PairingCode when logEvent.PairingCode is not null:
                PairingCodeReceived?.Invoke(this, logEvent.PairingCode);
                break;
            case AirMirror.Core.ReceiverState.Error:
                StateChanged?.Invoke(this, ReceiverState.Error);
                break;
        }
    }

    private void Process_Exited(object? sender, EventArgs eventArgs)
    {
        if (sender is not Process process)
        {
            return;
        }

        EventWaitHandle? stopEvent;
        lock (_processGate)
        {
            if (!ReferenceEquals(_process, process))
            {
                return;
            }

            _process = null;
            stopEvent = _stopEvent;
            _stopEvent = null;
            process.Exited -= Process_Exited;
        }

        var exitCode = process.ExitCode;
        OutputReceived?.Invoke(this, $"Receiver engine exited unexpectedly (code {exitCode}).");
        StateChanged?.Invoke(this, exitCode == 0 ? ReceiverState.Stopped : ReceiverState.Error);
        stopEvent?.Dispose();
        DetachAndDispose(process);
    }

    private void DetachAndDispose(Process process)
    {
        process.OutputDataReceived -= Process_OutputDataReceived;
        process.ErrorDataReceived -= Process_OutputDataReceived;
        process.Exited -= Process_Exited;
        process.Dispose();
    }
}
