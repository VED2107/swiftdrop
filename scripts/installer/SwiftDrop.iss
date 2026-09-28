; SwiftDrop Windows installer (Inno Setup 6).  Built by: pnpm build:installer
; Per-user by default (no admin prompt). Choosing "all users" installs to Program Files and
; also adds the inbound firewall rule, so phones can connect without Windows asking.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define Root ".."+"\.."

[Setup]
AppId={{6C1E2F0B-5B8A-4F4E-9C8E-2D7A1B3F9E41}
AppName=SwiftDrop
AppVersion={#AppVersion}
AppVerName=SwiftDrop {#AppVersion}
AppPublisher=SwiftDrop
AppPublisherURL=https://github.com/VED2107/swiftdrop
DefaultDirName={autopf}\SwiftDrop
DefaultGroupName=SwiftDrop
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#Root}\release
OutputBaseFilename=SwiftDrop-Setup-{#AppVersion}
SetupIconFile={#Root}\assets\brand\swiftdrop.ico
UninstallDisplayIcon={app}\SwiftDrop.exe
UninstallDisplayName=SwiftDrop
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=force
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName=SwiftDrop
VersionInfoDescription=SwiftDrop installer

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "firewall"; Description: "Let phones on private Wi-Fi reach SwiftDrop (Windows Firewall rule)"; Check: IsAdminInstallMode

[Files]
Source: "{#Root}\release\SwiftDrop.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\SwiftDrop"; Filename: "{app}\SwiftDrop.exe"; Comment: "Send files between your phone and this PC"
Name: "{autodesktop}\SwiftDrop"; Filename: "{app}\SwiftDrop.exe"; Tasks: desktopicon

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""SwiftDrop"""; Flags: runhidden; Tasks: firewall
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""SwiftDrop"" dir=in action=allow program=""{app}\SwiftDrop.exe"" profile=private enable=yes"; Flags: runhidden; Tasks: firewall
Filename: "{app}\SwiftDrop.exe"; Description: "{cm:LaunchProgram,SwiftDrop}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM SwiftDrop.exe"; Flags: runhidden; RunOnceId: "StopSwiftDrop"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""SwiftDrop"""; Flags: runhidden; RunOnceId: "DelFirewall"; Check: IsAdminInstallMode

; Settings and pairings in %USERPROFILE%\.swiftdrop, and received files, are the user's: left in place.
