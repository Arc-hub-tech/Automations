<#
    Get-ArcCapacityScreen.ps1
    Datto capacity sampling toolset - Platform & Infrastructure

    This is the real logic for DATTO RMM COMPONENT 3 of 3 ("Arc - Capacity Screen"),
    but it is NOT what's pasted into that Datto component - Invoke-ArcCapacityScreen.ps1
    is. That stub fetches this file fresh from git on every run and executes it, so a
    revision here only needs a git merge, never a re-paste into Datto. Reads the usr*
    environment variables Datto sets for the component exactly as before.

    Purpose : Same-day over-allocation screen. Requires no sample history - runs
              once and returns a defensible candidate list immediately. Intended
              to run alongside, not instead of, the 14-day sampler.

    How it gets history without waiting
      Peak working set per process is retained by Windows since process start, so
      summing it gives a high-water mark with no observation window. It overcounts
      deliberately: shared pages are double-counted and per-process peaks did not
      occur simultaneously. That makes it a conservative upper bound on demand,
      which is exactly what a screen wants - it will miss marginal candidates and
      will not produce false positives.

      Average CPU since boot is derived from the System Idle Process kernel time
      rather than by summing per-process CPU, which would undercount anything that
      has since exited. Idle time is accurate, so busy time is accurate.

    What this deliberately does NOT do
      No vCPU recommendation. An average cannot size CPU - a host averaging 6%
      with a daily 90% batch window needs its cores. The average is reported for
      triage and flagged for review, nothing more. vCPU counts come from
      Component 2 on a proper window.

    Screening test
      Basis   = max( current committed , sum of peak working sets )
      Target  = max( RoleFloor , Basis x 1.4 )
      Flag only where reclaim exceeds BOTH 40% of allocation and 8GB.

    Component input variables (all optional):
              usrScreenUdfBase Integer  default 70    First UDF index, uses 4 fields
              usrMinUptimeHrs  Integer  default 24    Below this, no recommendation
              usrExportPath    String   default ''    Optional UNC for per-device CSV

    Version : 1.2  -  17/08/2026  (header updated: now fetched by Invoke-ArcCapacityScreen.ps1
              rather than pasted into Datto directly; removed the company-name header credit
              for public-repo visibility - no logic change)
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$UdfKey = 'HKLM:\SOFTWARE\CentraStage'

function Get-DattoInt {
    param([string]$Name, [int]$Default)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $Default
}

$UdfBase      = Get-DattoInt -Name 'usrScreenUdfBase' -Default 70
$MinUptimeHrs = Get-DattoInt -Name 'usrMinUptimeHrs'  -Default 24
$ExportPath   = [Environment]::GetEnvironmentVariable('usrExportPath')

$UdfCount = 4
if ($UdfBase -lt 1 -or $UdfBase -gt (300 - $UdfCount + 1)) {
    Write-Output "usrScreenUdfBase of $UdfBase is invalid - must be 1 to $(300 - $UdfCount + 1)."
    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output 'ScreenStatus=BAD_UDF_BASE'
    Write-Output '<-End Result->'
    exit 1
}

function Set-Udf {
    param([int]$Index, [string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 255) { $Value = $Value.Substring(0, 255) }
    if (-not (Test-Path -LiteralPath $UdfKey)) { New-Item -Path $UdfKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $UdfKey -Name "Custom$Index" -Value $Value -Force
}

function Get-Floor2 { param([double]$Value) [int]([math]::Floor($Value / 2) * 2) }

# Role floors and exclusions kept identical to Component 2 so the two agree
$RamFloor         = @{ DomainController = 4; RDSH = 8; FileServer = 8; SQLServer = 8; Exchange = 16; BackupInfra = 8; Generic = 4 }
$RamExcludedRoles = @('SQLServer', 'Exchange', 'BackupInfra')

function Get-ServerRole {
    $flags = New-Object System.Collections.Generic.List[string]
    $role  = 'Generic'
    $svc   = @{}
    try { foreach ($s in (Get-Service -ErrorAction SilentlyContinue)) { $svc[$s.Name] = $true } } catch { }

    $hasSvc = {
        param([string]$Pattern)
        foreach ($k in $svc.Keys) { if ($k -like $Pattern) { return $true } }
        return $false
    }

    try {
        $dr = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DomainRole
        if ($dr -eq 4 -or $dr -eq 5) { $role = 'DomainController'; $flags.Add('DC') }
    } catch { }

    if ((& $hasSvc 'MSExchange*')) { $role = 'Exchange'; $flags.Add('EXCH') }
    if (($svc.ContainsKey('MSSQLSERVER')) -or (& $hasSvc 'MSSQL$*')) {
        if ($role -eq 'Generic') { $role = 'SQLServer' }; $flags.Add('SQL')
    }
    if ((& $hasSvc 'Veeam*')) { $flags.Add('VEEAM'); if ($role -eq 'Generic') { $role = 'BackupInfra' } }

    $isRdsh = $false
    try {
        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            $f = Get-WindowsFeature -Name RDS-RD-Server -ErrorAction Stop
            if ($f -and $f.Installed) { $isRdsh = $true }
        }
    } catch { }
    if ($isRdsh) { if ($role -eq 'Generic') { $role = 'RDSH' }; $flags.Add('RDSH') }

    try {
        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            $f = Get-WindowsFeature -Name FS-FileServer -ErrorAction Stop
            if ($f -and $f.Installed -and $role -eq 'Generic') {
                $shares = @(Get-CimInstance -ClassName Win32_Share -ErrorAction SilentlyContinue |
                            Where-Object { $_.Type -eq 0 -and $_.Name -notmatch '\$$' })
                if ($shares.Count -gt 0) { $role = 'FileServer'; $flags.Add('FS') }
            }
        }
    } catch { }

    [PSCustomObject]@{ Role = $role; Flags = $flags }
}

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem  -ErrorAction Stop

    $allocatedGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $vCPU        = [int]$cs.NumberOfLogicalProcessors
    if ($vCPU -lt 1) { $vCPU = 1 }

    $uptime      = (Get-Date) - $os.LastBootUpTime
    $uptimeHrs   = [math]::Round($uptime.TotalHours, 1)
    $uptimeText  = if ($uptime.TotalDays -ge 1) { '{0}d' -f [int]$uptime.TotalDays } else { '{0}h' -f [int]$uptime.TotalHours }

    $roleInfo = Get-ServerRole
    $role     = $roleInfo.Role
    $flags    = $roleInfo.Flags

    # -----------------------------------------------------------------------
    # Current memory position
    # -----------------------------------------------------------------------
    $mem = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    $committedGB = if ($mem) { [math]::Round([double]$mem.CommittedBytes / 1GB, 2) } else { 0 }
    $availableGB = if ($mem) { [math]::Round([double]$mem.AvailableMBytes / 1KB, 2) } else { 0 }

    # -----------------------------------------------------------------------
    # Peak working set high-water mark
    # -----------------------------------------------------------------------
    $peakSumGB = 0
    $topText   = ''
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.PeakWorkingSet64 -gt 0 })
        if ($procs.Count -gt 0) {
            $peakSumGB = [math]::Round((($procs | Measure-Object -Property PeakWorkingSet64 -Sum).Sum) / 1GB, 2)
            $top = $procs | Sort-Object PeakWorkingSet64 -Descending | Select-Object -First 5
            $topText = (($top | ForEach-Object {
                '{0} {1}GB' -f $_.ProcessName, [math]::Round($_.PeakWorkingSet64 / 1GB, 1)
            }) -join ', ')
        }
    } catch {
        # Fall back to CIM if Get-Process is unavailable or restricted
        try {
            $cimProcs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
            $peakSumGB = [math]::Round((($cimProcs | Measure-Object -Property PeakWorkingSetSize -Sum).Sum) / 1MB, 2)
        } catch {
            $flags.Add('NO-PEAKWS')
        }
    }

    # -----------------------------------------------------------------------
    # Average CPU since boot, from idle time
    #   KernelModeTime on ProcessId 0 accumulates idle across all cores in
    #   100-nanosecond units. Busy = 1 - (idle / (uptime x cores)).
    # -----------------------------------------------------------------------
    $avgCpuPct = $null
    try {
        $idle = Get-CimInstance -ClassName Win32_Process -Filter 'ProcessId = 0' -ErrorAction Stop |
                Select-Object -First 1
        if ($idle -and $idle.KernelModeTime) {
            $idleSeconds  = [double]$idle.KernelModeTime / 1e7
            $totalCoreSec = $uptime.TotalSeconds * $vCPU
            if ($totalCoreSec -gt 0) {
                $busy = 100 * (1 - ($idleSeconds / $totalCoreSec))
                if ($busy -lt 0)   { $busy = 0 }
                if ($busy -gt 100) { $busy = 100 }
                $avgCpuPct = [math]::Round($busy, 1)
            }
        }
    } catch { }

    $effCores = if ($null -ne $avgCpuPct) { [math]::Round(($avgCpuPct / 100) * $vCPU, 2) } else { $null }

    # -----------------------------------------------------------------------
    # Screening verdict
    # -----------------------------------------------------------------------
    $ramFloorGB = $RamFloor[$role]
    if (-not $ramFloorGB) { $ramFloorGB = 4 }

    $basisGB   = [math]::Max($committedGB, $peakSumGB)
    $reclaimGB = 0
    $verdict   = ''

    if ($uptimeHrs -lt $MinUptimeHrs) {
        $flags.Add('LOW-UPTIME')
        $verdict = "NO SCREEN - uptime ${uptimeText}, peak working sets not yet representative"
    }
    elseif ($RamExcludedRoles -contains $role) {
        $verdict = "EXCLUDED ($role) - size from the platform-specific metrics, not guest commit"
    }
    elseif ($basisGB -le 0) {
        $verdict = 'NO SCREEN - could not establish a memory demand basis'
    }
    else {
        $targetGB = [math]::Max($ramFloorGB, [math]::Round($basisGB * 1.4, 2))
        $raw      = $allocatedGB - $targetGB
        $candidate = if ($raw -gt 0) { Get-Floor2 -Value $raw } else { 0 }

        # Gross over-allocation only: must clear 40% of allocation and 8GB.
        # Matches Component 2 conservative mode so the two never disagree.
        $grossFloor = $allocatedGB * 0.4

        if ($candidate -ge 8 -and $candidate -ge $grossFloor) {
            $reclaimGB = $candidate
            $newAlloc  = [int]($allocatedGB - $reclaimGB)
            $verdict   = "SCREEN CANDIDATE - reclaim ${reclaimGB}GB -> ${newAlloc}GB (basis ${basisGB}GB x1.4)"
            $flags.Add('CANDIDATE')
        }
        elseif ($candidate -gt 0) {
            $verdict = "NOT GROSS - only ${candidate}GB clear of the 1.4x basis, defer to 14-day window"
        }
        else {
            $verdict = "NO HEADROOM - basis ${basisGB}GB against ${allocatedGB}GB allocated"
        }
    }

    # CPU is reported, never sized, from an average
    $cpuNote = if ($null -ne $avgCpuPct) {
        $n = "Avg since boot ${avgCpuPct}% over ${uptimeText} = ${effCores} cores of $vCPU"
        if ($avgCpuPct -lt 5 -and $vCPU -ge 8) { $flags.Add('CPU-REVIEW'); $n += ' | REVIEW' }
        $n
    } else { 'Average CPU unavailable' }

    # -----------------------------------------------------------------------
    # UDF write-back
    # -----------------------------------------------------------------------
    $ramText = 'Alloc {0}GB | Commit {1}GB | PeakWS sum {2}GB | Avail {3}GB | Up {4}' -f `
               $allocatedGB, $committedGB, $peakSumGB, $availableGB, $uptimeText
    $cpuText = '{0} vCPU | {1}' -f $vCPU, $cpuNote
    $verText = '{0} | {1} | {2}' -f $verdict, ($flags -join ','), (Get-Date -Format 'dd/MM/yyyy HH:mm')

    Set-Udf -Index ($UdfBase + 0) -Value $ramText
    Set-Udf -Index ($UdfBase + 1) -Value ('{0:D3}' -f $reclaimGB)
    Set-Udf -Index ($UdfBase + 2) -Value $cpuText
    Set-Udf -Index ($UdfBase + 3) -Value $verText

    # -----------------------------------------------------------------------
    # Optional CSV export - separate filename so it cannot collide with
    # Component 2's export in the same share
    # -----------------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($ExportPath)) {
        try {
            if (-not (Test-Path -LiteralPath $ExportPath)) {
                New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
            }
            $rowFile = Join-Path $ExportPath ("{0}-screen.csv" -f $env:COMPUTERNAME)
            [PSCustomObject][ordered]@{
                Hostname      = $env:COMPUTERNAME
                Reported      = (Get-Date -Format 'dd/MM/yyyy HH:mm')
                Role          = $role
                Flags         = ($flags -join ',')
                UptimeHours   = $uptimeHrs
                AllocatedGB   = $allocatedGB
                CommittedGB   = $committedGB
                PeakWsSumGB   = $peakSumGB
                BasisGB       = $basisGB
                AvailableGB   = $availableGB
                ScreenReclaim = $reclaimGB
                Verdict       = $verdict
                vCPU          = $vCPU
                AvgCpuPct     = $avgCpuPct
                EffCores      = $effCores
                TopPeakWs     = $topText
            } | Export-Csv -LiteralPath $rowFile -NoTypeInformation -Encoding UTF8 -Force
            Write-Output "Exported screen row to $rowFile"
        } catch {
            Write-Output "CSV export skipped: $($_.Exception.Message)"
        }
    }

    Write-Output "=== Arc Capacity Screen - $env:COMPUTERNAME ==="
    Write-Output "Role      : $role $(if ($flags.Count) { '(' + ($flags -join ',') + ')' })"
    Write-Output "Uptime    : $uptimeText"
    Write-Output "Memory    : $ramText"
    if ($topText) { Write-Output "Top peaks : $topText" }
    Write-Output "CPU       : $cpuText"
    Write-Output "Verdict   : $verdict"
    Write-Output ''
    Write-Output 'NOTE: screening figures only. Peak working set sums overcount shared pages and'
    Write-Output '      non-simultaneous peaks, so this understates reclaim by design. Average CPU'
    Write-Output '      since boot is not a vCPU sizing basis. Confirm against Component 2.'
    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output ('ScreenStatus=' + $(if ($flags -contains 'CANDIDATE') { 'CANDIDATE' } elseif ($flags -contains 'LOW-UPTIME') { 'LOW_UPTIME' } else { 'NO_ACTION' }))
    Write-Output "ScreenReclaimGB=$reclaimGB"
    Write-Output "AllocatedGB=$allocatedGB"
    Write-Output "BasisGB=$basisGB"
    Write-Output '<-End Result->'
    exit 0
}
catch {
    Write-Output "SCREEN FAILED: $($_.Exception.Message)"
    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output 'ScreenStatus=FAILED'
    Write-Output "ScreenError=$($_.Exception.Message)"
    Write-Output '<-End Result->'
    exit 1
}
