@echo off
rem Builds, installs into %LOCALAPPDATA%\MonitorInput, enables start with Windows and launches the tray app.
rem Safe to re-run after code changes: the running tray app is stopped and replaced, hotkeys are kept.
setlocal
cd /d "%~dp0"
set "DEST=%LOCALAPPDATA%\MonitorInput"

rem Stop any running copy first: it locks its exe, which would break both the build and the copy.
taskkill /im monitor-input-tray.exe /f >nul 2>&1
rem Give the process a moment to exit and release the exe (timeout.exe fails without a console).
ping -n 2 127.0.0.1 >nul

call "%~dp0build.cmd" || exit /b 1

if not exist "%DEST%" mkdir "%DEST%"
copy /y monitor-input.exe "%DEST%\" >nul || exit /b 1
copy /y monitor-input-tray.exe "%DEST%\" >nul || exit /b 1

rem The hotkey config lives next to the exe; seed it from a local one on first install only.
if not exist "%DEST%\monitor-input.ini" if exist monitor-input.ini copy /y monitor-input.ini "%DEST%\" >nul

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v MonitorInputTray /t REG_SZ /d "\"%DEST%\monitor-input-tray.exe\"" /f >nul || exit /b 1

start "" "%DEST%\monitor-input-tray.exe"
echo Installed to %DEST%
