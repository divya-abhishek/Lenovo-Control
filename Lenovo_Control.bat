@echo off
setlocal EnableExtensions
:: ============================================================
::  LENOVO CONTROL WIDGET - launcher
:: ============================================================
::  Keep this .bat in the SAME FOLDER as Lenovo_Control.ps1
::  Double-click it. It elevates itself to Administrator (needed
::  to open the Lenovo energy driver), then opens the widget -
::  this console window closes itself automatically.
:: ============================================================

net session >nul 2>&1
if "%errorLevel%"=="0" goto launch
echo.
echo  [!] Relaunching elevated - click "Yes" on the popup.
echo.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
exit /b

:launch
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Lenovo_Control.ps1"
exit
