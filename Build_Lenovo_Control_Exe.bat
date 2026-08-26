@echo off
setlocal EnableExtensions
:: ============================================================
::  BUILD LENOVO CONTROL.EXE
:: ============================================================
::  One-time step. Compiles Lenovo_Control.ps1 into a standalone
::  Lenovo_Control.exe using ps2exe, the open-source PowerShell
::  to exe compiler from the official PowerShell Gallery.
::
::  Run this once, in the same folder as Lenovo_Control.ps1.
::  The finished .exe elevates itself via its own manifest, so
::  you will not need the launcher .bat afterwards - just pin
::  Lenovo_Control.exe to your taskbar or Start menu.
::
::  If Lenovo_Control_Icon.ico sits in the same folder it gets
::  embedded as the icon automatically.
:: ============================================================

echo Installing ps2exe if it isn't already (needs internet once)...
powershell -NoProfile -Command "if (-not (Get-Module -ListAvailable -Name ps2exe)) { Install-Module ps2exe -Scope CurrentUser -Force -ErrorAction Stop }"
if not errorlevel 1 goto build
echo.
echo  [!] Could not install ps2exe - check your internet connection
echo      and try running this again.
pause
exit /b 1

:build
if exist "%~dp0Lenovo_Control_Icon.ico" goto buildicon
echo Compiling (no icon file found - using the default)...
powershell -NoProfile -Command "Invoke-ps2exe -inputFile '%~dp0Lenovo_Control.ps1' -outputFile '%~dp0Lenovo_Control.exe' -noConsole -title 'Lenovo Control' -requireAdmin"
goto checkbuilt

:buildicon
echo Compiling with custom icon...
powershell -NoProfile -Command "Invoke-ps2exe -inputFile '%~dp0Lenovo_Control.ps1' -outputFile '%~dp0Lenovo_Control.exe' -iconFile '%~dp0Lenovo_Control_Icon.ico' -noConsole -title 'Lenovo Control' -requireAdmin"

:checkbuilt
if not exist "%~dp0Lenovo_Control.exe" goto failed

echo.
echo Done. Lenovo_Control.exe is now next to this file.
echo Double-click it from now on - it elevates itself automatically.
pause
exit /b 0

:failed
echo.
echo  [!] Something went wrong - Lenovo_Control.exe was not created.
echo      Scroll up for the actual PowerShell error.
pause
exit /b 1
