; Inno Setup script for the Windows app (the Flutter build).
;
; Build the app first (flutter build windows --release), then compile this:
;   iscc "desktop\Sector Scout.iss"
; CI passes the release version in: iscc /DAppVersion=1.0.3-beta ...
;
; The install is per-user, so it needs no administrator rights. The AppId is the
; one the console installer used, so upgrading a machine that still has the
; console replaces it in place rather than leaving two Sector Scouts behind.

#ifndef AppVersion
  #define AppVersion "2.0.0-beta"
#endif

#define AppName "Sector Scout"
#define AppExe "SectorScout.exe"
; The Flutter Release folder: the exe, flutter_windows.dll, the plugin DLLs and
; the data\ directory. All of it is needed, not just the exe.
#define SourceDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6F1D9F0C-3B2A-4B57-9E1B-5C2E3A7C4D18}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=tsalisbury0
AppPublisherURL=https://github.com/tsalisbury0/sector-scout
DefaultDirName={localappdata}\Programs\Sector Scout
DefaultGroupName=Sector Scout
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=Sector Scout Setup {#AppVersion}
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
