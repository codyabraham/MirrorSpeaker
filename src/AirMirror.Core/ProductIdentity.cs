namespace AirMirror.Core;

/// <summary>Defines the public product name and narrowly migrates its former default receiver names.</summary>
public static class ProductIdentity
{
    /// <summary>The public product name.</summary>
    public const string Name = "MirrorSpeaker";

    /// <summary>The stable storage/protocol identity used by earlier releases.</summary>
    public const string LegacyName = "AirMirror";

    /// <summary>
    /// Rebrands only receiver names that match an old generated default.
    /// User-chosen names are returned unchanged.
    /// </summary>
    public static string MigrateLegacyDefaultDeviceName(string? deviceName, string machineName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(machineName);

        string value = deviceName?.Trim() ?? string.Empty;
        if (string.Equals(value, LegacyName, StringComparison.OrdinalIgnoreCase))
        {
            return Name;
        }

        string legacyMachineDefault = $"{machineName} {LegacyName}";
        if (string.Equals(value, legacyMachineDefault, StringComparison.OrdinalIgnoreCase))
        {
            return $"{machineName} {Name}";
        }

        return value;
    }
}
