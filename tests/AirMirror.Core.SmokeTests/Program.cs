using AirMirror.Core;

var tests = new (string Name, Func<Task> Run)[]
{
    ("command arguments are complete and injection-safe", TestCommandArguments),
    ("port boundaries are validated", TestPortValidation),
    ("UxPlay log lines produce receiver states", TestLogInterpreter),
    ("engine lookup honors injected candidates and environment", TestEngineLookup),
    ("settings survive atomic JSON replacement", TestSettingsRoundTrip),
    ("legacy default receiver names migrate safely", TestLegacyBrandMigration),
    ("wireless Windows outputs are identified", TestAudioOutputClassification)
};

int failures = 0;
foreach ((string name, Func<Task> run) in tests)
{
    try
    {
        await run();
        Console.WriteLine($"PASS: {name}");
    }
    catch (Exception exception)
    {
        failures++;
        Console.Error.WriteLine($"FAIL: {name}\n{exception}");
    }
}

Console.WriteLine($"{tests.Length - failures}/{tests.Length} smoke tests passed.");
return failures == 0 ? 0 : 1;

static Task TestCommandArguments()
{
    const string hostileName = "Office Screen & calc.exe \"quoted\"";
    var options = new ReceiverOptions(
        hostileName,
        42000,
        requirePin: true,
        fullscreen: true,
        lowLatency: true,
        VideoSink.Direct3D11,
        AudioSink.Wasapi);

    var startInfo = UxPlayCommandBuilder.CreateStartInfo(@"C:\Air Mirror\uxplay.exe", options);
    string[] arguments = startInfo.ArgumentList.ToArray();

    Equal(@"C:\Air Mirror\uxplay.exe", startInfo.FileName);
    False(startInfo.UseShellExecute, "The process must not invoke a shell.");
    Equal(hostileName, arguments[1]);
    Equal(1, arguments.Count(argument => argument == hostileName));
    Equal("0", startInfo.Environment["AIRMIRROR_RAOP_ONLY"]);
    ContainsInOrder(arguments, "-n", hostileName, "-nh", "-p", "42000", "-nofreeze", "-pin", "-reg", "-fs", "-vsync", "no", "-vs", "d3d11videosink", "-as", "wasapisink");
    Equal(string.Empty, startInfo.Arguments);

    var fixedPin = new ReceiverOptions(requirePin: true, pairingPin: "0834");
    string[] fixedPinArguments = UxPlayCommandBuilder.CreateStartInfo("uxplay.exe", fixedPin).ArgumentList.ToArray();
    ContainsConsecutive(fixedPinArguments, "-pin", "0834", "-reg");
    Throws<ArgumentException>(() => new ReceiverOptions(requirePin: true, pairingPin: "12x4"));
    Throws<ArgumentException>(() => new ReceiverOptions(requirePin: false, pairingPin: "1234"));

    var audioOnly = new ReceiverOptions(
        fullscreen: true,
        lowLatency: true,
        videoSink: VideoSink.Direct3D11,
        audioSink: AudioSink.Wasapi,
        contentMode: ReceiverContentMode.AudioOnly);
    string[] audioOnlyArguments = UxPlayCommandBuilder.CreateStartInfo("uxplay.exe", audioOnly).ArgumentList.ToArray();
    Equal(
        "1",
        UxPlayCommandBuilder.CreateStartInfo("uxplay.exe", audioOnly).Environment["AIRMIRROR_RAOP_ONLY"]);
    ContainsInOrder(
        audioOnlyArguments,
        "-n", "MirrorSpeaker", "-nh", "-p", "35000", "-nofreeze",
        "-vs", "0", "-async", "-as", "wasapisink low-latency=true use-audioclient3=true");
    DoesNotContain(audioOnlyArguments, "-fs", "-vsync", "-a", "d3d11videosink");

    var fastAudioOnly = new ReceiverOptions(
        audioSink: AudioSink.Wasapi,
        contentMode: ReceiverContentMode.AudioOnly,
        synchronizeAudioWithClientVideo: false);
    string[] fastAudioOnlyArguments = UxPlayCommandBuilder.CreateStartInfo("uxplay.exe", fastAudioOnly).ArgumentList.ToArray();
    ContainsConsecutive(
        fastAudioOnlyArguments,
        "-vs", "0", "-async", "no", "-as", "wasapisink low-latency=true use-audioclient3=true");
    return Task.CompletedTask;
}

static Task TestPortValidation()
{
    Equal(1024, new ReceiverOptions(basePort: 1024).BasePort);
    Equal(65533, new ReceiverOptions(basePort: 65533).BasePort);
    Throws<ArgumentOutOfRangeException>(() => new ReceiverOptions(basePort: 1023));
    Throws<ArgumentOutOfRangeException>(() => new ReceiverOptions(basePort: 65534));
    Throws<ArgumentException>(() => new ReceiverOptions("   "));
    return Task.CompletedTask;
}

static Task TestLogInterpreter()
{
    var interpreter = new ReceiverLogInterpreter();

    Equal(ReceiverState.Ready, interpreter.Interpret("Server listening for connections")?.State);
    Equal(ReceiverState.Mirroring, interpreter.Interpret("raop_rtp_mirror starting mirroring")?.State);
    Equal(ReceiverState.Mirroring, interpreter.Interpret("start audio connection, format ALAC 44100/16/2")?.State);
    ReceiverLogEvent? pin = interpreter.Interpret("Please enter PIN: 0834 on the client");
    Equal(ReceiverState.PairingCode, pin?.State);
    Equal("0834", pin?.PairingCode);
    Equal(ReceiverState.Error, interpreter.Interpret("FATAL: DNS registration failed")?.State);
    Equal(ReceiverState.Ready, interpreter.Interpret("Client disconnected!")?.State);
    Equal<ReceiverLogEvent?>(null, interpreter.Interpret("routine diagnostic noise"));
    return Task.CompletedTask;
}

static Task TestEngineLookup()
{
    string injected = Path.GetFullPath(Path.Combine("test-engine", "uxplay.exe"));
    var preferredLocator = new EnginePathLocator(
        applicationDirectory: Path.GetFullPath("app"),
        localApplicationDataDirectory: Path.GetFullPath("local"),
        getEnvironmentVariable: _ => null,
        fileExists: path => string.Equals(path, injected, StringComparison.OrdinalIgnoreCase),
        preferredCandidates: [injected]);
    Equal(injected, preferredLocator.Find());

    string environmentDirectory = Path.GetFullPath("environment-engine");
    string environmentExecutable = Path.Combine(environmentDirectory, "uxplay.exe");
    var environmentLocator = new EnginePathLocator(
        applicationDirectory: Path.GetFullPath("app"),
        localApplicationDataDirectory: Path.GetFullPath("local"),
        getEnvironmentVariable: name => name == "UXPLAY_PATH" ? environmentDirectory : null,
        fileExists: path => string.Equals(path, environmentExecutable, StringComparison.OrdinalIgnoreCase));
    Equal(environmentExecutable, environmentLocator.Find());

    string bundledApplicationDirectory = Path.GetFullPath("bundled-app");
    string bundledExecutable = Path.Combine(
        bundledApplicationDirectory,
        "engine",
        "ucrt64",
        "bin",
        "uxplay.exe");
    var bundledLocator = new EnginePathLocator(
        applicationDirectory: bundledApplicationDirectory,
        localApplicationDataDirectory: Path.GetFullPath("local"),
        getEnvironmentVariable: _ => null,
        fileExists: path => string.Equals(path, bundledExecutable, StringComparison.OrdinalIgnoreCase));
    Equal(bundledExecutable, bundledLocator.Find());
    return Task.CompletedTask;
}

static async Task TestSettingsRoundTrip()
{
    string directory = Path.Combine(Path.GetTempPath(), "AirMirror.Core.SmokeTests", Guid.NewGuid().ToString("N"));
    string filePath = Path.Combine(directory, "settings.json");
    var store = new ReceiverSettingsStore(filePath);

    ReceiverOptions defaults = await store.LoadAsync();
    Equal("MirrorSpeaker", defaults.DeviceName);

    var first = new ReceiverOptions(
        "Living Room",
        41000,
        true,
        false,
        true,
        VideoSink.OpenGL,
        AudioSink.DirectSound,
        contentMode: ReceiverContentMode.AudioOnly,
        synchronizeAudioWithClientVideo: false);
    await store.SaveAsync(first);
    ReceiverOptions loaded = await store.LoadAsync();
    Equal(first.DeviceName, loaded.DeviceName);
    Equal(first.BasePort, loaded.BasePort);
    Equal(first.VideoSink, loaded.VideoSink);
    Equal(ReceiverContentMode.AudioOnly, loaded.ContentMode);
    Equal(false, loaded.SynchronizeAudioWithClientVideo);

    var replacement = new ReceiverOptions("Desk", 43000, false, true, false, VideoSink.Direct3D11, AudioSink.Wasapi);
    await store.SaveAsync(replacement);
    Equal("Desk", (await store.LoadAsync()).DeviceName);
    Equal(0, Directory.EnumerateFiles(directory, "*.tmp").Count());
}

static Task TestLegacyBrandMigration()
{
    Equal(
        "MirrorSpeaker",
        ProductIdentity.MigrateLegacyDefaultDeviceName("AirMirror", "DESKTOP"));
    Equal(
        "DESKTOP MirrorSpeaker",
        ProductIdentity.MigrateLegacyDefaultDeviceName("DESKTOP AirMirror", "DESKTOP"));
    Equal(
        "Living Room",
        ProductIdentity.MigrateLegacyDefaultDeviceName("Living Room", "DESKTOP"));
    return Task.CompletedTask;
}

static Task TestAudioOutputClassification()
{
    True(AudioOutputClassifier.IsLikelyWireless("Speakers (Gaming Wireless Headset)"));
    True(AudioOutputClassifier.IsLikelyWireless("AirPods"));
    True(AudioOutputClassifier.IsLikelyWireless("Bluetooth Headset"));
    False(AudioOutputClassifier.IsLikelyWireless("Speakers (Realtek High Definition Audio)"), "Realtek speakers are not wireless.");
    False(AudioOutputClassifier.IsLikelyWireless("NS-32D311NA17 (NVIDIA High Definition Audio)"), "HDMI audio is not wireless.");
    False(AudioOutputClassifier.IsLikelyWireless(null), "A missing output name is not classified as wireless.");
    return Task.CompletedTask;
}

static void ContainsInOrder<T>(IReadOnlyList<T> actual, params T[] expected)
{
    Equal(expected.Length, actual.Count);
    for (int index = 0; index < expected.Length; index++)
    {
        Equal(expected[index], actual[index]);
    }
}

static void ContainsConsecutive<T>(IReadOnlyList<T> actual, params T[] expected)
{
    for (int start = 0; start <= actual.Count - expected.Length; start++)
    {
        bool found = true;
        for (int offset = 0; offset < expected.Length; offset++)
        {
            if (!EqualityComparer<T>.Default.Equals(actual[start + offset], expected[offset]))
            {
                found = false;
                break;
            }
        }

        if (found)
        {
            return;
        }
    }

    throw new InvalidOperationException("Expected consecutive values were not found.");
}

static void DoesNotContain<T>(IReadOnlyList<T> actual, params T[] unexpected)
{
    foreach (var value in unexpected)
    {
        if (actual.Contains(value))
        {
            throw new InvalidOperationException($"Unexpected value was found: {value}.");
        }
    }
}

static void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
    }
}

static void False(bool value, string message)
{
    if (value)
    {
        throw new InvalidOperationException(message);
    }
}

static void True(bool value)
{
    if (!value)
    {
        throw new InvalidOperationException("Expected true.");
    }
}

static void Throws<TException>(Action action) where TException : Exception
{
    try
    {
        action();
    }
    catch (TException)
    {
        return;
    }

    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}
