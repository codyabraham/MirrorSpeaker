MirrorSpeaker portable edition
==============================

Requirements
------------

- Windows 11 on an x64 PC.
- Microsoft .NET Desktop Runtime 10 for x64 (a stable 10.x release).

The portable ZIP deliberately does not include or automatically download the
Microsoft runtime. If MirrorSpeaker does not start, install the official x64
.NET Desktop Runtime from:

https://dotnet.microsoft.com/en-us/download/dotnet/10.0

The regular MirrorSpeaker setup installer detects this prerequisite and, when
needed, explains the download before retrieving the verified Microsoft runtime
installer.

Using the portable edition
--------------------------

Extract the entire ZIP to a folder you can write to, then run
MirrorSpeaker.exe. Keep portable.flag beside the application. MirrorSpeaker
stores its portable data in that same folder.

The AirPlay receiver engine is not bundled in the first public release.
MirrorSpeaker can download and prepare it on first use. Bluetooth speaker mode
does not require that AirPlay engine.
