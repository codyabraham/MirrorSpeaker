namespace AirMirror.Core;

/// <summary>Identifies output names that are likely to add a second wireless hop.</summary>
public static class AudioOutputClassifier
{
    private static readonly string[] WirelessMarkers =
    [
        "airpods",
        "bluetooth",
        "wireless",
        "hands-free",
        "headset"
    ];

    /// <summary>Returns whether a friendly endpoint name describes a likely wireless output.</summary>
    public static bool IsLikelyWireless(string? outputName) =>
        !string.IsNullOrWhiteSpace(outputName)
        && WirelessMarkers.Any(marker =>
            outputName.Contains(marker, StringComparison.OrdinalIgnoreCase));
}
