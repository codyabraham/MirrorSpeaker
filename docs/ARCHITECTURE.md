# Architecture

MirrorSpeaker deliberately separates the Windows controller from the AirPlay/media engine.

### AirPlay path

```text
iPhone
  │ AirPlay legacy mirror protocol + mDNS discovery
  ▼
UxPlay receiver process ── GStreamer ── video window + Windows audio
  ▲
  │ start/stop, arguments, stdout/stderr, pairing PIN
  ▼
MirrorSpeaker WPF controller
```

### Bluetooth speaker path

```text
iPhone -- Bluetooth A2DP audio --> Windows AudioPlaybackConnection --> current PC audio output
                                      ^
                                      | enable/open/stop and device selection
                                      v
                              MirrorSpeaker WPF controller
```

The Bluetooth path uses the Windows 10 build 19041+ audio-receiver API directly. It does not start UxPlay, advertise mDNS services, open receiver ports, or require a firewall exception.

## Projects

- `src/AirMirror.App`: .NET 10 WPF desktop UI, Windows Bluetooth A2DP receiver control, AirPlay process supervision, installation progress, firewall elevation, and diagnostics.
- `src/AirMirror.Core`: platform-light validation, UxPlay command construction, engine discovery, log interpretation, and atomic settings storage.
- `tests/AirMirror.Core.SmokeTests`: dependency-free executable tests suitable for a fresh checkout.

## Receiver runtime

`scripts/Install-ReceiverEngine.ps1` installs a portable MSYS2 UCRT64 environment into `%LOCALAPPDATA%\AirMirror\engine`, builds a pinned UxPlay 1.74 commit with internal mDNS, and verifies the required GStreamer elements. The legacy folder name is intentionally retained so upgrades reuse the existing 1–2 GB engine. The WPF application finds the resulting executable at `ucrt64\bin\uxplay.exe` and prepends that directory to the child process environment.

The default receiver invocation uses:

- `-nh` to advertise exactly the chosen name;
- `-p 35000` for fixed TCP and UDP ports 35000–35002;
- `-nofreeze` to clear stale video after disconnects;
- `-pin #### -reg` with a securely generated per-session code for first-use pairing and a persistent trusted-device register;
- `-vs d3d11videosink` for the Windows-compatible full-screen and rotation path;
- `-as wasapisink` for Windows audio;
- optional `-vsync no` for responsive mirroring and `-fs` for full screen.

## Bluetooth runtime

Bluetooth mode enumerates A2DP audio interfaces with `AudioPlaybackConnection.GetDeviceSelector()` and accepts enabled selector results. It intentionally does not filter on `DeviceInformation.Pairing.IsPaired`, because Windows can report that interface-level flag as false while the parent iPhone is visibly Connected in Settings. MirrorSpeaker joins each audio interface's `System.Devices.ContainerId` to the classic and Bluetooth LE parent records' `System.Devices.Aep.ContainerId`. This allows the UI to recognize an iPhone whose general Bluetooth link is already connected even when its separate classic A2DP transport is not open yet. Connected phones are selected first, but that parent-device **Connected** state is not treated as proof of working audio. MirrorSpeaker calls `StartAsync()` to request that Windows enable the sink and then calls `OpenAsync()` to open only the audio transport, matching Microsoft's documented API sequence. It reports **Bluetooth connected** only after `OpenAsync()` succeeds or Windows raises the connection's `Opened` state. A timeout or unknown initial opening failure leaves the enabled connection alive while bounded background attempts continue, allowing a later phone-initiated connection to succeed. Stopping the mode or closing the app disposes the connection and releases the underlying transport.

Pairing remains a Windows Settings operation because desktop apps cannot use the WinRT pairing method. MirrorSpeaker opens `ms-settings:bluetooth` and refreshes the paired-device list when the user returns. Windows exposes no codec or buffer tuning through `AudioPlaybackConnection`, so the app does not claim zero Bluetooth latency.

Each receiver process also gets a private Windows named event through `AIRMIRROR_STOP_EVENT`. MirrorSpeaker signals it during normal shutdown so UxPlay can unregister its DNS-SD records and send mDNS goodbye packets before exiting; forceful process termination remains a timeout fallback.

## Compatibility identifiers

The source namespaces, `AIRMIRROR_*` environment variables, engine marker, AppData folders, named-event prefix, and firewall rule names retain the product's former internal identifier. They are not public branding. Keeping them stable preserves the installed receiver engine, saved settings, trusted-iPhone registration, and existing firewall rules across the rename to MirrorSpeaker.

All process arguments are passed as individual `ProcessStartInfo.ArgumentList` entries. User-provided receiver names are never concatenated into a shell command.

## Network boundary

The firewall helper adds three inbound, Private-profile-only rules:

- UDP 5353 for multicast DNS discovery;
- TCP 35000–35002 for AirPlay control/media;
- UDP 35000–35002 for AirPlay media.

MirrorSpeaker never disables Windows Firewall and does not create Public-profile exceptions.
