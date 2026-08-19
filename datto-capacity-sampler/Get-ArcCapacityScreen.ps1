<#
    Get-ArcCapacityScreen.ps1
    Datto capacity sampling toolset

    This is the real logic for DATTO RMM COMPONENT 3 of 3 ("Arc - Capacity Screen"),
    but it is NOT what's pasted into that Datto component - Invoke-ArcCapacityScreen.ps1
    is. That stub fetches this file fresh from git on every run and executes it, so a
    revision here only needs a git merge, never a re-paste into Datto. Reads the usr*
    environment variables Datto sets for the component exactly as before.

    Purpose : Same-day over-allocation screen. Requires no sample history - runs
              once and returns a defensible candidate list immediately. Intended
              to run alongside, not instead of, the 14-day sampler.

    How it stays conservative without history
      The basis is committed bytes - a current reading, and the same demand metric
      Component 2 sizes from, so the two agree on what "demand" means. Peak working
      set sum is still collected and reported as context but is NOT the basis; see
      the note at $basisGB for why that changed.

      With a single instantaneous reading as the basis, the conservatism comes
      entirely from the gross-over-allocation gate: reclaim must clear both 40% of
      allocation and 8GB. That is what stops a one-off measurement producing a
      marginal recommendation, and it is doing the real filtering - switching the
      basis off peak working sets moved a 73-device estate only from 90GB to 104GB.

      Average CPU since boot is derived from the System Idle Process kernel time
      rather than by summing per-process CPU, which would undercount anything that
      has since exited. Idle time is accurate, so busy time is accurate.

    What this deliberately does NOT do
      No vCPU recommendation. An average cannot size CPU - a host averaging 6%
      with a daily 90% batch window needs its cores. The average is reported for
      triage and flagged for review, nothing more. vCPU counts come from
      Component 2 on a proper window.

    Screening test
      Basis   = current committed bytes
      Target  = max( RoleFloor , Basis x 1.4 )
      Flag only where reclaim exceeds BOTH 40% of allocation and 8GB.

    Over-commitment outranks all of the above, including the uptime gate and the
    role exclusions - see the UPSIZE block. It is an observable fact rather than
    a sizing claim, so neither guard applies to it.

    Component input variables (all optional):
              usrScreenUdfBase Integer  default 70    First UDF index, uses 4 fields
              usrMinUptimeHrs  Integer  default 24    Below this, no recommendation
              usrExportPath    String   default ''    Optional UNC for per-device CSV

    Version : 1.5  -  19/08/2026  (basis moved off peak-working-set sum onto committed
              bytes - the old max(committed, peakSum) exceeded allocated RAM on 20 of 73
              real devices, which cannot support a verdict either way. Gross-over-allocation
              gate and the 24h uptime floor both retained deliberately: the gate is what
              provides conservatism now, and the uptime gate's original warm-up rationale
              no longer applies to an instantaneous metric, so its wording is corrected to
              describe what it actually is)

    Version : 1.4  -  19/08/2026  (three fixes from a 73-device estate export.
              SQL exclusion now requires the engine to be a MATERIAL memory consumer
              rather than merely present - presence-only excluded 21 of 73 devices,
              including RD gateways, a VPN host and file servers carrying a bundled
              Express or Veeam instance, throwing away real reclaim. Added the UPSIZE
              verdict: 12 hosts sat at or over their allocation while reading NO
              HEADROOM or EXCLUDED. Added CPU-PRESSURE: the screen previously had no
              high-CPU path at all, so a host averaging 95.1% over 104 days produced
              no signal whatsoever. ScreenStatus values are unchanged on purpose -
              see the note at the result block)

    Version : 1.3  -  18/08/2026  (header updated: now fetched by Invoke-ArcCapacityScreen.ps1
              rather than pasted into Datto directly; removed the company-name header credit
              and internal team byline for public-repo visibility - no logic change)
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
    param([double]$AllocatedGB = 0)

    $flags   = New-Object System.Collections.Generic.List[string]
    $role    = 'Generic'
    $sqlWsGB = $null
    $svc     = @{}
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

    # SQL presence alone is NOT enough to exclude a host from sizing.
    #
    # The exclusion exists for one reason: on a host where SQL dominates memory,
    # guest committed bytes reports the configured 'max server memory' rather
    # than the requirement, so commit is not a safe sizing basis. That reasoning
    # only holds while SQL is actually a material consumer.
    #
    # Presence-only matching excluded 21 of 73 devices on a real estate,
    # including RD gateways, a VPN host and plain file servers. None were
    # mis-matched: they genuinely carry a bundled instance (MSSQL$SQLEXPRESS
    # from an RDS Connection Broker deployment, MSSQL$VEEAMSQL* from Veeam, or
    # an LOB app's Express instance). A capped Express instance idling at a few
    # hundred MB on a 12GB gateway does not distort that host's commit figure,
    # and excluding it threw away real, safe reclaim.
    #
    # So gate on the engine's actual footprint, which is measurable on the spot
    # with no history: material means sqlservr holds at least a quarter of
    # allocated RAM AND at least 2GB. Both conditions, deliberately - the ratio
    # alone over-fires on small hosts (25% of 4GB is reachable by Express,
    # whose buffer pool caps at ~1.4GB), and the absolute alone under-fires on
    # large ones. Below the bar the host is flagged SQL-MINOR and screened
    # normally, so the SQL is still visible without silently suppressing sizing.
    if (($svc.ContainsKey('MSSQLSERVER')) -or (& $hasSvc 'MSSQL$*')) {
        $sqlWsGB = 0.0
        try {
            $sqlProcs = @(Get-Process -Name 'sqlservr' -ErrorAction SilentlyContinue)
            if ($sqlProcs.Count -gt 0) {
                $sqlWsGB = [math]::Round((($sqlProcs | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1GB, 2)
            }
        } catch { }

        # $AllocatedGB is passed in by the caller, which has already read
        # Win32_OperatingSystem - no second CIM query. A 0 (caller could not
        # determine it) degrades to the absolute-only test rather than
        # mis-classifying the host in either direction.
        $sqlIsMaterial = ($sqlWsGB -ge 2) -and
                         (($AllocatedGB -le 0) -or ($sqlWsGB -ge ($AllocatedGB * 0.25)))

        if ($sqlIsMaterial) {
            if ($role -eq 'Generic') { $role = 'SQLServer' }
            $flags.Add('SQL')
        } else {
            $flags.Add('SQL-MINOR')
        }
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

    [PSCustomObject]@{ Role = $role; Flags = $flags; SqlWsGB = $sqlWsGB }
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

    $roleInfo = Get-ServerRole -AllocatedGB $allocatedGB
    $role     = $roleInfo.Role
    $flags    = $roleInfo.Flags
    $sqlWsGB  = $roleInfo.SqlWsGB

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

    # Basis is committed bytes. Peak working set sum is reported alongside it as
    # context but is deliberately NOT part of the basis any more.
    #
    # It used to be max(committed, peakSum), which in practice meant peakSum won
    # on most hosts. Summing per-process peaks double-counts shared pages and
    # adds peaks that never co-occurred, and the result is not bounded by
    # physical memory: on a real 73-device estate it exceeded allocated RAM on
    # 20 of them, producing output like "basis 13.89GB against 8GB allocated".
    # As an intentional over-count it was defensible in principle, but a basis
    # that exceeds the allocation it is being compared against cannot support a
    # verdict either way, and applying the 1.4x multiplier on top compounded it.
    #
    # Committed bytes is private memory demand, is bounded by something real, and
    # is what Component 2 sizes from - so the two components now agree on what
    # "demand" means. The conservatism that peakSum was providing is retained
    # instead by the gross-over-allocation gate below (must clear both 40% of
    # allocation and 8GB), which is what actually does the filtering: switching
    # the basis alone moved the estate result only from 90GB to 104GB.
    $basisGB   = $committedGB
    $reclaimGB = 0
    $verdict   = ''

    # Over-commitment outranks every other verdict, including the uptime gate
    # and the role exclusions.
    #
    # Committed bytes above allocated RAM means the host is leaning on its
    # pagefile right now. That is an instantaneous, observable fact - it needs
    # no history, so the uptime gate has no bearing on it (a host over-committed
    # 8 hours after boot is genuinely over-committed), and it is not a sizing
    # claim, so the SQL/Exchange/Veeam exclusions do not apply either. Those
    # exclusions exist because commit is an unreliable basis for *sizing down*;
    # they were never meant to hide a host that is out of memory, which is
    # exactly what they were doing - 12 hosts on a real estate sat over
    # allocation while reading NO HEADROOM or EXCLUDED.
    #
    # 0.9 rather than 1.0 catches hosts on the edge before they tip over.
    # Reported, never sized: the screen says "look at this", and Component 2's
    # growth-sizing produces the actual number from a real window.
    $overCommitted = ($allocatedGB -gt 0) -and ($committedGB -gt ($allocatedGB * 0.9))

    if ($overCommitted) {
        $flags.Add('UPSIZE')
        $pctOfAlloc  = [math]::Round(100 * $committedGB / $allocatedGB, 0)
        $roleContext = if ($RamExcludedRoles -contains $role) { " | $role - confirm against the platform-specific metrics" } else { '' }
        $verdict = "UPSIZE - commit ${committedGB}GB is ${pctOfAlloc}% of ${allocatedGB}GB allocated, no reclaim headroom${roleContext}"
    }
    elseif ($uptimeHrs -lt $MinUptimeHrs) {
        # Now a sanity floor, not a warm-up period. The gate originally existed
        # because peak working sets need time to become representative; with
        # committed bytes as the basis that no longer applies, since commit is a
        # current reading valid minutes after boot. It is kept only so a host
        # measured mid-boot - services still starting, caches cold - is not
        # screened on an unrepresentative moment.
        $flags.Add('LOW-UPTIME')
        $verdict = "NO SCREEN - uptime ${uptimeText}, still settling after boot"
    }
    elseif ($RamExcludedRoles -contains $role) {
        # Cite the footprint that justified a SQL exclusion, so the decision is
        # auditable from the UDF rather than being an unexplained suppression -
        # same principle as the DIT-derived floor detail in Component 2.
        $exclDetail = if ($role -eq 'SQLServer' -and $null -ne $sqlWsGB -and $sqlWsGB -gt 0) {
            " (sqlservr holding ${sqlWsGB}GB)"
        } else { '' }
        $verdict = "EXCLUDED ($role)$exclDetail - size from the platform-specific metrics, not guest commit"
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

    # CPU is reported, never sized, from an average.
    #
    # Two thresholds, deliberately asymmetric:
    #
    #   CPU-REVIEW (low)   - suspiciously idle, worth a look for reduction. Gated
    #                        on 8+ vCPU because trimming a 2-4 vCPU host is not
    #                        worth a change window.
    #   CPU-PRESSURE (high)- sustained saturation. Previously ABSENT ENTIRELY:
    #                        the screen only ever looked for idle hosts, so a
    #                        real host averaging 95.1% over 104 days (7.61 of 8
    #                        cores) produced no signal of any kind. An average
    #                        this high is a floor, not a peak - since averaging
    #                        flattens spikes, 70% sustained implies peaks well
    #                        above it. Applies at any vCPU count: a saturated
    #                        2 vCPU host is as stuck as a saturated 16 vCPU one.
    #
    # Name matches Component 2's flag vocabulary so one filter catches both.
    $cpuNote = if ($null -ne $avgCpuPct) {
        $n = "Avg since boot ${avgCpuPct}% over ${uptimeText} = ${effCores} cores of $vCPU"
        if ($avgCpuPct -ge 70) {
            $flags.Add('CPU-PRESSURE')
            $n += ' | PRESSURE - sustained saturation, needs more vCPU not fewer'
        }
        elseif ($avgCpuPct -lt 5 -and $vCPU -ge 8) {
            $flags.Add('CPU-REVIEW')
            $n += ' | REVIEW'
        }
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
                OverCommitted = $(if ($overCommitted) { 1 } else { 0 })
                SqlWsGB       = $sqlWsGB
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
    Write-Output 'NOTE: screening figures only, from a single instantaneous reading. Reclaim is'
    Write-Output '      gated to gross over-allocation (40% of allocation and 8GB) so a one-off'
    Write-Output '      measurement cannot produce a marginal recommendation. PeakWS sum is'
    Write-Output '      context only, not the basis - it overcounts shared pages and'
    Write-Output '      non-simultaneous peaks. Average CPU since boot is not a vCPU sizing'
    Write-Output '      basis. Confirm against Component 2.'
    Write-Output ''
    Write-Output '<-Start Result->'
    # ScreenStatus MUST stay within the set Invoke-ArcCapacityScreen.ps1
    # whitelists - CANDIDATE / LOW_UPTIME / NO_ACTION - because that stub fails
    # closed on any value it does not recognise. UPSIZE is deliberately NOT a
    # status for that reason: the stub is pasted into Datto's console, so a new
    # status value could not reach devices without a re-paste, and until every
    # device had been re-pasted each over-committed host would report its job as
    # FAILED. It travels as its own field instead, which the stub ignores, so
    # this stays a git-only change that works against any pasted stub version.
    Write-Output ('ScreenStatus=' + $(if ($flags -contains 'CANDIDATE') { 'CANDIDATE' } elseif ($flags -contains 'LOW-UPTIME') { 'LOW_UPTIME' } else { 'NO_ACTION' }))
    Write-Output "ScreenReclaimGB=$reclaimGB"
    Write-Output "AllocatedGB=$allocatedGB"
    Write-Output "BasisGB=$basisGB"
    Write-Output ('ScreenUpsize=' + $(if ($overCommitted) { '1' } else { '0' }))
    Write-Output ('ScreenCpuPressure=' + $(if ($flags -contains 'CPU-PRESSURE') { '1' } else { '0' }))
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
