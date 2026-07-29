# MirrorSpeaker privacy policy

Last updated: July 28, 2026

MirrorSpeaker is a local Windows application. The MirrorSpeaker project does
not operate an account service, cloud service, analytics service, advertising
service, telemetry endpoint, or automatic update service.

**This program will not transfer any information to other networked systems
unless specifically requested by the user or the person installing or
operating it.**

## Information received by the MirrorSpeaker project

MirrorSpeaker does not send usage, crash, device, media, or diagnostic data to
the project or its maintainer. The project therefore does not receive, sell,
or share personal information through the application.

If a user voluntarily posts an issue, security report, or other message on
GitHub, GitHub processes that submission under the
[GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## User-requested network and Bluetooth activity

MirrorSpeaker communicates only when a user selects a feature that requires
communication:

- **Bluetooth speaker mode:** MirrorSpeaker asks Windows to list paired audio
  devices and open the selected iPhone's Bluetooth audio receiver profile.
  Audio travels over the local Bluetooth connection. MirrorSpeaker does not
  send it to a project-operated server.
- **AirPlay modes:** MirrorSpeaker starts UxPlay, advertises the configured
  receiver name over mDNS on the local network, and accepts a direct AirPlay
  connection from the user's iPhone. The default advertised name can include
  the Windows computer name, so nearby devices on the same discoverable
  network may see it. Screen and audio content is rendered on the PC; the app
  does not record it or upload it.
- **Receiver-engine installation:** Only after the user chooses to install or
  update the AirPlay receiver engine, the installer downloads the pinned
  UxPlay source archive from GitHub and obtains MSYS2 and multimedia packages
  from MSYS2 repositories and mirrors. Those services receive normal download
  request information such as the public IP address and requested files.
  GitHub's handling is described in its
  [privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
  MSYS2 documents the request details, mirror behavior, and retention in its
  [privacy policy](https://www.msys2.org/privacy/).
- **Firewall setup:** MirrorSpeaker changes Windows Firewall only when the user
  clicks the firewall button and approves the administrator prompt. The rules
  allow the documented AirPlay ports only on Windows **Private** network
  profiles. Creating a rule does not itself send data.

Windows may independently perform operating-system functions such as
Bluetooth pairing, network discovery, certificate validation, malware
screening, or SmartScreen reputation checks. Those functions are controlled
by Windows, not MirrorSpeaker, and are subject to the
[Microsoft Privacy Statement](https://privacy.microsoft.com/privacystatement)
and the user's Windows settings.

Code signing is a release-time service. Installed copies of MirrorSpeaker do
not contact SignPath for application telemetry or project updates.

## Information stored on the PC

An installed copy stores its settings below `%APPDATA%\AirMirror`. The settings
can include:

- the configured AirPlay receiver name;
- the selected receiver mode and playback options;
- whether PIN pairing, low latency, full screen, and synchronization are
  enabled; and
- the Windows identifier of the selected Bluetooth audio device.

UxPlay stores pairing and trusted-device material below the same user-data
directory. The locally built AirPlay receiver engine is normally stored below
`%LOCALAPPDATA%\AirMirror\engine`.

The portable release stores settings and pairing information in its `data`
directory and the receiver in its `engine` directory. Windows and GStreamer
may also maintain their normal per-user device and multimedia caches.

Diagnostic output shown in the app is not automatically uploaded. It can
contain receiver, Bluetooth, or network details, so users should review it
before intentionally copying it into an issue or message.

## Retention and deletion

MirrorSpeaker keeps local settings and pairing information until the user
deletes them. Normal uninstall intentionally preserves those files so that an
upgrade or reinstall does not destroy the user's configuration.

To remove installed-app data after uninstalling, delete:

```text
%APPDATA%\AirMirror
%LOCALAPPDATA%\AirMirror
```

For a portable copy, delete its `data` and `engine` directories. Removing
Private-network firewall rules is described in
[`docs/RELEASING.md`](docs/RELEASING.md#7-exact-silent-commands).

## Third-party software

MirrorSpeaker uses Windows system services and can install UxPlay, MSYS2,
GStreamer, FFmpeg, and related packages at the user's request. These
components are not MirrorSpeaker-operated online services. Their licensing
and source information is listed in
[`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt). Any network activity
performed by a third-party component outside the specific operations described
above is governed by that component's documentation and the user's
configuration.

## Policy changes

Material privacy changes will be documented in this file and in the relevant
release notes. A change that introduces project-operated telemetry or an
unrequested data transfer must not be enabled silently.

