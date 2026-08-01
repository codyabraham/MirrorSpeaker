#define MyAppName "MirrorSpeaker"
#define MyAppExeName "MirrorSpeaker.exe"
#define MyAppId "MirrorSpeaker.2F4B9297-A660-4A07-B3C6-84E0C84E6A77"

#ifndef MyPublishDir
  #define MyPublishDir AddBackslash(SourcePath) + "..\dist\win-x64"
#endif

#ifndef MyAppVersion
  #define MyAppVersion GetVersionNumbersString(MyPublishDir + "\" + MyAppExeName)
#endif

#ifndef MyAppPublisher
  #define MyAppPublisher "MirrorSpeaker Project"
#endif

#ifndef MyPublisherUrl
  #define MyPublisherUrl ""
#endif

#ifndef MyOutputDir
  #define MyOutputDir AddBackslash(SourcePath) + "..\artifacts\release"
#endif

#ifndef MyArtifactSuffix
  #define MyArtifactSuffix ""
#endif

#ifndef MyEngineSourceDir
  #define MyEngineSourceDir ""
#endif

#if MyEngineSourceDir != ""
  #if FileExists(MyEngineSourceDir + "\.airmirror-engine.json")
    #if FileExists(MyEngineSourceDir + "\ucrt64\bin\uxplay.exe")
      #if FileExists(MyEngineSourceDir + "\ucrt64\bin\gst-inspect-1.0.exe")
        #define HasBundledEngine
      #endif
    #endif
  #endif
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyPublisherUrl}
AppSupportURL={#MyPublisherUrl}
AppUpdatesURL={#MyPublisherUrl}
AppCopyright=Copyright (c) 2026 {#MyAppPublisher}
AppComments=Bluetooth audio and AirPlay screen mirroring from iPhone to Windows 11.
SetupIconFile={#MyPublishDir}\MirrorSpeaker.ico

DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableDirPage=yes
DisableProgramGroupPage=yes

OutputDir={#MyOutputDir}
OutputBaseFilename=MirrorSpeaker-{#MyAppVersion}{#MyArtifactSuffix}-win-x64-setup
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}

VersionInfoVersion={#MyAppVersion}
VersionInfoTextVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

PrivilegesRequired=lowest
MinVersion=10.0.22000
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

AllowNetworkDrive=no
AllowUNCPath=no
AllowRootDirectory=no
ChangesAssociations=no
ChangesEnvironment=no

Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

CloseApplications=yes
CloseApplicationsFilter={#MyAppExeName},uxplay.exe
RestartApplications=no

UsePreviousAppDir=yes
UsePreviousGroup=yes
UsePreviousTasks=yes
Uninstallable=yes
LicenseFile={#MyPublishDir}\LICENSE
InfoBeforeFile={#SourcePath}\INSTALL-NOTICE.txt

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "{#MyPublishDir}\*"; DestDir: "{app}"; Excludes: "scripts\Build-*.ps1,README-PORTABLE.txt"; Flags: ignoreversion recursesubdirs createallsubdirs

#ifdef HasBundledEngine
Source: "{#MyEngineSourceDir}\*"; DestDir: "{app}\engine"; Excludes: ".airmirror-engine.json"; Flags: ignoreversion recursesubdirs createallsubdirs; BeforeInstall: ShowEngineInstallStatus
Source: "{#MyEngineSourceDir}\.airmirror-engine.json"; DestDir: "{app}\engine"; Flags: ignoreversion; BeforeInstall: ShowEngineInstallStatus; AfterInstall: VerifyBundledEngine
#endif

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\engine"
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\portable.flag"

[Code]
const
  DotNetDesktopRuntimeUrl =
    'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/10.0.10/windowsdesktop-runtime-10.0.10-win-x64.exe';
  DotNetDesktopRuntimeFileName =
    'windowsdesktop-runtime-10.0.10-win-x64.exe';
  DotNetDesktopRuntimeSha256 =
    'e82fc901c8f52d716293b2bc0830ce0dd254a06268c457a19e8fc503560a84d1';
  FirewallCleanupCommand =
    'JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAnADsAIABAACgAJwBBAGkAcgBNAGkAcgByAG8AcgAtAG0ARABOAFMALQBVAEQAUAAtAEkAbgAnACwAJwBBAGkAcgBNAGkAcgByAG8AcgAtAFIAZQBjAGUAaQB2AGUAcgAtAFQAQwBQAC0ASQBuACcALAAnAEEAaQByAE0AaQByAHIAbwByAC0AUgBlAGMAZQBpAHYAZQByAC0AVQBEAFAALQBJAG4AJwApACAAfAAgAEYAbwByAEUAYQBjAGgALQBPAGIAagBlAGMAdAAgAHsAIABHAGUAdAAtAE4AZQB0AEYAaQByAGUAdwBhAGwAbABSAHUAbABlACAALQBOAGEAbQBlACAAJABfACAALQBFAHIAcgBvAHIAQQBjAHQAaQBvAG4AIABTAGkAbABlAG4AdABsAHkAQwBvAG4AdABpAG4AdQBlACAAfAAgAFIAZQBtAG8AdgBlAC0ATgBlAHQARgBpAHIAZQB3AGEAbABsAFIAdQBsAGUAIAAtAEUAcgByAG8AcgBBAGMAdABpAG8AbgAgAFMAaQBsAGUAbgB0AGwAeQBDAG8AbgB0AGkAbgB1AGUAIAB9ADsAIABlAHgAaQB0ACAAMAA=';

var
  DotNetDownloadPage: TDownloadWizardPage;

function IsStableDotNet10Version(const VersionName: String): Boolean;
var
  CharacterIndex: Integer;
  CurrentCharacter: Char;
  PreviousWasDot: Boolean;
begin
  Result := False;
  if (Length(VersionName) < 4) or
     (Copy(VersionName, 1, 3) <> '10.') then
    Exit;

  PreviousWasDot := False;
  for CharacterIndex := 1 to Length(VersionName) do
  begin
    CurrentCharacter := VersionName[CharacterIndex];
    if CurrentCharacter = '.' then
    begin
      if PreviousWasDot then
        Exit;
      PreviousWasDot := True;
    end
    else
    begin
      if (CurrentCharacter < '0') or (CurrentCharacter > '9') then
        Exit;
      PreviousWasDot := False;
    end;
  end;

  Result := not PreviousWasDot;
end;

function HasDotNet10DesktopRuntimeAt(const DotNetRoot: String): Boolean;
var
  RuntimeDirectory: String;
  FindRecord: TFindRec;
begin
  Result := False;
  if DotNetRoot = '' then
    Exit;

  RuntimeDirectory :=
    AddBackslash(DotNetRoot) +
    'shared\Microsoft.WindowsDesktop.App';
  if not DirExists(RuntimeDirectory) then
    Exit;

  if FindFirst(AddBackslash(RuntimeDirectory) + '10.*', FindRecord) then
  begin
    try
      repeat
        if ((FindRecord.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
           IsStableDotNet10Version(FindRecord.Name) then
        begin
          Log('Found Microsoft.WindowsDesktop.App ' + FindRecord.Name +
            ' in ' + RuntimeDirectory + '.');
          Result := True;
          Exit;
        end;
      until not FindNext(FindRecord);
    finally
      FindClose(FindRecord);
    end;
  end;
end;

function GetMachineX64DotNetRoot: String;
begin
  Result := ExpandConstant('{commonpf64}\dotnet');
  if IsArm64 then
    Result := AddBackslash(Result) + 'x64';
end;

function HasRequiredDotNetDesktopRuntime: Boolean;
begin
  Result :=
    HasDotNet10DesktopRuntimeAt(GetEnv('DOTNET_ROOT_X64')) or
    HasDotNet10DesktopRuntimeAt(GetEnv('DOTNET_ROOT')) or
    HasDotNet10DesktopRuntimeAt(GetMachineX64DotNetRoot);
end;

procedure InitializeWizard;
var
  PrerequisitePage: TWizardPage;
  Explanation: TNewStaticText;
begin
  DotNetDownloadPage := CreateDownloadPage(
    'Downloading Microsoft .NET',
    'Setup is downloading the required Microsoft desktop runtime.',
    nil);
  DotNetDownloadPage.ShowBaseNameInsteadOfUrl := True;

  if HasRequiredDotNetDesktopRuntime then
    Exit;

  PrerequisitePage := CreateCustomPage(
    wpLicense,
    'Required Microsoft component',
    'MirrorSpeaker needs the Microsoft .NET 10 Desktop Runtime (x64).');

  Explanation := TNewStaticText.Create(PrerequisitePage);
  Explanation.Parent := PrerequisitePage.Surface;
  Explanation.AutoSize := False;
  Explanation.WordWrap := True;
  Explanation.SetBounds(
    0,
    ScaleY(8),
    PrerequisitePage.SurfaceWidth,
    ScaleY(190));
  Explanation.Caption :=
    'The required Microsoft .NET Desktop Runtime 10 is not installed.' +
    (#13#10#13#10) +
    'After you select Install, Setup will download the 10.0.10 x64 ' +
    'runtime directly from Microsoft (about 57 MB), verify its ' +
    'SHA-256 checksum, and run the Microsoft installer quietly.' +
    (#13#10#13#10) +
    'The Microsoft runtime is a system component, so Windows may ask ' +
    'for administrator permission. MirrorSpeaker itself remains a ' +
    'per-user installation. An Internet connection is required.';
end;

function InstallDotNetDesktopRuntime(var NeedsRestart: Boolean): String;
var
  RuntimeInstallerPath: String;
  ResultCode: Integer;
begin
  Result := '';
  if HasRequiredDotNetDesktopRuntime then
    Exit;

  Log(
    'Microsoft.WindowsDesktop.App 10.x x64 is missing. ' +
    'Downloading the official Microsoft 10.0.10 prerequisite. ' +
    'The runtime installation may require administrator permission.');

  DotNetDownloadPage.Clear;
  DotNetDownloadPage.Add(
    DotNetDesktopRuntimeUrl,
    DotNetDesktopRuntimeFileName,
    DotNetDesktopRuntimeSha256);
  DotNetDownloadPage.Show;
  try
    try
      DotNetDownloadPage.Download;
    except
      if DotNetDownloadPage.AbortedByUser then
        Result := 'The Microsoft .NET download was canceled.'
      else
        Result :=
          'The required Microsoft .NET Desktop Runtime could not be ' +
          'downloaded or did not pass checksum verification: ' +
          GetExceptionMessage;
      Exit;
    end;
  finally
    DotNetDownloadPage.Hide;
  end;

  RuntimeInstallerPath :=
    ExpandConstant('{tmp}\') + DotNetDesktopRuntimeFileName;
  if not FileExists(RuntimeInstallerPath) then
  begin
    Result :=
      'The verified Microsoft .NET runtime installer could not be found.';
    Exit;
  end;

  Log(
    'Starting the verified Microsoft .NET Desktop Runtime installer. ' +
    'Windows may request administrator permission.');
  if not ShellExec(
       'runas',
       RuntimeInstallerPath,
       '/install /quiet /norestart',
       '',
       SW_SHOWNORMAL,
       ewWaitUntilTerminated,
       ResultCode) then
  begin
    Result :=
      'The Microsoft .NET Desktop Runtime installer could not start. ' +
      'Administrator permission may have been declined. Windows error: ' +
      IntToStr(ResultCode) + '.';
    Exit;
  end;

  Log(
    'Microsoft .NET Desktop Runtime installer finished with code ' +
    IntToStr(ResultCode) + '.');
  if (ResultCode = 1641) or (ResultCode = 3010) then
    NeedsRestart := True;

  if not HasRequiredDotNetDesktopRuntime then
  begin
    Result :=
      'Microsoft .NET Desktop Runtime 10 (x64) is still unavailable ' +
      'after its installer finished with code ' +
      IntToStr(ResultCode) + '.';
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := InstallDotNetDesktopRuntime(NeedsRestart);
end;

procedure ShowEngineInstallStatus;
begin
  if not WizardSilent then
    WizardForm.StatusLabel.Caption :=
      'Installing the AirPlay receiver engine...';
end;

procedure VerifyBundledEngine;
begin
  if not FileExists(
    ExpandConstant('{app}\engine\ucrt64\bin\uxplay.exe')) then
    RaiseException(
      'The AirPlay receiver engine was not installed correctly.');

  if not FileExists(
    ExpandConstant('{app}\engine\ucrt64\bin\gst-inspect-1.0.exe')) then
    RaiseException(
      'The AirPlay multimedia components were not installed correctly.');
end;

function IsSilentUninstall: Boolean;
var
  ParameterIndex: Integer;
  ParameterValue: String;
begin
  Result := False;
  for ParameterIndex := 1 to ParamCount do
  begin
    ParameterValue := Uppercase(ParamStr(ParameterIndex));
    if (ParameterValue = '/SILENT') or
       (ParameterValue = '/VERYSILENT') then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  PowerShellPath: String;
  PowerShellParameters: String;
begin
  if (CurUninstallStep <> usUninstall) or IsSilentUninstall then
    Exit;

  PowerShellPath :=
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  PowerShellParameters :=
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-EncodedCommand ' + FirewallCleanupCommand;

  Log('Requesting permission to remove MirrorSpeaker firewall rules.');
  if ShellExec(
       'runas',
       PowerShellPath,
       PowerShellParameters,
       '',
       SW_HIDE,
       ewWaitUntilTerminated,
       ResultCode) then
    Log('MirrorSpeaker firewall cleanup finished with code ' +
      IntToStr(ResultCode) + '.')
  else
    Log('MirrorSpeaker firewall cleanup was skipped or could not start. ' +
      'Windows error: ' + IntToStr(ResultCode) + '.');
end;
