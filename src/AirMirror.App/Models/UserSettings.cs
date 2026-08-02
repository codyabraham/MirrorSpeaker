using AirMirror.Core;

namespace AirMirror.App.Models;

internal enum AppReceiverMode
{
    ScreenAndAudio = 0,
    BluetoothAudioOnly = 1
}

internal sealed class UserSettings
{
    public string DeviceName { get; set; } = $"{Environment.MachineName} {ProductIdentity.Name}";

    public bool RequirePin { get; set; } = true;

    public bool LowLatency { get; set; } = true;

    public bool Fullscreen { get; set; }

    // Values 0 and 1 remain stable across releases. The retired AirPlay-speaker
    // value 2 is migrated to normal AirPlay when settings are loaded.
    public AppReceiverMode ContentMode { get; set; } = AppReceiverMode.ScreenAndAudio;

    public string BluetoothDeviceId { get; set; } = string.Empty;
}
