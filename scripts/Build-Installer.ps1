#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [Parameter()]
    [string] $Version,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Publisher = 'MirrorSpeaker Project',

    [Parameter()]
    [string] $PublisherUrl = '',

    [Parameter()]
    [string] $InnoCompilerPath = '',

    [Parameter()]
    [switch] $SkipApplicationBuild,

    [Parameter()]
    [switch] $RequireReceiverEngine,

    [Parameter()]
    [switch] $AllowInternalReceiverEngine,

    [Parameter()]
    [switch] $ExcludeReceiverEngine
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$buildReleaseScript = Join-Path $PSScriptRoot 'Build-Release.ps1'
$projectPath = Join-Path $repoRoot 'src\AirMirror.App\AirMirror.App.csproj'
$testProjectPath = Join-Path $repoRoot 'tests\AirMirror.Core.SmokeTests\AirMirror.Core.SmokeTests.csproj'
$publishDirectory = Join-Path $repoRoot 'dist\win-x64'
$applicationPath = Join-Path $publishDirectory 'MirrorSpeaker.exe'
$installerScript = Join-Path $repoRoot 'installer\MirrorSpeaker.iss'
$artifactsRoot = Join-Path $repoRoot 'artifacts'
$outputDirectory = Join-Path $artifactsRoot 'release'
$engineDirectory = Join-Path $artifactsRoot 'receiver-engine\win-x64\engine'
$enginePackageMetadataPath = Join-Path $artifactsRoot 'receiver-engine\win-x64\metadata\package.json'
$stagingDirectory = Join-Path $artifactsRoot ('.installer-staging-' + [Guid]::NewGuid().ToString('N'))
$portableDirectory = Join-Path $stagingDirectory 'portable'

function Assert-SafeArtifactsChild {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullArtifactsRoot = [IO.Path]::GetFullPath($artifactsRoot).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullArtifactsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a packaging path outside the repository artifacts directory: $fullPath"
    }
}

function Get-ProjectVersion {
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        throw "The application project was not found at $projectPath."
    }

    [xml] $project = Get-Content -LiteralPath $projectPath -Raw
    $versions = @(
        $project.Project.PropertyGroup |
            ForEach-Object { $_.Version } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
    )
    if ($versions.Count -eq 0) {
        throw "The application project does not define a Version property."
    }

    return ([string] $versions[0]).Trim()
}

function Add-InnoCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]] $Candidates,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Path
    )

    foreach ($candidatePath in @($Path)) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
            [void] $Candidates.Add($candidatePath)
        }
    }
}

function Find-InnoCompiler {
    $candidates = New-Object 'Collections.Generic.List[string]'
    $baseDirectories = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $(if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $null
        }
        else {
            Join-Path $env:LOCALAPPDATA 'Programs'
        })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }

    foreach ($majorVersion in @('7')) {
        foreach ($baseDirectory in $baseDirectories) {
            Add-InnoCandidate -Candidates $candidates -Path (
                Join-Path $baseDirectory "Inno Setup $majorVersion\ISCC.exe")
        }
    }

    $pathCommand = Get-Command -Name 'ISCC.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand) {
        Add-InnoCandidate -Candidates $candidates -Path $pathCommand.Source
    }

    foreach ($majorVersion in @('7')) {
        $registryKeys = @(
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup $majorVersion`_is1",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup $majorVersion`_is1",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup $majorVersion`_is1"
        )
        foreach ($registryKey in $registryKeys) {
            try {
                $properties = Get-ItemProperty -LiteralPath $registryKey -ErrorAction Stop
                $installLocation = [string] $properties.InstallLocation
                if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                    Add-InnoCandidate -Candidates $candidates -Path (
                        Join-Path $installLocation 'ISCC.exe')
                }
            }
            catch {
                # This registry view does not contain Inno Setup.
            }
        }
    }

    $seen = New-Object 'Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        try {
            $fullCandidate = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($candidate))
            if ($seen.Add($fullCandidate) -and
                (Test-Path -LiteralPath $fullCandidate -PathType Leaf)) {
                return $fullCandidate
            }
        }
        catch {
            # Ignore malformed discovery candidates and continue.
        }
    }

    throw @'
Inno Setup 7.0.2 was not found. Install it, then run this script again.
Recommended command:
  winget install --id JRSoftware.InnoSetup.7 -e
'@
}

function Assert-InnoCompilerVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CompilerPath
    )

    $expectedVersion = '7.0.2'
    $fullCompilerPath = [IO.Path]::GetFullPath($CompilerPath)
    $registryKeys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 7_is1',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 7_is1',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 7_is1'
    )
    foreach ($registryKey in $registryKeys) {
        try {
            $properties = Get-ItemProperty -LiteralPath $registryKey -ErrorAction Stop
            $registeredCompiler = Join-Path (
                [string] $properties.InstallLocation) 'ISCC.exe'
            if ([IO.Path]::GetFullPath($registeredCompiler) -eq $fullCompilerPath -and
                [string] $properties.DisplayVersion -eq $expectedVersion) {
                return
            }
        }
        catch {
            # Continue through the supported registry views.
        }
    }

    throw @"
MirrorSpeaker public builds require Inno Setup $expectedVersion exactly.
The selected compiler was not registered as that version:
$fullCompilerPath
"@
}

function Assert-InnoRuntimeConstants {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ScriptPath
    )

    $allowedConstants = New-Object 'Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($constantName in @(
        'app',
        'autodesktop',
        'commonpf64',
        'group',
        'localappdata',
        'sys',
        'tmp'
    )) {
        [void] $allowedConstants.Add($constantName)
    }

    $scriptText = Get-Content -LiteralPath $ScriptPath -Raw
    $constantPattern =
        '(?<!\{)\{(?![#%\\])(?<name>[A-Za-z][A-Za-z0-9]*)(?=[:}])'
    foreach ($match in [regex]::Matches($scriptText, $constantPattern)) {
        $constantName = $match.Groups['name'].Value
        if (-not $allowedConstants.Contains($constantName)) {
            $lineNumber = 1 + [regex]::Matches(
                $scriptText.Substring(0, $match.Index),
                "`n").Count
            throw @"
Unsupported Inno Setup runtime constant '{$constantName}' in
$ScriptPath at line $lineNumber. Only documented and reviewed runtime
constants may be used in the public installer.
"@
        }
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function New-PortableZip {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    $sourceRoot = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\') + '\'
    $archiveStream = New-Object IO.FileStream(
        $Destination,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive(
            $archiveStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $true)
        try {
            Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse -Force |
                Sort-Object -Property FullName |
                ForEach-Object {
                    $fullFilePath = [IO.Path]::GetFullPath($_.FullName)
                    if (-not $fullFilePath.StartsWith(
                            $sourceRoot,
                            [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Refusing to package a file outside the portable staging directory: $fullFilePath"
                    }

                    $entryName = $fullFilePath.Substring($sourceRoot.Length).Replace('\', '/')
                    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $archive,
                        $fullFilePath,
                        $entryName,
                        [IO.Compression.CompressionLevel]::Optimal) | Out-Null
                }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $archiveStream.Dispose()
    }
}

function New-InnoDefineArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ($Value.Contains("`r") -or $Value.Contains("`n")) {
        throw "Inno Setup define '$Name' cannot contain a line break."
    }

    return "/D$Name=$Value"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-ProjectVersion
}
$Version = $Version.Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
    throw "Version must contain three or four numeric parts, for example 1.4.0."
}

$Publisher = $Publisher.Trim()
if ([string]::IsNullOrWhiteSpace($Publisher)) {
    throw 'Publisher cannot be empty.'
}

if (-not [string]::IsNullOrWhiteSpace($PublisherUrl)) {
    $parsedPublisherUri = $null
    if (-not [Uri]::TryCreate(
            $PublisherUrl,
            [UriKind]::Absolute,
            [ref] $parsedPublisherUri) -or
        ($parsedPublisherUri.Scheme -ne 'https' -and
         $parsedPublisherUri.Scheme -ne 'http')) {
        throw 'PublisherUrl must be an absolute HTTP or HTTPS URL.'
    }
}

foreach ($requiredFile in @($buildReleaseScript, $testProjectPath, $installerScript)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "A required build file was not found: $requiredFile"
    }
}

Assert-InnoRuntimeConstants -ScriptPath $installerScript

if ($ExcludeReceiverEngine -and
    ($RequireReceiverEngine -or $AllowInternalReceiverEngine)) {
    throw @'
-ExcludeReceiverEngine cannot be combined with -RequireReceiverEngine or
-AllowInternalReceiverEngine.
'@
}

$innoCompiler = if ([string]::IsNullOrWhiteSpace($InnoCompilerPath)) {
    Find-InnoCompiler
}
else {
    $expandedCompilerPath = [Environment]::ExpandEnvironmentVariables(
        $InnoCompilerPath.Trim())
    $fullCompilerPath = [IO.Path]::GetFullPath($expandedCompilerPath)
    if (-not (Test-Path -LiteralPath $fullCompilerPath -PathType Leaf)) {
        throw "The specified Inno Setup compiler was not found: $fullCompilerPath"
    }
    $fullCompilerPath
}
Assert-InnoCompilerVersion -CompilerPath $innoCompiler
$dotnet = Get-Command -Name 'dotnet.exe' -CommandType Application -ErrorAction Stop

if (-not $SkipApplicationBuild) {
    & $buildReleaseScript `
        -Configuration $Configuration `
        -Version $Version `
        -Publisher $Publisher
    if ($LASTEXITCODE -ne 0) {
        throw "Application release build failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) {
    throw "The published application was not found at $applicationPath."
}

$versionInfo = (Get-Item -LiteralPath $applicationPath).VersionInfo
$binaryVersion = ([string] $versionInfo.ProductVersion).Split('+')[0].Trim()
if ($binaryVersion -ne $Version) {
    throw "Published application version '$binaryVersion' does not match requested version '$Version'."
}
if ([string] $versionInfo.CompanyName -ne $Publisher) {
    throw "Published application publisher '$($versionInfo.CompanyName)' does not match requested publisher '$Publisher'."
}

$testArguments = @(
    'run',
    '--project', $testProjectPath,
    '--configuration', $Configuration
)
# -SkipApplicationBuild only reuses the already-published desktop application.
# Smoke tests are a separate build and must still restore/compile on a fresh
# machine (including a clean GitHub-hosted runner).
& $dotnet.Source @testArguments
if ($LASTEXITCODE -ne 0) {
    throw "Smoke tests failed with exit code $LASTEXITCODE."
}

$engineDirectoryExists = Test-Path -LiteralPath $engineDirectory -PathType Container
$engineIsPublicReleaseCandidate = $false
$engineMetadataProblem = $null
if (Test-Path -LiteralPath $enginePackageMetadataPath -PathType Leaf) {
    try {
        $enginePackageMetadata = Get-Content `
            -LiteralPath $enginePackageMetadataPath `
            -Raw |
            ConvertFrom-Json
        $releaseCandidateProperty = $enginePackageMetadata.PSObject.Properties[
            'publicReleaseCandidate']
        if ($null -eq $releaseCandidateProperty -or
            $releaseCandidateProperty.Value -isnot [bool]) {
            $engineMetadataProblem =
                'package.json must contain a Boolean publicReleaseCandidate property.'
        }
        else {
            $engineIsPublicReleaseCandidate = $releaseCandidateProperty.Value
        }
    }
    catch {
        $engineMetadataProblem = $_.Exception.Message
    }
}
else {
    $engineMetadataProblem = "Package metadata was not found at $enginePackageMetadataPath."
}

$hasReceiverEngine = $false
$usingInternalReceiverEngine = $false
$engineWasSelected =
    -not $ExcludeReceiverEngine -and
    ($engineIsPublicReleaseCandidate -or $AllowInternalReceiverEngine)
if ($engineWasSelected -and $engineDirectoryExists) {
    $requiredEngineFiles = @(
        (Join-Path $engineDirectory '.airmirror-engine.json'),
        (Join-Path $engineDirectory 'ucrt64\bin\uxplay.exe'),
        (Join-Path $engineDirectory 'ucrt64\bin\gst-inspect-1.0.exe')
    )
    foreach ($requiredEngineFile in $requiredEngineFiles) {
        if (-not (Test-Path -LiteralPath $requiredEngineFile -PathType Leaf)) {
            throw "The staged receiver engine is incomplete. Missing: $requiredEngineFile"
        }
    }

    try {
        $engineMetadata = Get-Content `
            -LiteralPath (Join-Path $engineDirectory '.airmirror-engine.json') `
            -Raw |
            ConvertFrom-Json
        if (-not ($engineMetadata.PSObject.Properties.Name -contains 'airMirrorPatchLevel') -or
            [int] $engineMetadata.airMirrorPatchLevel -lt 2) {
            throw 'The staged receiver engine patch level is older than 2.'
        }
    }
    catch {
        throw "The staged receiver engine marker is invalid: $($_.Exception.Message)"
    }

    $hasReceiverEngine = $true
    $usingInternalReceiverEngine =
        $AllowInternalReceiverEngine -and -not $engineIsPublicReleaseCandidate
}
elseif (-not $ExcludeReceiverEngine -and $engineIsPublicReleaseCandidate) {
    throw @"
Receiver package metadata marks the engine as a public release candidate,
but the engine directory was not found at $engineDirectory.
"@
}
elseif ($AllowInternalReceiverEngine -and -not $engineDirectoryExists) {
    Write-Warning @"
-AllowInternalReceiverEngine was specified, but no engine directory exists at:
$engineDirectory
"@
}

if ($ExcludeReceiverEngine) {
    Write-Output @"
Receiver engine exclusion is enforced for this build.
AirPlay users will use the explicit first-use local source build.
"@
}
elseif ($usingInternalReceiverEngine) {
    Write-Warning @"
INTERNAL RECEIVER ENGINE OVERRIDE ENABLED.
The generated artifacts will be labeled INTERNAL and must not be published.
"@
}
elseif (-not $engineIsPublicReleaseCandidate -and $engineDirectoryExists) {
    $metadataDetail = if ([string]::IsNullOrWhiteSpace($engineMetadataProblem)) {
        'package.json marks publicReleaseCandidate as false.'
    }
    else {
        $engineMetadataProblem
    }
    Write-Warning @"
An internal or ineligible receiver engine package was found and will NOT be bundled.
$metadataDetail
Use -AllowInternalReceiverEngine only for local installer validation.
"@
}

if ($RequireReceiverEngine -and -not $hasReceiverEngine) {
    throw @"
A public-release-eligible receiver engine is required, but none is available.
Build and approve the receiver package, or use -AllowInternalReceiverEngine only
for a clearly labeled local validation build.
"@
}
elseif (-not $hasReceiverEngine -and -not $ExcludeReceiverEngine) {
    Write-Warning @"
No eligible prebuilt receiver engine will be bundled.
The installer will still work, but AirPlay users will need the longer first-use engine setup.
"@
}

New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Assert-SafeArtifactsChild -Path $outputDirectory
Assert-SafeArtifactsChild -Path $stagingDirectory

$artifactSuffix = if ($usingInternalReceiverEngine) { '-INTERNAL' } else { '' }
$setupFileName = "MirrorSpeaker-$Version$artifactSuffix-win-x64-setup.exe"
$portableFileName = "MirrorSpeaker-$Version$artifactSuffix-win-x64-portable.zip"
$checksumsFileName = "MirrorSpeaker-$Version$artifactSuffix-SHA256SUMS.txt"
$setupPath = Join-Path $outputDirectory $setupFileName
$portablePath = Join-Path $outputDirectory $portableFileName
$checksumsPath = Join-Path $outputDirectory $checksumsFileName
$innoStagingDirectory = Join-Path $stagingDirectory 'inno'
$stagedSetupPath = Join-Path $innoStagingDirectory $setupFileName
$stagedPortablePath = Join-Path $stagingDirectory $portableFileName
$stagedChecksumsPath = Join-Path $stagingDirectory $checksumsFileName

try {
    New-Item -ItemType Directory -Path $portableDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $innoStagingDirectory -Force | Out-Null
    Copy-DirectoryContents -Source $publishDirectory -Destination $portableDirectory

    $portableScripts = Join-Path $portableDirectory 'scripts'
    if (Test-Path -LiteralPath $portableScripts -PathType Container) {
        Get-ChildItem -LiteralPath $portableScripts -File -Filter 'Build-*.ps1' |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force
            }
    }

    [IO.File]::WriteAllText(
        (Join-Path $portableDirectory 'portable.flag'),
        '',
        (New-Object Text.UTF8Encoding($false)))

    if ($hasReceiverEngine) {
        Write-Output 'Adding the prebuilt AirPlay receiver engine to the portable package.'
        Copy-DirectoryContents `
            -Source $engineDirectory `
            -Destination (Join-Path $portableDirectory 'engine')
    }

    if ($ExcludeReceiverEngine) {
        $unexpectedReceiverFiles = @(
            Get-ChildItem -LiteralPath $portableDirectory -Recurse -File |
                Where-Object {
                    $_.Name -ieq 'uxplay.exe' -or
                    $_.FullName -match '[\\/]engine[\\/]'
                }
        )
        if ($unexpectedReceiverFiles.Count -ne 0) {
            throw "Receiver exclusion failed; found $($unexpectedReceiverFiles[0].FullName)."
        }
    }

    New-PortableZip `
        -SourceDirectory $portableDirectory `
        -Destination $stagedPortablePath

    $innoArguments = @(
        (New-InnoDefineArgument -Name 'MyAppVersion' -Value $Version),
        (New-InnoDefineArgument -Name 'MyAppPublisher' -Value $Publisher),
        (New-InnoDefineArgument -Name 'MyPublisherUrl' -Value $PublisherUrl),
        (New-InnoDefineArgument -Name 'MyPublishDir' -Value $publishDirectory),
        (New-InnoDefineArgument -Name 'MyOutputDir' -Value $innoStagingDirectory),
        (New-InnoDefineArgument -Name 'MyArtifactSuffix' -Value $artifactSuffix)
    )
    if ($hasReceiverEngine) {
        $innoArguments += New-InnoDefineArgument `
            -Name 'MyEngineSourceDir' `
            -Value $engineDirectory
    }
    $innoArguments += $installerScript

    Write-Output "Compiling the per-user Windows installer with $innoCompiler"
    & $innoCompiler @innoArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $stagedSetupPath -PathType Leaf)) {
        throw "Inno Setup completed without creating $stagedSetupPath."
    }

    $checksumLines = @(
        Get-Item -LiteralPath $stagedSetupPath, $stagedPortablePath |
            Sort-Object -Property Name |
            ForEach-Object {
                $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
                '{0} *{1}' -f $hash.Hash.ToLowerInvariant(), $_.Name
            }
    )
    [IO.File]::WriteAllLines(
        $stagedChecksumsPath,
        $checksumLines,
        (New-Object Text.UTF8Encoding($false)))

    foreach ($oldArtifact in @($setupPath, $portablePath, $checksumsPath)) {
        if (Test-Path -LiteralPath $oldArtifact -PathType Leaf) {
            Assert-SafeArtifactsChild -Path $oldArtifact
            Remove-Item -LiteralPath $oldArtifact -Force
        }
    }
    Move-Item -LiteralPath $stagedSetupPath -Destination $setupPath
    Move-Item -LiteralPath $stagedPortablePath -Destination $portablePath
    Move-Item -LiteralPath $stagedChecksumsPath -Destination $checksumsPath

    Write-Output ''
    Write-Output 'MirrorSpeaker release artifacts:'
    Write-Output "  Installer: $setupPath"
    Write-Output "  Portable:  $portablePath"
    Write-Output "  Checksums: $checksumsPath"
    $engineSummary = if ($usingInternalReceiverEngine) {
        'INTERNAL OVERRIDE - DO NOT PUBLISH'
    }
    elseif ($hasReceiverEngine) {
        'bundled public release candidate'
    }
    else {
        'first-use setup'
    }
    Write-Output "  Engine:    $engineSummary"
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Assert-SafeArtifactsChild -Path $stagingDirectory
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}
