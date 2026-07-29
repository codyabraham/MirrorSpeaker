using System.IO;
using AirMirror.Core;

namespace AirMirror.App.Services;

internal static class AppStorage
{
    private static readonly bool PortableMode = File.Exists(
        Path.Combine(AppContext.BaseDirectory, "portable.flag"));

    public static bool IsPortable => PortableMode;

    public static string UserDataRoot => PortableMode
        ? Path.Combine(AppContext.BaseDirectory, "data")
        : Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            ProductIdentity.LegacyName);

    public static string EngineRoot => PortableMode
        ? Path.Combine(AppContext.BaseDirectory, "engine")
        : Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            ProductIdentity.LegacyName,
            "engine");
}
