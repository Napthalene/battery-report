@echo off
setlocal

set "TASK_NAME=BatteryServicePowerEstimator"
set "PROJECT_ROOT=%~dp0.."
for %%I in ("%PROJECT_ROOT%") do set "PROJECT_ROOT=%%~fI"
set "RUNNER=%PROJECT_ROOT%\scripts\run-windows-estimator.cmd"

schtasks.exe /Create /TN "%TASK_NAME%" /TR "%ComSpec% /c %RUNNER%" /SC ONLOGON /RL HIGHEST /F
if errorlevel 1 exit /b %errorlevel%

schtasks.exe /Run /TN "%TASK_NAME%"
if errorlevel 1 exit /b %errorlevel%

echo Installed and started %TASK_NAME%
