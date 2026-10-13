@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Wymagane uprawnienia administratora - uruchamiam ponownie...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b 3
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-Resurect.ps1" %*
set RC=%errorlevel%
echo.
echo Kod wyjscia: %RC%
pause
exit /b %RC%
