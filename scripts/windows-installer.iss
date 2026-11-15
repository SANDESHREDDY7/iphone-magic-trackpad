; Inno Setup Script for Magic Trackpad Windows Companion
#define MyAppName "Magic Trackpad"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Magic Trackpad Pro"
#define MyAppURL "https://github.com/SANDESHREDDY7/iphone-magic-trackpad"
#define MyAppExeName "MagicTrackpad.exe"

[Setup]
AppId={{D37F8E80-92B1-4F42-B8E5-3A2F9A9E3812}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=..\dist
OutputBaseFilename=MagicTrackpad-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startupicon"; Description: "Launch automatically on Windows startup"; GroupDescription: "Startup:"

[Files]
Source: "..\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "node_modules\*,dist\*,mobile_app\*,website\*,scripts\*"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "node.exe"; Parameters: """{app}\server.js"""
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "node.exe"; Parameters: """{app}\server.js"""; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "node.exe"; Parameters: """{app}\server.js"""; Tasks: startupicon

[Run]
Filename: "node.exe"; Parameters: """{app}\server.js"""; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
