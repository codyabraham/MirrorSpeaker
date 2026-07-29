using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

namespace AirMirror.App.Services;

internal static class FirewallController
{
    private const string ResourceName = "MirrorSpeaker.Configure-Firewall.ps1";

    public static async Task ConfigureAsync()
    {
        string script = LoadEmbeddedScript();
        string encodedCommand = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Verb = "runas",
            UseShellExecute = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-EncodedCommand");
        startInfo.ArgumentList.Add(encodedCommand);
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Windows Firewall setup could not be started.");
        await process.WaitForExitAsync();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Windows Firewall setup did not complete (code {process.ExitCode}).");
        }
    }

    private static string LoadEmbeddedScript()
    {
        Assembly assembly = typeof(FirewallController).Assembly;
        using Stream stream = assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException("The built-in Windows Firewall setup is unavailable.");
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }
}
