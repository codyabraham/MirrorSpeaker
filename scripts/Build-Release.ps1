#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [Parameter()]
    [string] $Version = '',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Publisher = 'MirrorSpeaker Project'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$projectPath = Join-Path $repoRoot 'src\AirMirror.App\AirMirror.App.csproj'
$distRoot = Join-Path $repoRoot 'dist'
$outputPath = Join-Path $distRoot 'win-x64'
$stagingPath = Join-Path $distRoot ('.staging-' + [Guid]::NewGuid().ToString('N'))

function Assert-SafeDistChild {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullDistRoot = [IO.Path]::GetFullPath($distRoot).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullDistRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a release path outside the repository dist directory: $fullPath"
    }
}

if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "The application project was not found at $projectPath."
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    [xml] $project = Get-Content -LiteralPath $projectPath -Raw
    $versions = @(
        $project.Project.PropertyGroup |
            ForEach-Object { $_.Version } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
    )
    if ($versions.Count -ne 1) {
        throw 'The application project must define exactly one Version.'
    }
    $Version = ([string] $versions[0]).Trim()
}
else {
    $Version = $Version.Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
    throw "Version must contain three or four numeric parts, for example 1.4.4."
}

$dotnet = Get-Command -Name 'dotnet.exe' -CommandType Application -ErrorAction Stop
New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
Assert-SafeDistChild -Path $stagingPath
Assert-SafeDistChild -Path $outputPath

try {
    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null

    $publishArguments = @(
        'publish',
        $projectPath,
        '--configuration', $Configuration,
        '--runtime', 'win-x64',
        '--self-contained', 'false',
        '--disable-build-servers',
        '--output', $stagingPath,
        '-p:PublishSingleFile=true',
        '-p:DebugType=embedded',
        '-p:DebugSymbols=false',
        "-p:Version=$Version",
        "-p:Company=$Publisher"
    )
    & $dotnet.Source @publishArguments

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }

    $stagedApplicationPath = Join-Path $stagingPath 'MirrorSpeaker.exe'
    if (-not (Test-Path -LiteralPath $stagedApplicationPath -PathType Leaf)) {
        throw "dotnet publish did not create $stagedApplicationPath."
    }

    $versionInfo = (Get-Item -LiteralPath $stagedApplicationPath).VersionInfo
    $productVersion = ([string] $versionInfo.ProductVersion).Trim()
    if ($productVersion -ne $Version) {
        throw "Published application product version '$productVersion' does not exactly match requested version '$Version'."
    }
    if (([string] $versionInfo.ProductName).Trim() -ne 'MirrorSpeaker') {
        throw "Published application product name '$($versionInfo.ProductName)' is not MirrorSpeaker."
    }
    if (([string] $versionInfo.CompanyName).Trim() -ne $Publisher) {
        throw "Published application publisher '$($versionInfo.CompanyName)' does not match requested publisher '$Publisher'."
    }

    $forbiddenRuntimeFiles = @(
        'coreclr.dll',
        'hostfxr.dll',
        'hostpolicy.dll',
        'PresentationCore.dll',
        'PresentationFramework.dll',
        'System.Private.CoreLib.dll',
        'WindowsBase.dll',
        'wpfgfx_cor3.dll'
    )
    $redistributedRuntimeFiles = @(
        Get-ChildItem -LiteralPath $stagingPath -File -Recurse |
            Where-Object { $forbiddenRuntimeFiles -contains $_.Name }
    )
    if ($redistributedRuntimeFiles.Count -gt 0) {
        $redistributedNames = @(
            $redistributedRuntimeFiles |
                ForEach-Object { $_.FullName.Substring($stagingPath.Length + 1) }
        ) -join ', '
        throw @"
Framework-dependent release invariant failed. The publish output contains
Microsoft .NET/Windows Desktop runtime binaries: $redistributedNames
"@
    }

    $packagedScripts = Join-Path $stagingPath 'scripts'
    New-Item -ItemType Directory -Path $packagedScripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-ReceiverEngine.ps1') `
        -Destination $packagedScripts `
        -Force

    Get-ChildItem -LiteralPath $repoRoot -File | Where-Object {
        $_.Name -like 'LICENSE*' -or $_.Name -like 'THIRD-PARTY*'
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $stagingPath -Force
    }

    $repositoryLicensesPath = Join-Path $repoRoot 'licenses'
    $packagedLicensesPath = Join-Path $stagingPath 'licenses'
    if (Test-Path -LiteralPath $repositoryLicensesPath -PathType Container) {
        Copy-Item -LiteralPath $repositoryLicensesPath `
            -Destination $packagedLicensesPath `
            -Recurse `
            -Force
    }

    Copy-Item `
        -LiteralPath (Join-Path $repoRoot 'src\AirMirror.App\Assets\MirrorSpeaker.ico') `
        -Destination (Join-Path $stagingPath 'MirrorSpeaker.ico') `
        -Force

    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Recurse -Force
    }
    Move-Item -LiteralPath $stagingPath -Destination $outputPath

    Write-Output "Release created at $outputPath"
}
finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Assert-SafeDistChild -Path $stagingPath
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}
