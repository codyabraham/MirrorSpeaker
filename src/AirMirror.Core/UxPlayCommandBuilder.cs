using System.Diagnostics;
using System.Globalization;

namespace AirMirror.Core;

/// <summary>Builds safe UxPlay process invocations from validated receiver options.</summary>
public static class UxPlayCommandBuilder
{
    /// <summary>Creates a process configuration suitable for background execution and log monitoring.</summary>
    /// <param name="executablePath">Full path to the UxPlay executable.</param>
    /// <param name="options">Validated receiver options.</param>
    /// <returns>A process configuration whose arguments are held as individual tokens.</returns>
    public static ProcessStartInfo CreateStartInfo(string executablePath, ReceiverOptions options)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);
        ArgumentNullException.ThrowIfNull(options);

        var result = new ProcessStartInfo
        {
            FileName = executablePath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        // MirrorSpeaker's patched UxPlay build uses this legacy protocol switch to advertise only
        // the RAOP speaker service in audio-only mode. Without it, video apps
        // can mistake the receiver for an external display and stop local video.
        result.Environment["AIRMIRROR_RAOP_ONLY"] =
            options.ContentMode == ReceiverContentMode.AudioOnly ? "1" : "0";

        Add(result, "-n", options.DeviceName);
        result.ArgumentList.Add("-nh");
        Add(result, "-p", options.BasePort.ToString(CultureInfo.InvariantCulture));
        result.ArgumentList.Add("-nofreeze");

        if (options.RequirePin)
        {
            result.ArgumentList.Add("-pin");
            if (options.PairingPin is not null)
            {
                result.ArgumentList.Add(options.PairingPin);
            }
            result.ArgumentList.Add("-reg");
        }

        if (options.ContentMode == ReceiverContentMode.AudioOnly)
        {
            Add(result, "-vs", "0");
            result.ArgumentList.Add("-async");
            if (!options.SynchronizeAudioWithClientVideo)
            {
                result.ArgumentList.Add("no");
            }
        }
        else
        {
            if (options.Fullscreen)
            {
                result.ArgumentList.Add("-fs");
            }

            if (options.LowLatency)
            {
                Add(result, "-vsync", "no");
            }

            string? videoSink = options.VideoSink switch
            {
                VideoSink.Automatic => null,
                VideoSink.Direct3D11 => "d3d11videosink",
                VideoSink.OpenGL => "glimagesink",
                VideoSink.Disabled => "0",
                _ => throw new ArgumentOutOfRangeException(nameof(options), "Unknown video sink.")
            };
            if (videoSink is not null)
            {
                Add(result, "-vs", videoSink);
            }
        }

        string? audioSink = options.AudioSink switch
        {
            AudioSink.Automatic => null,
            AudioSink.Wasapi when options.ContentMode == ReceiverContentMode.AudioOnly
                => "wasapisink low-latency=true use-audioclient3=true",
            AudioSink.Wasapi => "wasapisink",
            AudioSink.DirectSound => "directsoundsink",
            AudioSink.Disabled => "0",
            _ => throw new ArgumentOutOfRangeException(nameof(options), "Unknown audio sink.")
        };
        if (audioSink is not null)
        {
            Add(result, "-as", audioSink);
        }

        return result;
    }

    private static void Add(ProcessStartInfo startInfo, string option, string value)
    {
        startInfo.ArgumentList.Add(option);
        startInfo.ArgumentList.Add(value);
    }
}
