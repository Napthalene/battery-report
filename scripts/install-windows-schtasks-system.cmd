@echo off
setlocal

set "TASK_NAME=BatteryServicePowerEstimator"
set "PROJECT_ROOT=%~dp0.."
for %%I in ("%PROJECT_ROOT%") do set "PROJECT_ROOT=%%~fI"
set "RUNNER=%PROJECT_ROOT%\scripts\run-windows-estimator.cmd"

net session >nul 2>nul
if errorlevel 1 (
  echo ERROR: This installer must be run from an elevated Administrator command prompt.
  echo.
  echo Open Start, search for cmd or PowerShell, choose "Run as administrator",
  echo then run:
  echo "%~f0"
  exit /b 1
)

schtasks.exe /Create /TN "%TASK_NAME%" /TR "%ComSpec% /c %RUNNER%" /SC ONSTART /RU SYSTEM /RL HIGHEST /F
if errorlevel 1 exit /b %errorlevel%

schtasks.exe /Run /TN "%TASK_NAME%"
if errorlevel 1 exit /b %errorlevel%

echo Installed and started %TASK_NAME% as SYSTEM
