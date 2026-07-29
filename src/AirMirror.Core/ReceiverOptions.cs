namespace AirMirror.Core;

/// <summary>Chooses the GStreamer video output used by UxPlay.</summary>
public enum VideoSink
{
    /// <summary>Lets GStreamer select an available video output.</summary>
    Automatic,

    /// <summary>Uses the Windows Direct3D 11 video output.</summary>
    Direct3D11,

    /// <summary>Uses GStreamer's OpenGL video output.</summary>
    OpenGL,

    /// <summary>Disables video rendering while leaving the AirPlay stream active.</summary>
    Disabled
}

/// <summary>Chooses the GStreamer audio output used by UxPlay.</summary>
public enum AudioSink
{
    /// <summary>Lets GStreamer select an available audio output.</summary>
    Automatic,

    /// <summary>Uses Windows Audio Session API (WASAPI).</summary>
    Wasapi,

    /// <summary>Uses the legacy Windows DirectSound output.</summary>
    DirectSound,

    /// <summary>Disables audio playback.</summary>
    Disabled
}

/// <summary>Chooses which kind of content the receiver is intended to accept.</summary>
public enum ReceiverContentMode
{
    /// <summary>Receives the mirrored iPhone screen together with its audio.</summary>
    ScreenAndAudio,

    /// <summary>Acts as an AirPlay speaker and does not create a video renderer.</summary>
    AudioOnly
}

/// <summary>Immutable, validated options for a MirrorSpeaker receiver session.</summary>
public sealed class ReceiverOptions
{
    /// <summary>The lowest supported UxPlay port.</summary>
    public const int MinimumBasePort = 1024;

    /// <summary>
    /// The highest allowed base port. UxPlay also reserves the following two ports.
    /// </summary>
    public const int MaximumBasePort = 65533;

    /// <summary>Creates validated receiver options.</summary>
    /// <param name="deviceName">Name advertised in the iPhone Screen Mirroring list.</param>
    /// <param name="basePort">First of three consecutive TCP and UDP ports used by UxPlay.</param>
    /// <param name="requirePin">Whether a new client must complete PIN authentication.</param>
    /// <param name="fullscreen">Whether the mirror opens in fullscreen mode.</param>
    /// <param name="lowLatency">Whether timestamp synchronization is disabled to reduce latency.</param>
    /// <param name="videoSink">Video output selection.</param>
    /// <param name="audioSink">Audio output selection.</param>
    /// <param name="pairingPin">Optional four-digit PIN supplied directly to UxPlay.</param>
    /// <param name="contentMode">Whether this session receives mirroring or acts as an audio-only speaker.</param>
    /// <param name="synchronizeAudioWithClientVideo">Whether audio-only playback uses AirPlay timestamps so video left on the iPhone stays synchronized with PC audio.</param>
    /// <exception cref="ArgumentException">The device name is empty, too long, or contains a control character.</exception>
    /// <exception cref="ArgumentOutOfRangeException">The port or an enum value is outside its supported range.</exception>
    public ReceiverOptions(
        string deviceName = ProductIdentity.Name,
        int basePort = 35000,
        bool requirePin = false,
        bool fullscreen = false,
        bool lowLatency = true,
        VideoSink videoSink = VideoSink.Direct3D11,
        AudioSink audioSink = AudioSink.Wasapi,
        string? pairingPin = null,
        ReceiverContentMode contentMode = ReceiverContentMode.ScreenAndAudio,
        bool synchronizeAudioWithClientVideo = true)
    {
        ArgumentNullException.ThrowIfNull(deviceName);

        string normalizedName = deviceName.Trim();
        if (normalizedName.Length == 0)
        {
            throw new ArgumentException("The device name cannot be empty.", nameof(deviceName));
        }

        if (normalizedName.Length > 64)
        {
            throw new ArgumentException("The device name cannot be longer than 64 characters.", nameof(deviceName));
        }

        if (normalizedName.Any(char.IsControl))
        {
            throw new ArgumentException("The device name cannot contain control characters.", nameof(deviceName));
        }

        if (basePort is < MinimumBasePort or > MaximumBasePort)
        {
            throw new ArgumentOutOfRangeException(
                nameof(basePort),
                basePort,
                $"The base port must be between {MinimumBasePort} and {MaximumBasePort}.");
        }

        if (!Enum.IsDefined(videoSink))
        {
            throw new ArgumentOutOfRangeException(nameof(videoSink));
        }

        if (!Enum.IsDefined(audioSink))
        {
            throw new ArgumentOutOfRangeException(nameof(audioSink));
        }

        if (!Enum.IsDefined(contentMode))
        {
            throw new ArgumentOutOfRangeException(nameof(contentMode));
        }

        if (pairingPin is not null
            && (pairingPin.Length != 4 || pairingPin.Any(character => character is < '0' or > '9')))
        {
            throw new ArgumentException("The pairing PIN must contain exactly four digits.", nameof(pairingPin));
        }

        if (pairingPin is not null && !requirePin)
        {
            throw new ArgumentException("A pairing PIN can only be set when PIN authentication is enabled.", nameof(pairingPin));
        }

        DeviceName = normalizedName;
        BasePort = basePort;
        RequirePin = requirePin;
        Fullscreen = fullscreen;
        LowLatency = lowLatency;
        VideoSink = videoSink;
        AudioSink = audioSink;
        PairingPin = pairingPin;
        ContentMode = contentMode;
        SynchronizeAudioWithClientVideo = synchronizeAudioWithClientVideo;
    }

    /// <summary>Gets the receiver name advertised to nearby Apple devices.</summary>
    public string DeviceName { get; }

    /// <summary>Gets the first of three consecutive TCP and UDP ports reserved by UxPlay.</summary>
    public int BasePort { get; }

    /// <summary>Gets whether first-time clients must authenticate with a PIN.</summary>
    public bool RequirePin { get; }

    /// <summary>Gets whether the mirror window opens fullscreen.</summary>
    public bool Fullscreen { get; }

    /// <summary>Gets whether the receiver is optimized for interactive, low-latency mirroring.</summary>
    public bool LowLatency { get; }

    /// <summary>Gets the selected video output.</summary>
    public VideoSink VideoSink { get; }

    /// <summary>Gets the selected audio output.</summary>
    public AudioSink AudioSink { get; }

    /// <summary>
    /// Gets the optional four-digit PIN supplied directly to UxPlay. When omitted,
    /// UxPlay generates its own terminal-rendered code.
    /// </summary>
    public string? PairingPin { get; }

    /// <summary>Gets whether the receiver handles screen mirroring or audio only.</summary>
    public ReceiverContentMode ContentMode { get; }

    /// <summary>Gets whether audio-only playback keeps the client's video timeline synchronized with PC audio.</summary>
    public bool SynchronizeAudioWithClientVideo { get; }
}
