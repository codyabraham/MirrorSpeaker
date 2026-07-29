using System.IO;
using System.Text.Json;
using AirMirror.Core;

namespace AirMirror.App.Services;

internal static class EngineDiscovery
{
    private const int CurrentPatchLevel = 2;

    public static string InstallRoot => AppStorage.EngineRoot;

    public static string? FindUxPlay()
    {
        var locator = new EnginePathLocator(
            applicationDirectory: AppContext.BaseDirectory,
            localApplicationDataDirectory: Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        return locator.Find();
    }

    public static bool RequiresDiscoveryUpdate(string? executablePath)
    {
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            return false;
        }

        var managedExecutable = Path.Combine(InstallRoot, "ucrt64", "bin", "uxplay.exe");
        if (!string.Equals(
                Path.GetFullPath(executablePath),
                Path.GetFullPath(managedExecutable),
                StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var markerPath = Path.Combine(InstallRoot, ".airmirror-engine.json");
        try
        {
            using var marker = JsonDocument.Parse(File.ReadAllText(markerPath));
            return !marker.RootElement.TryGetProperty("airMirrorPatchLevel", out var patchLevel) ||
                   !patchLevel.TryGetInt32(out var value) ||
                   value < CurrentPatchLevel;
        }
        catch (IOException)
        {
            return true;
        }
        catch (JsonException)
        {
            return true;
        }
    }

    public static string? FindScript(string name)
    {
        var direct = Path.Combine(AppContext.BaseDirectory, "scripts", name);
        if (File.Exists(direct))
        {
            return direct;
        }

        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        for (var index = 0; index < 6 && directory is not null; index++, directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "scripts", name);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }
}
