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

call "%GRADLE%" assembleDebug --no-daemon %*
echo.
echo APK: app\build\outputs\apk\debug\app-debug.apk
pause
