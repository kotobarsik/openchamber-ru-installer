@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "POWERSHELL_EXE=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%POWERSHELL_EXE%" (
  echo PowerShell not found: %POWERSHELL_EXE%
  pause
  exit /b 1
)

set "TARGET=%~1"
set "EXTRA=%~2"

set "FORCEARG="
if /i "%EXTRA%"=="-Force" set "FORCEARG=-Force"
if /i "%EXTRA%"=="Force" set "FORCEARG=-Force"

echo ============================================
echo  OpenChamber Desktop - Russian Translation
echo ============================================
echo.
echo Usage: %~nx0 ["path\to\@openchamberelectron"] [-Force]
echo.

call "%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install-desktop-ru.ps1" -OpenChamberPath "%TARGET%" %FORCEARG%
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo.
  echo Installation failed with code %EXIT_CODE%.
  pause
  exit /b %EXIT_CODE%
)

echo.
choice /C YN /T 10 /D Y /M "Close this window (Y) or keep it open (N)"
if errorlevel 2 (
  echo Window kept open. Press any key to close...
  pause >nul
)

exit /b %EXIT_CODE%
