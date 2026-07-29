using System.Text.RegularExpressions;

namespace AirMirror.Core;

/// <summary>High-level receiver states extracted from UxPlay console output.</summary>
public enum ReceiverState
{
    /// <summary>The receiver is advertised and awaiting a client.</summary>
    Ready,

    /// <summary>A client is actively sending media.</summary>
    Mirroring,

    /// <summary>A PIN is awaiting entry on the Apple device.</summary>
    PairingCode,

    /// <summary>UxPlay reported an error that may require user action.</summary>
    Error
}

/// <summary>A meaningful state transition parsed from one line of UxPlay output.</summary>
/// <param name="State">Interpreted receiver state.</param>
/// <param name="Message">Original trimmed log line.</param>
/// <param name="PairingCode">Four-digit code when <paramref name="State"/> is <see cref="ReceiverState.PairingCode"/>.</param>
public sealed record ReceiverLogEvent(ReceiverState State, string Message, string? PairingCode = null);

/// <summary>Converts UxPlay console lines into UI-friendly state events.</summary>
public sealed partial class ReceiverLogInterpreter
{
    /// <summary>Interprets one standard-output or standard-error line.</summary>
    /// <returns>A state event for a recognized line; otherwise <see langword="null"/>.</returns>
    public ReceiverLogEvent? Interpret(string? line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return null;
        }

        string message = line.Trim();

        Match pinMatch = PinPattern().Match(message);
        if (pinMatch.Success)
        {
            return new ReceiverLogEvent(ReceiverState.PairingCode, message, pinMatch.Groups[1].Value);
        }

        if (ContainsAny(message, "fatal", "error", "failed", "failure", "cannot", "unable to"))
        {
            return new ReceiverLogEvent(ReceiverState.Error, message);
        }

        if (ContainsAny(
                message,
                "starting mirroring",
                "mirroring started",
                "video_renderer started",
                "audio_renderer started",
                "start audio connection",
                "changed audio connection",
                "client connected"))
        {
            return new ReceiverLogEvent(ReceiverState.Mirroring, message);
        }

        if (ContainsAny(
                message,
                "waiting for connections",
                "waiting for connection",
                "server listening",
                "listening for connections",
                "registered service",
                "initialized server socket",
                "client disconnected",
                "stopping mirroring",
                "connection closed"))
        {
            return new ReceiverLogEvent(ReceiverState.Ready, message);
        }

        return null;
    }

    private static bool ContainsAny(string input, params string[] values) =>
        values.Any(value => input.Contains(value, StringComparison.OrdinalIgnoreCase));

    [GeneratedRegex(@"(?:pin|pairing\s+code)[^0-9]{0,24}([0-9]{4})(?![0-9])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PinPattern();
}
