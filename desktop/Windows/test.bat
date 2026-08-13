@echo off
rem ====================================================================
rem  Быстрый запуск тестового кода SCVPN.
rem    test.bat              -> прогоняет smoke_test.py (полная проверка)
rem    test.bat файл.py ...  -> запускает указанный python-файл с аргументами
rem ====================================================================
chcp 65001 >nul
cd /d "%~dp0"
set PYTHONUTF8=1
set PY=.venv\Scripts\python.exe

if not exist "%PY%" (
  echo [!] Не найдено окружение .venv. Запусти setup\install.bat
  pause
  exit /b 1
)

if "%~1"=="" (
  echo === Прогоняю smoke_test.py ===
  "%PY%" smoke_test.py
) else (
  "%PY%" %*
)

echo.
echo --- готово (код выхода %ERRORLEVEL%) ---
pause
