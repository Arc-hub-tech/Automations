<#
    Read-ArcCapacityBuffer.ps1
    Datto capacity sampling toolset

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
      RAM   RoleFloor   = flat per-role minimum, except DomainController: raised to
                          ceil(DIT size x 1.15 + 2GB) where the DIT path can be read
                          from the registry, since ESE dynamically caches the DIT
                          against available memory on any currently supported
                          Windows Server version - no manual tuning needed, but a
                          large-DIT DC genuinely needs more RAM to benefit from that.
                          Never LOWERS the floor. If the DIT path can't be resolved,
                          the RAM verdict and growth verdict are both suppressed to
                          REVIEW/DIT-UNKNOWN rather than silently computed against the
                          flat floor this exists because it's wrong for a large DIT.
                          If the DIT-raised floor alone would trigger growth but actual
                          measured demand (the same target using the flat floor)
                          doesn't corroborate it, that also downgrades to REVIEW/
                          DIT-REVIEW instead of asserting a number - a DIT can be large
                          from tombstone/whitespace bloat with no live-memory
                          equivalent. Active memory pressure is independent, stronger
                          evidence and still fires URGENT regardless of this check.
            Target      = max( RoleFloor , p95 Committed x 1.25 )
            Reclaim     = Allocated - Target when positive, floored to a 2GB
                          increment, suppressed below 4GB (not worth a change window)
            Growth      = Target - Allocated when positive, ceilinged to a 2GB
                          increment. Escalates whenever the memory-pressure guardrail
                          is active (min available <1GB, or p95 faults >10/s while min
                          available <20% of RAM) to max( Target, peak Committed ): the
                          worst moment always fits in RAM, without adding the
                          multiplier on top of a figure that's already the peak. If
                          pressure is active but even that shows no shortfall, flags
                          REVIEW rather than forcing a number the math doesn't support.
      CPU   EffCores    = (p95 Total% / 100) x vCPU
            Reduce      = current vCPU minus max( RoleFloor, ceil( EffCores / 0.65 )
                          [rounded even] ) when that's lower than current. Held
                          while MEM-PRESSURE is active - CPU measured on a host
                          stalled on paging understates its real demand
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
      - Memory pressure also holds vCPU reduction (not growth)
      - SQL Server hosts are never sized, but are checked for attention signals
        (flags SQL-CAP, SQL-MEM, SQL-EXPRESS-CAP) reported in the growth verdict
      - Role exclusions from RAM sizing (both directions): SQL Server and
        MySQL/MariaDB where the engine holds >=2GB and >=25% of allocation
        (else SQL-MINOR / MYSQL-MINOR, sized normally), Exchange, and Veeam
        data-mover/control services (agent/installer only = VEEAM-MINOR).
        Under memory pressure every excluded role still reads URGENT, unsized
      - Hyper-V hosts (vmms): no RAM or vCPU sizing at all, overriding every
        other role; memory pressure still reads URGENT

    Component input variables (all optional):
              usrUdfBase       Integer  default 60    First UDF index, uses 10 consecutive fields (1-291)
              usrWindowDays    Integer  default 14    Analysis window
              usrInterval      Integer  default 15    Must match the sampler
              usrExportPath    String   default ''    Optional UNC for per-device CSV row
              usrConservative  Boolean  default false Short-window mode: max x1.4, gross only
                                                      Forced on when usrWindowDays < 7

    Version : 1.16 -  09/10/2026  (URGENT growth sized to max(p95 x1.25, peak commit)
              rather than peak x1.25 - the peak always fits, without 25% added on top of
              the worst moment. On a 224-host URGENT run: 1,532GB -> 1,016GB, session hosts
              850 -> 486GB, short-all-the-time hosts barely moved (392 -> 350GB), and 20 of
              25 dip-only hosts fall to MEM-REVIEW instead of a growth figure)

    Version : 1.15 -  09/10/2026  (hard faults alone no longer trigger MEM-PRESSURE: they
              count only while min available is under 20% of RAM. Memory\Pages Input/sec
              also counts memory-mapped FILE reads, so file and web servers fault constantly
              with memory to spare - on a 507-device run, 105 of 140 fault-only pressure
              hosts never dropped below 20% free and carried 244GB of growth advice. Those
              hosts are flagged FAULTS-IO and hold reclaim too, since cutting RAM would
              shrink the file cache serving those reads. The < 1GB trigger is unchanged)

    Version : 1.14 -  09/10/2026  (MySQL buffer pool sanity check: a configured pool can't
              explain mysqld holding more than pool x1.5 + 4GB, so past that the figure is
              reported unresolved - "config reads XGB but mysqld holds YGB - effective config
              not found" - instead of asserted. The first real material-MySQL host read the
              128M default while mysqld held 52.84GB, which under pressure would have produced
              a confident wrong "buffer pool isn't the cause". Root cause fixed too: a server
              running as a Windows service also reads the option group named after its
              service - WAMP's [wampmysqld64] held the 48G setting the parser skipped)

    Version : 1.13 -  09/10/2026  (SQL hosts under memory pressure get a cap-or-RAM
              decision instead of "URGENT, unsized": per-sample commit minus the sampled
              instance's Total Server Memory measures everything else over 14 days, so
              "cap <instance> at N GB" or "RAM short ... -> grow to N GB, then cap at M GB"
              (which fills Growth GB) can be stated from evidence. Names the sampled
              instance from the sampler's counter cache. From the first real two-instance
              pilot host, where the answer was RAM, not caps. Withheld where commit falls
              below SQL's own memory (locked pages). Also fixes [math]::Max(0, x) and
              similar binding PowerShell's integer overload and rounding decimals away -
              in the half-reserve bars and the conservative-mode reclaim minimum)

    Version : 1.12 -  09/10/2026  (multi-instance SQL hosts: the combined live footprint
              of every running sqlservr is compared with the allocation - "2 instances
              hold XGB of YGB - combined caps too high" (SQL-CAP) - since the counters
              cover only one instance and per-instance caps can each look fine. The squeeze
              finding names "another SQL instance" first on those hosts. Live footprint is
              now the larger of private bytes and working set per process. From the first
              real two-instance pilot host)

    Version : 1.11 -  09/10/2026  (role detection aligned with the Screen. SQL excluded
              only when material - >=2GB and >=25% of allocation, footprint the larger of
              sampled p95 Total Server Memory and live sqlservr working set - otherwise
              SQL-MINOR and sized, with SQL findings still appended. Veeam excluded only for
              data-mover/control services, else VEEAM-MINOR. Hyper-V hosts (vmms) get no
              sizing and no CPU flags, overriding every other role. Exchange, Veeam infra
              and Hyper-V hosts under memory pressure read URGENT instead of EXCLUDED)

    Version : 1.10 -  09/10/2026  (SQL Server attention signals from counters already
              sampled plus the registry - no sampler change, no login: SQL-CAP (max server
              memory unset or leaving the OS too little), SQL-MEM (low PLE with the pool at
              target, or Target squeezed below its peak), SQL-EXPRESS-CAP (Express database
              near the 10GB limit, or memory-bound at Express's pool cap). PLE now judged as
              p05 against 300s per 4GB of pool rather than a raw minimum. A SQL host under
              memory pressure reads URGENT naming the likeliest cause, instead of EXCLUDED.
              Verdict UDFs trim the RAM text rather than losing the CPU verdict and timestamp)

    Version : 1.9  -  09/10/2026  (MySQL/MariaDB role: detected by service binary,
              material at >=2GB and >=25% of allocation, floors 8GB/4 vCPU, RAM sized
              from neither direction of commit since InnoDB commits its buffer pool up
              front - under memory pressure it still reads URGENT, citing the configured
              buffer pool instead of a GB figure. vCPU reduction held under MEM-PRESSURE.
              Role floor now applied before deciding a reduction exists - it could
              previously emit "REDUCE to 4 vCPU" on a 4 vCPU host)

    Version : 1.8  -  18/08/2026  (domain controller RAM floor is now a function of
              actual DIT size where it can be read from the registry, rather than a
              flat 4GB - closes the open item from Known limitations. DIT-UNKNOWN
              suppresses the recommendation entirely rather than falling back to the
              flat floor and computing anyway; a DIT-driven-only growth trigger with
              no corroborating measured demand downgrades to DIT-REVIEW instead of
              asserting a number - both caught by a pre-commit review pass before
              this ran on a real device. CSV export gains DitSizeGB/RamFloorGB
              columns. Previous: 1.6 removed the internal team byline; 1.5 added
              under-provisioning detection - growth-sizing recommendation for RAM and
              vCPU, symmetric with reclaim/reduce and sharing the same target
              computation, with new UDFs Custom67-69)
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

# 'RAM: x || CPU: y || timestamp' for the two verdict UDFs. Set-Udf's plain
# 255-character cut takes from the end, which loses the CPU verdict and the
# timestamp first - the timestamp being how a stale UDF is spotted. Trim the
# RAM text instead, so the CPU half and the timestamp always survive.
function Format-VerdictUdf {
    param([string]$Ram, [string]$Cpu)
    $tail = ' || CPU: {0} || {1}' -f $Cpu, (Get-Date -Format 'dd/MM/yyyy HH:mm')
    $head = 'RAM: ' + $Ram
    $room = 255 - $tail.Length
    if ($head.Length -gt $room -and $room -gt 20) { $head = $head.Substring(0, $room - 3) + '...' }
    $head + $tail
}

# Whole findings joined with '; ', most actionable first, as many as fit the
# budget - always at least one - then a pointer to the flags for the rest
# (every finding sets one). Cutting mid-finding would leave a half-sentence
# that reads as a different instruction.
function Format-Findings {
    param([string[]]$Findings, [int]$Budget)
    $shown = New-Object System.Collections.Generic.List[string]
    foreach ($f in $Findings) {
        if (((@($shown) + $f) -join '; ').Length -gt $Budget -and $shown.Count -gt 0) { break }
        $shown.Add($f)
    }
    $body = $shown -join '; '
    if ($shown.Count -lt @($Findings).Count) { $body += " (+$(@($Findings).Count - $shown.Count), see flags)" }
    $body
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

# Domain controllers: the flat RoleFloor below is wrong for a DC with a large
# DIT - ESE dynamically sizes its database cache against available memory, up
# to the DIT's own size, with no registry tuning required on any currently
# supported Windows Server version. A DC with a large DIT genuinely benefits
# from more RAM to cache it, so a flat floor risks recommending a reclaim into
# that legitimate demand. Reads the actual configured DIT path from the
# registry rather than assuming the default %SystemRoot%\NTDS\ntds.dit
# location, since it's commonly relocated to its own volume. Returns $null
# (never a guessed default) on any failure, so the caller falls back to the
# flat RoleFloor explicitly rather than silently sizing against a wrong number.
function Get-DcDitSizeGB {
    try {
        $ntdsParams = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -ErrorAction Stop
        $ditPath = $ntdsParams.'DSA Database File'
        if ([string]::IsNullOrWhiteSpace($ditPath) -or -not (Test-Path -LiteralPath $ditPath)) { return $null }
        [math]::Round((Get-Item -LiteralPath $ditPath).Length / 1GB, 2)
    } catch {
        $null
    }
}

# --- SQL Server helpers ------------------------------------------------------
# Installed instances from the registry: edition, and the largest user-database
# data file in each instance's default data directory. Read through the 64-bit
# registry view explicitly - from a 32-bit host process, plain HKLM:\SOFTWARE
# is redirected to WOW6432Node and shows no 64-bit instances at all. Never
# throws; an instance whose details can't be read is still listed, with blanks.
# The data-file size is a heuristic: databases kept outside the default data
# directory, or split across .ndf files, aren't seen.
function Get-SqlInstanceInfo {
    # Emits one object per instance (nothing at all when there are none) -
    # callers wrap the call in @() to get a countable array.
    $seen = @{}
    $root = 'SOFTWARE\Microsoft\Microsoft SQL Server'
    foreach ($view in [Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32) {
        $base = $null
        try {
            $base  = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $names = $base.OpenSubKey("$root\Instance Names\SQL")
            if (-not $names) { continue }
            foreach ($name in $names.GetValueNames()) {
                if ($seen.ContainsKey($name)) { continue }
                $seen[$name] = $true
                $id        = [string]$names.GetValue($name)
                $edition   = ''
                $largestGB = $null
                try {
                    $setup = $base.OpenSubKey("$root\$id\Setup")
                    if ($setup) { $edition = [string]$setup.GetValue('Edition') }
                    $srv     = $base.OpenSubKey("$root\$id\MSSQLServer")
                    $dataDir = if ($srv) { [string]$srv.GetValue('DefaultData') } else { '' }
                    if (-not $dataDir -and $setup) {
                        $dataRoot = [string]$setup.GetValue('SQLDataRoot')
                        if ($dataRoot) { $dataDir = Join-Path $dataRoot 'DATA' }
                    }
                    if ($dataDir -and (Test-Path -LiteralPath $dataDir)) {
                        $mdf = Get-ChildItem -LiteralPath $dataDir -Filter '*.mdf' -File -ErrorAction SilentlyContinue |
                               Where-Object { $_.BaseName -notmatch '^(master|model|msdb|tempdb|mssqlsystemresource)' } |
                               Sort-Object Length -Descending | Select-Object -First 1
                        if ($mdf) { $largestGB = [math]::Round($mdf.Length / 1GB, 2) }
                    }
                } catch { }
                [PSCustomObject]@{
                    Name         = $name
                    Edition      = $edition
                    IsExpress    = ($edition -match 'Express')
                    LargestMdfGB = $largestGB
                }
            }
        } catch {
        } finally {
            if ($base) { $base.Dispose() }
        }
    }
}

# Which instance the sampler's SQL counters describe, from the counter set it
# cached (sqlcounters.json beside the buffer): 'SQLServer:Memory Manager' is
# the default instance, 'MSSQL$NAME:Memory Manager' a named one. So cap advice
# can name the instance it applies to. $null if the cache can't be read.
function Get-SampledSqlInstance {
    try {
        $cache = Get-Content -LiteralPath (Join-Path $InstallDir 'sqlcounters.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        $set   = [string]$cache.MemorySet
        if ($set -match '^MSSQL\$(.+?):') { return $Matches[1] }
        if ($set -match '^SQLServer:')     { return 'MSSQLSERVER' }
    } catch { }
    $null
}

# Memory to leave the OS when capping SQL Server: 1GB, plus 1GB per 4GB up to
# 16GB, plus 1GB per 8GB above that (Jonathan Kehayias's widely used guidance -
# a 32GB host reserves 7GB, so max server memory 25GB).
function Get-SqlOsReserveGB {
    param([double]$AllocatedGB)
    $r = 1 + ([math]::Min($AllocatedGB, 16) / 4)
    if ($AllocatedGB -gt 16) { $r += ($AllocatedGB - 16) / 8 }
    [int][math]::Ceiling($r)
}

# --- MySQL / MariaDB helpers -------------------------------------------------
# Kept identical in Get-ArcCapacityScreen.ps1 - change both together.
#
# InnoDB commits its whole buffer pool up front on Windows, so on a MySQL host
# guest committed bytes tracks the configured innodb_buffer_pool_size, not the
# requirement - the same distortion that excludes SQL Server, but read from an
# option file rather than a perf counter (MySQL publishes none). Read-only and
# credential-free: the configured value is what matters here, and nothing in
# this public repo may carry a database login.
function ConvertFrom-MySqlSize {
    param([string]$Value)
    if ($Value -match '^(\d+(?:\.\d+)?)\s*([KMGT]?)B?$') {
        $mult = switch ($Matches[2].ToUpper()) { 'K' { 1KB } 'M' { 1MB } 'G' { 1GB } 'T' { 1TB } default { 1 } }
        return [math]::Round(([double]$Matches[1] * $mult) / 1GB, 2)
    }
    $null
}

# Server-section options from one option file, keys normalised the way mysqld
# reads them (dash and underscore interchangeable, 'loose-' prefix ignored).
# A server running as a Windows service also reads the group named after the
# service (MySQL docs: "the group that has the same name as the service") -
# WAMP installs it as wampmysqld64 and puts its settings there, so a parser
# reading only [mysqld] took the 128M default for a 48G pool on the first real
# material-MySQL host. $ServiceGroups carries those names.
# !include / !includedir are not followed - a value set only in an included
# file reads as the built-in default, which errs toward "buffer pool smaller
# than it is" and so never inflates a recommendation.
function Read-MySqlOptionFile {
    param([string]$Path, [string[]]$ServiceGroups = @())
    $opts = @{}
    $inServer = $false
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $section  = $Matches[1].Trim()
            $inServer = ($section -match '^(mysqld|server|mariadb|mariadbd)(-[\d.]+)?$') -or ($ServiceGroups -contains $section)
            continue
        }
        if (-not $inServer) { continue }
        if ($t -match '^([A-Za-z0-9_-]+)\s*(?:=\s*(.*))?$') {
            $key = $Matches[1].ToLower().Replace('-', '_') -replace '^loose_', ''
            $val = if ($null -ne $Matches[2]) { ($Matches[2] -replace '\s+#.*$', '').Trim().Trim('"', "'") } else { 'ON' }
            $opts[$key] = $val
        }
    }
    $opts
}

# Configured innodb_buffer_pool_size for one service, from the same files
# mysqld itself would read: --defaults-file if the service command line names
# one, otherwise the standard Windows search order (later files override).
# A MySQL 8 'SET PERSIST' in <datadir>\mysqld-auto.cnf overrides both. Returns
# GB = $null with a Source explaining why whenever the value can't be trusted -
# never a guess.
function Get-InnoDbBufferPool {
    param([string]$PathName, [string]$ServiceName = '')
    try {
        $exe = if ($PathName -match '^\s*"([^"]+)"') { $Matches[1] } elseif ($PathName -match '^\s*(\S+)') { $Matches[1] } else { '' }
        # The service's own option group: the name mysqld was started with
        # (the trailing argument on its command line) and the Windows service
        # name - normally the same, both taken in case they differ.
        $lastArg = (($PathName.Trim() -split '\s+')[-1]).Trim('"')
        $groups  = @($ServiceName, $(if ($lastArg -notlike '--*' -and $lastArg -notlike '*.exe') { $lastArg })) |
                   Where-Object { $_ } | Select-Object -Unique
        $baseDir = if ($exe) { Split-Path -Path (Split-Path -Path $exe -Parent) -Parent } else { '' }

        $files = @()
        if ($PathName -match '--defaults-file=\s*"?([^"]+?\.(?:ini|cnf))') {
            $files = @($Matches[1])
        } elseif ($PathName -match '--defaults-file') {
            # Named but not in a shape parsed above - mysqld then reads ONLY that
            # file, so falling back to the search order would read the wrong ones
            return [PSCustomObject]@{ GB = $null; Source = 'defaults-file not parsed' }
        } else {
            $files = @("$env:WINDIR\my.ini", "$env:WINDIR\my.cnf", 'C:\my.ini', 'C:\my.cnf')
            if ($baseDir) { $files += @("$baseDir\my.ini", "$baseDir\my.cnf") }
        }

        $opts = @{}
        $read = @()
        foreach ($f in $files) {
            if (Test-Path -LiteralPath $f) {
                $o = Read-MySqlOptionFile -Path $f -ServiceGroups $groups
                foreach ($k in $o.Keys) { $opts[$k] = $o[$k] }
                $read += (Split-Path -Path $f -Leaf)
            }
        }
        if ($read.Count -eq 0) { return [PSCustomObject]@{ GB = $null; Source = 'no option file found' } }

        $dataDir = if ($opts.ContainsKey('datadir')) { $opts['datadir'] } elseif ($baseDir) { "$baseDir\data" } else { '' }
        if ($dataDir) {
            $auto = Join-Path $dataDir 'mysqld-auto.cnf'
            if (Test-Path -LiteralPath $auto) {
                $persisted = Get-Content -LiteralPath $auto -Raw | ConvertFrom-Json
                $p = $persisted.mysql_server.innodb_buffer_pool_size
                if ($p -and $null -ne $p.Value) {
                    $gb = ConvertFrom-MySqlSize -Value ([string]$p.Value)
                    if ($null -ne $gb) { return [PSCustomObject]@{ GB = $gb; Source = 'mysqld-auto.cnf' } }
                }
            }
        }

        if ($opts.ContainsKey('innodb_buffer_pool_size')) {
            $gb = ConvertFrom-MySqlSize -Value $opts['innodb_buffer_pool_size']
            if ($null -eq $gb) { return [PSCustomObject]@{ GB = $null; Source = 'unparseable' } }
            return [PSCustomObject]@{ GB = $gb; Source = ($read -join '+') }
        }
        # innodb_dedicated_server sizes the pool from RAM at startup, by a rule
        # that differs between MySQL releases - report it rather than guess.
        if ($opts.ContainsKey('innodb_dedicated_server') -and $opts['innodb_dedicated_server'] -match '^(ON|1|TRUE)$') {
            return [PSCustomObject]@{ GB = $null; Source = 'innodb_dedicated_server' }
        }
        [PSCustomObject]@{ GB = (ConvertFrom-MySqlSize -Value '128M'); Source = 'default 128M' }
    } catch {
        [PSCustomObject]@{ GB = $null; Source = 'unreadable' }
    }
}

# Detected by the service BINARY, not the service name - names vary (MySQL,
# MySQL80, MariaDB, wampmysqld64...) where the binary doesn't. Returns $null
# when no MySQL/MariaDB service exists. PrivateGB is mysqld's private bytes:
# its share of the commit figure, which is exactly the thing in question.
function Get-MySqlInfo {
    $svcs = @()
    try {
        $svcs = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop `
                  -Filter "PathName LIKE '%mysqld%' OR PathName LIKE '%mariadbd%'")
    } catch { }
    if ($svcs.Count -eq 0) { return $null }

    $privateGB = 0.0
    try {
        $procs = @(Get-Process -Name 'mysqld', 'mariadbd' -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $privateGB = [math]::Round((($procs | Measure-Object -Property PrivateMemorySize64 -Sum).Sum) / 1GB, 2)
        }
    } catch { }

    # Sum across running instances; any unresolved instance makes the total
    # unresolved rather than silently under-reporting it.
    $running = @($svcs | Where-Object { $_.State -eq 'Running' })
    if ($running.Count -eq 0) { $running = @($svcs) }
    $bpGB    = 0.0
    $sources = @()
    foreach ($s in $running) {
        $bp = Get-InnoDbBufferPool -PathName $s.PathName -ServiceName $s.Name
        $sources += $bp.Source
        if ($null -eq $bp.GB) { $bpGB = $null } elseif ($null -ne $bpGB) { $bpGB += $bp.GB }
    }

    # Sanity check against what mysqld actually holds. A configured pool
    # can't explain a footprint many times its size: on the first real
    # material-MySQL host the option files read as the 128M default while
    # mysqld held 52.84GB - the effective config was somewhere this didn't
    # read. Under pressure that wrong figure would have produced "buffer pool
    # 0.12GB isn't the cause", a confident wrong diagnosis. Allow the pool
    # x1.5 plus 4GB for per-connection buffers, temp tables and the engine
    # itself before calling it unresolved; a correctly-read pool sits well
    # inside that (48GB pool, 52.8GB held passes).
    if ($null -ne $bpGB -and $privateGB -gt ($bpGB * 1.5 + 4)) {
        $sources += ('config reads {0}GB but mysqld holds {1}GB - effective config not found' -f [math]::Round($bpGB, 2), $privateGB)
        $bpGB = $null
    }

    [PSCustomObject]@{
        Engine           = $(if (@($svcs | Where-Object { $_.PathName -match 'mariadb' }).Count -gt 0) { 'MariaDB' } else { 'MySQL' })
        PrivateGB        = $privateGB
        BufferPoolGB     = $(if ($null -ne $bpGB) { [math]::Round($bpGB, 2) } else { $null })
        BufferPoolSource = (($sources | Select-Object -Unique) -join ', ')
    }
}

# ---------------------------------------------------------------------------
# Role detection
# ---------------------------------------------------------------------------
#   Kept in step with Get-ArcCapacityScreen.ps1's Get-ServerRole: same roles,
#   same order, same materiality bars and Veeam/Hyper-V rules. The one
#   deliberate difference is the SQL footprint, which here can draw on 14 days
#   of sampled Total Server Memory where the Screen only has a live reading.
function Get-ServerRole {
    param([double]$AllocatedGB = 0, [double]$SqlSampledGB = 0)

    $flags = New-Object System.Collections.Generic.List[string]
    $role  = 'Generic'
    $sqlGB = $null

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

    # SQL Server - presence alone is NOT enough to exclude a host from sizing.
    # The exclusion exists because commit on a host SQL dominates reports the
    # configured cap rather than the requirement; that only holds while SQL is
    # a material consumer. Presence-only matching excluded 21 of 73 devices on
    # a real estate (RD gateways, a VPN host, file servers carrying a bundled
    # Express or Veeam instance) and threw away real reclaim. Same bar as the
    # Screen and as MySQL below: at least 2GB AND at least 25% of allocation.
    #
    # Footprint is the larger of the sampled p95 Total Server Memory (14 days,
    # but one instance only - the sampler reads the first counter set it
    # resolves) and the live working set of every sqlservr process (all
    # instances, but one moment). Taking the larger means a busy instance is
    # never missed because the sampler happened to read a small one.
    # Below the bar: SQL-MINOR, sized normally. The SQL attention checks run
    # either way, so an Express database near its limit still surfaces.
    $isSql = ($svc.ContainsKey('MSSQLSERVER')) -or (& $hasSvc 'MSSQL$*')
    if ($isSql) {
        # Per process, the larger of private bytes and working set: working
        # set alone understates a host that's paging (the pool is partly on
        # disk), private bytes alone understates one using locked pages.
        $liveGB    = 0.0
        $procCount = 0
        try {
            $sqlProcs = @(Get-Process -Name 'sqlservr' -ErrorAction SilentlyContinue)
            $procCount = $sqlProcs.Count
            if ($procCount -gt 0) {
                $bytes  = ($sqlProcs | ForEach-Object { [math]::Max([double]$_.WorkingSet64, [double]$_.PrivateMemorySize64) } | Measure-Object -Sum).Sum
                $liveGB = [math]::Round($bytes / 1GB, 2)
            }
        } catch { }
        $sqlGB = [math]::Max($liveGB, $SqlSampledGB)

        $sqlIsMaterial = ($sqlGB -ge 2) -and
                         (($AllocatedGB -le 0) -or ($sqlGB -ge ($AllocatedGB * 0.25)))
        if ($sqlIsMaterial) {
            if ($role -eq 'Generic') { $role = 'SQLServer' }
            $flags.Add('SQL')
        } else {
            $flags.Add('SQL-MINOR')
        }
    }

    # MySQL / MariaDB - same materiality bar the Screen applies to SQL Server:
    # mysqld must hold at least 2GB AND at least 25% of allocation in private
    # bytes before it is treated as distorting commit. Below that (an LOB app's
    # bundled instance) the host is flagged MYSQL-MINOR and sized normally.
    $mysql = Get-MySqlInfo
    if ($mysql) {
        $mysqlIsMaterial = ($mysql.PrivateGB -ge 2) -and
                           (($AllocatedGB -le 0) -or ($mysql.PrivateGB -ge ($AllocatedGB * 0.25)))
        if ($mysqlIsMaterial) {
            if ($role -eq 'Generic') { $role = 'MySQL' }
            $flags.Add('MYSQL')
        } else {
            $flags.Add('MYSQL-MINOR')
        }
    }

    # Veeam: backup INFRASTRUCTURE, not a backup TARGET. The exclusion exists
    # because proxy and repository demand peaks inside the job window, which a
    # 14-day p95 flattens - an argument about things that move or store backup
    # data. Veeam installs its Installer/Deployment service on every server it
    # backs up and its agent on protected endpoints, so matching any Veeam*
    # service classed a plain 12GB file server as backup infrastructure and
    # discarded its reclaim. Match only data-mover and control services, by
    # prefix so version suffixes survive. An unrecognised future service name
    # falls through to VEEAM-MINOR and the host is sized normally.
    if ((& $hasSvc 'Veeam*')) {
        $veeamInfraPatterns = @(
            'VeeamBackup*',        # B&R server
            'VeeamTransport*',     # data mover - proxy and repository
            'VeeamNFS*',           # vPower NFS
            'VeeamCatalog*',       # guest file catalog
            'VeeamBroker*',        # broker
            'VeeamMount*',         # mount server
            'VeeamHvIntegration*'  # Hyper-V off-host data mover
        )
        $hasVeeamInfra = $false
        foreach ($p in $veeamInfraPatterns) {
            if (& $hasSvc $p) { $hasVeeamInfra = $true; break }
        }
        if ($hasVeeamInfra) {
            $flags.Add('VEEAM')
            if ($role -eq 'Generic') { $role = 'BackupInfra' }
        } else {
            $flags.Add('VEEAM-MINOR')
        }
    }

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

    # Hyper-V host. Last and unconditional, so it overrides every other role
    # rather than relying on the '-eq Generic' guards above: a hypervisor
    # running a Veeam data mover, or with RDSH bolted on, is still a
    # hypervisor. Guest-side demand can't describe a host whose memory is
    # consumed by its VMs, and its CPU figures describe its guests. vmms exists
    # only where the role is actually installed, not merely available.
    if ($svc.ContainsKey('vmms')) { $role = 'Hypervisor'; $flags.Add('HYPER-V') }

    [PSCustomObject]@{
        Role = $role; Flags = $flags; MySql = $mysql
        SqlPresent = $isSql; SqlGB = $sqlGB; SqlLiveGB = $liveGB; SqlRunning = $procCount
    }
}

# Role floors: minimum sensible allocation, independent of measured demand
$RamFloor  = @{ DomainController = 4; RDSH = 8; FileServer = 8; SQLServer = 8; MySQL = 8; Exchange = 16; BackupInfra = 8; Generic = 4 }
$vCpuFloor = @{ DomainController = 2; RDSH = 4; FileServer = 2; SQLServer = 4; MySQL = 4; Exchange = 4;  BackupInfra = 4; Generic = 2 }

# Roles where guest-side committed bytes does not represent requirement.
# MySQL is deliberately NOT listed: it has its own branch below so that active
# memory pressure still surfaces as URGENT instead of reading EXCLUDED.
$RamExcludedRoles = @('SQLServer', 'Exchange', 'BackupInfra')

# Share of allocation an InnoDB buffer pool can reasonably take on a dedicated
# database host - the figure MySQL 8.0's own innodb_dedicated_server uses above
# 4GB. A reasoned working figure, same status as the 1.25 / 1.4 / 65% above.
$InnoDbPoolShare = 0.75

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

    # Role detection needs the allocation and the sampled SQL footprint for the
    # SQL/MySQL materiality tests, so it runs here rather than before the
    # no-data exit above (which doesn't use it).
    $sqlTotalVals = Get-NumericColumn -Rows $rows -Column 'SqlTotalGB'
    $sqlSampledGB = if ($sqlTotalVals.Count) { [math]::Round((Get-Percentile -Values $sqlTotalVals -P 0.95), 2) } else { 0 }
    $roleInfo   = Get-ServerRole -AllocatedGB $allocatedGB -SqlSampledGB $sqlSampledGB
    $role       = $roleInfo.Role
    $flags      = $roleInfo.Flags
    $mysql      = $roleInfo.MySql
    $sqlPresent = $roleInfo.SqlPresent

    $mysqlDetailSuffix = ''
    if ($mysql) {
        $bpText = if ($null -ne $mysql.BufferPoolGB) { "$($mysql.BufferPoolGB)GB" } else { "? ($($mysql.BufferPoolSource))" }
        $mysqlDetailSuffix = " | mysqld $($mysql.PrivateGB)GB, buffer pool $bpText"
    }

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
    # SQL supplementary - attention signals, not sizing
    #   Built from the counters the sampler already collects (Total/Target
    #   Server Memory, PLE) plus the registry, so no sampler change and no
    #   database login. Each finding sets a flag and adds a short reason;
    #   none of them produces a number, since a SQL host's RAM is excluded
    #   from commit-based sizing. Findings are listed most actionable first,
    #   because the growth verdict UDF can only carry the first few.
    #
    #   Only one instance's counters are sampled (the first counter set the
    #   sampler resolves), so on a multi-instance host the figures describe
    #   one of them - the note says so.
    # =======================================================================
    $sqlNote       = ''
    $sqlSizing     = $null   # cap-or-RAM decision, used only under MEM-PRESSURE
    $sampledInst   = if ($sqlPresent) { Get-SampledSqlInstance } else { $null }
    $sqlFindings   = New-Object System.Collections.Generic.List[string]
    $sqlTargetVals = Get-NumericColumn -Rows $rows -Column 'SqlTargetGB'
    $pleVals       = Get-NumericColumn -Rows $rows -Column 'SqlPLE'
    # Keyed on presence, not the SQLServer role: a SQL-MINOR host (a bundled
    # Express instance) is sized normally but its database can still be
    # approaching Express's 10GB limit. @() around the whole if: an if
    # statement unrolls its output, so a single instance would otherwise
    # arrive as a bare object with no usable .Count.
    $sqlInstances  = @(if ($sqlPresent) { Get-SqlInstanceInfo })
    $allExpress    = ($sqlInstances.Count -gt 0) -and (@($sqlInstances | Where-Object { -not $_.IsExpress }).Count -eq 0)
    # Multi-instance means more than one engine actually RUNNING - installed
    # but stopped instances don't compete for memory
    $sqlRunning    = [int]$roleInfo.SqlRunning
    $sqlLiveGB     = [double]$roleInfo.SqlLiveGB
    $multiSql      = $sqlRunning -gt 1

    # Express caps every database at 10GB of data, and the engine stops
    # accepting writes at the limit - the one finding here that's an outage
    # rather than a slowdown, so it goes first. 8GB gives time to act.
    foreach ($inst in @($sqlInstances | Where-Object { $_.IsExpress -and $null -ne $_.LargestMdfGB -and $_.LargestMdfGB -ge 8 })) {
        $sqlFindings.Add("Express DB $($inst.LargestMdfGB)GB of 10GB limit ($($inst.Name))")
        if (-not ($flags -contains 'SQL-EXPRESS-CAP')) { $flags.Add('SQL-EXPRESS-CAP') }
    }

    if ($sqlTotalVals.Count -gt 0) {
        $sqlTotal = [math]::Round((Get-Percentile -Values $sqlTotalVals -P 0.95), 1)

        # PLE judged against the pool it describes. The old fixed 300s dates
        # from 4GB servers; 300s per 4GB of buffer pool is the common modern
        # scaling. p05 rather than the minimum: PLE always dips briefly during
        # index maintenance, CHECKDB or a restart, so only a low reading for
        # 5% of the window (~17 hours over 14 days) counts as sustained.
        $pleP05   = if ($pleVals.Count) { [int](Get-Percentile -Values $pleVals -P 0.05) } else { -1 }
        $pleFloor = [int][math]::Max(300, 300 * $sqlTotal / 4)

        $sqlNote = "SQL pool p95 ${sqlTotal}GB"

        if ($sqlTargetVals.Count -gt 0) {
            $targetMax = [math]::Round(($sqlTargetVals | Measure-Object -Maximum).Maximum, 1)
            $targetP05 = [math]::Round((Get-Percentile -Values $sqlTargetVals -P 0.05), 1)
            $targetP50 = [math]::Round((Get-Percentile -Values $sqlTargetVals -P 0.50), 1)
            $sqlNote  += " of target ${targetP50}GB"

            # Is the pool at the size SQL is allowed to grow to? Total below
            # Target on its own is NOT a shortage - an instance whose data
            # fits in less than its cap sits below Target indefinitely - so
            # this only matters combined with low PLE below. Compared per
            # sample, since Total and Target are read at the same moment.
            $ratios = New-Object System.Collections.Generic.List[double]
            foreach ($r in $rows) {
                $t = 0.0; $g = 0.0
                if ([double]::TryParse($r.SqlTotalGB, [ref]$t) -and [double]::TryParse($r.SqlTargetGB, [ref]$g) -and $g -gt 0) {
                    $ratios.Add($t / $g)
                }
            }
            $poolAtTarget = ($ratios.Count -gt 0) -and ((Get-Percentile -Values $ratios.ToArray() -P 0.50) -ge 0.95)
        } else {
            $targetMax = $null; $targetP05 = $null; $poolAtTarget = $false
        }

        if ($pleP05 -ge 0) { $sqlNote += ", PLE p05 ${pleP05}s (floor ${pleFloor}s)" }
        if ($multiSql) {
            $which = if ($sampledInst) { " ($sampledInst)" } else { '' }
            $sqlNote += " | $sqlRunning instances, one sampled$which, all hold ${sqlLiveGB}GB"
        }

        # Cap or RAM? Every sample records both total committed memory and the
        # sampled instance's Total Server Memory, so their difference is
        # everything that ISN'T that instance - the OS, other processes, other
        # instances - measured over the whole window rather than guessed. That
        # turns "URGENT, unsized" into a decision:
        #   capFits = allocation - other (p95) - headroom
        #             the largest cap that still leaves everything else room
        #   sqlNeed = the instance's measured pool (p95). Not its Target: SQL
        #             grows to whatever it's allowed, so Target says what it's
        #             permitted, not what it needs. Low PLE says it would like
        #             more, but there's no measurement of how much - a x1.25
        #             uplift was tried and asked a 128GB host for +62GB, since
        #             the PLE floor gets very strict on large pools - so low
        #             PLE is stated in the text, not added to the number.
        #   capFits >= sqlNeed -> a cap fixes it, if the instance is currently
        #                         allowed past capFits (else no claim at all)
        #   capFits <  sqlNeed -> RAM short: grow to sqlNeed + other +
        #                         headroom, then cap at what fits
        # Built here, applied only on a SQLServer host under MEM-PRESSURE (see
        # the RAM verdict), so it can't add noise to a healthy host. "Other"
        # is commit, which can exceed what's resident - the direction that
        # recommends slightly more, not less, and only where pressure is
        # already proven by available memory and hard faults.
        #
        # Locked pages: with Lock Pages in Memory the buffer pool is allocated
        # outside the commit charge, so commit minus SQL goes small or
        # negative and "everything else" reads as nothing. If commit falls
        # below SQL's own memory in more than a quarter of samples the split
        # isn't valid on this host, and no decision is made rather than one
        # built on a wrong remainder.
        if ($confident -and $role -eq 'SQLServer') {
            # NB [math]::Max(0.0, ...) - with an integer literal first,
            # PowerShell binds Max(int, int) and rounds the double away
            # (Max(0, 3.4) is 3). Same reason for the 1.0 / 8.0 / 2.0
            # literals elsewhere in this file and in the Screen.
            $otherVals = New-Object System.Collections.Generic.List[double]
            $belowSql  = 0
            foreach ($r in $rows) {
                $c = 0.0; $s = 0.0
                if ([double]::TryParse($r.CommittedGB, [ref]$c) -and [double]::TryParse($r.SqlTotalGB, [ref]$s)) {
                    if ($c -lt $s) { $belowSql++ }
                    $otherVals.Add([math]::Max(0.0, $c - $s))
                }
            }
            if ($otherVals.Count -gt 0 -and $belowSql -gt ($otherVals.Count * 0.25)) {
                $sqlNote += ' | commit excludes SQL (locked pages?) - no cap/RAM split'
            }
            elseif ($otherVals.Count -ge ($rows.Count * 0.5)) {
                $otherP95   = [math]::Round((Get-Percentile -Values $otherVals.ToArray() -P 0.95), 1)
                $headroomGB = [math]::Round([math]::Max(1.5, $allocatedGB * 0.08), 1)
                $capFits    = [math]::Floor(($allocatedGB - $otherP95 - $headroomGB) * 10) / 10
                $pleLow     = ($pleP05 -ge 0 -and $pleP05 -lt $pleFloor)
                $sqlNeed    = $sqlTotal
                $allowedGB  = if ($null -ne $targetMax) { $targetMax } else { $sqlTotal }
                $inst       = if ($sampledInst) { $sampledInst } else { 'SQL' }

                if ($capFits -ge $sqlNeed) {
                    if ($allowedGB -gt $capFits) {
                        $sqlSizing = [PSCustomObject]@{
                            Kind = 'CAP'; GrowthGB = 0
                            Text = "cap $inst max server memory at ${capFits}GB - other processes need ${otherP95}GB, SQL fits in ${sqlNeed}GB"
                        }
                    }
                } else {
                    $grow = Get-CeilEven -Value ($sqlNeed + $otherP95 + $headroomGB - $allocatedGB)
                    if ($grow -gt 0) {
                        $newAlloc = [int]($allocatedGB + $grow)
                        $capAfter = [math]::Floor(($newAlloc - $otherP95 - $headroomGB) * 10) / 10
                        # Kept short: shares Custom69's 255 characters with the
                        # pressure prefix, the CPU verdict and the timestamp
                        $sqlText  = if ($pleLow) { "SQL ${sqlTotal}GB (low PLE)" } else { "SQL ${sqlTotal}GB" }
                        $sqlSizing = [PSCustomObject]@{
                            Kind = 'RAM'; GrowthGB = $grow
                            Text = "RAM short: $sqlText + other ${otherP95}GB + ${headroomGB}GB headroom -> +${grow}GB -> ${newAlloc}GB, cap $inst at ${capAfter}GB"
                        }
                    }
                }
            }
        }

        if ($confident) {
            # max server memory unset, or set so high the OS is left short.
            # Target can't be read as the configured value without a login,
            # but with no cap it climbs to nearly all of physical memory, so a
            # Target leaving under half the recommended OS reserve is either
            # unset or set too high - the same fix either way. Half, not the
            # whole reserve: a cap a few GB above the guidance is common and
            # usually fine; this is for the clear cases.
            if ($null -ne $targetMax -and -not $allExpress) {
                $reserveGB = Get-SqlOsReserveGB -AllocatedGB $allocatedGB
                if ($targetMax -gt ($allocatedGB - [math]::Max(1.0, $reserveGB / 2))) {
                    $capGB = [int]($allocatedGB - $reserveGB)
                    $sqlFindings.Add("max server memory unset/too high (target ${targetMax}GB of ${allocatedGB}GB) - cap at ${capGB}GB")
                    $flags.Add('SQL-CAP')
                }
            }

            # Memory-bound: the pool is as large as SQL is allowed to make it
            # and pages still aren't staying in it. More memory (or a higher
            # cap, or query/index tuning) is the remedy - unless this is
            # Express, whose ~1.4GB buffer pool cap no amount of RAM lifts.
            if ($pleP05 -ge 0 -and $pleP05 -lt $pleFloor -and $poolAtTarget) {
                if ($allExpress) {
                    $sqlFindings.Add("memory-bound at the Express pool cap (PLE p05 ${pleP05}s) - more RAM won't help")
                    if (-not ($flags -contains 'SQL-EXPRESS-CAP')) { $flags.Add('SQL-EXPRESS-CAP') }
                } else {
                    $sqlFindings.Add("memory-bound: PLE p05 ${pleP05}s < ${pleFloor}s with pool at target")
                    $flags.Add('SQL-MEM')
                }
            }

            # Squeezed: SQL lowers Target when Windows signals low memory, so
            # a Target that spends real time well below its own peak means
            # something outside SQL is taking memory from it (or the cap was
            # lowered mid-window, which reads the same). 1GB minimum so small
            # Express targets don't trip it on noise.
            # On a multi-instance host the likeliest squeezer is the other
            # instance, so say so - "OS pressure" alone sent the reader the
            # wrong way on the first real two-instance host.
            if ($null -ne $targetMax -and $targetP05 -lt ($targetMax * 0.8) -and ($targetMax - $targetP05) -ge 1) {
                $suspects = if ($multiSql) { 'another SQL instance, OS pressure or a lowered cap' } else { 'OS pressure or a lowered cap' }
                $sqlFindings.Add("target fell to ${targetP05}GB from ${targetMax}GB - $suspects")
                if (-not ($flags -contains 'SQL-MEM')) { $flags.Add('SQL-MEM') }
            }
        }
    }
    elseif ($flags -contains 'SQL') {
        $sqlNote = 'SQL counters not sampled'
        if ($multiSql) { $sqlNote += " | $sqlRunning instances hold ${sqlLiveGB}GB" }
    }

    # Combined footprint on a multi-instance host. The cap check above sees
    # only the one instance the sampler reads, so two instances whose caps
    # are each reasonable but together exceed the host can't trip it - the
    # first real two-instance host (two Standard instances on 12GB, 0.72GB
    # free, 179 faults/s) read only as "squeezed". This uses the live footprint
    # of every sqlservr process, which needs no counters and covers all
    # instances. Same half-reserve bar as the single-instance check, so the
    # two agree on what "leaves the OS too little" means; the advised total is
    # the full reserve. Inserted ahead of the squeeze finding, since it names
    # the cause the squeeze is the symptom of.
    if ($confident -and $multiSql -and $sqlLiveGB -gt 0) {
        $reserveGB = Get-SqlOsReserveGB -AllocatedGB $allocatedGB
        if ($sqlLiveGB -gt ($allocatedGB - [math]::Max(1.0, $reserveGB / 2))) {
            $capGB = [int]($allocatedGB - $reserveGB)
            $at = [math]::Min($sqlFindings.Count, @($sqlFindings | Where-Object { $_ -like 'Express DB*' -or $_ -like 'max server memory*' }).Count)
            $sqlFindings.Insert($at, "$sqlRunning instances hold ${sqlLiveGB}GB of ${allocatedGB}GB - combined caps too high, total at ${capGB}GB")
            if (-not ($flags -contains 'SQL-CAP')) { $flags.Add('SQL-CAP') }
        }
    }

    # =======================================================================
    # Pressure guardrails
    # =======================================================================
    # Hard faults count only alongside genuinely low memory. The counter
    # behind HardFaultsSec (Memory\Pages Input/sec) also counts pages read for
    # memory-mapped FILES, so file and web servers fault constantly with
    # memory to spare. On a 507-device estate run, 140 of 281 pressure hosts
    # were flagged on faults alone; 105 of those never dropped below 20% free
    # in 14 days (19 never below 50%), and carried 244GB of growth
    # recommendations - "+22GB" on a 144GB host whose worst moment was 36%
    # free. 20% is the Screen's UPSIZE bar, so the components agree on "short
    # of headroom". The absolute < 1GB trigger is unchanged and unconditional,
    # matching the Screen's own absolute trigger.
    $MemPressureFaultAvailFraction = 0.20
    $faultPressure = ($faultP95 -gt 10) -and ($availMin -lt ($allocatedGB * $MemPressureFaultAvailFraction))
    $memPressure   = ($availMin -lt 1.0) -or $faultPressure
    if (-not $memPressure -and $faultP95 -gt 10) {
        # Not pressure, but worth seeing why the faults were discounted
        $flags.Add('FAULTS-IO')
    }
    if ($memPressure) { $flags.Add('MEM-PRESSURE') }

    # Single-thread bound: one core near saturation while total sits near the
    # ceiling a single thread can produce on this vCPU count.
    $singleThreadCeiling = (100.0 / $vCPU) * 1.30
    $singleThreadBound = ($maxCoreP95 -gt 85) -and ($cpuTotalP95 -lt $singleThreadCeiling)
    $cpuPressure = ($queueP95 -gt (2 * $vCPU)) -or ($cpuTotalP95 -gt 75)

    # Not flagged on a Hyper-V host: its CPU is its guests' demand, and three
    # busy cluster nodes reading CPU-PRESSURE on a real estate looked
    # actionable when it wasn't. MEM-PRESSURE above still applies to them.
    if ($role -ne 'Hypervisor') {
        if ($singleThreadBound) { $flags.Add('SINGLE-THREAD') }
        if ($cpuPressure)       { $flags.Add('CPU-PRESSURE') }
    }

    # =======================================================================
    # RAM recommendation - reclaim (over-allocated) or growth (under-provisioned)
    #   Both directions share one target: Target = max(RoleFloor, basis x
    #   multiplier). Where Allocated sits relative to Target decides which way
    #   (or neither) the recommendation goes, so the two directions can never
    #   disagree with each other about what "right-sized" means.
    # =======================================================================
    $ramFloorGB = $RamFloor[$role]
    if (-not $ramFloorGB) { $ramFloorGB = 4 }

    # DC floor becomes a function of the actual DIT size where it can be
    # determined - see Get-DcDitSizeGB above for why. 1.15x + 2GB is a reasoned
    # estimate (DIT fully cacheable plus ESE/version-store overhead plus a
    # baseline for the OS and other DC services), not a vendor-published
    # constant - same status as this tool's other multipliers (1.25, 1.4,
    # 65%). Only ever raises the floor, never lowers it below the flat value.
    # $flatFloorGB (pre-DIT) is kept alongside for an evidence check below -
    # deliberately NOT expressed as a Get-SizingTarget call despite the
    # surface similarity, since this is additive (basis + overhead), not a
    # max(floor, basis x multiplier) - folding it into that shared helper
    # would silently change the arithmetic.
    $flatFloorGB = $ramFloorGB
    $ditSizeGB   = $null
    $ditUnknown  = $false
    if ($role -eq 'DomainController') {
        $ditSizeGB = Get-DcDitSizeGB
        if ($null -ne $ditSizeGB) {
            $ditFloorGB = [math]::Ceiling(($ditSizeGB * 1.15) + 2)
            $ramFloorGB = [math]::Max($ramFloorGB, $ditFloorGB)
        } else {
            $ditUnknown = $true
            $flags.Add('DIT-UNKNOWN')
        }
    }

    # Built once, here, alongside the floor computation it describes, rather
    # than re-deriving the same role/null checks again down at the RAM Detail
    # UDF write-back - keeps the two from being able to drift out of sync.
    $dcDetailSuffix = if ($role -ne 'DomainController') {
        ''
    } elseif ($null -ne $ditSizeGB) {
        " | DIT ${ditSizeGB}GB -> floor ${ramFloorGB}GB"
    } else {
        ' | DIT size unknown -> flat floor'
    }

    $reclaimGB     = 0
    $growthGB      = 0
    $ramVerdict    = ''
    $growthVerdict = ''
    $tag           = if ($Conservative) { 'PROVISIONAL ' } else { '' }

    if (-not $confident) {
        $ramVerdict    = "INSUFFICIENT DATA - $coverage% coverage"
        $growthVerdict = "INSUFFICIENT DATA - $coverage% coverage"
    }
    elseif ($role -eq 'Hypervisor') {
        # Guest-side commit can't size a host whose memory goes to its VMs, so
        # no number either way. Memory pressure is still surfaced, as the
        # Screen surfaces UPSIZE on a hypervisor: a root partition that is
        # itself out of memory is a host problem worth knowing about whatever
        # its guests are doing.
        $ramVerdict = 'NO SIZING - Hyper-V host, guest-side commit describes its VMs; size from hypervisor reporting'
        if ($memPressure) {
            $ramVerdict    = "NO RECLAIM - memory pressure (min avail ${availMin}GB, p95 faults ${faultP95}/s) - see growth verdict"
            $growthVerdict = "${tag}URGENT - host mem pressure (avail ${availMin}GB, faults ${faultP95}/s), unsized - check VM memory assignments and the host's own processes"
            $flags.Add('GROWTH')
        } else {
            $growthVerdict = 'NO SIZING - Hyper-V host'
        }
    }
    elseif ($role -eq 'SQLServer') {
        # Commit reflects the configured cap, not demand, so no number in
        # either direction - the growth verdict carries the SQL findings
        # instead. Under memory pressure it still reads URGENT, as MySQL does:
        # low available memory is real whatever commit says, and on a SQL host
        # the commonest cause is an unset max server memory, which the
        # findings name first.
        $ramVerdict = if ($sqlNote) { "EXCLUDED (SQLServer) | $sqlNote" } else { 'EXCLUDED (SQLServer) - guest commit reflects configured cap, not demand' }

        $prefix = if ($memPressure) { "${tag}URGENT - mem pressure (avail ${availMin}GB, faults ${faultP95}/s): " } else { 'REVIEW - ' }

        # Shares Custom69's 255 characters with 'RAM: ', the CPU growth
        # verdict and the timestamp (~70 between them in the usual case).
        # Format-VerdictUdf at the write-back is the backstop if the CPU side
        # runs long.
        # Under pressure, the cap-or-RAM decision (built in the SQL block
        # above) leads, since it answers what to actually do; the findings
        # explaining it follow. A RAM-short decision is the one SQL case that
        # fills Growth GB - its figure comes from SQL's own counters and the
        # measured non-SQL remainder, not the inflated commit total that keeps
        # every other SQL verdict unsized.
        $leading = @($sqlFindings)
        if ($memPressure -and $sqlSizing) {
            $leading = @($sqlSizing.Text) + $leading
            if ($sqlSizing.Kind -eq 'RAM') { $growthGB = $sqlSizing.GrowthGB }
            if ($sqlSizing.Kind -eq 'CAP' -and -not ($flags -contains 'SQL-CAP')) { $flags.Add('SQL-CAP') }
        }
        $body = Format-Findings -Findings $leading -Budget (180 - $prefix.Length)

        if ($memPressure) {
            $ramVerdict    = "NO RECLAIM - memory pressure (min avail ${availMin}GB, p95 faults ${faultP95}/s) - see growth verdict"
            $cause         = if ($body) { $body } else { 'SQL counters show no cause - check other processes' }
            $growthVerdict = "$prefix$cause"
            # GROWTH means "needs RAM". A host a cap alone fixes isn't a RAM
            # candidate - SQL-CAP and MEM-PRESSURE carry it to a worklist.
            if (-not ($sqlSizing -and $sqlSizing.Kind -eq 'CAP')) { $flags.Add('GROWTH') }
        }
        elseif ($body) {
            $growthVerdict = "$prefix$body"
        }
        elseif ($sqlTotalVals.Count -gt 0) {
            $growthVerdict = 'NO CHANGE - SQL counters show no memory concern'
        }
        else {
            $growthVerdict = 'EXCLUDED (SQLServer) - no SQL counters sampled, size from SQL metrics'
        }
    }
    elseif ($RamExcludedRoles -contains $role) {
        # Exchange and Veeam infrastructure (SQLServer has its own branch
        # above). Excluded from sizing in both directions, but - as for SQL,
        # MySQL and Hyper-V - active memory pressure reads URGENT rather than
        # hiding behind EXCLUDED: the exclusions exist to stop commit sizing a
        # host, never to conceal one that's out of memory.
        $ramVerdict = "EXCLUDED ($role) - guest commit reflects configured cap, not demand"
        if ($memPressure) {
            $ramVerdict    = "NO RECLAIM - memory pressure (min avail ${availMin}GB, p95 faults ${faultP95}/s) - see growth verdict"
            $growthVerdict = "${tag}URGENT - mem pressure (avail ${availMin}GB, faults ${faultP95}/s), unsized - size from $role metrics, not guest commit"
            $flags.Add('GROWTH')
        } else {
            $growthVerdict = "EXCLUDED ($role) - size from platform-specific metrics, not guest commit"
        }
    }
    elseif ($role -eq 'MySQL') {
        # Commit can't size this host in either direction - it carries the
        # buffer pool reservation, so commit x multiplier just restates the
        # configuration (a 24GB host with a 20GB pool reads as needing 30GB+).
        # But unlike the plain exclusion above, active pressure is still
        # surfaced as URGENT: low available memory and hard faults are real
        # whatever commit says. Withhold the GB figure and say instead whether
        # the configured pool explains the pressure - the fix is often lowering
        # innodb_buffer_pool_size, not adding RAM.
        $ramVerdict = 'EXCLUDED (MySQL) - guest commit includes the InnoDB buffer pool reservation, not demand'
        if ($memPressure) {
            $ramVerdict = "NO RECLAIM - memory pressure (min avail ${availMin}GB, p95 faults ${faultP95}/s) - see growth verdict"
            $bpGB = $mysql.BufferPoolGB
            $advice = if ($null -eq $bpGB) {
                "buffer pool unresolved ($($mysql.BufferPoolSource)) - check it before resizing"
            } elseif ($bpGB -gt ($allocatedGB * $InnoDbPoolShare)) {
                $bpPct  = [math]::Round(100 * $bpGB / $allocatedGB, 0)
                $safeGB = [math]::Floor($allocatedGB * $InnoDbPoolShare)
                $needGB = Get-CeilEven -Value ($bpGB / $InnoDbPoolShare)
                "buffer pool ${bpGB}GB is ${bpPct}% of ${allocatedGB}GB - lower it to ${safeGB}GB or grow RAM to ${needGB}GB"
            } else {
                $bpPct = [math]::Round(100 * $bpGB / $allocatedGB, 0)
                "buffer pool ${bpGB}GB (${bpPct}%) isn't the cause - check connection buffers, other processes"
            }
            # Kept short: this shares Custom69's 255 characters with the CPU
            # growth verdict and the timestamp.
            $growthVerdict = "${tag}URGENT - mem pressure (min avail ${availMin}GB, faults ${faultP95}/s), unsized - commit holds the buffer pool: $advice"
            # GROWTH with Growth GB left at 000 - same convention as the
            # CPU-GROWTH queue REVIEW case, so a flag-based worklist catches it.
            $flags.Add('GROWTH')
        } else {
            $growthVerdict = 'EXCLUDED (MySQL) - size from InnoDB metrics, not guest commit'
        }
    }
    elseif ($ditUnknown) {
        # Same "suppress rather than degrade" philosophy as every other
        # guardrail in this file - the flat 4GB floor this would otherwise
        # fall back to is exactly the value this whole feature exists because
        # it's wrong for a large-DIT DC. Silently computing a live reclaim
        # verdict against a known-wrong floor is worse than no verdict.
        $ramVerdict    = 'REVIEW - DIT size could not be resolved, cannot confirm a safe RAM floor for this DC'
        $growthVerdict = 'REVIEW - DIT size could not be resolved, cannot confirm a safe RAM floor for this DC'
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
        elseif ($flags -contains 'FAULTS-IO' -and $raw -gt 0) {
            # Faults discounted as pressure (memory never got tight), but they
            # are still real disk reads - typically a file or web server
            # serving from its file cache. Reclaiming shrinks that cache and
            # turns cached reads into disk reads, so hold rather than swing
            # from "URGENT, add RAM" straight to "remove RAM". Suppress rather
            # than degrade, as with every other guardrail here.
            $ramVerdict = "NO RECLAIM - high fault rate (p95 ${faultP95}/s) with memory to spare, likely file I/O; reclaim would shrink the file cache"
        }
        elseif ($raw -gt 0) {
            $reclaimGB = Get-Floor2 -Value $raw

            # Conservative mode only acts on gross over-allocation. 40% rather
            # than 50%: the 1.4x multiplier is already doing conservative work,
            # and at 50% a 32GB VM with 12GB peak demand - the most obvious
            # candidate there is - falls just outside and gets deferred for no
            # good reason.
            $minReclaim = if ($Conservative) { [math]::Max(8.0, $allocatedGB * 0.4) } else { 4 }

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
        # For a DC, $raw uses the (possibly DIT-raised) floor - but a DIT can be
        # large from tombstone/whitespace bloat with no live-memory equivalent,
        # so before asserting a growth number, check whether ACTUAL measured
        # demand (the flat, non-DIT-adjusted target) corroborates it. If the
        # evidence alone wouldn't ask for growth, the DIT floor alone is
        # driving this - flag for review instead of asserting a number the
        # commit-bytes evidence doesn't support. Non-DC roles are unaffected:
        # $flatFloorGB equals $ramFloorGB for them, so $evidenceRaw equals $raw
        # and this check can never trigger.
        $evidenceTargetGB = Get-SizingTarget -FloorGB $flatFloorGB -BasisGB $basisGB -Multiplier $multiplier
        $evidenceRaw      = $allocatedGB - $evidenceTargetGB
        $ditDrivenOnly    = $false

        if ($raw -lt 0) {
            if ($evidenceRaw -ge 0) {
                $ditDrivenOnly = $true
                $flags.Add('DIT-REVIEW')
            } else {
                $growthGB = Get-CeilEven -Value (-$raw)
            }
        }

        # Pressure escalation: active symptoms (available memory near zero,
        # real hard faults) are a more direct signal than a percentile crossing
        # a threshold, and can fire even when the trigger above doesn't - a
        # host can be thrashing on short spikes that a 14-day p95 smooths over.
        #
        # Target = the primary target (p95 x multiplier, or the floor), raised
        # to the PEAK if the peak is higher: the worst moment always fits in
        # RAM, so spike-thrashing is still covered. It was peak x multiplier,
        # which added 25% on top of a figure that is already the worst moment;
        # on a 224-host URGENT population that asked for 1,532GB, inflated most
        # on RDS session hosts whose logon-storm peaks run far above their
        # busy-time commit ("+26GB" on a 24GB host with p95 commit 23GB). This
        # asks 1,016GB: short-all-the-time hosts barely move (392 -> 350GB),
        # and 20 of 25 dip-only hosts (p95 under 80% of RAM) get no number and
        # fall to the MEM-REVIEW path below instead. Conservative mode is
        # unchanged in effect - its basis is already the peak, x1.4.
        if ($memPressure) {
            $pressureTarget = [math]::Max($targetGB, [math]::Round($commitMax, 2))
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
        }
        elseif ($ditDrivenOnly) {
            $growthVerdict = "REVIEW - DIT-derived floor (${ramFloorGB}GB) exceeds allocation but measured demand (${basisLabel} ${basisGB}GB) doesn't corroborate it - a large DIT can be tombstone/whitespace bloat with no live-memory equivalent; check for an overdue offline defrag before resizing"
        }
        else {
            $growthVerdict = 'NO CHANGE - demand within allocation'
        }
    }

    # SQL findings on a host that isn't in the SQLServer role - SQL-MINOR (a
    # bundled Express instance), or SQL on a DC/Exchange/hypervisor - still
    # belong in front of someone: an Express database near its 10GB limit is an
    # outage waiting, whatever the host's RAM sizing says. The SQLServer branch
    # above already carries them. Appended, so the host's own RAM verdict
    # stays first; Format-VerdictUdf trims if the total runs long.
    if ($role -ne 'SQLServer' -and $sqlFindings.Count -gt 0) {
        $growthVerdict += ' | SQL: ' + (Format-Findings -Findings $sqlFindings -Budget 100)
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
    elseif ($role -eq 'Hypervisor') {
        # A busy host's utilisation is its guests' demand - sustained high CPU
        # is normal and says nothing about the host's own vCPU.
        $cpuVerdict       = 'NO SIZING - Hyper-V host, CPU describes its guests'
        $cpuGrowthVerdict = 'NO SIZING - Hyper-V host'
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
        # The role floor applies before deciding there's a reduction at all -
        # applied afterwards, a floor at or above current vCPU produced
        # "REDUCE to 4 vCPU" on a 4 vCPU host, or a "reduction" upwards on a
        # 2 vCPU host whose role floor is 4.
        $floored = [math]::Max($cpuFloor, $sized)

        # --- Reduction side --------------------------------------------------
        if ($cpuPressure) {
            $cpuVerdict = "NO REDUCTION - CPU pressure (p95 ${cpuTotalP95}%, p95 queue ${queueP95})"
            if ($sized -gt $vCPU) { $cpuVerdict += ' - see growth verdict' }
        }
        elseif ($sized -lt $vCPU -and $floored -ge $vCPU) {
            $cpuVerdict = "NO CHANGE - demand sizes to $sized but $role floor is $cpuFloor vCPU"
        }
        elseif ($memPressure -and $floored -lt $vCPU) {
            # A host short of memory spends its time waiting on paging I/O, and
            # waiting isn't CPU time - so utilisation measured under pressure
            # understates what the workload will use once memory is fixed.
            # Holding vCPU costs nothing; cutting it on depressed figures and
            # then fixing memory leaves the host CPU-starved. Reduction only:
            # growth below is unaffected, since pressure can't inflate demand.
            $cpuVerdict = "NO REDUCTION - memory pressure, CPU measured while paging understates demand (would size to $floored); resolve memory first"
        }
        elseif ($floored -lt $vCPU) {
            $recVcpu = $floored
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
    $ramDetail = ('Alloc {0}GB | Commit p50 {1} p95 {2} max {3}GB | MinAvail {4}GB | Faults p95 {5}/s' -f `
                 $allocatedGB, $commitP50, $commitP95, $commitMax, $availMin, $faultP95) + $dcDetailSuffix + $mysqlDetailSuffix

    $cpuDetail = '{0} vCPU | Total p50 {1}% p95 {2}% max {3}% | MaxCore p95 {4}% | Queue p95 {5} max {6}' -f `
                 $vCPU, $cpuTotalP50, $cpuTotalP95, $cpuTotalMax, $maxCoreP95, $queueP95, $queueMax

    $flagText = if ($flags.Count) { "$role | " + ($flags -join ',') } else { $role }
    $summary  = Format-VerdictUdf -Ram $ramVerdict -Cpu $cpuVerdict

    Set-Udf -Index ($UdfBase + 0) -Value $windowText
    Set-Udf -Index ($UdfBase + 1) -Value $ramDetail
    Set-Udf -Index ($UdfBase + 2) -Value ('{0:D3}' -f $reclaimGB)   # zero-padded: Datto sorts UDFs as strings
    Set-Udf -Index ($UdfBase + 3) -Value $cpuDetail
    Set-Udf -Index ($UdfBase + 4) -Value ('{0:D2}' -f $recVcpu)     # zero-padded, same reason
    Set-Udf -Index ($UdfBase + 5) -Value $flagText
    Set-Udf -Index ($UdfBase + 6) -Value $summary
    Set-Udf -Index ($UdfBase + 7) -Value ('{0:D3}' -f $growthGB)    # zero-padded, same reason
    Set-Udf -Index ($UdfBase + 8) -Value ('{0:D2}' -f $vcpuGrowth)  # zero-padded, same reason
    Set-Udf -Index ($UdfBase + 9) -Value (Format-VerdictUdf -Ram $growthVerdict -Cpu $cpuGrowthVerdict)

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
                DitSizeGB       = $ditSizeGB
                RamFloorGB      = $ramFloorGB
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
                SqlFootprintGB  = $roleInfo.SqlGB
                SqlSampled      = $sampledInst
                SqlSizing       = $(if ($sqlSizing) { $sqlSizing.Text } else { $null })
                SqlRunning      = $sqlRunning
                SqlLiveGB       = $sqlLiveGB
                SqlNote         = $sqlNote
                SqlFindings     = ($sqlFindings -join '; ')
                SqlEditions     = (($sqlInstances | ForEach-Object { '{0}={1}' -f $_.Name, $_.Edition }) -join '; ')
                MySqlPrivateGB  = $(if ($mysql) { $mysql.PrivateGB } else { $null })
                InnoDbPoolGB    = $(if ($mysql) { $mysql.BufferPoolGB } else { $null })
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
    foreach ($inst in $sqlInstances) {
        $mdfText = if ($null -ne $inst.LargestMdfGB) { ", largest data file $($inst.LargestMdfGB)GB" } else { '' }
        Write-Output "SQL instance    : $($inst.Name) - $($inst.Edition)$mdfText"
    }
    foreach ($f in $sqlFindings) { Write-Output "SQL finding     : $f" }
    if ($sqlSizing) {
        $applied = if ($memPressure -and $role -eq 'SQLServer') { '' } else { ' (not applied - no memory pressure)' }
        Write-Output "SQL sizing      : $($sqlSizing.Text)$applied"
    }
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
