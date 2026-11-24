; Inno Setup script: turns windows/dist/PortHop-win32-x64 into PortHop-Setup.exe, a normal Windows installer
; (Start menu entry, optional desktop icon, uninstaller in Settings > Apps). Installs for the current user, so no admin rights.
;
; Build on Windows (Inno Setup 6 from jrsoftware.org):
;   node package-win.js
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\PortHop.iss
; The result is installer\Output\PortHop-Setup.exe. To sign it, add a SignTool line (see Inno Setup's [Setup] SignTool).

#define AppVersion "2.2.0"

[Setup]
AppId={{774905B6-24BE-40C8-9FC8-8E307EE050FF}
AppName=PortHop
AppVersion={#AppVersion}
AppPublisher=PortHop
AppPublisherURL=https://github.com/ARAVINDHRAJA123/porthop
DefaultDirName={localappdata}\Programs\PortHop
DefaultGroupName=PortHop
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=PortHop-Setup
SetupIconFile=..\icon.ico
UninstallDisplayIcon={app}\PortHop.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
LicenseFile=..\..\LICENSE

[Tasks]
Name: "desktopicon"; Description: "Add a desktop icon"; Flags: unchecked

[Files]
Source: "..\dist\PortHop-win32-x64\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\PortHop"; Filename: "{app}\PortHop.exe"
Name: "{userdesktop}\PortHop"; Filename: "{app}\PortHop.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\PortHop.exe"; Description: "Open PortHop"; Flags: nowait postinstall skipifsilent
