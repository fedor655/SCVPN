; Установщик SCVPN (Inno Setup 6.3 и новее — нужен идентификатор x64compatible).
; Пути относительны папки setup\ (где лежит этот файл).
;
; Вызов из build.ps1:
;   ISCC /DMyArch=x64   /DMyVersion=0.0.0 setup\installer.iss
;   ISCC /DMyArch=arm64 /DMyVersion=0.0.0 setup\installer.iss

#ifndef MyArch
  #define MyArch "x64"
#endif
#ifndef MyVersion
  #define MyVersion "0.0.0"
#endif

#define MyName "SCVPN"
#define MyPublisher "SCVPN (open source)"
#define MyExe "SCVPN.exe"

; x64compatible покрывает и x64-Windows, и arm64-Windows (там x64-приложение
; идёт под эмуляцией). Для arm64-сборки берём именно arm64: ставить нативную
; сборку на x64-машину нельзя.
#if MyArch == "arm64"
  #define MyArchIds "arm64"
#else
  #define MyArchIds "x64compatible"
#endif

[Setup]
; AppId тот же, что был у Python-версии: установка поверх неё обязана быть
; обновлением, а не вторым приложением в списке программ.
AppId={{8F3A6C12-9D4E-4B7A-A1C5-2E9B7F0D6A34}
AppName={#MyName}
AppVersion={#MyVersion}
AppPublisher={#MyPublisher}
DefaultDirName={autopf}\{#MyName}
DefaultGroupName={#MyName}
DisableProgramGroupPage=yes
OutputDir=..\dist_installer
OutputBaseFilename=SCVPN-Setup-{#MyVersion}-{#MyArch}
SetupIconFile=scvpn.ico
UninstallDisplayIcon={app}\{#MyExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed={#MyArchIds}
ArchitecturesInstallIn64BitMode={#MyArchIds}
; Нужны права админа: ставим в Program Files, а TUN-режим всё равно требует админа.
PrivilegesRequired=admin
; Windows 10 21H2 — нижняя поддерживаемая версия (сборка 19044).
MinVersion=10.0.19044

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Остатки прежней версии на Python. Установка поверх по тому же AppId файлы
; предыдущей установки не удаляет, и в {app} осталась бы сотня мегабайт
; PyInstaller и PySide6, которую уже никогда не подберут.
;
; Папку bin НЕ трогаем: там скачанные ядра, и их удаление заставило бы
; качать всё заново при каждом обновлении. Ядра не той архитектуры
; отбракует метка bin\arch.txt, и приложение само предложит скачать нужные.
Type: filesandordirs; Name: "{app}\_internal"
Type: filesandordirs; Name: "{app}\PySide6"
Type: filesandordirs; Name: "{app}\shiboken6"
Type: files; Name: "{app}\python*.dll"
Type: files; Name: "{app}\Qt6*.dll"
Type: files; Name: "{app}\base_library.zip"
Type: files; Name: "{app}\VCRUNTIME140*.dll"

[Files]
; Приложение целиком (вывод dotnet publish, self-contained).
Source: "..\dist\{#MyArch}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; Документация
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme

; Ядра (xray, sing-box, wintun, гео-базы) в установщик НЕ кладутся, в отличие
; от прежней версии. Они зависят от архитектуры, а сборочная машина у нас
; arm64: положить её bin в x64-установщик значило бы выдать пользователю
; заведомо нерабочие бинарники. Приложение скачивает их само при первом
; запуске — оно и раньше это умело.

[Icons]
Name: "{group}\{#MyName}"; Filename: "{app}\{#MyExe}"
Name: "{group}\Удалить {#MyName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyName}"; Filename: "{app}\{#MyExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyExe}"; Description: "{cm:LaunchProgram,{#MyName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; чистим рабочие данные пользователя при удалении (по желанию можно убрать)
Type: filesandordirs; Name: "{localappdata}\SCVPN"
