@echo off
rem ====================================================================
rem  Сборка установщика SCVPN-Setup.exe через Inno Setup.
rem  Предварительно должен быть собран build.bat (dist\SCVPN\SCVPN.exe).
rem ====================================================================
chcp 65001 >nul
cd /d "%~dp0"

set ISCC="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if not exist %ISCC% set ISCC="C:\Program Files\Inno Setup 6\ISCC.exe"
if not exist %ISCC% ( echo [!] Не найден Inno Setup 6 ^(ISCC.exe^). Установи с jrsoftware.org & pause & exit /b 1 )

if not exist "dist\SCVPN\SCVPN.exe" ( echo [!] Сначала собери приложение: build.bat & pause & exit /b 1 )

%ISCC% "setup\installer.iss"
if errorlevel 1 ( echo [!] Сборка установщика не удалась & pause & exit /b 1 )

echo.
echo Готово. Установщик в папке dist_installer\
pause
