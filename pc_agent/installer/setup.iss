; SlateSync - Inno Setup installer script (Doc 19, Wave 3.A authoring only)
; Compile in Wave 3.B only: ISCC.exe pc_agent\installer\setup.iss
; Requires the Wave 3.A PyInstaller bundle at ..\..\dist\SlateSyncAgent\ (Doc 18).
; ASCII-only content - no non-ASCII bytes, safe with or without a UTF-8 BOM.

#define MyAppName "SlateSync"
#define MyAppVersion "1.0.0"
#define MyAppExeName "SlateSyncAgent.exe"
#define WsPort "50606"
#define FirewallRule "SlateSync WS"

[Setup]
; Fixed AppId GUID - upgrades replace in place; never change across releases (Doc 19 Section 4).
AppId={{8F3C2A1B-5D4E-4B9C-A7F6-1E2D3C4B5A69}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\SlateSync
DefaultGroupName={#MyAppName}
UninstallDisplayName={#MyAppName}
; Template Section 3 constant: installer output dist\SlateSync_Setup.exe.
; OutputDir is relative to this .iss (pc_agent\installer\..\..\dist = repo dist\).
OutputDir=..\..\dist
OutputBaseFilename=SlateSync_Setup
PrivilegesRequired=admin
Compression=lzma2
SolidCompression=yes
; SetupIconFile omitted: pc_agent\assets\slatesync.ico does not exist (Doc 19: optional, only if present).

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\..\dist\SlateSyncAgent\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\SlateSync"; Filename: "{app}\SlateSyncAgent.exe"
Name: "{autodesktop}\SlateSync"; Filename: "{app}\SlateSyncAgent.exe"

[Registry]
Root: HKCR; Subkey: ".slatesync"; ValueType: string; ValueData: "SlateSyncCanvas"; Flags: uninsdeletekey
Root: HKCR; Subkey: "SlateSyncCanvas"; ValueType: string; ValueData: "SlateSync Canvas"; Flags: uninsdeletekey
Root: HKCR; Subkey: "SlateSyncCanvas\DefaultIcon"; ValueType: string; ValueData: "{app}\SlateSyncAgent.exe,0"
Root: HKCR; Subkey: "SlateSyncCanvas\shell\open\command"; ValueType: string; ValueData: """{app}\SlateSyncAgent.exe"" ""%1"""

[Run]
Filename: "{cmd}"; Parameters: "/C netsh advfirewall firewall add rule name=""SlateSync WS"" dir=in action=allow protocol=TCP localport=50606"; Flags: runhidden waituntilterminated
Filename: "{app}\SlateSyncAgent.exe"; Description: "Launch SlateSync"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C netsh advfirewall firewall delete rule name=""SlateSync WS"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: files; Name: "{app}\*.log"
