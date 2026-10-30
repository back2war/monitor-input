@echo off
rem Stops the tray app, removes start with Windows and deletes %LOCALAPPDATA%\MonitorInput (including hotkeys).
setlocal
set "DEST=%LOCALAPPDATA%\MonitorInput"

taskkill /im monitor-input-tray.exe /f >nul 2>&1
ping -n 2 127.0.0.1 >nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v MonitorInputTray /f >nul 2>&1
if exist "%DEST%" rmdir /s /q "%DEST%"
echo Uninstalled
