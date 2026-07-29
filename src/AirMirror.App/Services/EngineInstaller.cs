using System.Diagnostics;

namespace AirMirror.App.Services;

internal sealed class EngineInstaller
{
    public async Task InstallAsync(
        string scriptPath,
        string installRoot,
        IProgress<(int Percentage, string Message)> progress,
        Action<string> output,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);
        startInfo.ArgumentList.Add("-InstallRoot");
        startInfo.ArgumentList.Add(installRoot);

        using var process = new Process { StartInfo = startInfo };
        process.OutputDataReceived += (_, args) => HandleLine(args.Data, progress, output);
        process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                output(args.Data);
            }
        };

        if (!process.Start())
        {
            throw new InvalidOperationException("The receiver setup process could not be started.");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }

            throw;
        }

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Receiver setup did not finish successfully (code {process.ExitCode}). Open Diagnostics for details.");
        }
    }

    private static void HandleLine(
        string? line,
        IProgress<(int Percentage, string Message)> progress,
        Action<string> output)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return;
        }

        const string prefix = "AIRMIRROR_PROGRESS:";
        if (!line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            output(line);
            return;
        }

        var parts = line[prefix.Length..].Split(':', 2);
        if (parts.Length == 2 && int.TryParse(parts[0], out var percentage))
        {
            string message = parts[1].Trim();
            output(message);
            progress.Report((Math.Clamp(percentage, 0, 100), message));
            return;
        }

        output(line);
    }
}
