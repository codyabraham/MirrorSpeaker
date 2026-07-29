using AirMirror.Core;

namespace AirMirror.App.Models;

internal enum AppReceiverMode
{
    ScreenAndAudio = 0,
    BluetoothAudioOnly = 1,
    AirPlayAudioOnly = 2
}

internal sealed class UserSettings
{
    public string DeviceName { get; set; } = $"{Environment.MachineName} {ProductIdentity.Name}";

    public bool RequirePin { get; set; } = true;

    public bool LowLatency { get; set; } = true;

    public bool Fullscreen { get; set; }

    // Values 0 and 1 intentionally migrate settings from earlier releases: the old
    // audio-only selection becomes Bluetooth, which keeps phone video local.
    public AppReceiverMode ContentMode { get; set; } = AppReceiverMode.ScreenAndAudio;

    public bool SynchronizeAudioWithClientVideo { get; set; } = true;

    public string BluetoothDeviceId { get; set; } = string.Empty;
}
