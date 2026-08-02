# MirrorSpeaker for Windows 11

MirrorSpeaker is a small Windows desktop app that turns a PC into an AirPlay screen receiver or an iPhone Bluetooth speaker. It uses Windows' built-in Bluetooth audio receiver for phone-only video apps such as TikTok, and gives [UxPlay](https://github.com/FDH2/UxPlay) a simple native interface for AirPlay mirroring.

[Privacy policy](PRIVACY.md) · [Security policy](SECURITY.md) ·
[Code signing policy](CODE_SIGNING_POLICY.md) · [MIT license](LICENSE)

The public source repository is
[github.com/codyabraham/MirrorSpeaker](https://github.com/codyabraham/MirrorSpeaker).

## What it does

- Mirrors an iPhone screen and audio over the local Wi-Fi network.
- Streams iPhone audio to the PC over Bluetooth without opening a video window or invoking AirPlay.
- Keeps TikTok video playing locally on the iPhone by using a real Bluetooth audio route.
- Shows the active Windows audio output and automatically retries a briefly closed Bluetooth audio profile.
- Appears in the iPhone's **Control Center → Screen Mirroring** list under a configurable name.
- Requires a one-time pairing code for new iPhones by default.
- Offers low-latency and full-screen modes.
- Keeps the command window hidden while showing useful status and errors in the app.
- Uses fixed TCP/UDP ports `35000–35002` and mDNS UDP port `5353`, so firewall access is predictable.
- Stores settings and receiver trust information in the current user's AppData folders.

The mirrored video opens in a separate GStreamer window managed by UxPlay. Keeping the media renderer separate is the most reliable Windows configuration supported by the upstream receiver.

## Build and run

The public source build requires Windows 11 and the .NET 10 LTS SDK. From
PowerShell in this folder:

```powershell
.\scripts\Build-Release.ps1
```

Then run:

```text
dist\win-x64\MirrorSpeaker.exe
```

The published app is framework-dependent and does not bundle Microsoft .NET or
WPF runtime binaries. Running `dist\win-x64\MirrorSpeaker.exe` requires the
Microsoft .NET 10 Desktop Runtime (x64) to be installed.

For development:

```powershell
dotnet run --project .\src\AirMirror.App\AirMirror.App.csproj
```

## Windows installer and portable release

With the pinned Inno Setup 7.0.2 installed, create the per-user Windows
installer, portable ZIP, and SHA-256 checksum file with:

```powershell
.\scripts\Build-Installer.ps1 `
  -Version 1.4.3 `
  -Publisher "MirrorSpeaker Project" `
  -PublisherUrl "https://github.com/codyabraham/MirrorSpeaker"
```

The outputs are written below `artifacts\release`. The installer adds Start
Menu and desktop shortcuts, registers a normal Windows uninstaller, and
supports Inno Setup's silent switches. It first checks for a compatible
Microsoft .NET 10 Desktop Runtime (x64). If that runtime is missing, setup
clearly prompts the user, downloads only the pinned official Microsoft
10.0.10 x64 runtime, verifies its SHA-256 checksum, and runs Microsoft's
runtime installer. An Internet connection and administrator approval for that
Microsoft system prerequisite may therefore be required; MirrorSpeaker itself
remains a per-user installation. The pinned runtime-installer SHA-256 is
`e82fc901c8f52d716293b2bc0830ce0dd254a06268c457a19e8fc503560a84d1`.

The portable ZIP does not download or bundle .NET. Its
`MirrorSpeaker.exe` requires the Microsoft .NET 10 Desktop Runtime (x64) to be
installed before launch. The ZIP uses `portable.flag` so MirrorSpeaker settings
and pairing records stay with the extracted app.

The first public release intentionally does **not** redistribute a prebuilt
receiver engine. AirPlay setup remains an explicit, user-initiated local
source build. A future release may include a pruned, versioned receiver
package built by `scripts\Build-ReceiverPackage.ps1` only after the receiver
has a reproducible public CI build, complete corresponding source, and an
explicit license and legal review. The internal-test override and its
artifacts are never publishable. See
[`docs/RELEASING.md`](docs/RELEASING.md) for the complete signing, licensing,
silent-install, and clean-Windows test checklist.

## First-time setup

For TikTok or normal iPhone audio, choose **Bluetooth speaker — best for TikTok**. MirrorSpeaker checks Windows' Bluetooth-device records first, selects an already-connected iPhone, and reuses it without pairing again. **Connected** beside the phone describes its general Bluetooth link; only the **Bluetooth connected** status badge confirms that Windows also opened the separate audio receiver profile. If that profile does not open, MirrorSpeaker reports a failure and this PC will not appear as an iPhone audio destination yet. If the iPhone is not listed, click **Bluetooth settings**, confirm Windows shows it, return to MirrorSpeaker, and click **Refresh phones**. Bluetooth mode needs neither the AirPlay engine nor a Private Wi-Fi network or firewall exception.

For AirPlay screen mirroring:

1. Open MirrorSpeaker and click **Install receiver engine**. This downloads a pinned UxPlay 1.74 source revision plus official MSYS2/GStreamer packages, builds the receiver locally, and verifies the required audio/video plugins. It does not require administrator access, but it can take several minutes and the full developer-toolchain installation can use roughly 3 GB.
2. Click **Allow through firewall** and approve the Windows administrator prompt. The script adds inbound rules only for the Windows **Private** network profile; it does not disable Windows Firewall.
3. Make sure the PC's current Wi-Fi network is marked **Private** in Windows Settings.
4. Choose **AirPlay**, then start the receiver and wait for **Ready**.
5. Open **Screen Mirroring** on the iPhone and choose the name shown in MirrorSpeaker. If prompted, enter the four-digit code displayed in MirrorSpeaker.

AirPlay requires the iPhone and PC on the same local network. Guest Wi-Fi, VPNs, access-point/client isolation, or VLAN separation can block AirPlay discovery.

## Troubleshooting

If the PC does not appear on the iPhone:

- Confirm MirrorSpeaker says **Ready** and both devices are on the same Wi-Fi/LAN.
- Mark the Windows network as **Private**, then run **Allow through firewall** again.
- Temporarily disconnect VPN software on both devices.
- Avoid a router's guest network and turn off wireless/client isolation.
- Open **Diagnostics** in MirrorSpeaker and look for mDNS, socket, or firewall errors.

If the iPhone connects but video or audio does not appear:

- Stop and restart the receiver.
- Update the graphics and audio drivers in Windows Update.
- Disable **Low-latency mode** when watching video if audio/video synchronization matters more than responsiveness.
- Protected content from the Apple TV app and other DRM-protected services cannot be decrypted by UxPlay. Ordinary screen content, photos, presentations, games, and most apps are the intended use.

For TikTok, use **Bluetooth speaker — best for TikTok**. TikTok may treat AirPlay screen mirroring as external playback and stop its local picture. Bluetooth avoids that AirPlay classification. Windows does not expose codec or buffer controls for this receiver API, so a small wireless delay remains. Using another wireless headset or speaker creates two radio hops and can be less reliable than the PC's built-in speakers or wired headphones. If Windows actually closes the Bluetooth audio profile, MirrorSpeaker makes three bounded reconnection attempts before asking for attention.

## Verification

```powershell
dotnet build .\AirMirror.sln --configuration Release
dotnet run --project .\tests\AirMirror.Core.SmokeTests\AirMirror.Core.SmokeTests.csproj --configuration Release
```

The smoke tests cover safe argument construction, port validation, receiver log/PIN interpretation, engine discovery, settings persistence, and wireless-output classification. A physical iPhone is required for end-to-end Bluetooth audio validation; AirPlay mirroring also requires a local Wi-Fi network.

## Privacy and security

MirrorSpeaker has no telemetry or project-operated cloud service. The screen
stream travels directly from the iPhone to the PC over the local network.
Pairing is enabled by default, and the provided firewall rules apply only to
Private networks. The AirPlay receiver and its dependencies connect to the
network only for the user-requested operations described in the
[privacy policy](PRIVACY.md). Please report vulnerabilities privately as
described in the [security policy](SECURITY.md).

## Code signing policy

MirrorSpeaker has not yet been accepted into the SignPath Foundation
open-source program. Current builds are unsigned and must not be represented
as signed. If the project is accepted, official Windows releases will use:

**Free code signing provided by SignPath.io, certificate by SignPath Foundation**

Code-signing roles are currently assigned as follows:

- Authors: [@codyabraham](https://github.com/codyabraham)
- Reviewers: [@codyabraham](https://github.com/codyabraham)
- Approvers: [@codyabraham](https://github.com/codyabraham)

`MirrorSpeaker Project` is the publisher stored in the product and installer
metadata. A future SignPath signature would instead show `SignPath Foundation`
as the Authenticode certificate signer; the two fields have different
purposes. See the complete [code signing policy](CODE_SIGNING_POLICY.md).

## Upstream and licensing

MirrorSpeaker's original C# and XAML controller code is open source under the
[MIT License](LICENSE). The user-initiated receiver setup obtains and locally
builds the pinned UxPlay revision recorded in
`scripts/Install-ReceiverEngine.ps1`;
UxPlay is GPL-3.0. UxPlay-derived source fragments and patch payloads embedded
in that script are GPL-3.0 material and are not covered by MirrorSpeaker's
root MIT license.

UxPlay also warns that the legal status of its third-party GPL PlayFair
library for handling FairPlay is unclear. MirrorSpeaker repeats that warning
without making a legal determination or representing that redistribution has
been approved. This is one reason the first public release must omit the
prebuilt receiver binary.

The framework-dependent application does not redistribute Microsoft .NET or
WPF runtime binaries. The normal Windows installer can obtain the pinned
Microsoft .NET 10 Desktop Runtime prerequisite directly from Microsoft when it
is missing; the portable ZIP requires that runtime to be installed separately.
The application does include Microsoft's unmodified Windows SDK .NET projection
assemblies needed to call the Windows Bluetooth APIs; their Windows SDK terms
and the remaining SignPath System Library review are disclosed in the
third-party notices.
The user-initiated receiver setup obtains GStreamer and MSYS2 locally, and the
Windows setup and uninstall programs contain Inno Setup-generated code. Each
third-party component remains governed by its respective license. See
[`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt) for the full notices and
receiver redistribution restrictions.
