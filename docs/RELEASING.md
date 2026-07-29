# Releasing MirrorSpeaker

This guide is the release checklist for the Windows installer, portable ZIP,
and prebuilt AirPlay receiver engine. Run every command from the repository
root in Windows PowerShell.

Do not publish a release if a command, signature check, source-compliance
gate, or clean-machine test fails.

Project-wide release requirements are also defined in the
[code signing policy](../CODE_SIGNING_POLICY.md),
[privacy policy](../PRIVACY.md), [security policy](../SECURITY.md), and
[third-party notices](../THIRD-PARTY-NOTICES.txt).

## 1. Prerequisites

The build computer needs:

- Windows 11 x64.
- Windows PowerShell 5.1 or later.
- The .NET 10 LTS SDK selected by `global.json`.
- Inno Setup 7.0.2, including `ISCC.exe`. The build finds normal all-user and
  current-user installations automatically and rejects other versions.
- Several gigabytes of free disk space for temporary release files and any
  local receiver-package testing.
- A working receiver engine, normally installed at
  `%LOCALAPPDATA%\AirMirror\engine`, only when testing an internal or future
  prebuilt receiver package. It is not required for the first public
  no-prebuilt-receiver build.
- For a future public prebuilt receiver release, the exact
  corresponding-source archive or archives and the completed legal review.
- For a signed release, an accepted and configured SignPath project connected
  to the public
  [MirrorSpeaker repository](https://github.com/codyabraham/MirrorSpeaker).
- Multi-factor authentication on the maintainer's GitHub and SignPath
  accounts.
- A separate clean Windows 11 VM or physical PC and a physical iPhone for
  final testing.

Check .NET:

```powershell
dotnet --version
```

The result must start with `10.`. If Inno Setup is missing, install it and then
open a new PowerShell window:

```powershell
winget install --id JRSoftware.InnoSetup.7 -e
```

`Build-Installer.ps1` runs the automated smoke tests. The clean Windows 11
test later in this guide is still mandatory because automated tests cannot
prove that Bluetooth, AirPlay, Windows Firewall, shortcuts, or uninstall work
on a user's PC.

## 2. Choose the version and publisher

Use a three- or four-part numeric version such as `1.4.0` or `1.4.0.0`.
Pre-release text such as `1.4.0-beta` is not accepted by the packaging script.
Once a version is public, never replace its files with a different build.
Increase the version instead.

Set the release values at the start of the PowerShell session:

```powershell
$Version = '1.4.0'
$Publisher = 'MirrorSpeaker Project'
$PublisherUrl = 'https://github.com/codyabraham/MirrorSpeaker'
```

`MirrorSpeaker Project` is the selected product-metadata publisher. Keep it
stable and use it consistently in:

- `-Publisher` on every release build.
- The download website and release notes.
- Future Store or WinGet metadata.

Changing publisher identity later makes updates and trust more confusing.
The build writes the supplied publisher and version into both
`MirrorSpeaker.exe` and the installer and fails if they do not match.

The product publisher and certificate signer are different fields.
`MirrorSpeaker Project` is displayed in application file metadata and Windows
**Installed apps**. If SignPath Foundation accepts this project, the
Authenticode certificate subject displayed by Windows will be
`SignPath Foundation`. Do not change the product metadata to `SignPath
Foundation`, because SignPath Foundation does not develop or maintain
MirrorSpeaker.

## 3. Prepare the receiver corresponding source

MirrorSpeaker's prebuilt receiver contains a modified GPL-3.0 UxPlay build and
redistributed GPL/LGPL dependencies. A public binary receiver package must
ship with complete corresponding source for the exact binaries in that
package.

UxPlay-derived source fragments and replacement payloads embedded in
`scripts\Install-ReceiverEngine.ps1` are GPL-3.0 material, not material
covered by MirrorSpeaker's root MIT license. Keep that license boundary
explicit in every source and binary release.

UxPlay's upstream disclaimer says it uses a third-party GPL PlayFair library
for FairPlay handling and that the legal status of that library is unclear.
MirrorSpeaker does not make a legal determination or represent that
redistribution is legally approved. Review the pinned upstream disclaimer and
[`THIRD-PARTY-NOTICES.txt`](../THIRD-PARTY-NOTICES.txt) before any release
work.

**Current public-release status: DO NOT REDISTRIBUTE the prebuilt receiver.**
The first public and signable MirrorSpeaker release must omit the prebuilt
engine and use the explicit, user-initiated local source build. This status
may change only after all of the following are complete:

- the receiver and every included dependency are built reproducibly by the
  public CI workflow from recorded source;
- complete corresponding source and build material are supplied for every
  conveyed GPL/LGPL component;
- an explicit license and legal review covers UxPlay, PlayFair, multimedia
  codecs, and the exact dependency inventory; and
- the public receiver packaging and clean-machine gates pass without an
  internal override.

Before building the public receiver archive, prepare one archive, or a small
set of archives, containing at least:

- The exact UxPlay revision used to build the package.
- MirrorSpeaker's complete UxPlay modifications in the preferred form for
  editing, not merely a description of the changes.
- The scripts, configuration, package lists, and build instructions needed to
  reproduce the distributed binaries.
- Corresponding source and required license material for every GPL/LGPL
  binary listed in the generated dependency inventory.
- The applicable license texts and third-party notices.

A link to a moving upstream branch is not a substitute for the exact source.
Keep the source archives available for as long as the matching binaries are
available.

The packaging script records each source archive's name, size, and SHA-256
hash. It cannot inspect an arbitrary archive and prove that its contents are
legally complete. `-ConfirmCompleteCorrespondingSource` is the maintainer's
explicit self-attestation, not an automated license or legal audit. It does
not lift the current DO NOT REDISTRIBUTE status by itself.

## 4. Build the prebuilt receiver package

For a local engineering build, the shortest command is:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-ReceiverPackage.ps1 `
  -PackageVersion $Version `
  -Force
```

By default, this reads `%LOCALAPPDATA%\AirMirror\engine` and writes to
`artifacts\receiver-engine\win-x64`. Use `-EngineRoot <path>` only when the
verified engine is elsewhere. Use `-OutputRoot <path>` only for a deliberate
alternate staging location.

The following hard-gated command is documented for a future receiver release
only. Do not run it for, or include its output in, the first public
MirrorSpeaker release. It becomes eligible only after the reproducible-CI,
corresponding-source, license, and legal-review requirements in the previous
section are recorded as complete:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-ReceiverPackage.ps1 `
  -PackageVersion $Version `
  -PublicRelease `
  -CorrespondingSourceArchive `
    ".\sources\MirrorSpeaker-receiver-corresponding-source-${Version}.zip" `
  -ConfirmCompleteCorrespondingSource `
  -Force
```

`-CorrespondingSourceArchive` accepts one path or multiple paths. A
`-PublicRelease` build fails unless at least one source archive exists and the
confirmation switch is present. Those automated checks are necessary but are
not sufficient to approve redistribution.

`-Force` may replace an earlier local staging build. Never use it to replace
files for a version that has already been published.

The receiver output directory contains the expanded `engine` directory used
by the installer, redistribution notices, copied source archives, and
machine-readable metadata. Its main files are:

```text
artifacts\receiver-engine\win-x64\
  engine\
  metadata\package.json
  metadata\dependencies.json
  metadata\source-compliance.json
  sources\
  REDISTRIBUTION-NOTICE.txt
  MirrorSpeaker-Receiver-<version>-win-x64.zip
  MirrorSpeaker-Receiver-<version>-win-x64.zip.sha256
  MirrorSpeaker-Receiver-<version>-win-x64.manifest.json
  MirrorSpeaker-Receiver-<version>-win-x64.dependencies.json
  MirrorSpeaker-Receiver-<version>-win-x64.sources.json
```

Do not edit the receiver ZIP after it is built. Verify its `.zip.sha256` value
before continuing.

## 5. Build the installer and portable ZIP

For the first public and signable release, use a clean checkout with no staged
receiver package and build without `-RequireReceiverEngine`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-Installer.ps1 `
  -Configuration Release `
  -Version $Version `
  -Publisher $Publisher `
  -PublisherUrl $PublisherUrl
```

This is the approved public release form until the receiver audit is
complete. The app must explain that AirPlay setup is a user-initiated local
source build that downloads the pinned UxPlay source and MSYS2 packages and
can take several minutes. Bluetooth speaker mode does not require that
engine.

The application itself is a framework-dependent .NET 10 x64 build. Neither
the installed application nor the portable ZIP redistributes Microsoft .NET
or WPF runtime binaries. The Windows installer handles the prerequisite as
follows:

- It checks for a compatible Microsoft .NET 10 Desktop Runtime (x64) before
  installing MirrorSpeaker.
- If that runtime is already present, it does not download or reinstall it.
- If it is missing, setup shows a clear prerequisite prompt, downloads only
  the pinned official Microsoft 10.0.10 x64 runtime directly from Microsoft,
  verifies its SHA-256 checksum, and then runs Microsoft's runtime installer.
- Installing the Microsoft system prerequisite can require an Internet
  connection and administrator approval. MirrorSpeaker remains a per-user
  installation.

The portable ZIP has no prerequisite downloader. It requires the Microsoft
.NET 10 Desktop Runtime (x64) to be installed before
`MirrorSpeaker.exe` can run.

The pinned Microsoft 10.0.10 x64 runtime-installer SHA-256 is:

```text
e82fc901c8f52d716293b2bc0830ce0dd254a06268c457a19e8fc503560a84d1
```

Stop the release if build output says that a prebuilt receiver was included,
if the portable archive contains `engine\ucrt64\bin\uxplay.exe`, or if the
installed application already contains that file. An `INTERNAL` receiver must
never be copied into a public artifact.

For a future audited receiver release, `-RequireReceiverEngine` may be added
to the command above. At that time the required engine must be at:

```text
artifacts\receiver-engine\win-x64\engine
```

The same package must also have:

```text
artifacts\receiver-engine\win-x64\metadata\package.json
```

The installer build bundles the engine automatically only when that metadata
contains the Boolean value `"publicReleaseCandidate": true`. The public
receiver command in the previous section creates that approval only after its
source-compliance gate passes. That flag is not a legal approval and does not
override the documented audit requirements. An `engine` directory by itself
is never treated as publishable.

The build also verifies the engine marker, `uxplay.exe`,
`gst-inspect-1.0.exe`, and the minimum MirrorSpeaker patch level when an
eligible future engine is included.

To exercise an internal engine before its source-compliance approval, a
maintainer may deliberately run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-Installer.ps1 `
  -Configuration Release `
  -Version $Version `
  -Publisher 'MirrorSpeaker Project' `
  -RequireReceiverEngine `
  -AllowInternalReceiverEngine
```

This override is for local installer testing only. The script prints
`DO NOT PUBLISH` and makes the warning difficult to miss by naming its files:

```text
MirrorSpeaker-<version>-INTERNAL-win-x64-setup.exe
MirrorSpeaker-<version>-INTERNAL-win-x64-portable.zip
MirrorSpeaker-<version>-INTERNAL-SHA256SUMS.txt
```

Never rename or publish an `INTERNAL` artifact.

The script builds the framework-dependent app, runs the smoke tests, creates a
per-user Inno Setup installer, and creates the portable ZIP. The installer:

- Installs the MirrorSpeaker files to
  `%LOCALAPPDATA%\Programs\MirrorSpeaker` per-user. Only the separate Microsoft
  runtime prerequisite can require administrator approval.
- Creates a Start Menu shortcut.
- Selects the desktop shortcut by default.
- Detects an existing Microsoft .NET 10 Desktop Runtime (x64), or clearly
  prompts before downloading, SHA-256-verifying, and installing the pinned
  official Microsoft 10.0.10 x64 runtime when it is missing.
- Does not bundle Microsoft .NET or WPF runtime binaries.
- Does not bundle a receiver in the current public release form.
- Lets the user explicitly start the local receiver source build from the app
  and shows clear installation progress.
- Registers a normal Windows uninstaller.

The portable ZIP contains `portable.flag`, no Microsoft .NET/WPF runtime, and
no prebuilt receiver in the current public release form. It must be described
as requiring the Microsoft .NET 10 Desktop Runtime (x64) to be installed
separately. If the user explicitly installs the receiver, portable-mode
MirrorSpeaker settings, UxPlay HOME and pairing records, and receiver files
stay below the extracted folder's `data` and `engine` directories. GStreamer
or Windows may still maintain normal per-user caches. Firewall rules are
system state and can be created only after the user approves an administrator
prompt.

The release output is:

```text
artifacts\release\
  MirrorSpeaker-<version>-win-x64-setup.exe
  MirrorSpeaker-<version>-win-x64-portable.zip
  MirrorSpeaker-<version>-SHA256SUMS.txt
```

The checksum file uses lowercase SHA-256 values in this form:

```text
<sha256> *MirrorSpeaker-<version>-win-x64-portable.zip
<sha256> *MirrorSpeaker-<version>-win-x64-setup.exe
```

## 6. Code signing policy and public signing gate

The authoritative [code signing policy](../CODE_SIGNING_POLICY.md) assigns
Authors, Reviewers, and Approvers and defines what the project may sign.

MirrorSpeaker has not yet been accepted into SignPath Foundation's open-source
program. The current build scripts do not apply a public Authenticode
signature, and current artifacts must not be described as signed. If the
project is accepted, releases will include this required attribution:

**Free code signing provided by SignPath.io, certificate by SignPath Foundation**

### Initial unsigned preview

SignPath Foundation requires a project to be publicly released before it
applies. If an unsigned preview is needed for that application, it is the only
exception to the normal signed-release gate:

- Complete every source-compliance, automated-test, clean-machine, malware,
  privacy, and uninstall check that does not depend on a signature.
- Mark both the GitHub release and version as a **pre-release**.
- State prominently that the setup and application are unsigned and that
  Windows will show an unknown publisher warning.
- Link to the [code signing policy](../CODE_SIGNING_POLICY.md) and
  [privacy policy](../PRIVACY.md).
- State that the installer obtains the official Microsoft 10.0.10 x64 Desktop
  Runtime only when .NET 10 x64 is missing, while the portable ZIP requires
  .NET 10 x64 to be installed in advance.
- Do not include any prebuilt receiver-engine package in the first preview.
  Disclose the longer user-requested first-use source build.
- Never replace the files behind an existing version or tag; publish a new
  version for any rebuild.

An unsigned preview is not an official signed release. After SignPath
acceptance and workflow integration, normal public releases must pass the
signed gate below.

### SignPath build and approval rules

The signing workflow must build from an immutable commit in
[github.com/codyabraham/MirrorSpeaker](https://github.com/codyabraham/MirrorSpeaker)
using a build that SignPath can verify. It must not upload a locally built
substitute. Each signing request requires a manual decision by the Approver.
GitHub and SignPath accounts assigned a signing role must use multi-factor
authentication.

Sign only MirrorSpeaker-authored artifacts. Do not apply the project's
signature to `uxplay.exe`, GStreamer, FFmpeg, MSYS2 binaries, or other upstream
components. An eligible receiver can be included unsigned inside the signed
MirrorSpeaker installer only after the receiver corresponding-source gate
passes. The setup signature protects the installer as a package; it does not
claim that every embedded upstream file has its own Authenticode signature.

SignPath keeps the certificate key in its managed signing system. Do not add a
PFX file, private key, certificate password, or equivalent secret to the
repository or GitHub Actions.

The approved workflow must enforce this order:

1. Build and test `MirrorSpeaker.exe` from the tagged commit with the final
   product name, version, and `MirrorSpeaker Project` company metadata.
2. Obtain the SignPath signature and trusted timestamp for
   `MirrorSpeaker.exe` after manual approval.
3. Build the portable ZIP and Inno Setup installer from that exact signed
   application without rebuilding or replacing it. The current release form
   must omit the prebuilt receiver. Only after the separate receiver audit may
   a future workflow require its public-release metadata and
   corresponding-source records.
4. Obtain the SignPath signature and trusted timestamp for the final setup
   executable after manual approval.
5. Verify the application inside the portable ZIP, the installed application,
   and the setup executable.
6. Generate final SHA-256 checksums only after signing, because signing changes
   the file bytes.

The normal public release must satisfy all of these conditions:

- `dist\win-x64\MirrorSpeaker.exe` has a valid trusted Authenticode signature.
- The `MirrorSpeaker.exe` inside the portable ZIP has that same valid
  signature.
- The final setup EXE has a valid trusted Authenticode signature.
- The Authenticode signer is `SignPath Foundation`; the separate product
  publisher metadata remains `MirrorSpeaker Project`.
- The application and setup signatures have trusted timestamps.
- No self-signed test certificate is used.
- The version and product-name metadata restrictions configured in SignPath
  match the release.

Check each executable with:

```powershell
$Signature = Get-AuthenticodeSignature -LiteralPath `
  .\dist\win-x64\MirrorSpeaker.exe
$Signature |
  Format-List Status, StatusMessage, SignerCertificate, TimeStamperCertificate

if ($Signature.Status -ne 'Valid') {
  throw "MirrorSpeaker.exe does not have a valid Authenticode signature."
}
if ($Signature.SignerCertificate.Subject -notmatch 'SignPath Foundation') {
  throw "MirrorSpeaker.exe was not signed by SignPath Foundation."
}
if ($null -eq $Signature.TimeStamperCertificate) {
  throw "MirrorSpeaker.exe does not have a trusted signature timestamp."
}
```

Extract the portable ZIP to a temporary directory and perform the same check
on its `MirrorSpeaker.exe`. Check the setup executable and the installed
application as well.

After all signing is complete, recreate the final checksum file:

```powershell
$ReleaseRoot = (Resolve-Path .\artifacts\release).Path
$ArtifactNames = @(
  "MirrorSpeaker-$Version-win-x64-portable.zip"
  "MirrorSpeaker-$Version-win-x64-setup.exe"
)
$ChecksumLines = foreach ($Name in ($ArtifactNames | Sort-Object)) {
  $Path = Join-Path $ReleaseRoot $Name
  $Hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
  '{0} *{1}' -f $Hash.Hash.ToLowerInvariant(), $Name
}
[IO.File]::WriteAllLines(
  (Join-Path $ReleaseRoot "MirrorSpeaker-$Version-SHA256SUMS.txt"),
  [string[]] $ChecksumLines,
  (New-Object Text.UTF8Encoding($false)))
```

Every signed GitHub release description must contain a **Code signing
policy** section with the exact SignPath attribution above, the three
code-signing role assignments from the project policy, and links to the
[code signing policy](../CODE_SIGNING_POLICY.md) and
[privacy policy](../PRIVACY.md).

Do not modify any release file after this point.

## 7. Exact silent commands

If the Microsoft .NET 10 Desktop Runtime (x64) is already present, silent
setup skips the prerequisite download. If it is missing, silent setup still
downloads the pinned official Microsoft 10.0.10 x64 runtime, verifies its
SHA-256 checksum, and starts Microsoft's runtime installer quietly. This path
requires Internet access and can trigger a Windows administrator-approval
prompt; `/VERYSILENT` does not suppress Windows elevation. Setup must fail
rather than continue if the download is canceled, checksum verification
fails, the prerequisite installer cannot run, or .NET 10 x64 is still
unavailable afterward.

Silent installation with the default desktop shortcut:

```powershell
$Setup = ".\artifacts\release\MirrorSpeaker-$Version-win-x64-setup.exe"
& $Setup '/VERYSILENT' '/SUPPRESSMSGBOXES' '/NORESTART' '/SP-'
if ($LASTEXITCODE -ne 0) {
  throw "Silent installation failed with code $LASTEXITCODE."
}
```

Silent installation without a desktop shortcut:

```powershell
& $Setup '/VERYSILENT' '/SUPPRESSMSGBOXES' '/NORESTART' '/SP-' `
  '/MERGETASKS="!desktopicon"'
if ($LASTEXITCODE -ne 0) {
  throw "Silent installation failed with code $LASTEXITCODE."
}
```

Exact silent uninstall:

```powershell
$Uninstaller = Join-Path $env:LOCALAPPDATA `
  'Programs\MirrorSpeaker\unins000.exe'
& $Uninstaller '/VERYSILENT' '/SUPPRESSMSGBOXES' '/NORESTART'
if ($LASTEXITCODE -ne 0) {
  throw "Silent uninstall failed with code $LASTEXITCODE."
}
```

Interactive uninstall requests administrator permission to remove
MirrorSpeaker's three Private-network firewall rules. Silent uninstall never
opens that prompt, so those firewall rules can remain. This limitation must
be stated in deployment documentation that recommends silent uninstall.
For a clean silent-uninstall QA reset, open PowerShell as Administrator and
run:

```powershell
$RuleNames = @(
  'AirMirror-mDNS-UDP-In'
  'AirMirror-Receiver-TCP-In'
  'AirMirror-Receiver-UDP-In'
)
Get-NetFirewallRule -Name $RuleNames -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule
```

Normal uninstall removes the installed program, bundled engine, Start Menu
shortcut, desktop shortcut, and Installed Apps entry. It deliberately
preserves the user's legacy `%APPDATA%\AirMirror` settings and
`%LOCALAPPDATA%\AirMirror` first-use engine so an upgrade or reinstall does
not destroy pairing and configuration data.

## 8. Required clean Windows 11 QA

Use a fresh Windows 11 x64 VM snapshot or a separate physical PC. For the
missing-prerequisite test, it must not already have MirrorSpeaker, the
Microsoft .NET 10 Desktop Runtime (x64), UxPlay, MSYS2, GStreamer, a
development .NET SDK, or leftover MirrorSpeaker firewall rules. Keep a second
snapshot, or restore the first one and install the official .NET 10 Desktop
Runtime separately, to test the already-installed prerequisite path. Record
the Windows build, iPhone model, iOS version, .NET runtime state and version,
and the exact release artifacts in the release notes.

Complete every check below for the exact final signed files. For the one
initial unsigned SignPath-application preview, skip only checks that require a
trusted signature and instead confirm that the release notes clearly identify
the files as unsigned.

### Artifact and installer checks

- Verify the final SHA-256 values against
  `MirrorSpeaker-<version>-SHA256SUMS.txt`.
- Verify the setup signature before running it.
- Confirm the publish directory, portable ZIP, and setup payload do not contain
  a .NET Desktop Runtime installer or redistributed Microsoft .NET/WPF runtime
  binaries. The runtime prerequisite must remain a separate Microsoft
  download.
- Confirm `THIRD-PARTY-NOTICES.txt` still identifies the unmodified
  `Microsoft.Windows.SDK.NET.dll` and `WinRT.Runtime.dll` projection assemblies
  and the applicable Windows SDK terms. Before applying for Foundation
  signing, obtain SignPath's confirmation that these Windows-only interop
  assemblies qualify for its System Library exception.
- Run the normal graphical installer.
- Confirm the displayed product, version, and publisher are correct.
- On the snapshot without .NET 10 x64, confirm setup clearly explains the
  prerequisite before downloading it.
- Confirm setup downloads exactly the official Microsoft 10.0.10 x64 Desktop
  Runtime only after that prompt, verifies the pinned SHA-256 checksum, and
  does not continue if verification or prerequisite installation fails.
- Approve the Microsoft prerequisite installation, confirm .NET 10 x64 is
  available afterward, and confirm MirrorSpeaker launches.
- Repeat from the snapshot where a compatible .NET 10 Desktop Runtime (x64) is
  already installed. Confirm setup skips the runtime prompt, download, and
  reinstall.
- Confirm setup finishes without downloading or compiling an AirPlay receiver
  and that neither the installed app nor portable archive contains a prebuilt
  `uxplay.exe`.
- Confirm the Start Menu shortcut and default desktop shortcut work.
- Confirm MirrorSpeaker appears in Windows **Installed apps**.
- Confirm the installed `MirrorSpeaker.exe` signature is valid.
- Confirm Windows Defender reports no detection.

### Bluetooth checks with a real iPhone

- Pair a new iPhone and confirm MirrorSpeaker finds it.
- Restart MirrorSpeaker and confirm it finds an already-connected iPhone.
- Start Bluetooth speaker mode and play ordinary audio.
- Play TikTok video and confirm the picture continues on the iPhone while its
  sound comes from the PC.
- Listen for at least ten minutes through the PC's built-in speakers or wired
  headphones and record any breakup or unexpected disconnect.
- Stop and reconnect Bluetooth audio at least twice.

### AirPlay checks with a real iPhone

- In MirrorSpeaker, explicitly choose **Install receiver engine** and confirm
  that the app shows clear progress while it downloads the pinned source and
  MSYS2 packages and builds the engine locally.
- Confirm the user-initiated build completes on the clean PC and that closing
  or cancelling the app does not falsely report a successful installation.
- Put the PC on a trusted Private Wi-Fi network.
- Start screen-receiver mode and approve the one-time firewall prompt.
- Confirm the PC appears in the iPhone's Screen Mirroring list.
- Complete PIN pairing, then verify moving video and audio.
- Stop and restart the receiver and confirm it is discoverable again.
- Restart Windows and repeat discovery and connection.
- Confirm Bluetooth-only use still works when AirPlay is stopped.

### Upgrade, portable, silent, and uninstall checks

- When a previous public version exists, install over it and confirm settings,
  pairing trust, and the selected iPhone are preserved.
- On a clean snapshot without the Microsoft .NET 10 Desktop Runtime (x64),
  extract the portable ZIP to a path containing spaces and confirm it contains
  no bundled runtime or prerequisite installer.
- Confirm the portable app requires .NET 10 x64 and does not run successfully
  until that runtime is installed separately.
- Install the official Microsoft .NET 10 Desktop Runtime (x64), verify the
  portable `MirrorSpeaker.exe` signature, and launch it.
- Confirm the portable archive has no prebuilt receiver, then explicitly
  install it from the portable app and confirm the locally built engine works.
- Confirm the portable build does not create an Installed Apps entry.
- Confirm its MirrorSpeaker settings, pairing records, and engine remain below
  its own `data` and `engine` directories rather than AppData.
- Restore the clean VM snapshot without .NET 10 x64 and test the exact silent
  install command, including its separate Microsoft runtime download,
  SHA-256 verification, and any Windows elevation prompt.
- Repeat the silent install with .NET 10 x64 already present and confirm setup
  skips the prerequisite download.
- Repeat with the no-desktop-shortcut switch and confirm the shortcut is
  absent.
- Run the exact silent uninstall command and confirm exit code `0`.
- Confirm installed program files, shortcuts, and the Installed Apps entry are
  removed. Confirm the documented user settings and locally built engine are
  preserved until the user deliberately deletes them.
- Manually clean the firewall rules after silent-uninstall testing.
- Restore the snapshot, install normally, and uninstall interactively.
- Approve the firewall cleanup prompt and confirm all three rules are gone.

For a future release that has passed the separate receiver redistribution
audit, replace the no-prebuilt-engine checks above with checks that the exact
approved receiver and its corresponding-source records are bundled, require no
receiver download or local receiver compilation, and work from both installed
and portable layouts. The separate .NET prerequisite rules above still apply.

Any failure blocks the release. Fix it, rebuild with a new version if the
artifacts were already published, and repeat the complete clean-machine test.

## 9. Files to publish

For a normal signed release, publish together:

- The final signed setup EXE.
- The portable ZIP containing the signed app.
- `MirrorSpeaker-<version>-SHA256SUMS.txt`.
- If a prebuilt receiver is included, the matching receiver
  corresponding-source archive or archives.
- If a prebuilt receiver is included, its manifest, dependency inventory,
  source-compliance inventory, redistribution notice, and checksums.
- Release notes containing system requirements, known limitations, and the
  test environment recorded above. They must distinguish the installer, which
  obtains the pinned official Microsoft 10.0.10 x64 Desktop Runtime only when
  needed, from the portable ZIP, which requires .NET 10 x64 to be installed
  beforehand.
- Links to the [privacy policy](../PRIVACY.md),
  [security policy](../SECURITY.md),
  [code signing policy](../CODE_SIGNING_POLICY.md), and
  [third-party notices](../THIRD-PARTY-NOTICES.txt).

For the one initial SignPath-application preview, the setup and portable ZIP
in this list are unsigned, contain no prebuilt receiver, and must be published
only as a clearly labeled GitHub pre-release. Its release notes must state
`Unsigned preview — Windows will show Unknown publisher` before the download
links. The checksum, policy-link, licensing, and test-record requirements
still apply.

For a signed release, the release notes' **Code signing policy** section must
state:

> Free code signing provided by SignPath.io, certificate by SignPath Foundation

It must also identify [@codyabraham](https://github.com/codyabraham) as the
current Author, Reviewer, and Approver, link the full policies, and state that
Windows shows `SignPath Foundation` as certificate signer while the product
publisher metadata is `MirrorSpeaker Project`.

The expanded staging directories are build inputs, not user downloads.
Keep a maintainer release record containing the build date, exact source
commit and tag, .NET SDK version, pinned Microsoft Desktop Runtime prerequisite
version and SHA-256 value, Inno Setup version, product publisher metadata,
certificate subject, signature timestamp, final hashes, SignPath request and
approval identifiers, receiver source-compliance record, and completed QA
checklist.
