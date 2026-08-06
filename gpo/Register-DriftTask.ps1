<#
================================================================
 Register-DriftTask.ps1  -  install the baseline drift re-apply task
================================================================
.SYNOPSIS
    Registers a scheduled task that periodically re-fetches Apply-Baseline.ps1
    from the repo and re-applies the local-policy baseline, so a machine
    self-heals back to standard between reboots. Run once per machine (or bake
    into a gold image). Re-running re-registers the task cleanly.

.DESCRIPTION
    The task runs as SYSTEM, at startup and every -IntervalHours, and its action
    is the same download-then-run one-liner an operator would use by hand:

        irm .../<Branch>/gpo/Apply-Baseline.ps1 -OutFile <local>; & <local> -BaselineName <name> -Branch <Branch>

    Because it re-fetches Apply-Baseline.ps1 (which itself re-fetches the baseline
    file) on every tick, ANY change merged to the branch propagates to the whole
    fleet automatically - Git is both the source of truth and the delivery channel.
    Point production machines at -Branch main; leave test machines on develop.

.PARAMETER IntervalHours
    How often to re-apply, in hours. Default: 4.

.PARAMETER BaselineName
    Baseline to apply (folder under gpo/baselines/). Default: 'arc-workstation-v1'.

.PARAMETER Branch
    Repo branch the task fetches from. Default: 'develop'. Use 'main' for production.

.PARAMETER TaskName
    Scheduled task name. Default: 'ArcGpoBaselineReapply'.

.NOTES
    Run elevated. STATUS: new tool, not yet validated on a real build.
================================================================
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [int]$IntervalHours = 4,
    [string]$BaselineName = 'arc-workstation-v1',
    [string]$Branch       = 'develop',
    [string]$TaskName     = 'ArcGpoBaselineReapply'
)

$ScriptVersion = '0.1.0-dev'
$ErrorActionPreference = 'Stop'

Write-Host ("Register-DriftTask.ps1  v{0}" -f $ScriptVersion) -ForegroundColor Cyan

# The command the task runs each tick: download-then-run Apply-Baseline.ps1 from
# the chosen branch, then invoke it. Single-quoted here so $env:/vars resolve on
# the TARGET at run time, not now. -NonInteractive so it never blocks on a prompt.
$applyUrl = "https://raw.githubusercontent.com/Arc-hub-tech/Automations/$Branch/gpo/Apply-Baseline.ps1"
$inner = @"
`$ErrorActionPreference='Stop';
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;
`$p="`$env:ProgramData\Arc Systems\GpoBaseline\Apply-Baseline.ps1";
New-Item -ItemType Directory -Path (Split-Path `$p) -Force | Out-Null;
Invoke-WebRequest -Uri '$applyUrl' -OutFile `$p -UseBasicParsing;
& `$p -BaselineName '$BaselineName' -Branch '$Branch'
"@
# Collapse to a single line for the task action.
$inner = ($inner -split "`r?`n" | Where-Object { $_ -ne '' }) -join ' '

$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -Command `"$inner`""

# Triggers: at startup, plus a repeating trigger every N hours. The repeating
# trigger needs a concrete start time; anchor it to the local day's midnight so
# no wall-clock is captured at registration (keeps re-registration deterministic).
$startAnchor = (Get-Date).Date
$triggerBoot   = New-ScheduledTaskTrigger -AtStartup
$triggerRepeat = New-ScheduledTaskTrigger -Once -At $startAnchor `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)

# SYSTEM, highest privileges - LGPO writes machine-wide local policy.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# VM-friendly settings, mirroring the gold-image resume task: run on battery,
# start if a scheduled run was missed (machine was off), no hard time limit.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

# Idempotent: replace any existing task of the same name.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "  Removing existing task '$TaskName'..." -ForegroundColor DarkGray
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger @($triggerBoot, $triggerRepeat) `
    -Principal $principal -Settings $settings `
    -Description ("Arc Systems: re-apply GPO baseline '{0}' from branch '{1}' every {2}h (drift self-heal)." -f $BaselineName, $Branch, $IntervalHours) | Out-Null

Write-Host ("Registered '{0}': baseline '{1}', branch '{2}', every {3}h + at startup." -f $TaskName, $BaselineName, $Branch, $IntervalHours) -ForegroundColor Green
Write-Host "  Run it now to seed the baseline:  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
