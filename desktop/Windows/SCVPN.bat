@echo off
rem Запуск SCVPN без окна консоли.
cd /d "%~dp0"
start "" ".venv\Scripts\pythonw.exe" run.py
