; Inno Setup script. Build: ISCC /DAppVersion=1.2.0 /DSourceDir=<flutter Release dir> installer\open_connect.iss
; Per-user install (no admin) so the in-app updater can overwrite files in {app} without elevation.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<Release folder>
#endif

[Setup]
AppId={{6F1D0C58-3E8B-4C57-9B0A-0E4A2B7C91D3}
AppName=Open Connect
AppVersion={#AppVersion}
AppPublisher=Open Connect
DefaultDirName={autopf}\Open Connect
DefaultGroupName=Open Connect
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=OpenConnect-Setup-{#AppVersion}
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\open_connect.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Open Connect"; Filename: "{app}\open_connect.exe"
Name: "{autodesktop}\Open Connect"; Filename: "{app}\open_connect.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\open_connect.exe"; Description: "Launch Open Connect"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; the app registers its own autostart entry when "Start with Windows" is on
Filename: "{sys}\reg.exe"; Parameters: "delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v OpenConnect /f"; Flags: runhidden; RunOnceId: "RemoveAutostart"

[UninstallDelete]
; files added by the in-app updater are not in the install log
Type: filesandordirs; Name: "{app}"
