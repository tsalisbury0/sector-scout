; Inno Setup script for the desktop console.
;
; Build the app first (python desktop/build_windows.py), then compile this:
;   iscc "desktop\Sector Scout Desktop.iss"
; CI passes the release version in: iscc /DAppVersion=1.0.1 ...
;
; The install is per-user, so it needs no administrator rights and can write
; its config and carrier cache beside itself under %LOCALAPPDATA%.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppName "Sector Scout Desktop"
#define AppExe "Sector Scout Desktop.exe"
#define SourceDir "..\build\windows\dist\Sector Scout Desktop"

[Setup]
AppId={{6F1D9F0C-3B2A-4B57-9E1B-5C2E3A7C4D18}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=tsalisbury0
AppPublisherURL=https://github.com/tsalisbury0/sector-scout
DefaultDirName={localappdata}\Programs\Sector Scout Desktop
DefaultGroupName=Sector Scout
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=Sector Scout Desktop Setup {#AppVersion}
SetupIconFile=sector_scout.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
