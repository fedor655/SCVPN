@echo off
rem ====================================================================
rem  Сборка SCVPN.exe через PyInstaller (папка dist\SCVPN).
rem  Бинарники ядра (xray/sing-box/wintun/гео) НЕ упаковываются сюда —
rem  их добавляет установщик из папки bin\ (так их проще обновлять).
rem  Иконка не генерируется: setup\scvpn.ico нарисован один раз и лежит в git.
rem ====================================================================
chcp 65001 >nul
cd /d "%~dp0"
set PY=.venv\Scripts\python.exe

if not exist "%PY%" ( echo [!] Нет .venv & pause & exit /b 1 )
if not exist "setup\scvpn.ico" ( echo [!] Нет setup\scvpn.ico & pause & exit /b 1 )

echo === PyInstaller ===
"%PY%" -m PyInstaller --noconfirm --clean --windowed --name SCVPN ^
  --icon setup\scvpn.ico ^
  --add-data "setup\scvpn.ico;." ^
  --exclude-module tkinter ^
  --exclude-module PySide6.QtWebEngineCore ^
  --exclude-module PySide6.QtWebEngineWidgets ^
  --exclude-module PySide6.Qt3DCore ^
  --exclude-module PySide6.QtQuick ^
  --exclude-module PySide6.QtQml ^
  --exclude-module PySide6.QtCharts ^
  --exclude-module PySide6.QtDataVisualization ^
  --exclude-module PySide6.QtPdf ^
  run.py

if errorlevel 1 ( echo [!] Сборка не удалась & pause & exit /b 1 )

echo.
echo Готово: dist\SCVPN\SCVPN.exe
echo Дальше: build_installer.bat — соберёт установщик.
pause
