@echo off
rem ====================================================================
rem  Сборка APK SCVPN.
rem  Использует JDK от Android Studio (JBR 21) и Gradle с D:.
rem ====================================================================
chcp 65001 >nul
cd /d "%~dp0"

set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
set "GRADLE_USER_HOME=D:\gradle\.gradle"
set "GRADLE=D:\gradle\gradle-8.9\bin\gradle.bat"

if not exist "%GRADLE%" ( echo [!] Нет Gradle в D:\gradle\gradle-8.9 & pause & exit /b 1 )
rem Бинарник AmneziaWG собирается из awg/ этого же репозитория (см. README).
rem Без него wireguard-серверы не поднимаются, а узнать это можно было бы
rem только на телефоне.
if not exist "app\src\main\jniLibs\arm64-v8a\libscvpnawg.so" ( echo [!] Нет libscvpnawg.so — собери его из awg/, см. README & pause & exit /b 1 )

call "%GRADLE%" assembleDebug --no-daemon %*
echo.
echo APK: app\build\outputs\apk\debug\app-debug.apk
pause
