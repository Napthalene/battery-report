@echo off
setlocal

set "TASK_NAME=BatteryServicePowerEstimator"
set "WATCHDOG_TASK_NAME=BatteryServicePowerEstimatorWatchdog"

schtasks.exe /End /TN "%TASK_NAME%" >nul 2>nul
schtasks.exe /Run /TN "%TASK_NAME%"
schtasks.exe /Run /TN "%WATCHDOG_TASK_NAME%" >nul 2>nul
