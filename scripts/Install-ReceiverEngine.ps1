#requires -Version 5.1

# MirrorSpeaker's installer orchestration is covered by the repository's MIT
# License. Embedded source-patch payloads derived from UxPlay were modified by
# the MirrorSpeaker Project on 2026-07-28 and remain covered by UxPlay's GNU
# GPL version 3 license. See THIRD-PARTY-NOTICES.txt.

[CmdletBinding()]
param(
    [Parameter()]
    [string] $InstallRoot,

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# UxPlay 1.74 is currently an experimental branch rather than a tagged release.
# Pinning and checksumming the source keeps the receiver implementation stable
# while retaining the built-in mDNS responder that removes Bonjour on Windows.
# MSYS2 runtime packages are intentionally updated to their current signed
# repository versions so security fixes are not frozen by this script.
$UxPlayCommit = '3ca7526387e894d6848b84c209de361c3bedd1ec'
$UxPlayArchiveUri = "https://github.com/FDH2/UxPlay/archive/$UxPlayCommit.tar.gz"
$UxPlayArchiveSha256 = '7ad295c244c5aa4c2c2ebbfbd2e2b2c193ca317da9edd7c2ba4cfc8b62ac4a50'
$MirrorSpeakerPatchLevel = 2

# Official portable MSYS2 base image, pinned instead of following a mutable
# "latest" URL. Package databases are updated before dependencies are installed.
$Msys2BaseVersion = '20260611'
$Msys2ArchiveUri = "https://repo.msys2.org/distrib/x86_64/msys2-base-x86_64-$Msys2BaseVersion.tar.xz"
$Msys2ArchiveSha256 = 'a2d047e8ee213c3c6a49a8de427eb1069df12207c0422ff1b3cbb5c905c34221'

$RequiredPackages = @(
    'mingw-w64-ucrt-x86_64-cmake'
    'mingw-w64-ucrt-x86_64-gcc'
    'mingw-w64-ucrt-x86_64-ninja'
    'mingw-w64-ucrt-x86_64-pkgconf'
    'mingw-w64-ucrt-x86_64-openssl'
    'mingw-w64-ucrt-x86_64-libplist'
    'mingw-w64-ucrt-x86_64-gstreamer'
    'mingw-w64-ucrt-x86_64-gst-plugins-base'
    'mingw-w64-ucrt-x86_64-gst-plugins-good'
    'mingw-w64-ucrt-x86_64-gst-plugins-bad'
    'mingw-w64-ucrt-x86_64-gst-libav'
)

function Write-MirrorSpeakerProgress {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 100)]
        [int] $Percent,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $singleLineMessage = ($Message -replace '[\r\n]+', ' ').Trim()
    [Console]::Out.WriteLine(("AIRMIRROR_PROGRESS:{0}:{1}" -f $Percent, $singleLineMessage))
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function ConvertTo-MsysPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = (Get-FullPath -Path $Path) -replace '\\', '/'
    if ($fullPath -notmatch '^([A-Za-z]):/(.*)$') {
        throw "MSYS2 setup requires a path on a local Windows drive. Unsupported path: $Path"
    }

    $drive = $Matches[1].ToLowerInvariant()
    return "/$drive/$($Matches[2])"
}

function ConvertTo-ShellLiteral {
    param([Parameter(Mandatory = $true)][string] $Value)

    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][uri] $Uri,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
            if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
                throw "The download completed without creating $Destination."
            }
            if ((Get-Item -LiteralPath $Destination).Length -lt 1024) {
                throw "The downloaded file is unexpectedly small."
            }
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }

    throw "Unable to download $Uri after three attempts. $($lastError.Exception.Message)"
}

function Expand-ValidatedTarArchive {
    param(
        [Parameter(Mandatory = $true)][string] $Archive,
        [Parameter(Mandatory = $true)][string] $Destination,
        [Parameter(Mandatory = $true)][string] $ExpectedTopLevelPrefix
    )

    $tarCommand = Get-Command -Name 'tar.exe' -CommandType Application -ErrorAction Stop
    $entries = @(& $tarCommand.Source -tf $Archive)
    if ($LASTEXITCODE -ne 0 -or $entries.Count -eq 0) {
        throw "Unable to inspect archive $Archive."
    }

    $normalizedPrefix = $ExpectedTopLevelPrefix.TrimEnd('/') + '/'
    foreach ($entry in $entries) {
        $normalizedEntry = ([string] $entry) -replace '\\', '/'
        if ($normalizedEntry.StartsWith('/') -or
            $normalizedEntry -match '(^|/)\.\.(/|$)' -or
            -not $normalizedEntry.StartsWith($normalizedPrefix, [StringComparison]::Ordinal)) {
            throw "Archive $Archive contains an unexpected or unsafe entry: $entry"
        }
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & $tarCommand.Source -xf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to extract archive $Archive."
    }
}

function Invoke-MsysCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string] $Description
    )

    if (-not (Test-Path -LiteralPath $script:BashPath -PathType Leaf)) {
        throw "MSYS2 bash was not found at $script:BashPath."
    }

    $oldMsystem = $env:MSYSTEM
    $oldChereInvoking = $env:CHERE_INVOKING
    $oldPathType = $env:MSYS2_PATH_TYPE
    try {
        $env:MSYSTEM = 'UCRT64'
        $env:CHERE_INVOKING = '1'
        $env:MSYS2_PATH_TYPE = 'minimal'
        $wrappedCommand = "export PATH=/ucrt64/bin:/usr/bin; $Command"
        & $script:BashPath --login -c $wrappedCommand
        if ($LASTEXITCODE -ne 0) {
            throw "$Description failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        $env:MSYSTEM = $oldMsystem
        $env:CHERE_INVOKING = $oldChereInvoking
        $env:MSYS2_PATH_TYPE = $oldPathType
    }
}

function Test-ReceiverEngine {
    $uxplayPath = Join-Path $script:InstallRootFull 'ucrt64\bin\uxplay.exe'
    $gstInspectPath = Join-Path $script:InstallRootFull 'ucrt64\bin\gst-inspect-1.0.exe'
    if (-not (Test-Path -LiteralPath $uxplayPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $gstInspectPath -PathType Leaf)) {
        return $false
    }

    $verification = @'
set -e
test -x /ucrt64/bin/uxplay.exe
uxplay -h >/dev/null 2>&1
grep -a -F "AIRMIRROR_RAOP_ONLY" /ucrt64/bin/uxplay.exe >/dev/null
grep -a -F "AIRMIRROR_STOP_EVENT" /ucrt64/bin/uxplay.exe >/dev/null
for element in appsrc queue h264parse decodebin videoconvert audioconvert audioresample autovideosink avdec_h264 avdec_aac avdec_alac d3d11videosink wasapisink; do
    gst-inspect-1.0 "$element" >/dev/null 2>&1
done
'@

    try {
        Invoke-MsysCommand -Command $verification -Description 'Receiver engine verification'
        return $true
    }
    catch {
        return $false
    }
}

function Test-MirrorSpeakerEnginePatchLevel {
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $false
    }

    try {
        $metadata = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        return $null -ne $metadata.airMirrorPatchLevel -and
            [int] $metadata.airMirrorPatchLevel -ge $MirrorSpeakerPatchLevel
    }
    catch {
        return $false
    }
}

function Apply-MirrorSpeakerUxPlayPatches {
    param([Parameter(Mandatory = $true)][string] $SourceRoot)

    $mdnsSourcePath = Join-Path $SourceRoot 'lib\mdnsd\mdnsd.c'
    $uxplaySourcePath = Join-Path $SourceRoot 'uxplay.cpp'
    if (-not (Test-Path -LiteralPath $mdnsSourcePath -PathType Leaf)) {
        throw 'The pinned UxPlay source is missing lib/mdnsd/mdnsd.c.'
    }
    if (-not (Test-Path -LiteralPath $uxplaySourcePath -PathType Leaf)) {
        throw 'The pinned UxPlay source is missing uxplay.cpp.'
    }

    $source = [IO.File]::ReadAllText($mdnsSourcePath)
    $defineNeedle = '#define MDNS_ADDR4 "224.0.0.251"'
    if (([regex]::Matches($source, [regex]::Escape($defineNeedle))).Count -ne 1) {
        throw 'The UxPlay mDNS IPv4 definition did not match the verified source exactly once.'
    }

    $source = $source.Replace(
        $defineNeedle,
        $defineNeedle + "`n#define AIRMIRROR_ROUTE_PROBE4 `"192.0.2.1`"")

    $functionPattern = '(?s)static uint32_t mdns_get_default_ipv4\(void\)\r?\n\{.*?\r?\n\}\r?\n\r?\n(?=static int mdns_get_default_ipv6)'
    $functionRegex = New-Object Text.RegularExpressions.Regex($functionPattern)
    if ($functionRegex.Matches($source).Count -ne 1) {
        throw 'The UxPlay IPv4 interface selector did not match the verified source exactly once.'
    }

    $functionReplacement = @'
static uint32_t mdns_route_ipv4(const char *destination)
{
    int fd;
    uint32_t addr = 0;
    struct sockaddr_in remote;
    struct sockaddr_in local;
    socklen_t local_len = sizeof(local);

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd == -1) {
        return 0;
    }

    memset(&remote, 0, sizeof(remote));
    remote.sin_family = AF_INET;
    remote.sin_port = htons(MDNS_PORT);
    if (inet_pton(AF_INET, destination, &remote.sin_addr) != 1) {
        CLOSESOCKET(fd);
        return 0;
    }

    if (connect(fd, (struct sockaddr *) &remote, sizeof(remote)) == 0 &&
        getsockname(fd, (struct sockaddr *) &local, &local_len) == 0) {
        addr = local.sin_addr.s_addr;
    }

    CLOSESOCKET(fd);
    return addr;
}

static int mdns_ipv4_is_local(uint32_t addr)
{
    int fd;
    int is_local = 0;
    struct sockaddr_in local;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd == -1) {
        return 0;
    }

    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = 0;
    local.sin_addr.s_addr = addr;
    if (bind(fd, (struct sockaddr *) &local, sizeof(local)) == 0) {
        is_local = 1;
    }

    CLOSESOCKET(fd);
    return is_local;
}

static uint32_t mdns_get_default_ipv4(void)
{
    const char *configured_addr = getenv("UXPLAY_MDNS_IPV4");
    struct in_addr configured;
    uint32_t addr;

    /* MirrorSpeaker supplies the address of the adapter with the default route.
     * This avoids advertising on Wi-Fi Direct and host-only virtual adapters
     * that Windows may otherwise choose for the IPv4 multicast destination. */
    memset(&configured, 0, sizeof(configured));
    if (configured_addr != NULL && configured_addr[0] != '\0' &&
        inet_pton(AF_INET, configured_addr, &configured) == 1 &&
        configured.s_addr != 0 && mdns_ipv4_is_local(configured.s_addr)) {
        return configured.s_addr;
    }

    /* A unicast route probe follows Windows' normal default route. If an
     * isolated LAN has no default route, preserve UxPlay's multicast probe. */
    addr = mdns_route_ipv4(AIRMIRROR_ROUTE_PROBE4);
    if (addr != 0) {
        return addr;
    }
    return mdns_route_ipv4(MDNS_ADDR4);
}

'@

    $source = $functionRegex.Replace($source, $functionReplacement, 1)

    $multicastInterfacePattern = '(?s)    if \(iface_addr\) \{\r?\n        struct in_addr iface;\r?\n        iface\.s_addr = iface_addr;\r?\n        setsockopt\(fd, IPPROTO_IP, IP_MULTICAST_IF, \(const char \*\) &iface, sizeof\(iface\)\);\r?\n    \}'
    $multicastInterfaceRegex = New-Object Text.RegularExpressions.Regex($multicastInterfacePattern)
    if ($multicastInterfaceRegex.Matches($source).Count -ne 1) {
        throw 'The UxPlay multicast interface configuration did not match the verified source exactly once.'
    }

    $multicastInterfaceReplacement = @'
    if (iface_addr) {
        struct in_addr iface;
        iface.s_addr = iface_addr;
        if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF,
                       (const char *) &iface, sizeof(iface)) == -1) {
            int error = SOCKET_GET_ERROR();
            CLOSESOCKET(fd);
            return -error;
        }
    }
'@
    $source = $multicastInterfaceRegex.Replace($source, $multicastInterfaceReplacement, 1)

    $membershipFallbackPattern = '(?s)        if \(iface_addr\) \{\r?\n            mreq\.imr_interface\.s_addr = htonl\(INADDR_ANY\);.*?            \}\r?\n        \}\r?\n'
    $membershipFallbackRegex = New-Object Text.RegularExpressions.Regex($membershipFallbackPattern)
    if ($membershipFallbackRegex.Matches($source).Count -ne 1) {
        throw 'The UxPlay multicast membership fallback did not match the verified source exactly once.'
    }
    $source = $membershipFallbackRegex.Replace($source, '', 1)

    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($mdnsSourcePath, $source, $utf8WithoutBom)

    $uxplaySource = [IO.File]::ReadAllText($uxplaySourcePath)
    $airplayRegistrationPattern = '(?s)    dnssd_error = dnssd_register_airplay\(dnssd, airplay_port\);\r?\n    if \(dnssd_error\) \{.*?\r?\n    \}\r?\n\r?\n(?=    LOGD\("register_dnssd)'
    $airplayRegistrationRegex = New-Object Text.RegularExpressions.Regex($airplayRegistrationPattern)
    if ($airplayRegistrationRegex.Matches($uxplaySource).Count -ne 1) {
        throw 'The UxPlay AirPlay service registration did not match the verified source exactly once.'
    }

    $airplayRegistrationReplacement = @'
    const char *raop_only = getenv("AIRMIRROR_RAOP_ONLY");
    const bool raop_only_mode = raop_only != NULL && strcmp(raop_only, "1") == 0;
    if (raop_only_mode) {
        LOGI("MirrorSpeaker audio-only discovery: advertising RAOP speaker service without AirPlay video service");
    } else {
        dnssd_error = dnssd_register_airplay(dnssd, airplay_port);
        if (dnssd_error) {
            if (ble_filename.empty()) {
                LOGE("dnssd_register_airplay failed with error code %d", dnssd_error);
                dnssd_error_text(&dnssd_error, appname);
                return -4;
            } else {
                LOGI("dnssd_register_airplay failed: ignoring because Bluetooth LE service discovery may be available");
            }
        }
    }

'@
    $uxplaySource = $airplayRegistrationRegex.Replace($uxplaySource, $airplayRegistrationReplacement, 1)

    $airplayLogNeedle = @'
    LOGD("register_dnssd: advertised AirPlay service with \"Features\" code = 0x%llX",
         dnssd_get_airplay_features(dnssd));
'@
    if (([regex]::Matches($uxplaySource, [regex]::Escape($airplayLogNeedle))).Count -ne 1) {
        throw 'The UxPlay discovery debug message did not match the verified source exactly once.'
    }
    $airplayLogReplacement = @'
    if (raop_only_mode) {
        LOGD("register_dnssd: advertised RAOP audio service only");
    } else {
        LOGD("register_dnssd: advertised AirPlay service with \"Features\" code = 0x%llX",
             dnssd_get_airplay_features(dnssd));
    }
'@
    $uxplaySource = $uxplaySource.Replace($airplayLogNeedle, $airplayLogReplacement)

    $windowsSignalNeedle = @'
static gboolean handle_signal(gpointer data) {
    relaunch_video = false;
    g_main_loop_quit(gmainloop);
    return G_SOURCE_REMOVE;
}

static BOOL WINAPI CtrlHandler(DWORD signal) {
'@
    if (([regex]::Matches($uxplaySource, [regex]::Escape($windowsSignalNeedle))).Count -ne 1) {
        throw 'The UxPlay Windows signal handler did not match the verified source exactly once.'
    }
    $windowsSignalReplacement = @'
static gboolean handle_signal(gpointer data) {
    relaunch_video = false;
    g_main_loop_quit(gmainloop);
    return G_SOURCE_REMOVE;
}

static HANDLE airmirror_stop_event = NULL;
static guint airmirror_stop_watch_id = 0;

static gboolean airmirror_stop_callback(gpointer loop) {
    if (airmirror_stop_event != NULL &&
        WaitForSingleObject(airmirror_stop_event, 0) == WAIT_OBJECT_0) {
        airmirror_stop_watch_id = 0;
        relaunch_video = false;
        g_main_loop_quit((GMainLoop *) loop);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static BOOL WINAPI CtrlHandler(DWORD signal) {
'@
    $uxplaySource = $uxplaySource.Replace($windowsSignalNeedle, $windowsSignalReplacement)

    $resetWatchNeedle = '    guint reset_watch_id = g_timeout_add(100, (GSourceFunc) reset_callback, (gpointer) loop);'
    if (([regex]::Matches($uxplaySource, [regex]::Escape($resetWatchNeedle))).Count -ne 1) {
        throw 'The UxPlay main-loop reset watcher did not match the verified source exactly once.'
    }
    $resetWatchReplacement = @'
    guint reset_watch_id = g_timeout_add(100, (GSourceFunc) reset_callback, (gpointer) loop);

#ifdef _WIN32
    const char *airmirror_stop_event_name = getenv("AIRMIRROR_STOP_EVENT");
    if (airmirror_stop_event_name != NULL && airmirror_stop_event_name[0] != '\0') {
        airmirror_stop_event = OpenEventA(SYNCHRONIZE, FALSE, airmirror_stop_event_name);
        if (airmirror_stop_event != NULL) {
            airmirror_stop_watch_id = g_timeout_add(
                100, (GSourceFunc) airmirror_stop_callback, (gpointer) loop);
        } else {
            LOGE("MirrorSpeaker graceful-stop event could not be opened");
        }
    }
#endif
'@
    $uxplaySource = $uxplaySource.Replace($resetWatchNeedle, $resetWatchReplacement)

    $loopCleanupNeedle = @'
    if (feedback_watch_id > 0) g_source_remove(feedback_watch_id);
    g_main_loop_unref(loop);
'@
    if (([regex]::Matches($uxplaySource, [regex]::Escape($loopCleanupNeedle))).Count -ne 1) {
        throw 'The UxPlay main-loop cleanup did not match the verified source exactly once.'
    }
    $loopCleanupReplacement = @'
    if (feedback_watch_id > 0) g_source_remove(feedback_watch_id);
#ifdef _WIN32
    if (airmirror_stop_watch_id > 0) {
        g_source_remove(airmirror_stop_watch_id);
        airmirror_stop_watch_id = 0;
    }
    if (airmirror_stop_event != NULL) {
        CloseHandle(airmirror_stop_event);
        airmirror_stop_event = NULL;
    }
#endif
    g_main_loop_unref(loop);
'@
    $uxplaySource = $uxplaySource.Replace($loopCleanupNeedle, $loopCleanupReplacement)
    [IO.File]::WriteAllText($uxplaySourcePath, $uxplaySource, $utf8WithoutBom)
}

function Remove-SetupWorkspace {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $candidate = Get-FullPath -Path $Path
    $tempRoot = (Get-FullPath -Path ([IO.Path]::GetTempPath())) + [IO.Path]::DirectorySeparatorChar
    $leafName = Split-Path -Leaf $candidate
    if (-not $candidate.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $leafName.StartsWith('MirrorSpeakerEngine-', [StringComparison]::Ordinal)) {
        throw "Refusing to clean an unexpected setup path: $candidate"
    }

    Remove-Item -LiteralPath $candidate -Recurse -Force
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is not available. Pass -InstallRoot explicitly.'
    }
    # The original storage identity is retained so upgrades reuse the already
    # installed 1-2 GB receiver engine instead of downloading it again.
    $InstallRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'AirMirror') 'engine'
}

$script:InstallRootFull = Get-FullPath -Path $InstallRoot
$installPathRoot = [IO.Path]::GetPathRoot($script:InstallRootFull).TrimEnd('\')
if ($script:InstallRootFull.TrimEnd('\') -eq $installPathRoot) {
    throw 'InstallRoot cannot be the root of a drive.'
}

$script:BashPath = Join-Path $script:InstallRootFull 'usr\bin\bash.exe'
$markerPath = Join-Path $script:InstallRootFull '.airmirror-engine.json'
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("MirrorSpeakerEngine-{0}" -f [Guid]::NewGuid().ToString('N'))
$oldProgressPreference = $ProgressPreference
$oldSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol

try {
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = $oldSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-MirrorSpeakerProgress -Percent 0 -Message 'Preparing receiver engine setup'

    if (Test-Path -LiteralPath $script:InstallRootFull -PathType Leaf) {
        throw "InstallRoot points to a file, not a directory: $script:InstallRootFull"
    }

    if (Test-Path -LiteralPath $script:InstallRootFull -PathType Container) {
        $existingItems = @(Get-ChildItem -LiteralPath $script:InstallRootFull -Force)
        $looksLikeMsys2 = Test-Path -LiteralPath $script:BashPath -PathType Leaf
        $isOwnedInstall = Test-Path -LiteralPath $markerPath -PathType Leaf
        if ($existingItems.Count -gt 0 -and -not $looksLikeMsys2 -and -not $isOwnedInstall) {
            throw "InstallRoot is not empty and is not a MirrorSpeaker or MSYS2 engine directory: $script:InstallRootFull"
        }
    }

    if ((Test-Path -LiteralPath $script:BashPath -PathType Leaf) -and -not $Force) {
        Write-MirrorSpeakerProgress -Percent 5 -Message 'Checking the existing receiver engine'
        if ((Test-ReceiverEngine) -and (Test-MirrorSpeakerEnginePatchLevel)) {
            Write-MirrorSpeakerProgress -Percent 100 -Message 'Receiver engine is already installed and verified'
            return
        }

        Write-MirrorSpeakerProgress -Percent 8 -Message 'Updating receiver compatibility'
    }

    New-Item -ItemType Directory -Path $script:InstallRootFull -Force | Out-Null
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

    if (-not (Test-Path -LiteralPath $script:BashPath -PathType Leaf)) {
        Write-MirrorSpeakerProgress -Percent 10 -Message 'Downloading the portable MSYS2 base image'
        $msysArchive = Join-Path $workRoot "msys2-base-$Msys2BaseVersion.tar.xz"
        $msysExtract = Join-Path $workRoot 'msys2-bootstrap'
        Invoke-Download -Uri $Msys2ArchiveUri -Destination $msysArchive

        $actualMsysHash = (Get-FileHash -LiteralPath $msysArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualMsysHash -ne $Msys2ArchiveSha256) {
            throw "The portable MSYS2 archive failed SHA-256 verification. Expected $Msys2ArchiveSha256 but received $actualMsysHash."
        }

        Write-MirrorSpeakerProgress -Percent 22 -Message 'Extracting the portable build environment'
        Expand-ValidatedTarArchive -Archive $msysArchive -Destination $msysExtract -ExpectedTopLevelPrefix 'msys64'
        $extractedMsysRoot = Join-Path $msysExtract 'msys64'
        if (-not (Test-Path -LiteralPath (Join-Path $extractedMsysRoot 'usr\bin\bash.exe') -PathType Leaf)) {
            throw 'The official MSYS2 archive did not contain the expected portable environment.'
        }

        Get-ChildItem -LiteralPath $extractedMsysRoot -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $script:InstallRootFull -Recurse -Force
        }
    }

    Write-MirrorSpeakerProgress -Percent 32 -Message 'Initializing the UCRT64 environment'
    Invoke-MsysCommand -Command 'true' -Description 'MSYS2 initialization'

    Write-MirrorSpeakerProgress -Percent 38 -Message 'Updating official MSYS2 packages'
    Invoke-MsysCommand -Command 'pacman -Syu --noconfirm' -Description 'MSYS2 system update'
    # Running the update again from a fresh shell completes any core-runtime
    # transition that required the first shell to exit.
    Invoke-MsysCommand -Command 'pacman -Syu --noconfirm' -Description 'MSYS2 system update completion'

    Write-MirrorSpeakerProgress -Percent 50 -Message 'Installing UxPlay and GStreamer build dependencies'
    $neededSwitch = '--needed'
    $packageCommand = "pacman -S --noconfirm $neededSwitch " + ($RequiredPackages -join ' ')
    Invoke-MsysCommand -Command $packageCommand -Description 'Receiver dependency installation'

    Write-MirrorSpeakerProgress -Percent 62 -Message 'Downloading pinned UxPlay 1.74 source'
    $uxplayArchive = Join-Path $workRoot "UxPlay-$UxPlayCommit.tar.gz"
    $uxplayExtract = Join-Path $workRoot 'uxplay-source'
    Invoke-Download -Uri $UxPlayArchiveUri -Destination $uxplayArchive

    $actualUxPlayHash = (Get-FileHash -LiteralPath $uxplayArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualUxPlayHash -ne $UxPlayArchiveSha256) {
        throw "The pinned UxPlay source archive failed SHA-256 verification. Expected $UxPlayArchiveSha256 but received $actualUxPlayHash."
    }

    Write-MirrorSpeakerProgress -Percent 68 -Message 'Validating and extracting UxPlay source'
    Expand-ValidatedTarArchive -Archive $uxplayArchive -Destination $uxplayExtract -ExpectedTopLevelPrefix "UxPlay-$UxPlayCommit"
    $sourceRoot = Join-Path $uxplayExtract "UxPlay-$UxPlayCommit"
    $cmakeFile = Join-Path $sourceRoot 'CMakeLists.txt'
    $readmeFile = Join-Path $sourceRoot 'README.md'
    if (-not (Test-Path -LiteralPath $cmakeFile -PathType Leaf) -or
        -not (Test-Path -LiteralPath $readmeFile -PathType Leaf) -or
        -not (Select-String -LiteralPath $cmakeFile -SimpleMatch 'lib/mdnsd' -Quiet) -or
        -not (Select-String -LiteralPath $readmeFile -SimpleMatch 'UxPlay 1.74' -Quiet)) {
        throw 'The pinned source does not contain the expected UxPlay 1.74 internal mDNS implementation.'
    }

    Write-MirrorSpeakerProgress -Percent 72 -Message 'Applying Windows discovery and audio-only fixes'
    Apply-MirrorSpeakerUxPlayPatches -SourceRoot $sourceRoot

    $buildRoot = Join-Path $workRoot 'uxplay-build'
    $sourceMsys = ConvertTo-ShellLiteral -Value (ConvertTo-MsysPath -Path $sourceRoot)
    $buildMsys = ConvertTo-ShellLiteral -Value (ConvertTo-MsysPath -Path $buildRoot)

    Write-MirrorSpeakerProgress -Percent 75 -Message 'Configuring UxPlay with internal mDNS'
    $configureCommand = "cmake -S $sourceMsys -B $buildMsys -G Ninja -DCMAKE_BUILD_TYPE=Release -DNO_MARCH_NATIVE=ON -DUSE_DNS_SD=OFF -DUSE_MDNS=ON -DCMAKE_INSTALL_PREFIX=/ucrt64"
    Invoke-MsysCommand -Command $configureCommand -Description 'UxPlay configuration'

    Write-MirrorSpeakerProgress -Percent 84 -Message 'Building the receiver engine'
    Invoke-MsysCommand -Command "cmake --build $buildMsys --parallel" -Description 'UxPlay build'

    Write-MirrorSpeakerProgress -Percent 92 -Message 'Installing the receiver engine'
    Invoke-MsysCommand -Command "cmake --install $buildMsys" -Description 'UxPlay installation'

    Write-MirrorSpeakerProgress -Percent 97 -Message 'Verifying receiver and multimedia plugins'
    if (-not (Test-ReceiverEngine)) {
        throw 'UxPlay or a required GStreamer audio/video plugin failed verification.'
    }

    $metadata = [ordered]@{
        schemaVersion = 2
        airMirrorPatchLevel = $MirrorSpeakerPatchLevel
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        installRoot = $script:InstallRootFull
        msys2BaseVersion = $Msys2BaseVersion
        uxPlayCommit = $UxPlayCommit
        serviceDiscovery = 'internal-mDNS'
        mdnsInterfaceSelection = 'default-route-with-environment-override'
        audioOnlyAdvertisement = 'raop-only-environment-switch'
        gracefulStop = 'named-event'
        uxPlayExecutable = (Join-Path $script:InstallRootFull 'ucrt64\bin\uxplay.exe')
    }
    $json = $metadata | ConvertTo-Json
    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($markerPath, $json, $utf8WithoutBom)

    Write-MirrorSpeakerProgress -Percent 100 -Message 'Receiver engine installed and verified'
}
catch {
    $failureMessage = $_.Exception.Message
    Write-MirrorSpeakerProgress -Percent 99 -Message "Failed - $failureMessage"
    throw
}
finally {
    try {
        Remove-SetupWorkspace -Path $workRoot
    }
    catch {
        Write-Warning "Setup workspace cleanup failed: $($_.Exception.Message)"
    }
    $ProgressPreference = $oldProgressPreference
    [Net.ServicePointManager]::SecurityProtocol = $oldSecurityProtocol
}
