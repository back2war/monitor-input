@echo off
rem Builds with the C# compiler that ships with Windows (.NET Framework 4.x) - nothing to install.
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
cd /d "%~dp0"
"%CSC%" /nologo /optimize /target:exe /out:monitor-input.exe MonitorInput.cs || exit /b 1
"%CSC%" /nologo /optimize /target:winexe /define:TRAY /r:System.Windows.Forms.dll /r:System.Drawing.dll /out:monitor-input-tray.exe MonitorInput.cs || exit /b 1
echo Built monitor-input.exe and monitor-input-tray.exe
