@echo off
setlocal

set "TASK_NAME=BatteryServicePowerEstimator"

schtasks.exe /Query /TN "%TASK_NAME%" /V /FO LIST
