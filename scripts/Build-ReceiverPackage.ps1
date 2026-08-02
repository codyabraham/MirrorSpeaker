#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string] $EngineRoot,

    [Parameter()]
    [string] $OutputRoot,

    [Parameter()]
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$')]
    [string] $PackageVersion = '1.0.0',

    [Parameter()]
    [string[]] $CorrespondingSourceArchive = @(),

    [Parameter()]
    [switch] $PublicRelease,

    [Parameter()]
    [switch] $ConfirmCompleteCorrespondingSource,

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($EngineRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable. Pass -EngineRoot explicitly.'
    }

    $EngineRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'AirMirror') 'engine'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot 'artifacts\receiver-engine\win-x64'
}

$utf8WithoutBom = New-Object Text.UTF8Encoding($false)

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $json = $Value | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8WithoutBom)
}

function Assert-SafeOutputChild {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = Get-NormalizedFullPath -Path $Path
    $fullOutputRoot = (Get-NormalizedFullPath -Path $script:OutputRootFull) + '\'
    if (-not $fullPath.StartsWith($fullOutputRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the receiver-package output directory: $fullPath"
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function New-PortableZip {
    param(
        [Parameter(Mandatory = $true)][string] $SourceDirectory,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    # ZipFile.CreateFromDirectory on Windows PowerShell 5.1 records backslashes
    # in entry names. Create entries directly so the portable archive follows
    # the ZIP convention and extracts correctly outside Windows as well.
    Add-Type -AssemblyName System.IO.Compression
    $destinationStream = [IO.File]::Open(
        $Destination,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    $archive = $null
    try {
        $archive = New-Object -TypeName IO.Compression.ZipArchive -ArgumentList @(
            $destinationStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false)
        $sourcePrefix = (Get-NormalizedFullPath -Path $SourceDirectory) + '\'
        foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Force | Sort-Object FullName) {
            $entryName = $file.FullName.Substring($sourcePrefix.Length).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $null
            $inputStream = $null
            try {
                $entryStream = $entry.Open()
                $inputStream = $file.OpenRead()
                $inputStream.CopyTo($entryStream)
            }
            finally {
                if ($null -ne $inputStream) {
                    $inputStream.Dispose()
                }
                if ($null -ne $entryStream) {
                    $entryStream.Dispose()
                }
            }
        }
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
        else {
            $destinationStream.Dispose()
        }
    }
}

function Read-PacmanSections {
    param([Parameter(Mandatory = $true)][string] $Path)

    $sections = @{}
    $current = $null
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^%(.+)%$') {
            $current = $Matches[1]
            $sections[$current] = @()
            continue
        }

        if ($null -ne $current -and -not [string]::IsNullOrEmpty($line)) {
            $sections[$current] += [string] $line
        }
    }

    return $sections
}

function Test-WindowsSystemImport {
    param([Parameter(Mandatory = $true)][string] $Name)

    $normalized = $Name.ToLowerInvariant()
    if ($normalized -match '^(api|ext)-ms-win-') {
        return $true
    }

    $windowsLibraries = @(
        'advapi32.dll',
        'bcrypt.dll',
        'bcryptprimitives.dll',
        'cfgmgr32.dll',
        'combase.dll',
        'crypt32.dll',
        'd2d1.dll',
        'd3d11.dll',
        'dnsapi.dll',
        'dwrite.dll',
        'dxgi.dll',
        'gdi32.dll',
        'gdiplus.dll',
        'iphlpapi.dll',
        'kernel32.dll',
        'mf.dll',
        'mfplat.dll',
        'mfreadwrite.dll',
        'mfuuid.dll',
        'msimg32.dll',
        'ncrypt.dll',
        'normaliz.dll',
        'ntdll.dll',
        'ole32.dll',
        'oleaut32.dll',
        'propsys.dll',
        'rpcrt4.dll',
        'secur32.dll',
        'setupapi.dll',
        'shell32.dll',
        'shlwapi.dll',
        'ucrtbase.dll',
        'user32.dll',
        'userenv.dll',
        'usp10.dll',
        'version.dll',
        'winhttp.dll',
        'winmm.dll',
        'ws2_32.dll',
        'wsock32.dll'
    )

    return $windowsLibraries -contains $normalized
}

function Get-PeImports {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ObjdumpPath
    )

    $output = @(& $ObjdumpPath -p $Path 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "objdump could not inspect $Path (exit code $LASTEXITCODE)."
    }

    $imports = @()
    foreach ($lineValue in $output) {
        $line = [string] $lineValue
        if ($line -match '^\s*DLL Name:\s*(.+?)\s*$') {
            $imports += $Matches[1].Trim()
        }
    }

    return @($imports | Sort-Object -Unique)
}

function Restore-EnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [AllowNull()][string] $Value
    )

    if ($null -eq $Value) {
        Remove-Item -LiteralPath ("Env:\" + $Name) -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath ("Env:\" + $Name) -Value $Value
    }
}

$script:OutputRootFull = Get-NormalizedFullPath -Path $OutputRoot
$engineRootFull = Get-NormalizedFullPath -Path $EngineRoot

if (-not (Test-Path -LiteralPath $engineRootFull -PathType Container)) {
    throw "The receiver engine was not found at $engineRootFull."
}

$driveRoot = [IO.Path]::GetPathRoot($script:OutputRootFull).TrimEnd('\')
if ($script:OutputRootFull -eq $driveRoot) {
    throw 'OutputRoot cannot be the root of a drive.'
}

$engineMarkerPath = Join-Path $engineRootFull '.airmirror-engine.json'
$ucrtRoot = Join-Path $engineRootFull 'ucrt64'
$binRoot = Join-Path $ucrtRoot 'bin'
$pluginRoot = Join-Path $ucrtRoot 'lib\gstreamer-1.0'
$pluginScannerRoot = Join-Path $ucrtRoot 'libexec\gstreamer-1.0'
$objdumpPath = Join-Path $binRoot 'objdump.exe'
$pacmanLocalDatabase = Join-Path $engineRootFull 'var\lib\pacman\local'

foreach ($requiredPath in @($engineMarkerPath, $objdumpPath, $pacmanLocalDatabase)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "The installed engine is missing packaging metadata or tools: $requiredPath"
    }
}

$markerRaw = [IO.File]::ReadAllText($engineMarkerPath)
try {
    $engineMarker = $markerRaw | ConvertFrom-Json
}
catch {
    throw "The receiver marker is not valid JSON: $engineMarkerPath. $($_.Exception.Message)"
}

$uxPlayCommit = $null
$patchLevel = $null
if ($null -ne $engineMarker.PSObject.Properties['uxPlayCommit']) {
    $uxPlayCommit = [string] $engineMarker.uxPlayCommit
}
if ($null -ne $engineMarker.PSObject.Properties['airMirrorPatchLevel']) {
    $patchLevel = [int] $engineMarker.airMirrorPatchLevel
}
if ([string]::IsNullOrWhiteSpace($uxPlayCommit) -or $null -eq $patchLevel) {
    throw 'The receiver marker does not identify its UxPlay commit and MirrorSpeaker patch level.'
}

$resolvedSourceArchives = @()
$sourceArchiveNames = @{}
foreach ($sourceArchive in @($CorrespondingSourceArchive)) {
    if ([string]::IsNullOrWhiteSpace($sourceArchive)) {
        continue
    }

    $sourceFullPath = Get-NormalizedFullPath -Path $sourceArchive
    if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) {
        throw "A corresponding-source archive was not found: $sourceFullPath"
    }

    $sourceItem = Get-Item -LiteralPath $sourceFullPath
    if ($sourceArchiveNames.ContainsKey($sourceItem.Name)) {
        throw "Corresponding-source archives must have unique file names: $($sourceItem.Name)"
    }

    $sourceArchiveNames[$sourceItem.Name] = $true
    $resolvedSourceArchives += $sourceItem
}

if ($PublicRelease) {
    if ($resolvedSourceArchives.Count -eq 0) {
        throw 'Public packaging is blocked: pass one or more exact corresponding-source archives with -CorrespondingSourceArchive.'
    }
    if (-not $ConfirmCompleteCorrespondingSource) {
        throw 'Public packaging is blocked: -ConfirmCompleteCorrespondingSource is required after verifying that the supplied archives cover the modified UxPlay build and every GPL/LGPL runtime component.'
    }
}

$requiredGStreamerElements = @(
    'appsrc',
    'queue',
    'h264parse',
    'decodebin',
    'videoconvert',
    'audioconvert',
    'audioresample',
    'volume',
    'autovideosink',
    'avdec_h264',
    'avdec_aac',
    'avdec_alac',
    'd3d11videosink',
    'wasapisink'
)

# GStreamer discovers plug-ins at runtime, so their DLLs do not appear as
# imports of uxplay.exe. These are the modules that provide the elements above.
# volume and typefindfunctions are included in addition to the installer checks:
# UxPlay constructs a volume element, and decodebin may perform type detection.
$requiredPluginFiles = @(
    'libgstapp.dll',
    'libgstcoreelements.dll',
    'libgstvideoparsersbad.dll',
    'libgstplayback.dll',
    'libgstvideoconvertscale.dll',
    'libgstaudioconvert.dll',
    'libgstaudioresample.dll',
    'libgstvolume.dll',
    'libgstautodetect.dll',
    'libgstlibav.dll',
    'libgstd3d11.dll',
    'libgstwasapi.dll',
    'libgsttypefindfunctions.dll'
)

$rootFiles = @(
    (Join-Path $binRoot 'uxplay.exe'),
    (Join-Path $binRoot 'gst-inspect-1.0.exe'),
    (Join-Path $pluginScannerRoot 'gst-plugin-scanner.exe')
)
$rootFiles += $requiredPluginFiles | ForEach-Object { Join-Path $pluginRoot $_ }

foreach ($rootFile in $rootFiles) {
    if (-not (Test-Path -LiteralPath $rootFile -PathType Leaf)) {
        throw "A required receiver runtime file is missing: $rootFile"
    }
}

# Windows resolves imported MinGW DLLs through ucrt64\bin. Keep the plug-in and
# helper executables as explicit roots, but resolve their imports from bin.
$runtimeFileByName = @{}
Get-ChildItem -LiteralPath $binRoot -File | Where-Object {
    $_.Extension -ieq '.dll' -or $_.Extension -ieq '.exe'
} | ForEach-Object {
    $runtimeFileByName[$_.Name.ToLowerInvariant()] = $_.FullName
}

$pending = New-Object 'System.Collections.Generic.Queue[string]'
foreach ($rootFile in $rootFiles) {
    $pending.Enqueue((Get-NormalizedFullPath -Path $rootFile))
}

$includedFiles = @{}
$importsByFile = @{}
$externalSystemImports = @{}
$unresolvedImports = @{}

while ($pending.Count -gt 0) {
    $currentPath = $pending.Dequeue()
    if ($includedFiles.ContainsKey($currentPath)) {
        continue
    }

    $currentItem = Get-Item -LiteralPath $currentPath
    $includedFiles[$currentPath] = [long] $currentItem.Length
    $imports = @(Get-PeImports -Path $currentPath -ObjdumpPath $objdumpPath)
    $importsByFile[$currentPath] = $imports

    foreach ($import in $imports) {
        $key = $import.ToLowerInvariant()
        if ($runtimeFileByName.ContainsKey($key)) {
            $dependencyPath = [string] $runtimeFileByName[$key]
            if (-not $includedFiles.ContainsKey($dependencyPath)) {
                $pending.Enqueue($dependencyPath)
            }
        }
        elseif (Test-WindowsSystemImport -Name $import) {
            $externalSystemImports[$import] = $true
        }
        else {
            $unresolvedImports[$import] = $true
        }
    }
}

if ($unresolvedImports.Count -gt 0) {
    $missingList = ($unresolvedImports.Keys | Sort-Object) -join ', '
    throw "The receiver has imported DLLs that are neither staged nor recognized as Windows system libraries: $missingList"
}

# Build a file-to-package map from the installed MSYS2 database. This creates a
# versioned dependency inventory without copying the package manager or toolchain.
$packageByName = @{}
$ownerByRelativePath = @{}
foreach ($packageDirectory in Get-ChildItem -LiteralPath $pacmanLocalDatabase -Directory) {
    $descriptionPath = Join-Path $packageDirectory.FullName 'desc'
    $filesPath = Join-Path $packageDirectory.FullName 'files'
    if (-not (Test-Path -LiteralPath $descriptionPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $filesPath -PathType Leaf)) {
        continue
    }

    $description = Read-PacmanSections -Path $descriptionPath
    if (-not $description.ContainsKey('NAME') -or $description['NAME'].Count -eq 0) {
        continue
    }

    $packageName = [string] $description['NAME'][0]
    $packageVersionValue = ''
    $packageLicenses = @()
    $installedSize = 0
    if ($description.ContainsKey('VERSION') -and $description['VERSION'].Count -gt 0) {
        $packageVersionValue = [string] $description['VERSION'][0]
    }
    if ($description.ContainsKey('LICENSE')) {
        $packageLicenses = @($description['LICENSE'])
    }
    if ($description.ContainsKey('SIZE') -and $description['SIZE'].Count -gt 0) {
        $installedSize = [long] $description['SIZE'][0]
    }

    $packageByName[$packageName] = [pscustomobject][ordered]@{
        name = $packageName
        version = $packageVersionValue
        installedSize = $installedSize
        licenses = $packageLicenses
    }

    $fileSections = Read-PacmanSections -Path $filesPath
    if (-not $fileSections.ContainsKey('FILES')) {
        continue
    }

    foreach ($relativePackagePath in @($fileSections['FILES'])) {
        if ($relativePackagePath.EndsWith('/')) {
            continue
        }
        $normalizedPackagePath = $relativePackagePath.Replace('/', '\')
        $ownerByRelativePath[$normalizedPackagePath] = $packageName
    }
}

$runtimeFileRecords = @()
$usedPackageNames = @{}
foreach ($includedPath in @($includedFiles.Keys | Sort-Object)) {
    $relativePath = $includedPath.Substring($engineRootFull.Length).TrimStart('\')
    $packageName = 'MirrorSpeaker-modified-UxPlay'
    if ($ownerByRelativePath.ContainsKey($relativePath)) {
        $packageName = [string] $ownerByRelativePath[$relativePath]
    }
    $usedPackageNames[$packageName] = $true

    $runtimeFileRecords += [pscustomobject][ordered]@{
        path = $relativePath.Replace('\', '/')
        size = [long] $includedFiles[$includedPath]
        sha256 = Get-Sha256 -Path $includedPath
        package = $packageName
        imports = @($importsByFile[$includedPath])
    }
}

$packageRecords = @()
foreach ($usedPackageName in @($usedPackageNames.Keys | Sort-Object)) {
    if ($usedPackageName -eq 'MirrorSpeaker-modified-UxPlay') {
        $packageRecords += [pscustomobject][ordered]@{
            name = $usedPackageName
            version = $uxPlayCommit
            installedSize = [long] $includedFiles[(Join-Path $binRoot 'uxplay.exe')]
            licenses = @('GPL-3.0')
        }
    }
    elseif ($packageByName.ContainsKey($usedPackageName)) {
        $packageRecords += $packageByName[$usedPackageName]
    }
    else {
        $packageRecords += [pscustomobject][ordered]@{
            name = $usedPackageName
            version = 'unknown'
            installedSize = 0
            licenses = @('unknown')
        }
    }
}

$archiveBaseName = "MirrorSpeaker-Receiver-$PackageVersion-win-x64"
$archiveFileName = "$archiveBaseName.zip"
$archivePath = Join-Path $script:OutputRootFull $archiveFileName
$archiveHashPath = $archivePath + '.sha256'
$externalManifestPath = Join-Path $script:OutputRootFull "$archiveBaseName.manifest.json"
$externalDependenciesPath = Join-Path $script:OutputRootFull "$archiveBaseName.dependencies.json"
$externalSourcesPath = Join-Path $script:OutputRootFull "$archiveBaseName.sources.json"
$finalEnginePath = Join-Path $script:OutputRootFull 'engine'
$finalMetadataPath = Join-Path $script:OutputRootFull 'metadata'
$finalSourcesPath = Join-Path $script:OutputRootFull 'sources'
$finalNoticePath = Join-Path $script:OutputRootFull 'REDISTRIBUTION-NOTICE.txt'
$stagingRoot = Join-Path $script:OutputRootFull ('.staging-' + [Guid]::NewGuid().ToString('N'))
$temporaryArchivePath = Join-Path $script:OutputRootFull ('.archive-' + [Guid]::NewGuid().ToString('N') + '.zip')
$stagedEnginePath = Join-Path $stagingRoot 'engine'
$stagedMetadataPath = Join-Path $stagingRoot 'metadata'
$stagedSourcesPath = Join-Path $stagingRoot 'sources'
$validationRegistryPath = Join-Path $stagingRoot '.validation-registry.bin'
$validationHomePath = Join-Path $stagingRoot '.validation-home'

New-Item -ItemType Directory -Path $script:OutputRootFull -Force | Out-Null
Assert-SafeOutputChild -Path $stagingRoot
Assert-SafeOutputChild -Path $temporaryArchivePath

$managedTargets = @(
    $finalEnginePath,
    $finalMetadataPath,
    $finalSourcesPath,
    $finalNoticePath,
    $archivePath,
    $archiveHashPath,
    $externalManifestPath,
    $externalDependenciesPath,
    $externalSourcesPath
)
$existingTargets = @($managedTargets | Where-Object { Test-Path -LiteralPath $_ })
if ($existingTargets.Count -gt 0 -and -not $Force) {
    throw "Receiver-package output already exists. Pass -Force to replace it: $($existingTargets -join ', ')"
}

try {
    New-Item -ItemType Directory -Path $stagedEnginePath -Force | Out-Null
    New-Item -ItemType Directory -Path $stagedMetadataPath -Force | Out-Null

    foreach ($includedPath in @($includedFiles.Keys)) {
        $relativePath = $includedPath.Substring($engineRootFull.Length).TrimStart('\')
        $destinationPath = Join-Path $stagedEnginePath $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
        Copy-Item -LiteralPath $includedPath -Destination $destinationPath -Force
    }

    # Include all license material installed by MSYS2 plus UxPlay's installed
    # GPL/license documentation. Some MSYS2 packages do not install license
    # texts here, so this is necessary but not sufficient for redistribution.
    Copy-DirectoryContents `
        -Source (Join-Path $ucrtRoot 'share\licenses') `
        -Destination (Join-Path $stagedEnginePath 'ucrt64\share\licenses')
    Copy-DirectoryContents `
        -Source (Join-Path $ucrtRoot 'share\doc\uxplay') `
        -Destination (Join-Path $stagedEnginePath 'ucrt64\share\doc\uxplay')

    # Preserve the engine marker's compatibility fields without publishing the
    # build machine's user profile or stale absolute installation path.
    if ($null -ne $engineMarker.PSObject.Properties['installRoot']) {
        $engineMarker.installRoot = 'engine'
    }
    if ($null -ne $engineMarker.PSObject.Properties['uxPlayExecutable']) {
        $engineMarker.uxPlayExecutable = 'engine\ucrt64\bin\uxplay.exe'
    }
    Write-JsonFile -Value $engineMarker -Path (Join-Path $stagedEnginePath '.airmirror-engine.json')

    $sourceArchiveRecords = @()
    if ($resolvedSourceArchives.Count -gt 0) {
        New-Item -ItemType Directory -Path $stagedSourcesPath -Force | Out-Null
        foreach ($sourceItem in $resolvedSourceArchives) {
            $sourceDestination = Join-Path $stagedSourcesPath $sourceItem.Name
            Copy-Item -LiteralPath $sourceItem.FullName -Destination $sourceDestination -Force
            $sourceArchiveRecords += [pscustomobject][ordered]@{
                fileName = $sourceItem.Name
                size = [long] $sourceItem.Length
                sha256 = Get-Sha256 -Path $sourceDestination
            }
        }
    }

    $copyleftPackages = @($packageRecords | Where-Object {
        (($_.licenses -join ' ') -match '(?i)(GPL|LGPL|MPL|CDDL)')
    } | ForEach-Object {
        [pscustomobject][ordered]@{
            name = $_.name
            version = $_.version
            licenses = @($_.licenses)
        }
    })

    $dependenciesMetadata = [ordered]@{
        schemaVersion = 1
        packageVersion = $PackageVersion
        architecture = 'win-x64'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        uxPlayCommit = $uxPlayCommit
        mirrorSpeakerPatchLevel = $patchLevel
        rootFiles = @($rootFiles | ForEach-Object {
            $_.Substring($engineRootFull.Length).TrimStart('\').Replace('\', '/')
        })
        requiredGStreamerElements = $requiredGStreamerElements
        requiredGStreamerPluginFiles = $requiredPluginFiles
        runtimeFiles = $runtimeFileRecords
        externalWindowsLibraries = @($externalSystemImports.Keys | Sort-Object)
        packages = $packageRecords
        notes = @(
            'PE imports do not expose every runtime-loaded media component; the explicit GStreamer plug-in roots are therefore part of this manifest.',
            'The package intentionally excludes the MSYS2 shell, compiler, headers, CMake, Ninja, package database, caches, and build tools.',
            'Clean Windows 11 testing with an actual iPhone screen-and-audio session remains required before release.'
        )
    }

    $sourceComplianceMetadata = [ordered]@{
        schemaVersion = 1
        packageVersion = $PackageVersion
        publicReleaseRequested = [bool] $PublicRelease
        completeCorrespondingSourceConfirmed = [bool] $ConfirmCompleteCorrespondingSource
        publicRedistributionGatePassed = [bool] (
            $PublicRelease -and
            $ConfirmCompleteCorrespondingSource -and
            $sourceArchiveRecords.Count -gt 0)
        originalEngineMarkerSha256 = Get-Sha256 -Path $engineMarkerPath
        uxPlay = [ordered]@{
            commit = $uxPlayCommit
            mirrorSpeakerPatchLevel = $patchLevel
            license = 'GPL-3.0'
            sourceMustInclude = @(
                'The complete source for the exact pinned UxPlay revision.',
                'Every MirrorSpeaker modification, including discovery, RAOP-only audio advertisement, graceful stop, and connection-reset changes.',
                'The scripts, configuration, and instructions needed to rebuild the conveyed executable.'
            )
        }
        runtimePackages = $packageRecords
        copyleftSourceCandidates = $copyleftPackages
        suppliedArchives = $sourceArchiveRecords
        warning = 'This script inventories binaries and enforces an explicit release gate; it does not determine legal sufficiency. The maintainer confirmation asserts that the supplied archives contain exact corresponding source and build materials for every conveyed GPL/LGPL component.'
    }

    $packageMetadata = [ordered]@{
        schemaVersion = 1
        product = 'MirrorSpeaker Receiver Engine'
        packageVersion = $PackageVersion
        architecture = 'win-x64'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        uxPlayCommit = $uxPlayCommit
        mirrorSpeakerPatchLevel = $patchLevel
        runtimeFileCount = $runtimeFileRecords.Count
        runtimeBytes = [long] (($runtimeFileRecords | Measure-Object -Property size -Sum).Sum)
        packageCount = $packageRecords.Count
        publicReleaseCandidate = [bool] $sourceComplianceMetadata.publicRedistributionGatePassed
        layout = [ordered]@{
            executable = 'engine/ucrt64/bin/uxplay.exe'
            plugins = 'engine/ucrt64/lib/gstreamer-1.0'
            pluginScanner = 'engine/ucrt64/libexec/gstreamer-1.0/gst-plugin-scanner.exe'
            marker = 'engine/.airmirror-engine.json'
        }
    }

    Write-JsonFile -Value $dependenciesMetadata -Path (Join-Path $stagedMetadataPath 'dependencies.json')
    Write-JsonFile -Value $sourceComplianceMetadata -Path (Join-Path $stagedMetadataPath 'source-compliance.json')
    Write-JsonFile -Value $packageMetadata -Path (Join-Path $stagedMetadataPath 'package.json')

    $noticeLines = @(
        'MirrorSpeaker receiver package redistribution notice',
        '====================================================',
        '',
        "Package version: $PackageVersion",
        "UxPlay source revision: $uxPlayCommit",
        "MirrorSpeaker receiver patch level: $patchLevel",
        ''
    )
    if ($sourceComplianceMetadata.publicRedistributionGatePassed) {
        $noticeLines += @(
            'PUBLIC RELEASE CANDIDATE - SOURCE COMPLIANCE SELF-ATTESTED',
            '',
            'The package builder was explicitly told that the source archives in',
            'the sources directory contain exact corresponding source and build',
            'materials for every conveyed GPL/LGPL component. This automated gate',
            'is not a legal review. Verify metadata/source-compliance.json before',
            'publishing or signing this package.'
        )
    }
    else {
        $noticeLines += @(
            'INTERNAL EVALUATION PACKAGE - DO NOT REDISTRIBUTE PUBLICLY',
            '',
            'This package contains modified GPL-3.0 UxPlay and GPL/LGPL multimedia',
            'runtime components. Installed license files alone do not satisfy all',
            'source-distribution obligations. Rebuild with -PublicRelease, one or',
            'more exact -CorrespondingSourceArchive files, and',
            '-ConfirmCompleteCorrespondingSource only after a complete source and',
            'license audit.'
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $stagingRoot 'REDISTRIBUTION-NOTICE.txt'),
        ($noticeLines -join [Environment]::NewLine) + [Environment]::NewLine,
        $utf8WithoutBom)

    # Validate from the staged tree with no access to the original engine path.
    $stagedBinRoot = Join-Path $stagedEnginePath 'ucrt64\bin'
    $stagedPluginRoot = Join-Path $stagedEnginePath 'ucrt64\lib\gstreamer-1.0'
    $stagedPluginScanner = Join-Path $stagedEnginePath 'ucrt64\libexec\gstreamer-1.0\gst-plugin-scanner.exe'
    $stagedUxPlay = Join-Path $stagedBinRoot 'uxplay.exe'
    $stagedGstInspect = Join-Path $stagedBinRoot 'gst-inspect-1.0.exe'

    $oldPath = $env:PATH
    $oldPluginPath = $env:GST_PLUGIN_PATH_1_0
    $oldSystemPluginPath = $env:GST_PLUGIN_SYSTEM_PATH_1_0
    $oldPluginScanner = $env:GST_PLUGIN_SCANNER_1_0
    $oldRegistry = $env:GST_REGISTRY_1_0
    $oldHome = $env:HOME
    try {
        New-Item -ItemType Directory -Path $validationHomePath -Force | Out-Null
        $env:PATH = $stagedBinRoot
        $env:GST_PLUGIN_PATH_1_0 = $stagedPluginRoot
        $env:GST_PLUGIN_SYSTEM_PATH_1_0 = $stagedPluginRoot
        $env:GST_PLUGIN_SCANNER_1_0 = $stagedPluginScanner
        $env:GST_REGISTRY_1_0 = $validationRegistryPath
        $env:HOME = $validationHomePath

        $null = @(& $stagedUxPlay -h 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "The staged UxPlay help check failed with exit code $LASTEXITCODE."
        }

        foreach ($element in $requiredGStreamerElements) {
            $null = @(& $stagedGstInspect $element 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "The staged GStreamer element '$element' failed validation."
            }
        }

        $null = @(& $stagedGstInspect 'typefindfunctions' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "The staged GStreamer typefindfunctions plug-in failed validation."
        }
    }
    finally {
        Restore-EnvironmentValue -Name 'PATH' -Value $oldPath
        Restore-EnvironmentValue -Name 'GST_PLUGIN_PATH_1_0' -Value $oldPluginPath
        Restore-EnvironmentValue -Name 'GST_PLUGIN_SYSTEM_PATH_1_0' -Value $oldSystemPluginPath
        Restore-EnvironmentValue -Name 'GST_PLUGIN_SCANNER_1_0' -Value $oldPluginScanner
        Restore-EnvironmentValue -Name 'GST_REGISTRY_1_0' -Value $oldRegistry
        Restore-EnvironmentValue -Name 'HOME' -Value $oldHome
        Remove-Item -LiteralPath $validationRegistryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $validationHomePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-PortableZip -SourceDirectory $stagingRoot -Destination $temporaryArchivePath

    $temporaryArchiveHash = Get-Sha256 -Path $temporaryArchivePath
    $temporaryArchiveSize = (Get-Item -LiteralPath $temporaryArchivePath).Length

    foreach ($managedTarget in $managedTargets) {
        if (Test-Path -LiteralPath $managedTarget) {
            Assert-SafeOutputChild -Path $managedTarget
            Remove-Item -LiteralPath $managedTarget -Recurse -Force
        }
    }

    Move-Item -LiteralPath (Join-Path $stagingRoot 'engine') -Destination $finalEnginePath
    Move-Item -LiteralPath (Join-Path $stagingRoot 'metadata') -Destination $finalMetadataPath
    if (Test-Path -LiteralPath (Join-Path $stagingRoot 'sources')) {
        Move-Item -LiteralPath (Join-Path $stagingRoot 'sources') -Destination $finalSourcesPath
    }
    Move-Item -LiteralPath (Join-Path $stagingRoot 'REDISTRIBUTION-NOTICE.txt') -Destination $finalNoticePath
    Move-Item -LiteralPath $temporaryArchivePath -Destination $archivePath

    [IO.File]::WriteAllText(
        $archiveHashPath,
        "$temporaryArchiveHash *$archiveFileName" + [Environment]::NewLine,
        $utf8WithoutBom)

    Copy-Item -LiteralPath (Join-Path $finalMetadataPath 'dependencies.json') -Destination $externalDependenciesPath -Force
    Copy-Item -LiteralPath (Join-Path $finalMetadataPath 'source-compliance.json') -Destination $externalSourcesPath -Force

    $externalManifest = [ordered]@{
        schemaVersion = 1
        product = 'MirrorSpeaker Receiver Engine'
        packageVersion = $PackageVersion
        architecture = 'win-x64'
        archive = [ordered]@{
            fileName = $archiveFileName
            size = [long] $temporaryArchiveSize
            sha256 = $temporaryArchiveHash
        }
        expandedEngine = 'engine'
        metadata = [ordered]@{
            package = 'metadata/package.json'
            dependencies = 'metadata/dependencies.json'
            sourceCompliance = 'metadata/source-compliance.json'
        }
        publicReleaseCandidate = [bool] $sourceComplianceMetadata.publicRedistributionGatePassed
    }
    Write-JsonFile -Value $externalManifest -Path $externalManifestPath

    Write-Output "Receiver package created: $archivePath"
    Write-Output "SHA-256: $temporaryArchiveHash"
    Write-Output "Expanded engine: $finalEnginePath"
    if (-not $sourceComplianceMetadata.publicRedistributionGatePassed) {
        Write-Warning 'This package is marked INTERNAL EVALUATION - DO NOT REDISTRIBUTE PUBLICLY.'
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryArchivePath) {
        Assert-SafeOutputChild -Path $temporaryArchivePath
        Remove-Item -LiteralPath $temporaryArchivePath -Force
    }
    if (Test-Path -LiteralPath $stagingRoot) {
        Assert-SafeOutputChild -Path $stagingRoot
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
