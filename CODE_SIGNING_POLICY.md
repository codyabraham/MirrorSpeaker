# MirrorSpeaker code signing policy

## Current status

MirrorSpeaker has not yet been accepted into the SignPath Foundation
open-source program. Builds produced before that acceptance and before the
signing workflow is enabled are unsigned. They must not be described as signed
or as having a verified publisher.

If the project is accepted, official Windows releases will use the following
service:

**Free code signing provided by SignPath.io, certificate by SignPath Foundation**

The authoritative source repository is
[github.com/codyabraham/MirrorSpeaker](https://github.com/codyabraham/MirrorSpeaker).

## Code-signing roles

MirrorSpeaker currently has one maintainer, so the required responsibilities
are assigned as follows:

- **Authors:** [@codyabraham](https://github.com/codyabraham) is trusted to
  modify source code and build definitions.
- **Reviewers:** [@codyabraham](https://github.com/codyabraham) reviews
  contributions from people who do not have direct commit access.
- **Approvers:** [@codyabraham](https://github.com/codyabraham) decides
  whether a specific release is ready for a manual signing approval.

Repository ownership is also recorded in
[`.github/CODEOWNERS`](.github/CODEOWNERS). Everyone assigned one of these
roles must use multi-factor authentication for GitHub and SignPath.

## What may be signed

The MirrorSpeaker signing configuration may sign only artifacts built from
this repository by the project's approved, verifiable build workflow. The
intended signing scope is:

- `MirrorSpeaker.exe`;
- the copy of `MirrorSpeaker.exe` placed in the portable archive; and
- the final MirrorSpeaker setup executable.

UxPlay, GStreamer, FFmpeg, MSYS2 packages, and other upstream binaries must not
be signed as if they were authored by MirrorSpeaker. Eligible upstream
components may be included without an individual MirrorSpeaker signature
inside the signed installer only when their licenses, notices, corresponding
source obligations, and the receiver redistribution gate are all satisfied.

The first public and signable release must not contain a prebuilt receiver.
It may include `scripts/Install-ReceiverEngine.ps1` so that the user can
explicitly request a local source build. The UxPlay-derived source fragments
and patch payloads embedded in that script are GPL-3.0 material, not
MirrorSpeaker MIT-licensed controller code.

## Release and approval controls

For each signed release:

1. The release comes from an immutable source commit and version tag in the
   public repository.
2. The automated build runs the project's tests and produces artifacts from
   that commit without substituting privately built binaries.
3. Changes to source, installer scripts, workflows, and signing configuration
   receive the review required by the repository's access rules.
4. The Approver manually checks the version, source commit, test result,
   dependency and receiver-engine compliance records, and artifact metadata
   before approving the signing request.
5. SignPath applies an Authenticode signature and trusted timestamp. Signing
   keys and certificate passwords are never placed in this repository or on a
   maintainer's computer.
6. The signed application and setup signatures are verified before final
   SHA-256 checksums are generated and the release is published.

No release may bypass SignPath's source-origin, metadata, or manual-approval
controls.

## Product publisher versus certificate signer

These two Windows identities serve different purposes:

- `MirrorSpeaker Project` is the product publisher stored in the application's
  `Company` metadata and the installer's `AppPublisher` metadata. It can appear
  in file properties and Windows **Installed apps**.
- If SignPath Foundation accepts the project, `SignPath Foundation` will be
  the Authenticode certificate subject shown by Windows as the verified
  cryptographic signer.

The product metadata must not be changed to imply that SignPath Foundation
develops or maintains MirrorSpeaker. Conversely, the certificate subject is
not expected to match the product's `Company` metadata.

## Privacy

See the full [MirrorSpeaker privacy policy](PRIVACY.md).

This program will not transfer any information to other networked systems
unless specifically requested by the user or the person installing or
operating it.
