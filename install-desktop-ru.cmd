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

echo ============================================
echo  OpenChamber Desktop - Russian Translation
echo ============================================
echo.

call "%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install-desktop-ru.ps1" -OpenChamberPath "%TARGET%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo.
  echo Installation failed with code %EXIT_CODE%.
  pause
)

exit /b %EXIT_CODE%
