<#
    Read-ArcCapacityBuffer.ps1
    Datto capacity sampling toolset - Platform & Infrastructure

    This is the real logic for DATTO RMM COMPONENT 2 of 3 ("Arc - Capacity Analyse"),
    but it is NOT what's pasted into that Datto component - Invoke-ArcCapacityAnalyse.ps1
    is. That stub fetches this file fresh from git on every run and executes it, so a
    revision here only needs a git merge, never a re-paste into Datto. Reads the usr*
    environment variables Datto sets for the component exactly as before.

    Purpose : Reads the rolling buffer written by Arc-CapacitySampler.ps1, computes
              percentile demand for memory and CPU, applies role-based floors and
              pressure guardrails, and stamps the result into user-defined fields
              for Devices grid export. Sizes in both directions - reclaim when
              over-allocated, growth when under-provisioned - from one shared target.

    Sizing logic
      RAM   Target      = max( RoleFloor , p95 Committed x 1.25 )
            Reclaim     = Allocated - Target when positive, floored to a 2GB
                          increment, suppressed below 4GB (not worth a change window)
            Growth      = Target - Allocated when positive, ceilinged to a 2GB
                          increment. Escalates independently of Target whenever the
                          memory-pressure guardrail is active (min available <1GB or
                          p95 faults >10/s), using max Committed rather than p95 -
                          active thrashing is a peak problem, not a typical-case one -
                          with the same mode-appropriate multiplier as the primary
                          target (shared via Get-SizingTarget, so the two can't drift
                          onto different multipliers). If pressure is active but even
                          that escalation shows no shortfall, flags REVIEW rather than
                          forcing a number the math doesn't support.
      CPU   EffCores    = (p95 Total% / 100) x vCPU
            Reduce      = current vCPU minus ceil( EffCores / 0.65 ) [rounded even]
                          when that's lower than current
            Growth      = ceil( EffCores / 0.65 ) [rounded even] minus current vCPU
                          when that's higher than current. Queue-driven CPU pressure
                          that the total%-based model doesn't catch (e.g. many
                          short-lived threads) is flagged for manual review instead
                          of forcing a fabricated core count.

    Guardrails - any of these suppress the recommendation rather than degrade it:
      - Sample coverage below 60% of the expected window
      - Minimum Available memory under 1GB, or p95 hard faults above 10/sec (also
        the growth-escalation trigger above)
      - p95 max-core above 85% while total is near the single-thread ceiling -
        suppresses BOTH reduction and growth, since more vCPU doesn't help a
        workload that can't spread past one core
      - Role exclusions from RAM sizing (both directions): SQL, Exchange, Veeam
        proxy/repository

    Component input variables (all optional):
              usrUdfBase       Integer  default 60    First UDF index, uses 10 consecutive fields (1-291)
              usrWindowDays    Integer  default 14    Analysis window
              usrInterval      Integer  default 15    Must match the sampler
              usrExportPath    String   default ''    Optional UNC for per-device CSV row
              usrConservative  Boolean  default false Short-window mode: max x1.4, gross only
                                                      Forced on when usrWindowDays < 7

    Version : 1.5  -  17/08/2026  (proper under-provisioning detection: growth-sizing
              recommendation for RAM and vCPU, symmetric with the existing
              reclaim/reduce logic and sharing the same target computation. New UDFs
              Custom67 Growth GB, Custom68 Growth vCPU, Custom69 Growth Verdict -
              usrUdfBase now needs 10 consecutive fields instead of 7)
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$InstallDir = 'C:\ProgramData\Arc\CapacitySampler'
$BufferPath = Join-Path $InstallDir 'samples.csv'
$UdfKey     = 'HKLM:\SOFTWARE\CentraStage'

# ---------------------------------------------------------------------------
# Datto variable mapping
# ---------------------------------------------------------------------------
function Get-DattoInt {
    param([string]$Name, [int]$Default)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $Default
}

$UdfBase    = Get-DattoInt -Name 'usrUdfBase'    -Default 60
$WindowDays = Get-DattoInt -Name 'usrWindowDays' -Default 14
$Interval   = Get-DattoInt -Name 'usrInterval'   -Default 15
$ExportPath = [Environment]::GetEnvironmentVariable('usrExportPath')

# Conservative mode - for windows too short for a meaningful p95.
# Swaps p95 x 1.25 for max x 1.4, requires reclaim to clear half of allocation,
# and drops the CPU headroom target from 65% to 50%. Output is labelled
# PROVISIONAL so a short-window figure cannot be mistaken for a settled one.
$rawCons     = [Environment]::GetEnvironmentVariable('usrConservative')
$Conservative = (-not [string]::IsNullOrWhiteSpace($rawCons)) -and ($rawCons.Trim() -match '^(true|1|yes)$')

# Below this window length, conservative mode is forced regardless of the flag -
# a p95 over a handful of days is not a percentile, it is the maximum with extra
# steps, and presenting it as p95 invites acting on it.
if ($WindowDays -lt 7 -and -not $Conservative) {
    $Conservative = $true
    Write-Output "NOTE: window of $WindowDays days is under 7 - conservative mode forced."
}

# Datto RMM supports UDF 1-300 (registry values Custom1-Custom300). Ten
# consecutive fields are required (seven for reclaim/reduce, three more for
# the growth-sizing fields), so the highest valid base is 291.
# Fail loudly - silently falling back to a default would overwrite whatever
# occupies the default range on every device in the job.
$UdfMax = 300
$UdfCount = 10
if ($UdfBase -lt 1 -or $UdfBase -gt ($UdfMax - $UdfCount + 1)) {
    Write-Output "usrUdfBase of $UdfBase is invalid - must be between 1 and $($UdfMax - $UdfCount + 1) to fit $UdfCount consecutive fields."
    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output 'CapacityStatus=BAD_UDF_BASE'
    Write-Output '<-End Result->'
    exit 1
}
if ($UdfBase -eq 1) {
    Write-Output 'WARNING: UDF 1 is reserved by Datto Ransomware Detection for isolation notices and will be overwritten.'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $idx = [int][math]::Ceiling($P * $sorted.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    [double]$sorted[$idx]
}

function Get-NumericColumn {
    param($Rows, [string]$Column)
    $out = New-Object System.Collections.Generic.List[double]
    foreach ($r in $Rows) {
        $v = $r.$Column
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $d = 0.0
        if ([double]::TryParse($v, [ref]$d)) { $out.Add($d) }
    }
    ,$out.ToArray()
}

function Set-Udf {
    param([int]$Index, [string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 255) { $Value = $Value.Substring(0, 255) }
    if (-not (Test-Path -LiteralPath $UdfKey)) { New-Item -Path $UdfKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $UdfKey -Name "Custom$Index" -Value $Value -Force
}

function Get-Floor2   { param([double]$Value) [int]([math]::Floor($Value / 2) * 2) }
function Get-CeilEven { param([double]$Value) $i = [int][math]::Ceiling($Value); if ($i % 2 -ne 0) { $i++ }; $i }

# Shared by both the primary RAM target and the memory-pressure escalation target
# below, so the two can never drift onto different multipliers - the escalation
# always uses whichever multiplier the current mode (standard/conservative)
# selected, even though it evaluates a different basis (max, not p95/basisGB).
function Get-SizingTarget {
    param([double]$FloorGB, [double]$BasisGB, [double]$Multiplier)
    [math]::Max($FloorGB, [math]::Round($BasisGB * $Multiplier, 2))
}

# ---------------------------------------------------------------------------
# Role detection
# ---------------------------------------------------------------------------
function Get-ServerRole {
    $flags = New-Object System.Collections.Generic.List[string]
    $role  = 'Generic'

    $svc = @{}
    try {
        foreach ($s in (Get-Service -ErrorAction SilentlyContinue)) { $svc[$s.Name] = $true }
    } catch { }

    $hasSvc = {
        param([string]$Pattern)
        foreach ($k in $svc.Keys) { if ($k -like $Pattern) { return $true } }
        return $false
    }

    # Domain controller
    try {
        $dr = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DomainRole
        if ($dr -eq 4 -or $dr -eq 5) { $role = 'DomainController'; $flags.Add('DC') }
    } catch { }

    # Exchange
    if ((& $hasSvc 'MSExchange*')) { $role = 'Exchange'; $flags.Add('EXCH') }

    # SQL Server
    $isSql = ($svc.ContainsKey('MSSQLSERVER')) -or (& $hasSvc 'MSSQL$*')
    if ($isSql) { if ($role -eq 'Generic') { $role = 'SQLServer' }; $flags.Add('SQL') }

    # Veeam proxy / repository - job windows can fall outside a p95 view
    if ((& $hasSvc 'Veeam*')) { $flags.Add('VEEAM'); if ($role -eq 'Generic') { $role = 'BackupInfra' } }

    # RDSH
    $isRdsh = $false
    try {
        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            $f = Get-WindowsFeature -Name RDS-RD-Server -ErrorAction Stop
            if ($f -and $f.Installed) { $isRdsh = $true }
        }
    } catch { }
    if (-not $isRdsh) {
        try {
            $ts = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop
            if ($ts.PSObject.Properties.Name -contains 'TSServerDrainMode') { $isRdsh = $true }
        } catch { }
    }
    if ($isRdsh) { if ($role -eq 'Generic') { $role = 'RDSH' }; $flags.Add('RDSH') }

    # File server
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

# Role floors: minimum sensible allocation, independent of measured demand
$RamFloor  = @{ DomainController = 4; RDSH = 8; FileServer = 8; SQLServer = 8; Exchange = 16; BackupInfra = 8; Generic = 4 }
$vCpuFloor = @{ DomainController = 2; RDSH = 4; FileServer = 2; SQLServer = 4; Exchange = 4;  BackupInfra = 4; Generic = 2 }

# Roles where guest-side committed bytes does not represent requirement
$RamExcludedRoles = @('SQLServer', 'Exchange', 'BackupInfra')

try {
    # =======================================================================
    # Load and window the buffer
    # =======================================================================
    if (-not (Test-Path -LiteralPath $BufferPath)) {
        throw "No buffer at $BufferPath - deploy Component 1 (Deploy-ArcCapacitySampler) first."
    }

    $cutoff  = (Get-Date).AddDays(-$WindowDays)
    $allRows = @(Import-Csv -LiteralPath $BufferPath)
    $rows = @($allRows | Where-Object {
        $ts = [datetime]::MinValue
        [datetime]::TryParse($_.Timestamp, [ref]$ts) -and $ts -ge $cutoff
    })

    $expected  = [int](($WindowDays * 24 * 60) / $Interval)
    $coverage  = if ($expected -gt 0) { [math]::Round(100 * $rows.Count / $expected, 0) } else { 0 }
    $confident = ($coverage -ge 60)

    $roleInfo = Get-ServerRole
    $role     = $roleInfo.Role
    $flags    = $roleInfo.Flags

    $modeText   = if ($Conservative) { ' | CONSERVATIVE' } else { '' }
    $windowText = '{0}d | {1}/{2} samples | {3}% coverage{4}' -f $WindowDays, $rows.Count, $expected, $coverage, $modeText

    if ($rows.Count -eq 0) {
        Set-Udf -Index ($UdfBase + 0) -Value $windowText
        for ($i = 1; $i -le 5; $i++) { Set-Udf -Index ($UdfBase + $i) -Value '' }
        Set-Udf -Index ($UdfBase + 6) -Value ('NO DATA IN WINDOW | ' + (Get-Date -Format 'dd/MM/yyyy HH:mm'))
        for ($i = 7; $i -le 9; $i++) { Set-Udf -Index ($UdfBase + $i) -Value '' }
        Write-Output "No samples inside the $WindowDays day window. Buffer holds $($allRows.Count) row(s) in total."
        Write-Output ''
        Write-Output '<-Start Result->'
        Write-Output 'CapacityStatus=NO_DATA'
        Write-Output '<-End Result->'
        exit 0
    }

    # =======================================================================
    # Memory statistics
    # =======================================================================
    $allocVals  = Get-NumericColumn -Rows $rows -Column 'AllocatedGB'
    $commitVals = Get-NumericColumn -Rows $rows -Column 'CommittedGB'
    $availVals  = Get-NumericColumn -Rows $rows -Column 'AvailableGB'
    $faultVals  = Get-NumericColumn -Rows $rows -Column 'HardFaultsSec'

    $allocatedGB  = if ($allocVals.Count)  { [math]::Round(($allocVals | Measure-Object -Maximum).Maximum, 1) } else { 0 }
    $commitP50    = if ($commitVals.Count) { [math]::Round((Get-Percentile -Values $commitVals -P 0.50), 2) } else { 0 }
    $commitP95    = if ($commitVals.Count) { [math]::Round((Get-Percentile -Values $commitVals -P 0.95), 2) } else { 0 }
    $commitMax    = if ($commitVals.Count) { [math]::Round(($commitVals | Measure-Object -Maximum).Maximum, 2) } else { 0 }
    $availMin     = if ($availVals.Count)  { [math]::Round(($availVals | Measure-Object -Minimum).Minimum, 2) } else { 0 }
    $faultP95     = if ($faultVals.Count)  { [math]::Round((Get-Percentile -Values $faultVals -P 0.95), 1) } else { 0 }

    # =======================================================================
    # CPU statistics
    # =======================================================================
    $vcpuVals    = Get-NumericColumn -Rows $rows -Column 'vCPU'
    $totalVals   = Get-NumericColumn -Rows $rows -Column 'CpuTotalPct'
    $maxCoreVals = Get-NumericColumn -Rows $rows -Column 'CpuMaxCorePct'
    $queueVals   = Get-NumericColumn -Rows $rows -Column 'ProcQueue'

    $vCPU         = if ($vcpuVals.Count)    { [int](($vcpuVals | Measure-Object -Maximum).Maximum) } else { 0 }
    if ($vCPU -lt 1) { $vCPU = 1 }
    $cpuTotalP50  = if ($totalVals.Count)   { [math]::Round((Get-Percentile -Values $totalVals -P 0.50), 1) } else { 0 }
    $cpuTotalP95  = if ($totalVals.Count)   { [math]::Round((Get-Percentile -Values $totalVals -P 0.95), 1) } else { 0 }
    $cpuTotalMax  = if ($totalVals.Count)   { [math]::Round(($totalVals | Measure-Object -Maximum).Maximum, 1) } else { 0 }
    $maxCoreP95   = if ($maxCoreVals.Count) { [math]::Round((Get-Percentile -Values $maxCoreVals -P 0.95), 1) } else { 0 }
    $queueP95     = if ($queueVals.Count)   { [math]::Round((Get-Percentile -Values $queueVals -P 0.95), 1) } else { 0 }
    $queueMax     = if ($queueVals.Count)   { [int](($queueVals | Measure-Object -Maximum).Maximum) } else { 0 }

    $effectiveCores = [math]::Round(($cpuTotalP95 / 100) * $vCPU, 2)

    # =======================================================================
    # SQL supplementary
    # =======================================================================
    $sqlNote = ''
    $sqlTotalVals = Get-NumericColumn -Rows $rows -Column 'SqlTotalGB'
    $pleVals      = Get-NumericColumn -Rows $rows -Column 'SqlPLE'
    if ($sqlTotalVals.Count -gt 0) {
        $sqlTotal = [math]::Round((Get-Percentile -Values $sqlTotalVals -P 0.95), 1)
        $pleMin   = if ($pleVals.Count) { [int](($pleVals | Measure-Object -Minimum).Minimum) } else { -1 }
        $sqlNote  = "SQL buffer pool p95 ${sqlTotal}GB"
        if ($pleMin -ge 0) { $sqlNote += ", min PLE ${pleMin}s" }
    }

    # =======================================================================
    # Pressure guardrails
    # =======================================================================
    $memPressure = ($availMin -lt 1.0) -or ($faultP95 -gt 10)
    if ($memPressure) { $flags.Add('MEM-PRESSURE') }

    # Single-thread bound: one core near saturation while total sits near the
    # ceiling a single thread can produce on this vCPU count.
    $singleThreadCeiling = (100.0 / $vCPU) * 1.30
    $singleThreadBound = ($maxCoreP95 -gt 85) -and ($cpuTotalP95 -lt $singleThreadCeiling)
    if ($singleThreadBound) { $flags.Add('SINGLE-THREAD') }

    $cpuPressure = ($queueP95 -gt (2 * $vCPU)) -or ($cpuTotalP95 -gt 75)
    if ($cpuPressure) { $flags.Add('CPU-PRESSURE') }

    # =======================================================================
    # RAM recommendation - reclaim (over-allocated) or growth (under-provisioned)
    #   Both directions share one target: Target = max(RoleFloor, basis x
    #   multiplier). Where Allocated sits relative to Target decides which way
    #   (or neither) the recommendation goes, so the two directions can never
    #   disagree with each other about what "right-sized" means.
    # =======================================================================
    $ramFloorGB = $RamFloor[$role]
    if (-not $ramFloorGB) { $ramFloorGB = 4 }

    $reclaimGB     = 0
    $growthGB      = 0
    $ramVerdict    = ''
    $growthVerdict = ''
    $tag           = if ($Conservative) { 'PROVISIONAL ' } else { '' }

    if (-not $confident) {
        $ramVerdict    = "INSUFFICIENT DATA - $coverage% coverage"
        $growthVerdict = "INSUFFICIENT DATA - $coverage% coverage"
    }
    elseif ($RamExcludedRoles -contains $role) {
        $ramVerdict = "EXCLUDED ($role) - guest commit reflects configured cap, not demand"
        if ($sqlNote) { $ramVerdict += " | $sqlNote" }
        $growthVerdict = "EXCLUDED ($role) - size from platform-specific metrics, not guest commit"
    }
    else {
        if ($Conservative) {
            # Maximum observed, not p95, with a wider multiplier
            $basisGB    = $commitMax
            $multiplier = 1.4
            $basisLabel = 'max'
        } else {
            $basisGB    = $commitP95
            $multiplier = 1.25
            $basisLabel = 'p95'
        }

        $targetGB = Get-SizingTarget -FloorGB $ramFloorGB -BasisGB $basisGB -Multiplier $multiplier
        $raw      = $allocatedGB - $targetGB   # positive => reclaim headroom; negative => short of target

        # --- Reclaim side ---------------------------------------------------
        if ($memPressure) {
            $ramVerdict = "NO RECLAIM - memory pressure (min avail ${availMin}GB, p95 faults ${faultP95}/s)"
            if ($raw -lt 0) { $ramVerdict += ' - see growth verdict' }
        }
        elseif ($raw -gt 0) {
            $reclaimGB = Get-Floor2 -Value $raw

            # Conservative mode only acts on gross over-allocation. 40% rather
            # than 50%: the 1.4x multiplier is already doing conservative work,
            # and at 50% a 32GB VM with 12GB peak demand - the most obvious
            # candidate there is - falls just outside and gets deferred for no
            # good reason.
            $minReclaim = if ($Conservative) { [math]::Max(8, $allocatedGB * 0.4) } else { 4 }

            if ($reclaimGB -lt $minReclaim) {
                $shortfall = $reclaimGB
                $reclaimGB = 0
                if ($Conservative) {
                    $ramVerdict = "${tag}NO CHANGE - ${shortfall}GB is not gross over-allocation, defer to full window"
                } else {
                    $ramVerdict = 'NO CHANGE - under 4GB reclaim, not worth a change window'
                }
            } else {
                $newAlloc   = [int]($allocatedGB - $reclaimGB)
                $ramVerdict = "${tag}RECLAIM ${reclaimGB}GB -> ${newAlloc}GB (${basisLabel} ${basisGB}GB x${multiplier})"
            }
        }
        elseif ($raw -lt 0) {
            $ramVerdict = 'NO CHANGE - below sized target, see growth verdict'
        }
        else {
            $ramVerdict = 'NO CHANGE - already at sized target'
        }

        # --- Growth side ------------------------------------------------------
        # Standard trigger: demand plus headroom already exceeds allocation.
        if ($raw -lt 0) {
            $growthGB = Get-CeilEven -Value (-$raw)
        }

        # Pressure escalation: active symptoms (available memory near zero,
        # real hard faults) are a more direct signal than a percentile crossing
        # a threshold, and can fire even when the trigger above doesn't - a
        # host can be thrashing on short spikes that a 14-day p95 smooths over.
        # Uses max, not p95, since the concern here is the peak that's actually
        # causing the pain, not the typical case - but the SAME mode-appropriate
        # multiplier as the primary target, via the shared helper, so this can't
        # silently end up narrower than standard mode's own margin.
        if ($memPressure) {
            $pressureTarget = Get-SizingTarget -FloorGB $ramFloorGB -BasisGB $commitMax -Multiplier $multiplier
            $pressureRaw    = $allocatedGB - $pressureTarget
            $pressureGrowth = if ($pressureRaw -lt 0) { Get-CeilEven -Value (-$pressureRaw) } else { 0 }
            if ($pressureGrowth -gt $growthGB) { $growthGB = $pressureGrowth }
        }

        if ($growthGB -gt 0) {
            $newAllocGrow = [int]($allocatedGB + $growthGB)
            if ($memPressure) {
                # Real pressure symptoms are present right now regardless of
                # which trigger (percentile or pressure-escalation) produced
                # the winning number - label URGENT either way.
                $growthVerdict = "${tag}URGENT +${growthGB}GB -> ${newAllocGrow}GB (active memory pressure: min avail ${availMin}GB, p95 faults ${faultP95}/s)"
            } else {
                $growthVerdict = "${tag}GROWTH +${growthGB}GB -> ${newAllocGrow}GB (${basisLabel} ${basisGB}GB x${multiplier}, target ${targetGB}GB)"
            }
            $flags.Add('GROWTH')
        }
        elseif ($memPressure) {
            # Active pressure symptoms, but even the max-based target doesn't
            # show a shortfall - the pressure likely has some other cause (a
            # leaking process, a transient spike) rather than insufficient
            # allocation. Flag for a look rather than fabricate a number the
            # math doesn't actually support - same pattern as CPU's queue-driven
            # REVIEW case below.
            $growthVerdict = "REVIEW - memory pressure (min avail ${availMin}GB, p95 faults ${faultP95}/s) without a matching allocation shortfall - investigate before resizing"
            $flags.Add('MEM-REVIEW')
        } else {
            $growthVerdict = 'NO CHANGE - demand within allocation'
        }
    }

    # =======================================================================
    # vCPU recommendation - reduction (over-provisioned) or growth (under-provisioned)
    # =======================================================================
    $cpuFloor = $vCpuFloor[$role]
    if (-not $cpuFloor) { $cpuFloor = 2 }

    $recVcpu          = $vCPU
    $vcpuGrowth       = 0
    $cpuVerdict       = ''
    $cpuGrowthVerdict = ''

    if (-not $confident) {
        $cpuVerdict       = "INSUFFICIENT DATA - $coverage% coverage"
        $cpuGrowthVerdict = "INSUFFICIENT DATA - $coverage% coverage"
    }
    elseif ($singleThreadBound) {
        $cpuVerdict = "NO CHANGE - single-thread bound (p95 max-core ${maxCoreP95}%)"
        # More vCPU doesn't help a workload that can't spread past one core -
        # deliberately not offered as growth even if queue depth is also high;
        # the fix here is workload-side, not allocation-side.
        $cpuGrowthVerdict = 'NO CHANGE - single-thread bound, more vCPU would not help'
    }
    else {
        if ($Conservative) {
            # Max observed utilisation, and only halve or better
            $cpuBasis    = [math]::Round(($cpuTotalMax / 100) * $vCPU, 2)
            $headroom    = 0.50
            $basisLabel  = 'max'
        } else {
            $cpuBasis    = $effectiveCores
            $headroom    = 0.65
            $basisLabel  = 'p95'
        }

        $sized = Get-CeilEven -Value ($cpuBasis / $headroom)

        # --- Reduction side --------------------------------------------------
        if ($cpuPressure) {
            $cpuVerdict = "NO REDUCTION - CPU pressure (p95 ${cpuTotalP95}%, p95 queue ${queueP95})"
            if ($sized -gt $vCPU) { $cpuVerdict += ' - see growth verdict' }
        }
        elseif ($sized -lt $vCPU) {
            $recVcpu = [math]::Max($cpuFloor, $sized)
            if ($Conservative -and $recVcpu -gt ($vCPU * 0.5)) {
                $recVcpu    = $vCPU
                $cpuVerdict = "${tag}NO CHANGE - reduction under half, defer to full window"
            } else {
                $cpuVerdict = "${tag}REDUCE to $recVcpu vCPU (${basisLabel} demand ${cpuBasis} cores at $([int]($headroom*100))% target)"
            }
        }
        elseif ($sized -gt $vCPU) {
            $cpuVerdict = 'NO CHANGE - below sized requirement, see growth verdict'
        }
        else {
            $cpuVerdict = 'NO CHANGE - vCPU already at sized requirement'
        }

        # --- Growth side -------------------------------------------------------
        if ($sized -gt $vCPU) {
            $vcpuGrowth       = $sized - $vCPU
            $cpuGrowthVerdict = "${tag}GROWTH +$vcpuGrowth vCPU -> $sized vCPU (${basisLabel} demand ${cpuBasis} cores at $([int]($headroom*100))% target)"
            $flags.Add('CPU-GROWTH')
        }
        # Queue-driven pressure can appear without the total%-based sizing model
        # catching it (e.g. many short-lived threads contending briefly). Flag
        # it for manual review rather than fabricate a core count queue depth
        # alone doesn't cleanly map to. Still adds CPU-GROWTH so a worklist
        # built on the flag (not just "Growth vCPU not equal 00") catches this
        # host too - Custom68 has no number to filter on here.
        elseif ($cpuPressure -and $queueP95 -gt (2 * $vCPU)) {
            $cpuGrowthVerdict = "REVIEW - queue pressure (p95 queue ${queueP95}) not reflected in total utilisation; sizing model may understate demand"
            $flags.Add('CPU-GROWTH')
        }
        else {
            $cpuGrowthVerdict = 'NO CHANGE - demand within current vCPU'
        }
    }

    # A device should never be shown as both a reclaim and a growth candidate
    # for the same metric - today's branch structure happens to guarantee that,
    # but that guarantee is a consequence of how the branches are written, not
    # something structurally enforced. Assert it explicitly rather than trust
    # it silently holds if this logic is ever touched again: growth wins, since
    # this tool treats a missed growth candidate as the worse failure mode.
    if ($reclaimGB -gt 0 -and $growthGB -gt 0) {
        $reclaimGB = 0
        $ramVerdict = 'NO CHANGE - reclaim/growth conflict resolved in favour of growth, see growth verdict'
    }
    if ($recVcpu -lt $vCPU -and $vcpuGrowth -gt 0) {
        $recVcpu = $vCPU
        $cpuVerdict = 'NO CHANGE - reduce/growth conflict resolved in favour of growth, see growth verdict'
    }

    # =======================================================================
    # UDF write-back
    # =======================================================================
    $ramDetail = 'Alloc {0}GB | Commit p50 {1} p95 {2} max {3}GB | MinAvail {4}GB | Faults p95 {5}/s' -f `
                 $allocatedGB, $commitP50, $commitP95, $commitMax, $availMin, $faultP95

    $cpuDetail = '{0} vCPU | Total p50 {1}% p95 {2}% max {3}% | MaxCore p95 {4}% | Queue p95 {5} max {6}' -f `
                 $vCPU, $cpuTotalP50, $cpuTotalP95, $cpuTotalMax, $maxCoreP95, $queueP95, $queueMax

    $flagText = if ($flags.Count) { "$role | " + ($flags -join ',') } else { $role }
    $summary  = 'RAM: {0} || CPU: {1} || {2}' -f $ramVerdict, $cpuVerdict, (Get-Date -Format 'dd/MM/yyyy HH:mm')

    Set-Udf -Index ($UdfBase + 0) -Value $windowText
    Set-Udf -Index ($UdfBase + 1) -Value $ramDetail
    Set-Udf -Index ($UdfBase + 2) -Value ('{0:D3}' -f $reclaimGB)   # zero-padded: Datto sorts UDFs as strings
    Set-Udf -Index ($UdfBase + 3) -Value $cpuDetail
    Set-Udf -Index ($UdfBase + 4) -Value ('{0:D2}' -f $recVcpu)     # zero-padded, same reason
    Set-Udf -Index ($UdfBase + 5) -Value $flagText
    Set-Udf -Index ($UdfBase + 6) -Value $summary
    Set-Udf -Index ($UdfBase + 7) -Value ('{0:D3}' -f $growthGB)    # zero-padded, same reason
    Set-Udf -Index ($UdfBase + 8) -Value ('{0:D2}' -f $vcpuGrowth)  # zero-padded, same reason
    Set-Udf -Index ($UdfBase + 9) -Value ('RAM: {0} || CPU: {1} || {2}' -f $growthVerdict, $cpuGrowthVerdict, (Get-Date -Format 'dd/MM/yyyy HH:mm'))

    # =======================================================================
    # Optional per-device CSV row for estate-wide aggregation
    #   Bypasses the Devices grid export. Runs as SYSTEM, so the share must
    #   grant write to the computer account (or Domain Computers).
    # =======================================================================
    if (-not [string]::IsNullOrWhiteSpace($ExportPath)) {
        try {
            if (-not (Test-Path -LiteralPath $ExportPath)) {
                New-Item -Path $ExportPath -ItemType Directory -Force | Out-Null
            }
            $rowFile = Join-Path $ExportPath ("{0}.csv" -f $env:COMPUTERNAME)
            [PSCustomObject][ordered]@{
                Hostname        = $env:COMPUTERNAME
                Reported        = (Get-Date -Format 'dd/MM/yyyy HH:mm')
                Role            = $role
                Flags           = ($flags -join ',')
                Mode            = $(if ($Conservative) { 'Conservative' } else { 'Standard' })
                Samples         = $rows.Count
                CoveragePct     = $coverage
                AllocatedGB     = $allocatedGB
                CommitP50GB     = $commitP50
                CommitP95GB     = $commitP95
                CommitMaxGB     = $commitMax
                MinAvailGB      = $availMin
                HardFaultsP95   = $faultP95
                ReclaimGB       = $reclaimGB
                RamVerdict      = $ramVerdict
                GrowthGB        = $growthGB
                GrowthVerdict   = $growthVerdict
                vCPU            = $vCPU
                CpuTotalP50Pct  = $cpuTotalP50
                CpuTotalP95Pct  = $cpuTotalP95
                CpuMaxCoreP95   = $maxCoreP95
                QueueP95        = $queueP95
                EffectiveCores  = $effectiveCores
                RecommendedVcpu = $recVcpu
                CpuVerdict      = $cpuVerdict
                VcpuGrowth      = $vcpuGrowth
                CpuGrowthVerdict = $cpuGrowthVerdict
                SqlNote         = $sqlNote
            } | Export-Csv -LiteralPath $rowFile -NoTypeInformation -Encoding UTF8 -Force
            Write-Output "Exported device row to $rowFile"
        } catch {
            Write-Output "CSV export skipped: $($_.Exception.Message)"
        }
    }

    # =======================================================================
    # Console output for the Datto activity log
    # =======================================================================
    Write-Output "=== Arc Capacity Analysis - $env:COMPUTERNAME ==="
    Write-Output "Role            : $flagText"
    Write-Output "Window          : $windowText"
    Write-Output "Mode            : $(if ($Conservative) { 'CONSERVATIVE - max x1.4, gross over-allocation only, PROVISIONAL output' } else { 'Standard - p95 x1.25' })"
    Write-Output ''
    Write-Output "Memory          : $ramDetail"
    Write-Output "Memory verdict  : $ramVerdict"
    Write-Output "Memory growth   : $growthVerdict"
    if ($sqlNote) { Write-Output "SQL             : $sqlNote" }
    Write-Output ''
    Write-Output "CPU             : $cpuDetail"
    Write-Output "Effective cores : $effectiveCores of $vCPU allocated"
    Write-Output "CPU verdict     : $cpuVerdict"
    Write-Output "CPU growth      : $cpuGrowthVerdict"
    Write-Output ''
    Write-Output "UDFs written    : Custom$UdfBase - Custom$($UdfBase + 9)"

    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output ('CapacityStatus=' + $(if ($confident) { 'OK' } else { 'LOW_COVERAGE' }))
    Write-Output "ReclaimGB=$reclaimGB"
    Write-Output "RecommendedVcpu=$recVcpu"
    Write-Output "CurrentVcpu=$vCPU"
    Write-Output "GrowthGB=$growthGB"
    Write-Output "VcpuGrowth=$vcpuGrowth"
    Write-Output ('Mode=' + $(if ($Conservative) { 'Conservative' } else { 'Standard' }))
    Write-Output '<-End Result->'

    exit 0
}
catch {
    Write-Output "ANALYSIS FAILED: $($_.Exception.Message)"
    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output 'CapacityStatus=FAILED'
    Write-Output "CapacityError=$($_.Exception.Message)"
    Write-Output '<-End Result->'
    exit 1
}
