@echo off
setlocal EnableExtensions
:: ============================================================
::  LENOVO CONTROL - start with Windows
:: ============================================================
::  Sets the widget to launch automatically when you log in.
::
::  This uses Task Scheduler rather than the Startup folder on
::  purpose. The widget needs Administrator rights to open the
::  Lenovo energy driver, and anything in the Startup folder or
::  the registry Run key would pop a UAC prompt every single
::  boot. A scheduled task with "highest privileges" starts it
::  elevated silently instead.
::
::  Keep this file next to Lenovo_Control.exe (or the .ps1).
:: ============================================================

title Lenovo Control - Startup Setup

set "TASKNAME=Lenovo Control"

net session >nul 2>&1
if "%errorLevel%"=="0" goto findtarget
echo.
echo  [!] Creating a startup task needs Administrator - relaunching.
echo      Click "Yes" on the popup that appears.
echo.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
exit /b

:findtarget
:: Prefer the compiled .exe; fall back to running the .ps1 directly.
if exist "%~dp0Lenovo_Control.exe" goto useexe
if exist "%~dp0Lenovo_Control.ps1" goto useps1
echo.
echo  [!] Neither Lenovo_Control.exe nor Lenovo_Control.ps1 was found
echo      in this folder:
echo        %~dp0
echo      Put this .bat next to the widget and run it again.
echo.
pause
exit /b 1

:useexe
set "RUNCMD=\"%~dp0Lenovo_Control.exe\" -Hidden"
set "TARGETDESC=Lenovo_Control.exe"
goto menu

:useps1
set "RUNCMD=powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0Lenovo_Control.ps1\" -Hidden"
set "TARGETDESC=Lenovo_Control.ps1 (via PowerShell)"
goto menu

:menu
cls
echo ================================================================
echo    LENOVO CONTROL - START WITH WINDOWS
echo ================================================================
echo.
echo   Target found: %TARGETDESC%
echo.
echo   1. Enable  - start the widget automatically at logon
echo   2. Disable - stop starting it automatically
echo   3. Check   - is it currently set up?
echo   4. Exit
echo.
set "choice="
set /p choice="Enter your choice (1-4): "

if "%choice%"=="1" goto enable
if "%choice%"=="2" goto disable
if "%choice%"=="3" goto check
if "%choice%"=="4" goto end
goto menu

:enable
cls
echo Creating the logon task...
echo.
:: /RL HIGHEST is what avoids the UAC prompt on every boot.
:: /DELAY gives the desktop and the tray time to be ready first;
:: older Windows builds reject /DELAY, so fall back without it.
schtasks /Create /TN "%TASKNAME%" /TR "%RUNCMD%" /SC ONLOGON /RL HIGHEST /DELAY 0000:15 /F >nul 2>&1
if not errorlevel 1 goto enabled
echo (Your Windows build rejected the startup delay - retrying without it.)
schtasks /Create /TN "%TASKNAME%" /TR "%RUNCMD%" /SC ONLOGON /RL HIGHEST /F >nul 2>&1
if not errorlevel 1 goto enabled
echo.
echo  [!] Could not create the task. The exact error follows:
echo.
schtasks /Create /TN "%TASKNAME%" /TR "%RUNCMD%" /SC ONLOGON /RL HIGHEST /F
echo.
pause
goto menu

:enabled
echo.
echo  Done. The widget will start in the system tray about 15
echo  seconds after you log in, with no UAC prompt.
echo.
echo  It starts hidden - click its tray icon to open the panel.
echo  If you do not see the icon, check the "show hidden icons"
echo  arrow on the taskbar and drag it out to keep it visible.
echo.
echo  Note: if you move or rename the widget's folder later, run
echo  this again - the task stores the full path.
echo.
pause
goto menu

:disable
cls
schtasks /Delete /TN "%TASKNAME%" /F >nul 2>&1
if errorlevel 1 goto notset
echo.
echo  Done. The widget will no longer start automatically.
echo  It is not uninstalled - you can still run it any time.
echo.
pause
goto menu

:notset
echo.
echo  There was no startup task to remove - it was not enabled.
echo.
pause
goto menu

:check
cls
echo ================================================================
echo   CURRENT STATUS
echo ================================================================
echo.
schtasks /Query /TN "%TASKNAME%" /FO LIST >nul 2>&1
if errorlevel 1 goto checknone
echo   ENABLED - the widget is set to start at logon.
echo.
schtasks /Query /TN "%TASKNAME%" /FO LIST
echo.
pause
goto menu

:checknone
echo   NOT ENABLED - the widget will not start automatically.
echo.
pause
goto menu

:end
echo.
echo Bye!
timeout /t 2 >nul
exit
