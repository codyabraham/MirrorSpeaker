namespace AirMirror.Core;

/// <summary>Finds a usable UxPlay executable in the bundled, legacy product, and MSYS2 locations.</summary>
public sealed class EnginePathLocator
{
    private readonly string _applicationDirectory;
    private readonly string _localApplicationDataDirectory;
    private readonly Func<string, string?> _getEnvironmentVariable;
    private readonly Func<string, bool> _fileExists;
    private readonly IReadOnlyList<string> _preferredCandidates;

    /// <summary>Creates an engine path locator.</summary>
    /// <param name="applicationDirectory">Directory containing the running application.</param>
    /// <param name="localApplicationDataDirectory">Current user's LocalAppData directory.</param>
    /// <param name="getEnvironmentVariable">Environment lookup, injectable for deterministic tests.</param>
    /// <param name="fileExists">File existence lookup, injectable for deterministic tests.</param>
    /// <param name="preferredCandidates">Paths checked before the standard locations.</param>
    public EnginePathLocator(
        string? applicationDirectory = null,
        string? localApplicationDataDirectory = null,
        Func<string, string?>? getEnvironmentVariable = null,
        Func<string, bool>? fileExists = null,
        IEnumerable<string>? preferredCandidates = null)
    {
        _applicationDirectory = applicationDirectory ?? AppContext.BaseDirectory;
        _localApplicationDataDirectory = localApplicationDataDirectory
            ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        _getEnvironmentVariable = getEnvironmentVariable ?? Environment.GetEnvironmentVariable;
        _fileExists = fileExists ?? File.Exists;
        _preferredCandidates = preferredCandidates?.ToArray() ?? [];
    }

    /// <summary>Returns the first existing UxPlay executable, or <see langword="null"/> when none is found.</summary>
    public string? Find()
    {
        foreach (string candidate in GetCandidatePaths())
        {
            if (_fileExists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        return null;
    }

    /// <summary>Returns the ordered, de-duplicated paths searched by <see cref="Find"/>.</summary>
    public IReadOnlyList<string> GetCandidatePaths()
    {
        var candidates = new List<string>();
        candidates.AddRange(_preferredCandidates.Where(path => !string.IsNullOrWhiteSpace(path)));

        AddEnvironmentPath(candidates, _getEnvironmentVariable("UXPLAY_PATH"));

        candidates.Add(Path.Combine(_applicationDirectory, "engine", "ucrt64", "bin", "uxplay.exe"));
        candidates.Add(Path.Combine(_applicationDirectory, "engine", "uxplay.exe"));
        candidates.Add(Path.Combine(_applicationDirectory, "runtimes", "win-x64", "native", "uxplay.exe"));
        candidates.Add(Path.Combine(_applicationDirectory, "uxplay.exe"));
        // Retain the original storage identity so existing installations do not
        // download and rebuild the large receiver engine after the public rename.
        candidates.Add(Path.Combine(_localApplicationDataDirectory, ProductIdentity.LegacyName, "engine", "ucrt64", "bin", "uxplay.exe"));
        candidates.Add(Path.Combine(_localApplicationDataDirectory, ProductIdentity.LegacyName, "engine", "msys64", "ucrt64", "bin", "uxplay.exe"));
        candidates.Add(Path.Combine(_localApplicationDataDirectory, ProductIdentity.LegacyName, "engine", "uxplay.exe"));

        candidates.Add(@"C:\msys64\ucrt64\bin\uxplay.exe");
        candidates.Add(@"C:\msys64\mingw64\bin\uxplay.exe");
        candidates.Add(@"C:\msys64\usr\bin\uxplay.exe");

        string? path = _getEnvironmentVariable("PATH");
        if (!string.IsNullOrWhiteSpace(path))
        {
            foreach (string directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                candidates.Add(Path.Combine(directory.Trim('"'), "uxplay.exe"));
            }
        }

        var normalizedCandidates = new List<string>(candidates.Count);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string candidate in candidates)
        {
            try
            {
                string normalized = NormalizeCandidate(candidate);
                if (seen.Add(normalized))
                {
                    normalizedCandidates.Add(normalized);
                }
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
            {
                // An invalid PATH entry must not prevent later valid engine locations from being checked.
            }
        }

        return normalizedCandidates;
    }

    private static void AddEnvironmentPath(List<string> candidates, string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        string path = value.Trim().Trim('"');
        candidates.Add(path);
        if (!path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            candidates.Add(Path.Combine(path, "uxplay.exe"));
        }
    }

    private static string NormalizeCandidate(string candidate)
    {
        string expanded = Environment.ExpandEnvironmentVariables(candidate.Trim().Trim('"'));
        return Path.GetFullPath(expanded);
    }
}
