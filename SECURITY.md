# MirrorSpeaker security policy

## Supported versions

Only the latest public MirrorSpeaker release is supported. Before the first
public release, reports against the current source are welcome. Older,
development, and locally modified builds may be useful for reproducing a
problem but do not receive separate security fixes.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public GitHub issue.
Use GitHub's private
[security-advisory form](https://github.com/codyabraham/MirrorSpeaker/security/advisories/new)
to send the report to [@codyabraham](https://github.com/codyabraham).

Include, when possible:

- the MirrorSpeaker version and download filename;
- the affected Windows and iOS versions;
- whether the issue concerns Bluetooth, AirPlay, the receiver installer, the
  Windows installer, or the build/release pipeline;
- steps to reproduce the problem and its security impact; and
- logs or proof-of-concept material with personal device and network details
  removed.

If private vulnerability reporting is temporarily unavailable, open a public
issue asking the maintainer to enable a private contact channel, but do not
include vulnerability details in that issue.

The maintainer will investigate and coordinate a fix and disclosure when the
report is reproducible. No fixed response or remediation time is promised.

## Security design notes

- AirPlay listens on the local network and therefore increases local attack
  surface while the receiver is running. PIN pairing is enabled by default.
- The provided firewall action is explicit, requires administrator approval,
  and limits its inbound rules to Windows **Private** network profiles.
- Bluetooth mode relies on Windows pairing and the Windows audio receiver API;
  it does not open MirrorSpeaker network ports.
- The receiver installer pins and SHA-256 verifies the UxPlay source archive.
  MSYS2's package manager verifies repository package signatures.
- The first public release omits the prebuilt receiver. AirPlay dependencies
  are obtained and built locally only after the user explicitly requests
  receiver installation. Prebuilt redistribution remains blocked pending the
  reproducible-CI, corresponding-source, license, and legal reviews in the
  release guide.
- MirrorSpeaker does not disable Windows Firewall, antivirus, SmartScreen, or
  certificate validation.
- Upstream multimedia components have their own security lifecycles. Release
  builds must use supported inputs and pass the receiver licensing and source
  compliance gates documented in
  [`docs/RELEASING.md`](docs/RELEASING.md).

MirrorSpeaker has not yet been accepted into SignPath Foundation's program,
and current builds must not be assumed to be signed. If signing is enabled,
verify the Authenticode signature and published SHA-256 checksum before
running a downloaded installer. See the
[code signing policy](CODE_SIGNING_POLICY.md).
