@echo off
setlocal
set "WINRES_SELF=%~f0"
set "WINRES_ARGS=%*"
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Wymagane uprawnienia administratora - uruchamiam ponownie...
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath $env:WINRES_SELF -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath $env:WINRES_SELF -ArgumentList $env:WINRES_ARGS -Verb RunAs"
  )
  if errorlevel 1 pause
  exit /b 3
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-Resurect.ps1" %*
set RC=%errorlevel%
echo.
echo Kod wyjscia: %RC%
pause
exit /b %RC%
