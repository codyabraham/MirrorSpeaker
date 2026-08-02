using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using AirMirror.App.Models;
using AirMirror.App.Services;
using ReceiverOptions = AirMirror.Core.ReceiverOptions;
using ReceiverContentMode = AirMirror.Core.ReceiverContentMode;
using VideoSink = AirMirror.Core.VideoSink;
using AudioSink = AirMirror.Core.AudioSink;

namespace AirMirror.App;

public partial class MainWindow : Window
{
    private readonly SettingsService _settingsService = new();
    private readonly ReceiverController _receiver = new();
    private readonly BluetoothAudioController _bluetoothAudio = new();
    private readonly EngineInstaller _installer = new();
    private readonly DispatcherTimer _saveTimer;
    private readonly CancellationTokenSource _shutdownToken = new();
    private UserSettings _settings = new();
    private string? _enginePath;
    private ReceiverState _airPlayState = ReceiverState.Stopped;
    private ReceiverState _bluetoothState = ReceiverState.Stopped;
    private bool _windowLoaded;
    private bool _installing;
    private bool _closeAllowed;
    private bool _engineNeedsDiscoveryUpdate;
    private bool _refreshingBluetoothDevices;
    private DateTime _lastBluetoothRefreshUtc = DateTime.MinValue;
    private Task? _bluetoothRefreshTask;
    private AudioOutputInfo? _audioOutputInfo;

    public MainWindow()
    {
        InitializeComponent();

        _saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
        _saveTimer.Tick += SaveTimer_Tick;

        _receiver.OutputReceived += Receiver_OutputReceived;
        _receiver.StateChanged += Receiver_StateChanged;
        _receiver.PairingCodeReceived += Receiver_PairingCodeReceived;
        _bluetoothAudio.OutputReceived += Receiver_OutputReceived;
        _bluetoothAudio.StateChanged += Receiver_StateChanged;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        _settings = await _settingsService.LoadAsync();
        ApplySettingsToControls();
        _windowLoaded = true;
        RefreshEngineState();
        if (SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly)
        {
            await RefreshBluetoothDevicesAsync();
            await RefreshBluetoothOutputAsync();
        }
    }

    private void ApplySettingsToControls()
    {
        DeviceNameTextBox.Text = NormalizeDeviceName(_settings.DeviceName);
        RequirePinCheckBox.IsChecked = _settings.RequirePin;
        LowLatencyCheckBox.IsChecked = _settings.LowLatency;
        FullscreenCheckBox.IsChecked = _settings.Fullscreen;
        ReceiverModeComboBox.SelectedIndex = (int)_settings.ContentMode;
        UpdateReceiverModeUi();
    }

    private void RefreshEngineState()
    {
        _enginePath = EngineDiscovery.FindUxPlay();
        _engineNeedsDiscoveryUpdate = EngineDiscovery.RequiresDiscoveryUpdate(_enginePath);
        if (SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly)
        {
            var airPlayEngineStatus = _enginePath is null
                ? "not installed (not needed for Bluetooth)"
                : _engineNeedsDiscoveryUpdate
                    ? "installed; compatibility update available"
                    : "installed";
            EnvironmentText.Text = $"Bluetooth speaker: Windows built-in audio receiver{Environment.NewLine}AirPlay engine: {airPlayEngineStatus}";
            FirewallButton.Visibility = Visibility.Collapsed;
            DiagnosticsSummaryText.Text = "Bluetooth speaker status and troubleshooting details";
            ApplyReceiverState(_bluetoothState);
            return;
        }

        FirewallButton.Visibility = Visibility.Visible;
        if (_enginePath is null)
        {
            EnvironmentText.Text = "Receiver engine: not installed";
            ReceiverSummaryText.Text = "One-time setup is needed before this PC can receive your iPhone screen.";
            PrimaryButton.Content = "Install receiver engine";
            PrimaryButton.IsEnabled = true;
            FirewallButton.IsEnabled = false;
            SetStatusBadge("Setup needed", BadgeKind.Warning);
            DiagnosticsSummaryText.Text = "Receiver engine is not installed";
            return;
        }

        if (_engineNeedsDiscoveryUpdate)
        {
            EnvironmentText.Text = $"Receiver engine: {_enginePath}{Environment.NewLine}Compatibility update: required";
            ReceiverSummaryText.Text = "A one-time compatibility update is required for the AirPlay receiver engine.";
            PrimaryButton.Content = "Update receiver";
            PrimaryButton.IsEnabled = true;
            FirewallButton.IsEnabled = false;
            SetStatusBadge("Update needed", BadgeKind.Warning);
            DiagnosticsSummaryText.Text = "Receiver compatibility update is ready";
            return;
        }

        EnvironmentText.Text = $"Receiver engine: {_enginePath}{Environment.NewLine}Network ports: TCP/UDP 35000–35002; mDNS: UDP 5353; firewall profile: Private";
        FirewallButton.IsEnabled = !_receiver.IsRunning && !_installing;
        DiagnosticsSummaryText.Text = "Receiver log and troubleshooting details";
        ApplyReceiverState(_airPlayState);
    }

    private async void PrimaryButton_Click(object sender, RoutedEventArgs e)
    {
        if (_installing)
        {
            return;
        }

        if (SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly)
        {
            if (_bluetoothAudio.IsRunning)
            {
                await StopBluetoothAudioAsync();
            }
            else
            {
                await StartBluetoothAudioAsync();
            }

            return;
        }

        if (_enginePath is null || _engineNeedsDiscoveryUpdate)
        {
            await InstallEngineAsync();
            return;
        }

        if (_receiver.IsRunning)
        {
            await StopReceiverAsync();
        }
        else
        {
            await StartReceiverAsync();
        }
    }

    private async Task InstallEngineAsync()
    {
        var isDiscoveryUpdate = _engineNeedsDiscoveryUpdate;
        var scriptPath = EngineDiscovery.FindScript("Install-ReceiverEngine.ps1");
        if (scriptPath is null)
        {
            ShowError("The receiver setup file is missing. Build or download a complete MirrorSpeaker release and try again.");
            return;
        }

        _installing = true;
        SetOptionsEnabled(false);
        PrimaryButton.IsEnabled = false;
        FirewallButton.IsEnabled = false;
        InstallProgressPanel.Visibility = Visibility.Visible;
        InstallProgressBar.Value = 1;
        InstallProgressText.Text = "Preparing receiver setup…";
        SetStatusBadge(isDiscoveryUpdate ? "Updating" : "Installing", BadgeKind.Working);
        ReceiverSummaryText.Text = isDiscoveryUpdate
            ? "Updating speaker-mode compatibility. Existing multimedia packages will be reused."
            : "Downloading and preparing the open-source AirPlay receiver. This one-time setup can take several minutes.";
        AppendLog(isDiscoveryUpdate ? "Starting receiver compatibility update." : "Starting receiver engine installation.");

        var progress = new Progress<(int Percentage, string Message)>(value =>
        {
            InstallProgressBar.Value = value.Percentage;
            InstallProgressText.Text = value.Message;
        });

        try
        {
            await _installer.InstallAsync(
                scriptPath,
                EngineDiscovery.InstallRoot,
                progress,
                AppendLog,
                _shutdownToken.Token);
            AppendLog(isDiscoveryUpdate ? "Receiver compatibility update completed." : "Receiver engine installation completed.");
            InstallProgressBar.Value = 100;
            InstallProgressText.Text = "Receiver setup complete.";
            _enginePath = EngineDiscovery.FindUxPlay();
            if (_enginePath is null)
            {
                throw new InvalidOperationException("Setup completed, but MirrorSpeaker could not locate uxplay.exe.");
            }

            _engineNeedsDiscoveryUpdate = EngineDiscovery.RequiresDiscoveryUpdate(_enginePath);
            if (_engineNeedsDiscoveryUpdate)
            {
                throw new InvalidOperationException("Setup completed, but the receiver compatibility update was not recorded.");
            }

            SetStatusBadge("Installed", BadgeKind.Success);
            await Task.Delay(500);
            RefreshEngineState();
        }
        catch (OperationCanceledException) when (_shutdownToken.IsCancellationRequested)
        {
            AppendLog("Receiver setup was cancelled because MirrorSpeaker is closing.");
        }
        catch (Exception exception)
        {
            AppendLog(exception.Message);
            ShowError(exception.Message);
            DiagnosticsExpander.IsExpanded = true;
        }
        finally
        {
            _installing = false;
            SetOptionsEnabled(true);
            PrimaryButton.IsEnabled = true;
            FirewallButton.IsEnabled = _enginePath is not null;
        }
    }

    private async Task StartReceiverAsync()
    {
        if (_enginePath is null)
        {
            RefreshEngineState();
            return;
        }

        var deviceName = NormalizeDeviceName(DeviceNameTextBox.Text);
        if (string.IsNullOrWhiteSpace(deviceName))
        {
            ShowError("Enter a name for this PC before starting the receiver.");
            DeviceNameTextBox.Focus();
            return;
        }

        DeviceNameTextBox.Text = deviceName;
        await SaveSettingsFromControlsAsync();
        PairingCard.Visibility = Visibility.Collapsed;
        SetOptionsEnabled(false);
        FirewallButton.IsEnabled = false;

        try
        {
            var requirePin = RequirePinCheckBox.IsChecked == true;
            var pairingPin = requirePin
                ? RandomNumberGenerator.GetInt32(1000, 10_000).ToString("D4", System.Globalization.CultureInfo.InvariantCulture)
                : null;
            var launchSettings = new ReceiverOptions(
                deviceName: deviceName,
                basePort: 35000,
                requirePin: requirePin,
                fullscreen: FullscreenCheckBox.IsChecked == true,
                lowLatency: LowLatencyCheckBox.IsChecked == true,
                videoSink: VideoSink.Direct3D11,
                audioSink: AudioSink.Wasapi,
                pairingPin: pairingPin,
                contentMode: ReceiverContentMode.ScreenAndAudio);
            AppendLog("Starting AirPlay receiver mode.");
            await _receiver.StartAsync(_enginePath, launchSettings);

            if (pairingPin is not null)
            {
                PairingCodeText.Text = pairingPin;
                PairingCard.Visibility = Visibility.Visible;
            }

            await Task.Delay(800);
            if (_receiver.IsRunning && _airPlayState == ReceiverState.Starting)
            {
                ApplyReceiverState(ReceiverState.Ready);
            }
        }
        catch (Exception exception)
        {
            AppendLog(exception.ToString());
            ShowError($"The receiver could not start: {exception.Message}");
            SetOptionsEnabled(true);
            FirewallButton.IsEnabled = true;
            DiagnosticsExpander.IsExpanded = true;
        }
    }

    private async Task StopReceiverAsync()
    {
        PrimaryButton.IsEnabled = false;
        try
        {
            await _receiver.StopAsync();
        }
        catch (Exception exception)
        {
            AppendLog(exception.ToString());
            ShowError($"The receiver did not stop cleanly: {exception.Message}");
        }
        finally
        {
            PrimaryButton.IsEnabled = true;
            SetOptionsEnabled(true);
            FirewallButton.IsEnabled = _enginePath is not null;
            PairingCard.Visibility = Visibility.Collapsed;
        }
    }

    private async Task StartBluetoothAudioAsync()
    {
        // Re-read Windows' parent Bluetooth device records immediately before
        // starting. This lets an already-connected phone win over a stale or
        // merely paired selection.
        await RefreshBluetoothDevicesAsync();
        await RefreshBluetoothOutputAsync(logOutput: true);
        if (BluetoothDeviceComboBox.SelectedItem is not BluetoothAudioDevice selectedDevice)
        {
            ShowError("Windows is not exposing an iPhone audio endpoint. Confirm the iPhone appears in Bluetooth settings, then click Refresh phones.");
            return;
        }

        _settings.BluetoothDeviceId = selectedDevice.Id;
        await SaveSettingsFromControlsAsync();
        PairingCard.Visibility = Visibility.Collapsed;
        SetOptionsEnabled(false);
        FirewallButton.IsEnabled = false;

        try
        {
            AppendLog($"Starting Bluetooth speaker mode for {selectedDevice.Name}.");
            await _bluetoothAudio.StartAsync(selectedDevice);
        }
        catch (Exception exception)
        {
            AppendLog(exception.ToString());
            ShowError($"Bluetooth speaker mode could not start: {exception.Message}");
            SetOptionsEnabled(true);
            DiagnosticsExpander.IsExpanded = true;
        }
    }

    private async Task StopBluetoothAudioAsync()
    {
        PrimaryButton.IsEnabled = false;
        try
        {
            await _bluetoothAudio.StopAsync();
        }
        catch (Exception exception)
        {
            AppendLog(exception.ToString());
            ShowError($"Bluetooth speaker mode did not stop cleanly: {exception.Message}");
        }
        finally
        {
            PrimaryButton.IsEnabled = true;
            SetOptionsEnabled(true);
            PairingCard.Visibility = Visibility.Collapsed;
        }
    }

    private async void FirewallButton_Click(object sender, RoutedEventArgs e)
    {
        if (_enginePath is null)
        {
            ShowError("Install the receiver engine before configuring Windows Firewall.");
            return;
        }

        FirewallButton.IsEnabled = false;
        AppendLog("Requesting permission to add Private-network firewall rules.");
        try
        {
            await FirewallController.ConfigureAsync();
            AppendLog("Windows Firewall rules are ready for Private networks.");
            MessageBox.Show(
                this,
                "MirrorSpeaker is allowed through Windows Firewall on Private networks.",
                "Firewall ready",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode == 1223)
        {
            AppendLog("Windows Firewall setup was cancelled.");
        }
        catch (Exception exception)
        {
            AppendLog(exception.Message);
            ShowError(exception.Message);
        }
        finally
        {
            FirewallButton.IsEnabled = !_receiver.IsRunning;
        }
    }

    private void Receiver_OutputReceived(object? sender, string line)
    {
        Dispatcher.BeginInvoke(() => AppendLog(line));
    }

    private void Receiver_StateChanged(object? sender, ReceiverState state)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (ReferenceEquals(sender, _bluetoothAudio))
            {
                // A WinRT state callback can be queued just before Stop or a
                // recovery transition. Read the controller's current state so
                // a stale callback cannot turn the UI green again.
                _bluetoothState = _bluetoothAudio.CurrentState;
                if (SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly)
                {
                    ApplyReceiverState(_bluetoothState);
                }
            }
            else
            {
                _airPlayState = state;
                if (SelectedReceiverMode != AppReceiverMode.BluetoothAudioOnly)
                {
                    ApplyReceiverState(state);
                }
            }
        });
    }

    private void Receiver_PairingCodeReceived(object? sender, string code)
    {
        Dispatcher.BeginInvoke(() =>
        {
            PairingCodeText.Text = code;
            PairingCard.Visibility = Visibility.Visible;
            SetStatusBadge("Pairing", BadgeKind.Working);
            ReceiverSummaryText.Text = "Enter the pairing code on your iPhone to trust this PC.";
        });
    }

    private void ApplyReceiverState(ReceiverState state)
    {
        var mode = SelectedReceiverMode;
        var bluetooth = mode == AppReceiverMode.BluetoothAudioOnly;
        var selectedBluetoothDevice = BluetoothDeviceComboBox.SelectedItem as BluetoothAudioDevice;
        var hasBluetoothDevice = selectedBluetoothDevice is not null;
        var phoneIsConnected = selectedBluetoothDevice?.IsWindowsConnected == true;
        if (bluetooth)
        {
            _bluetoothState = state;
        }
        else
        {
            _airPlayState = state;
        }
        switch (state)
        {
            case ReceiverState.Stopped:
                if (bluetooth && !hasBluetoothDevice)
                {
                    SetStatusBadge("Phone not found", BadgeKind.Warning);
                    ReceiverSummaryText.Text = "Windows is not exposing an iPhone audio connection yet. Check Bluetooth settings, then refresh phones.";
                    PrimaryButton.Content = "Check Bluetooth settings first";
                    PrimaryButton.IsEnabled = false;
                    SetOptionsEnabled(true);
                    PairingCard.Visibility = Visibility.Collapsed;
                    break;
                }

                SetStatusBadge("Stopped", BadgeKind.Neutral);
                ReceiverSummaryText.Text = bluetooth
                    ? phoneIsConnected
                        ? "Windows already reports the iPhone connected. Start Bluetooth speaker mode to open its audio profile; no pairing is needed."
                        : "Windows found the paired iPhone, but it is not currently connected. Start Bluetooth speaker mode to open its audio link."
                    : "Start the receiver, then choose this PC from Screen Mirroring on your iPhone.";
                PrimaryButton.Content = bluetooth
                    ? "Start Bluetooth speaker"
                    : "Start receiver";
                PrimaryButton.IsEnabled = true;
                SetOptionsEnabled(true);
                PairingCard.Visibility = Visibility.Collapsed;
                break;

            case ReceiverState.Starting:
                SetStatusBadge("Starting", BadgeKind.Working);
                ReceiverSummaryText.Text = bluetooth
                    ? phoneIsConnected
                        ? "Reusing the connected iPhone and opening its Bluetooth audio profile…"
                        : "Turning on Windows Bluetooth speaker mode and connecting to the iPhone…"
                    : "Advertising this PC on your Wi-Fi network…";
                PrimaryButton.Content = bluetooth ? "Stop Bluetooth speaker" : "Stop receiver";
                PrimaryButton.IsEnabled = true;
                break;

            case ReceiverState.Reconnecting:
                SetStatusBadge("Reconnecting", BadgeKind.Working);
                ReceiverSummaryText.Text = "The Bluetooth audio link briefly dropped. MirrorSpeaker is reconnecting it automatically…";
                PrimaryButton.Content = "Stop Bluetooth speaker";
                PrimaryButton.IsEnabled = true;
                DiagnosticsExpander.IsExpanded = true;
                break;

            case ReceiverState.Ready:
                if (bluetooth)
                {
                    SetStatusBadge("Needs attention", BadgeKind.Error);
                    ReceiverSummaryText.Text = "Windows has not confirmed that its Bluetooth audio receiver profile opened, so this PC will not appear as an iPhone audio destination yet.";
                    PrimaryButton.Content = IsAnyReceiverRunning ? "Stop Bluetooth speaker" : "Try again";
                    PrimaryButton.IsEnabled = true;
                    DiagnosticsExpander.IsExpanded = true;
                    break;
                }

                SetStatusBadge("Ready", BadgeKind.Success);
                ReceiverSummaryText.Text = "Ready for your iPhone. Open Control Center and tap Screen Mirroring.";
                PrimaryButton.Content = "Stop receiver";
                PrimaryButton.IsEnabled = true;
                break;

            case ReceiverState.Mirroring:
                SetStatusBadge(bluetooth ? "Bluetooth connected" : "Mirroring", BadgeKind.Success);
                ReceiverSummaryText.Text = bluetooth
                    ? BuildBluetoothConnectedSummary()
                    : "Your iPhone is connected. The mirrored screen is open in a separate window.";
                PrimaryButton.Content = bluetooth ? "Stop Bluetooth speaker" : "Stop receiver";
                PairingCard.Visibility = Visibility.Collapsed;
                break;

            case ReceiverState.Error:
                SetStatusBadge("Needs attention", BadgeKind.Error);
                ReceiverSummaryText.Text = bluetooth
                    ? phoneIsConnected
                        ? "Windows sees the iPhone's general Bluetooth connection, but could not open its separate Bluetooth audio receiver profile. This PC therefore will not appear as an iPhone audio destination yet; no re-pairing is needed."
                        : "Windows found the iPhone, but could not open its Bluetooth audio receiver profile. This PC therefore will not appear as an iPhone audio destination yet."
                    : "The receiver reported a problem. Open Diagnostics below for details.";
                PrimaryButton.Content = IsAnyReceiverRunning
                    ? bluetooth ? "Stop Bluetooth speaker" : "Stop receiver"
                    : "Try again";
                PrimaryButton.IsEnabled = true;
                DiagnosticsExpander.IsExpanded = true;
                break;
        }
    }

    private void Settings_Changed(object sender, RoutedEventArgs e)
    {
        if (!_windowLoaded)
        {
            return;
        }

        UpdateInstructionName();
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private async void ReceiverModeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_windowLoaded)
        {
            return;
        }

        UpdateReceiverModeUi();
        RefreshEngineState();
        if (SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly)
        {
            await RefreshBluetoothDevicesAsync();
            await RefreshBluetoothOutputAsync();
        }

        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private async void Window_Activated(object? sender, EventArgs e)
    {
        if (!_windowLoaded
            || SelectedReceiverMode != AppReceiverMode.BluetoothAudioOnly)
        {
            return;
        }

        await RefreshBluetoothOutputAsync();
        if (IsAnyReceiverRunning
            || _refreshingBluetoothDevices
            || DateTime.UtcNow - _lastBluetoothRefreshUtc < TimeSpan.FromSeconds(2))
        {
            return;
        }

        await RefreshBluetoothDevicesAsync();
    }

    private async void RefreshBluetoothDevicesButton_Click(object sender, RoutedEventArgs e)
    {
        await RefreshBluetoothDevicesAsync();
    }

    private void BluetoothDeviceComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateInstructionName();
        if (!_windowLoaded || BluetoothDeviceComboBox.SelectedItem is not BluetoothAudioDevice device)
        {
            return;
        }

        _settings.BluetoothDeviceId = device.Id;
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void OpenBluetoothSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo("ms-settings:bluetooth") { UseShellExecute = true });
            BluetoothDeviceHelpText.Text = "If Windows shows iPhone as Connected, return and click Refresh phones. MirrorSpeaker will reuse it without pairing again.";
        }
        catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
        {
            ShowError($"Windows Bluetooth settings could not be opened: {exception.Message}");
        }
    }

    private Task RefreshBluetoothDevicesAsync()
    {
        if (_bluetoothRefreshTask is { IsCompleted: false })
        {
            return _bluetoothRefreshTask;
        }

        _bluetoothRefreshTask = RefreshBluetoothDevicesCoreAsync();
        return _bluetoothRefreshTask;
    }

    private async Task RefreshBluetoothDevicesCoreAsync()
    {
        _refreshingBluetoothDevices = true;
        RefreshBluetoothDevicesButton.IsEnabled = false;
        BluetoothDeviceHelpText.Text = "Checking Windows' connected Bluetooth phones…";
        var selectedId = BluetoothDeviceComboBox.SelectedItem is BluetoothAudioDevice current
            ? current.Id
            : _settings.BluetoothDeviceId;

        try
        {
            var devices = await BluetoothAudioController.FindDevicesAsync();
            BluetoothDeviceComboBox.ItemsSource = devices;
            var savedDevice = devices.FirstOrDefault(device =>
                string.Equals(device.Id, selectedId, StringComparison.OrdinalIgnoreCase));
            var selectedDevice = savedDevice?.IsWindowsConnected == true
                ? savedDevice
                : devices.FirstOrDefault(device => device.IsWindowsConnected)
                  ?? savedDevice
                  ?? devices.FirstOrDefault();
            BluetoothDeviceComboBox.SelectedItem = selectedDevice;

            if (devices.Count == 0)
            {
                BluetoothDeviceHelpText.Text = "No compatible iPhone audio connection was found. Confirm iPhone is Connected in Windows Bluetooth settings, then refresh.";
                AppendLog("No compatible Bluetooth audio source was found.");
            }
            else
            {
                var connectedCount = devices.Count(device => device.IsWindowsConnected);
                BluetoothDeviceHelpText.Text = selectedDevice switch
                {
                    { IsWindowsConnected: true } =>
                        $"{selectedDevice.Name}'s general Bluetooth link is connected. MirrorSpeaker will reuse it and attempt to open Windows' separate audio receiver profile—no pairing needed.",
                    _ =>
                        $"{selectedDevice?.Name ?? "iPhone"} is paired, but Windows does not currently report it connected."
                };
                AppendLog(
                    $"Found {devices.Count} Bluetooth audio phone{(devices.Count == 1 ? string.Empty : "s")}; Windows reports {connectedCount} connected.");
            }

            if (SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly && !IsAnyReceiverRunning)
            {
                ApplyReceiverState(ReceiverState.Stopped);
            }
        }
        catch (Exception exception)
        {
            BluetoothDeviceComboBox.ItemsSource = null;
            BluetoothDeviceHelpText.Text = "Windows could not list Bluetooth phones. Make sure Bluetooth is turned on, then refresh.";
            AppendLog($"Bluetooth device search failed: {exception}");
            if (SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly)
            {
                SetStatusBadge("Bluetooth unavailable", BadgeKind.Warning);
            }
        }
        finally
        {
            _lastBluetoothRefreshUtc = DateTime.UtcNow;
            _refreshingBluetoothDevices = false;
            RefreshBluetoothDevicesButton.IsEnabled = !IsAnyReceiverRunning;
        }
    }

    private async void SaveTimer_Tick(object? sender, EventArgs e)
    {
        _saveTimer.Stop();
        await SaveSettingsFromControlsAsync();
    }

    private async Task SaveSettingsFromControlsAsync()
    {
        _settings.DeviceName = NormalizeDeviceName(DeviceNameTextBox.Text);
        _settings.RequirePin = RequirePinCheckBox.IsChecked == true;
        _settings.LowLatency = LowLatencyCheckBox.IsChecked == true;
        _settings.Fullscreen = FullscreenCheckBox.IsChecked == true;
        _settings.ContentMode = SelectedReceiverMode;
        if (BluetoothDeviceComboBox.SelectedItem is BluetoothAudioDevice bluetoothDevice)
        {
            _settings.BluetoothDeviceId = bluetoothDevice.Id;
        }

        try
        {
            await _settingsService.SaveAsync(_settings);
        }
        catch (IOException exception)
        {
            AppendLog($"Could not save settings: {exception.Message}");
        }
        catch (UnauthorizedAccessException exception)
        {
            AppendLog($"Could not save settings: {exception.Message}");
        }
    }

    private void UpdateInstructionName()
    {
        if (SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly)
        {
            var phoneName = BluetoothDeviceComboBox.SelectedItem is BluetoothAudioDevice device
                ? device.Name
                : "your iPhone";
            InstructionDeviceNameText.Text = $"After the status says Bluetooth connected, play TikTok on {phoneName}.";
            return;
        }

        var name = NormalizeDeviceName(DeviceNameTextBox.Text);
        if (string.IsNullOrWhiteSpace(name))
        {
            name = "this PC";
        }

        InstructionDeviceNameText.Text = $"Choose “{name}”.";
    }

    private void UpdateReceiverModeUi()
    {
        var bluetooth = SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly;
        AirPlayIdentityPanel.Visibility = bluetooth ? Visibility.Collapsed : Visibility.Visible;
        AirPlayOptionsPanel.Visibility = bluetooth ? Visibility.Collapsed : Visibility.Visible;
        BluetoothOptionsPanel.Visibility = bluetooth ? Visibility.Visible : Visibility.Collapsed;
        MirroringOptionsPanel.Visibility = bluetooth ? Visibility.Collapsed : Visibility.Visible;
        InstructionNoteBorder.Visibility = bluetooth ? Visibility.Collapsed : Visibility.Visible;
        OpenSettingsButton.Content = bluetooth ? "Open sound settings" : "Open network settings";

        if (bluetooth)
        {
            ReceiverModeDescriptionText.Text = "Play iPhone audio through Windows Bluetooth. TikTok keeps video on the phone, and Wi-Fi is not required.";
            InstructionConnectionRequirementText.Text = "Bluetooth is used for audio; the iPhone and PC do not need the same Wi-Fi network.";
            InstructionStepOneTitleText.Text = "Use the connected iPhone";
            InstructionStepOneDetailText.Text = "MirrorSpeaker checks Windows' connected Bluetooth devices first and reuses the iPhone—no re-pairing.";
            InstructionStepTwoTitleText.Text = "Open Bluetooth audio";
            InstructionStepTwoDetailText.Text = "MirrorSpeaker asks Windows to enable and open its separate audio receiver profile.";
            InstructionStepThreeTitleText.Text = "Play TikTok normally";
        }
        else
        {
            ReceiverModeDescriptionText.Text = "Mirror the iPhone display and play its audio through this PC using AirPlay.";
            InstructionConnectionRequirementText.Text = "Keep your iPhone and PC on the same Wi-Fi network.";
            InstructionStepOneTitleText.Text = "Start the receiver";
            InstructionStepOneDetailText.Text = "Wait until the status says Ready.";
            InstructionStepTwoTitleText.Text = "Open Control Center";
            InstructionStepTwoDetailText.Text = "Swipe down from the top-right corner.";
            InstructionStepThreeTitleText.Text = "Tap Screen Mirroring";
            InstructionNoteText.Text = "Some protected streaming video cannot be mirrored. Your iPhone screen, photos, presentations, games, and most apps work normally.";
        }

        UpdateInstructionName();
    }

    private async Task RefreshBluetoothOutputAsync(bool logOutput = false)
    {
        try
        {
            var output = await AudioOutputInspector.GetDefaultAsync();
            var outputChanged = !string.Equals(
                output?.Id,
                _audioOutputInfo?.Id,
                StringComparison.OrdinalIgnoreCase);
            _audioOutputInfo = output;

            if (output is not null && (logOutput || outputChanged))
            {
                AppendLog($"Windows audio output: {output.Name}.");
            }

            if (_bluetoothState == ReceiverState.Mirroring
                && SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly)
            {
                ReceiverSummaryText.Text = BuildBluetoothConnectedSummary();
            }
        }
        catch (Exception exception)
        {
            _audioOutputInfo = null;
            AppendLog($"Windows audio output could not be identified: {exception.Message}");
        }
    }

    private string BuildBluetoothConnectedSummary() =>
        _audioOutputInfo switch
        {
            { } output =>
                $"The iPhone is connected by Bluetooth and will play through {output.Name}.",
            _ =>
                "The iPhone is connected by Bluetooth. Its audio will use the current Windows output."
        };

    private AppReceiverMode SelectedReceiverMode => ReceiverModeComboBox.SelectedIndex switch
    {
        1 => AppReceiverMode.BluetoothAudioOnly,
        _ => AppReceiverMode.ScreenAndAudio
    };

    private bool IsAnyReceiverRunning => _receiver.IsRunning || _bluetoothAudio.IsRunning;

    private static string NormalizeDeviceName(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var cleaned = new string(value
            .Where(character => !char.IsControl(character))
            .ToArray())
            .Trim();
        return cleaned.Length <= 48 ? cleaned : cleaned[..48];
    }

    private void SetOptionsEnabled(bool enabled)
    {
        DeviceNameTextBox.IsEnabled = enabled;
        ReceiverModeComboBox.IsEnabled = enabled;
        RequirePinCheckBox.IsEnabled = enabled;
        LowLatencyCheckBox.IsEnabled = enabled;
        FullscreenCheckBox.IsEnabled = enabled;
        BluetoothDeviceComboBox.IsEnabled = enabled;
        RefreshBluetoothDevicesButton.IsEnabled = enabled && !_refreshingBluetoothDevices;
        OpenBluetoothSettingsButton.IsEnabled = enabled;
    }

    private void AppendLog(string line)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => AppendLog(line));
            return;
        }

        var entry = $"[{DateTime.Now:HH:mm:ss}] {line}{Environment.NewLine}";
        LogTextBox.AppendText(entry);
        if (LogTextBox.Text.Length > 180_000)
        {
            LogTextBox.Text = LogTextBox.Text[^120_000..];
        }

        LogTextBox.ScrollToEnd();
    }

    private void SetStatusBadge(string text, BadgeKind kind)
    {
        var (background, foreground, dot) = kind switch
        {
            BadgeKind.Success => (Color.FromRgb(231, 248, 239), Color.FromRgb(23, 103, 67), Color.FromRgb(34, 157, 100)),
            BadgeKind.Warning => (Color.FromRgb(255, 244, 229), Color.FromRgb(140, 85, 0), Color.FromRgb(230, 138, 0)),
            BadgeKind.Working => (Color.FromRgb(234, 240, 255), Color.FromRgb(42, 82, 169), Color.FromRgb(50, 103, 227)),
            BadgeKind.Error => (Color.FromRgb(255, 235, 235), Color.FromRgb(157, 39, 39), Color.FromRgb(215, 63, 63)),
            _ => (Color.FromRgb(239, 242, 247), Color.FromRgb(82, 93, 112), Color.FromRgb(130, 140, 156))
        };

        StatusBadge.Background = new SolidColorBrush(background);
        StatusBadgeText.Foreground = new SolidColorBrush(foreground);
        StatusDot.Fill = new SolidColorBrush(dot);
        StatusBadgeText.Text = text;
    }

    private void ShowError(string message)
    {
        SetStatusBadge("Needs attention", BadgeKind.Error);
        MessageBox.Show(this, message, "MirrorSpeaker", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    private void CopyLogButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(string.IsNullOrEmpty(LogTextBox.Text) ? "No MirrorSpeaker diagnostics have been recorded." : LogTextBox.Text);
        }
        catch (System.Runtime.InteropServices.COMException exception)
        {
            ShowError($"Windows could not access the clipboard: {exception.Message}");
        }
    }

    private void OpenNetworkSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        var openingSoundSettings = SelectedReceiverMode == AppReceiverMode.BluetoothAudioOnly;
        try
        {
            Process.Start(new ProcessStartInfo(
                openingSoundSettings ? "ms-settings:sound" : "ms-settings:network-status")
            {
                UseShellExecute = true
            });
        }
        catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
        {
            ShowError(
                $"Windows {(openingSoundSettings ? "sound" : "network")} settings could not be opened: {exception.Message}");
        }
    }

    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_closeAllowed)
        {
            return;
        }

        e.Cancel = true;
        _closeAllowed = true;
        _shutdownToken.Cancel();
        try
        {
            _saveTimer.Stop();
            await SaveSettingsFromControlsAsync();
        }
        catch (Exception exception)
        {
            Debug.WriteLine(exception);
        }

        try
        {
            await _receiver.StopAsync();
        }
        catch (Exception exception)
        {
            Debug.WriteLine(exception);
        }

        try
        {
            await _bluetoothAudio.StopAsync();
        }
        catch (Exception exception)
        {
            Debug.WriteLine(exception);
        }
        finally
        {
            _shutdownToken.Dispose();
            Close();
        }
    }

    private enum BadgeKind
    {
        Neutral,
        Success,
        Warning,
        Working,
        Error
    }
}
