; Установщик SCVPN (Inno Setup 6).
; Собирает в красивый инсталлятор: ярлыки, удаление, иконка.
; Пути относительны папки setup\ (где лежит этот файл).

#define MyName "SCVPN"
#define MyVersion "0.0.0"
#define MyPublisher "SCVPN (open source)"
#define MyExe "SCVPN.exe"

[Setup]
AppId={{8F3A6C12-9D4E-4B7A-A1C5-2E9B7F0D6A34}
AppName={#MyName}
AppVersion={#MyVersion}
AppPublisher={#MyPublisher}
DefaultDirName={autopf}\{#MyName}
DefaultGroupName={#MyName}
DisableProgramGroupPage=yes
OutputDir=..\dist_installer
OutputBaseFilename=SCVPN-Setup-{#MyVersion}
SetupIconFile=scvpn.ico
UninstallDisplayIcon={app}\{#MyExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; Нужны права админа: ставим в Program Files, а TUN-режим всё равно требует админа.
PrivilegesRequired=admin

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Само приложение (вывод PyInstaller)
Source: "..\dist\SCVPN\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; Ядро и компоненты (xray, sing-box, wintun, гео-базы)
Source: "..\bin\*"; DestDir: "{app}\bin"; Flags: recursesubdirs createallsubdirs ignoreversion
; Документация
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme

[Icons]
Name: "{group}\{#MyName}"; Filename: "{app}\{#MyExe}"
Name: "{group}\Удалить {#MyName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyName}"; Filename: "{app}\{#MyExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyExe}"; Description: "{cm:LaunchProgram,{#MyName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; чистим рабочие данные пользователя при удалении (по желанию можно убрать)
Type: filesandordirs; Name: "{localappdata}\SCVPN"
