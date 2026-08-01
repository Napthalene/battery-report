param(
    [string] $TaskName = "BatteryServicePowerEstimator"
)

$ErrorActionPreference = "Stop"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    Write-Host "Scheduled task does not exist: $TaskName"
    exit 1
}

$info = Get-ScheduledTaskInfo -TaskName $TaskName

[pscustomobject] @{
    TaskName = $TaskName
    State = $task.State
    LastRunTime = $info.LastRunTime
    LastTaskResult = $info.LastTaskResult
    NextRunTime = $info.NextRunTime
    UserId = $task.Principal.UserId
    LogonType = $task.Principal.LogonType
    RunLevel = $task.Principal.RunLevel
} | Format-List
