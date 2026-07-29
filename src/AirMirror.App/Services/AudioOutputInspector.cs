using AirMirror.Core;
using Windows.Devices.Enumeration;
using Windows.Media.Devices;

namespace AirMirror.App.Services;

internal sealed record AudioOutputInfo(string Id, string Name, bool IsLikelyWireless);

internal static class AudioOutputInspector
{
    public static async Task<AudioOutputInfo?> GetDefaultAsync()
    {
        var id = MediaDevice.GetDefaultAudioRenderId(AudioDeviceRole.Default);
        if (string.IsNullOrWhiteSpace(id))
        {
            return null;
        }

        var device = await DeviceInformation.CreateFromIdAsync(id);
        if (device is null)
        {
            return null;
        }

        var name = string.IsNullOrWhiteSpace(device.Name)
            ? "Windows default output"
            : device.Name.Trim();
        return new AudioOutputInfo(
            id,
            name,
            AudioOutputClassifier.IsLikelyWireless(name));
    }
}
