using System.Text.Json;
using System.IO;
using AirMirror.App.Models;
using AirMirror.Core;

namespace AirMirror.App.Services;

internal sealed class SettingsService
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _settingsPath;
    private readonly SemaphoreSlim _saveLock = new(1, 1);

    public SettingsService()
    {
        _settingsPath = Path.Combine(AppStorage.UserDataRoot, "settings.json");
    }

    public async Task<UserSettings> LoadAsync()
    {
        try
        {
            if (!File.Exists(_settingsPath))
            {
                return new UserSettings();
            }

            await using var stream = File.OpenRead(_settingsPath);
            var settings = await JsonSerializer.DeserializeAsync<UserSettings>(stream, SerializerOptions)
                ?? new UserSettings();
            settings.DeviceName = ProductIdentity.MigrateLegacyDefaultDeviceName(
                settings.DeviceName,
                Environment.MachineName);
            return settings;
        }
        catch (JsonException)
        {
            return new UserSettings();
        }
        catch (IOException)
        {
            return new UserSettings();
        }
        catch (UnauthorizedAccessException)
        {
            return new UserSettings();
        }
    }

    public async Task SaveAsync(UserSettings settings)
    {
        var snapshot = new UserSettings
        {
            DeviceName = settings.DeviceName,
            RequirePin = settings.RequirePin,
            LowLatency = settings.LowLatency,
            Fullscreen = settings.Fullscreen,
            ContentMode = settings.ContentMode,
            SynchronizeAudioWithClientVideo = settings.SynchronizeAudioWithClientVideo,
            BluetoothDeviceId = settings.BluetoothDeviceId
        };

        await _saveLock.WaitAsync();
        string? temporaryPath = null;
        try
        {
            var directory = Path.GetDirectoryName(_settingsPath)
                ?? throw new InvalidOperationException("The settings folder is unavailable.");
            Directory.CreateDirectory(directory);

            temporaryPath = Path.Combine(
                directory,
                $".{Path.GetFileName(_settingsPath)}.{Guid.NewGuid():N}.tmp");
            await using (var stream = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             4096,
                             FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, snapshot, SerializerOptions);
                await stream.FlushAsync();
                stream.Flush(flushToDisk: true);
            }

            if (File.Exists(_settingsPath))
            {
                File.Replace(temporaryPath, _settingsPath, destinationBackupFileName: null, ignoreMetadataErrors: true);
            }
            else
            {
                File.Move(temporaryPath, _settingsPath);
            }

            temporaryPath = null;
        }
        finally
        {
            if (temporaryPath is not null && File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }

            _saveLock.Release();
        }
    }
}
