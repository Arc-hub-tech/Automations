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

    Version : 1.11 -  09/10/2026  (Hyper-V host health checks replace NO SCREEN on
              hypervisors: VMs in a critical state, host memory headroom, low free space
              on VM volumes, stale/stuck/orphaned checkpoints, replication health, lost
              guest heartbeats, vCPU over-subscription, and - from the core cluster group
              owner only - cluster nodes not Up and CSVs low or redirected. Flags HV-*; the
              same four UDFs carry host content. Re-runs in 64-bit PowerShell when Datto's
              process is 32-bit, since the Hyper-V module only loads in 64-bit)

    Version : 1.10 -  09/10/2026  (Hyper-V hosts no longer flagged CPU-PRESSURE or
              CPU-REVIEW - their CPU is their guests' demand. Matches Component 2, whose
              role detection is now aligned with this script)

    Version : 1.9  -  09/10/2026  (MySQL/MariaDB role, kept in step with Component 2:
              detected by service binary, excluded from reclaim where mysqld holds >=2GB
              and >=25% of allocation - InnoDB commits its whole buffer pool up front, so
              commit restates the configuration rather than the demand. Verdicts cite
              mysqld's footprint and the configured innodb_buffer_pool_size; UPSIZE on a
              MySQL host points at the buffer pool before RAM)

    Version : 1.8  -  19/08/2026  (the commit ratio no longer triggers UPSIZE on its own -
              at 100% it still flagged a 96GB host holding 30% of its memory available, plus
              three session hosts at 23-30%. Commit charge routinely exceeds RAM on RDSH.
              Over-commitment must now be accompanied by available memory under 20% of
              allocation; the absolute available < 1GB trigger is unchanged)

    Version : 1.7  -  19/08/2026  (Veeam exclusion narrowed to backup INFRASTRUCTURE - matching
              any Veeam* service treated every backed-up machine as backup infra, discarding a
              file server's reclaim; agent/installer-only hosts are now VEEAM-MINOR and screened.
              Added a Hyper-V host guard: guest-side demand cannot describe a host whose memory
              is consumed by its VMs, so those return NO SCREEN rather than misleading figures)

    Version : 1.6  -  19/08/2026  (UPSIZE no longer fires on the commit ratio alone - that
              produced false positives on the first real run, flagging a host at 93% of
              allocation that had 35% of its memory available. Now triggers on commit
              exceeding allocation OR available memory under 1GB, the latter being the same
              metric and threshold Component 2 uses for MEM-PRESSURE. The verdict names
              which trigger fired)

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
# !include / !includedir are not followed - a value set only in an included
# file reads as the built-in default, which errs toward "buffer pool smaller
# than it is" and so never inflates a recommendation.
function Read-MySqlOptionFile {
    param([string]$Path)
    $opts = @{}
    $inServer = $false
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $inServer = ($Matches[1].Trim() -match '^(mysqld|server|mariadb|mariadbd)(-[\d.]+)?$')
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
    param([string]$PathName)
    try {
        $exe = if ($PathName -match '^\s*"([^"]+)"') { $Matches[1] } elseif ($PathName -match '^\s*(\S+)') { $Matches[1] } else { '' }
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
                $o = Read-MySqlOptionFile -Path $f
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
        $bp = Get-InnoDbBufferPool -PathName $s.PathName
        $sources += $bp.Source
        if ($null -eq $bp.GB) { $bpGB = $null } elseif ($null -ne $bpGB) { $bpGB += $bp.GB }
    }

    [PSCustomObject]@{
        Engine           = $(if (@($svcs | Where-Object { $_.PathName -match 'mariadb' }).Count -gt 0) { 'MariaDB' } else { 'MySQL' })
        PrivateGB        = $privateGB
        BufferPoolGB     = $(if ($null -ne $bpGB) { [math]::Round($bpGB, 2) } else { $null })
        BufferPoolSource = (($sources | Select-Object -Unique) -join ', ')
    }
}

# Role floors and exclusions kept identical to Component 2 so the two agree.
# MySQL is listed as excluded here but handled in its own branch there - the
# outcome matches, since UPSIZE below already outranks every exclusion.
$RamFloor         = @{ DomainController = 4; RDSH = 8; FileServer = 8; SQLServer = 8; MySQL = 8; Exchange = 16; BackupInfra = 8; Generic = 4 }
$RamExcludedRoles = @('SQLServer', 'MySQL', 'Exchange', 'BackupInfra')

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

    # MySQL / MariaDB - the same materiality bar as SQL above, measured on
    # private bytes rather than working set: InnoDB commits its whole buffer
    # pool at startup, so private bytes is mysqld's actual share of the commit
    # figure this screen sizes from, however little of the pool is touched yet.
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
    # Veeam: distinguish backup INFRASTRUCTURE from a backup TARGET.
    #
    # Matching any Veeam* service is the same over-broad mistake the SQL predicate
    # made. Veeam installs its Installer/Deployment service on every managed
    # server it backs up, and its agent on protected endpoints - so a plain file
    # server being backed up looked like backup infrastructure and had its reclaim
    # discarded (on a real estate, a 12GB file server with 8.58GB committed).
    #
    # The exclusion exists because proxy and repository demand peaks inside the
    # job window and a p95 across 14 days flattens it. That argument applies to
    # something that moves or stores backup data, not to a machine that is merely
    # a backup source. So match the services that indicate a data-mover or
    # control role, by prefix so version suffixes don't break the match.
    #
    # Fail-open direction is deliberate but worth knowing: an unrecognised future
    # service name falls through to VEEAM-MINOR and the host gets screened. The
    # gross-over-allocation gate still has to clear 40% of allocation and 8GB
    # before anything is recommended, which keeps that failure mode cheap.
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

    # Hyper-V host. Genuinely last, and unconditional, so it overrides every other
    # role rather than relying on the '-eq Generic' guards above staying in place:
    # a hypervisor running a Veeam data mover, or with the RDSH role bolted on, is
    # still a hypervisor, and that is the fact that decides whether this tool has
    # anything useful to say.
    #
    # It doesn't, which is the point. This tool measures guest-side demand, and
    # that is meaningless on a host whose memory is consumed by its VMs - a 127GB
    # cluster node reporting 51GB committed and 78% sustained CPU is describing its
    # guests, not itself, and neither figure supports a right-sizing decision.
    # Better to say so explicitly than to emit numbers that look actionable.
    #
    # vmms exists only where the Hyper-V role is actually installed, not merely
    # available. Other hypervisors are not detected: an ESXi host never runs this
    # script (no Windows guest OS), so Hyper-V is the case that can actually reach
    # a Datto device filter.
    if ($svc.ContainsKey('vmms')) { $role = 'Hypervisor'; $flags.Add('HYPER-V') }

    [PSCustomObject]@{ Role = $role; Flags = $flags; SqlWsGB = $sqlWsGB; MySql = $mysql }
}

# ---------------------------------------------------------------------------
# Hyper-V host health
#   A hypervisor can't be right-sized from guest-side figures, but it can be
#   checked for the things that actually take hosts down: VMs stuck in a
#   critical state, host memory exhaustion, full or nearly-full VM storage,
#   stale or orphaned checkpoints, failing replication, unresponsive guests,
#   vCPU over-subscription, and a degraded cluster. All point-in-time facts
#   read from the Hyper-V and FailoverClusters modules as SYSTEM - no history,
#   no login, nothing changed.
#
#   Noise is the failure mode to avoid (see UPSIZE's history), so each check
#   starts strict and documents what it deliberately ignores. Each runs in its
#   own try/catch: one failing cmdlet records an error and the rest still
#   report. A host with failed checks is flagged HV-PARTIAL so "no findings"
#   is never mistaken for "healthy" when it means "couldn't look".
# ---------------------------------------------------------------------------

# Local fixed volumes by mount point, for mapping VM disk paths to free space.
# CSVs are excluded here - they're handled once per cluster in the cluster
# check, from the cluster's own figures.
function Get-HvVolumeSpace {
    @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 3' -ErrorAction Stop |
      Where-Object { $_.Name -and $_.Name -notlike '\\?\*' -and $_.Capacity -gt 0 -and $_.FileSystem -ne 'CSVFS' } |
      ForEach-Object {
          [PSCustomObject]@{
              Name   = $_.Name
              SizeGB = [math]::Round($_.Capacity / 1GB, 1)
              FreeGB = [math]::Round($_.FreeSpace / 1GB, 1)
          }
      })
}

function Get-HyperVHealth {
    param(
        [double]$AvailableGB    = -1,   # root partition Available MBytes, from the caller
        [int]   $CheckpointDays = 3,    # standard/production checkpoints older than this
        [double]$MinFreePct     = 12,   # VM volume free space below this
        [double]$MaxVcpuRatio   = 4     # running vCPU : logical processor
    )

    $findings = @{}   # priority -> list, so the most actionable sort first
    foreach ($p in 1..8) { $findings[$p] = New-Object System.Collections.Generic.List[string] }
    $flags    = New-Object System.Collections.Generic.List[string]
    $errors   = New-Object System.Collections.Generic.List[string]
    $result   = [ordered]@{
        Unavailable = ''; Findings = @(); Flags = @(); Errors = @()
        VmCount = 0; Running = 0; MemoryGB = $null; AssignedGB = 0
        LogicalProcs = $null; VcpuRunning = 0; VcpuRatio = $null; ClusterName = ''
    }
    $add = {
        param([int]$Priority, [string]$Flag, [string]$Text)
        $findings[$Priority].Add($Text)
        if (-not $flags.Contains($Flag)) { $flags.Add($Flag) }
    }

    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        try { Import-Module Hyper-V -ErrorAction Stop } catch { }
    }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        $result.Unavailable = 'Hyper-V PowerShell module not installed (RSAT-Hyper-V-Tools)'
        return [PSCustomObject]$result
    }

    # Host capacity from the hypervisor, not the root partition: on a Hyper-V
    # host the management OS's own CPU/memory view excludes its guests.
    try {
        $vmHost = Get-VMHost -ErrorAction Stop
        $result.MemoryGB     = [math]::Round($vmHost.MemoryCapacity / 1GB, 1)
        $result.LogicalProcs = [int]$vmHost.LogicalProcessorCount
    } catch { $errors.Add("host: $($_.Exception.Message)") }

    try {
        $vms = @(Get-VM -ErrorAction Stop)
    } catch {
        $result.Unavailable = "Get-VM failed: $($_.Exception.Message)"
        return [PSCustomObject]$result
    }
    $running = @($vms | Where-Object { "$($_.State)" -eq 'Running' })
    # Replica VMs carry recovery points and .avhdx files by design, so every
    # checkpoint-based check would flag them. Their health is the replication
    # check's job.
    $primary = @($vms | Where-Object { "$($_.ReplicationMode)" -ne 'Replica' })

    $result.VmCount    = $vms.Count
    $result.Running    = $running.Count
    $result.AssignedGB = [math]::Round((($running | Measure-Object -Property MemoryAssigned -Sum).Sum) / 1GB, 1)
    $result.VcpuRunning = [int](($running | Measure-Object -Property ProcessorCount -Sum).Sum)

    # 1. VMs in a critical state. PausedCritical almost always means the
    #    volume under the VM is full or gone - an outage in progress.
    try {
        $critical = @($vms | Where-Object { "$($_.State)" -match 'Critical$' })
        if ($critical.Count -gt 0) {
            $names = ($critical | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ', '
            & $add 1 'HV-CRITICAL' "VM critical: $names"
        }
    } catch { $errors.Add("critical: $($_.Exception.Message)") }

    # 2. Host memory headroom - can the host still start or restart VMs? Root
    #    Available MBytes excludes memory assigned to running VMs. 5% of
    #    capacity, between 2GB and 8GB: Hyper-V wants a few GB for the root
    #    partition and VM worker processes, and that need doesn't scale with
    #    the host - uncapped, 5% of a deliberately packed 256GB host is 12.8GB
    #    and a healthy host would flag.
    try {
        if ($AvailableGB -ge 0 -and $result.MemoryGB) {
            $minFree = [math]::Min(8, [math]::Max(2, $result.MemoryGB * 0.05))
            if ($AvailableGB -lt $minFree) {
                & $add 2 'HV-MEM' "host memory low: ${AvailableGB}GB free of $($result.MemoryGB)GB (VMs assigned $($result.AssignedGB)GB)"
            }
        }
    } catch { $errors.Add("memory: $($_.Exception.Message)") }

    # 3. Cluster - reported by ONE node only (the owner of the core cluster
    #    group), or every node would show the same finding in the grid. Gated
    #    on the cluster service actually running: Get-Cluster on a standalone
    #    host fails rather than returning nothing.
    try {
        $clusSvc = Get-Service -Name ClusSvc -ErrorAction SilentlyContinue
        if ($clusSvc -and "$($clusSvc.Status)" -eq 'Running' -and (Get-Command Get-Cluster -ErrorAction SilentlyContinue)) {
            $result.ClusterName = [string](Get-Cluster -ErrorAction Stop).Name
            $coreOwner = [string](Get-ClusterGroup -Name 'Cluster Group' -ErrorAction Stop).OwnerNode.Name
            if ($coreOwner -eq $env:COMPUTERNAME) {
                $notUp = @(Get-ClusterNode -ErrorAction Stop | Where-Object { "$($_.State)" -ne 'Up' })
                if ($notUp.Count -gt 0) {
                    & $add 3 'HV-CLUSTER' ("node " + (($notUp | ForEach-Object { "$($_.Name) $($_.State)" }) -join ', '))
                }
                foreach ($csv in @(Get-ClusterSharedVolume -ErrorAction Stop)) {
                    foreach ($info in @($csv.SharedVolumeInfo)) {
                        $pct = [math]::Round([double]$info.Partition.PercentFree, 0)
                        if ($pct -lt $MinFreePct) {
                            $freeGB = [math]::Round($info.Partition.FreeSpace / 1GB, 0)
                            & $add 3 'HV-STORAGE' "CSV $($csv.Name) ${pct}% free (${freeGB}GB)"
                        }
                    }
                }
                # Redirected I/O: the CSV is being reached over the network
                # through another node - slow, and usually a storage path or
                # backup problem. Except by design: ReFS CSVs (most S2D
                # clusters) run file-system-redirected on non-owner nodes
                # permanently, as do tiered volumes, and Storage Replica volumes
                # run block-redirected. Those reasons are filtered out, or every
                # ReFS cluster would flag forever. A state with no reason
                # recorded still counts. The reason strings are Microsoft's
                # enum names, not yet confirmed on a real ReFS cluster here.
                $byDesign = @('NotFileSystemRedirected', 'NotBlockRedirected', 'FileSystemReFs', 'FileSystemTiering', 'VolumeReplicationEnabled')
                $redirected = @(Get-ClusterSharedVolumeState -ErrorAction Stop | Where-Object {
                    if ("$($_.StateInfo)" -notmatch 'Redirected') { return $false }
                    $reasons = @("$($_.FileSystemRedirectedIOReason)", "$($_.BlockRedirectedIOReason)") | Where-Object { $_ }
                    if (@($reasons).Count -eq 0) { return $true }
                    @($reasons | Where-Object { $byDesign -notcontains $_ }).Count -gt 0
                })
                if ($redirected.Count -gt 0) {
                    & $add 3 'HV-CLUSTER' ("CSV redirected: " + (($redirected | ForEach-Object { "$($_.Name) on $($_.Node)" }) -join ', '))
                }
            }
        }
    } catch { $errors.Add("cluster: $($_.Exception.Message)") }

    # Disk inventory, shared by the storage and checkpoint checks.
    $disksByVm = @{}
    foreach ($vm in $vms) {
        try { $disksByVm[$vm.Name] = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | Where-Object { $_.Path }) }
        catch { $errors.Add("disks $($vm.Name): $($_.Exception.Message)") }
    }

    # 4. VM storage on local volumes. The finding is LOW FREE SPACE on a volume
    #    holding VM disks. Dynamic-disk overcommit (maximum sizes exceeding free
    #    space) is normal thin provisioning on most hosts, so on its own it
    #    would flag nearly every one - it's reported as context on a volume
    #    that's already low. SMB paths are skipped (no local free-space figure)
    #    and CSV paths are left to the cluster check.
    try {
        $volumes = @(Get-HvVolumeSpace | Sort-Object { $_.Name.Length } -Descending)
        $paths   = @($disksByVm.Values | ForEach-Object { $_ } | ForEach-Object { $_.Path } | Sort-Object -Unique)
        $perVol  = @{}
        foreach ($path in $paths) {
            if ($path -like '\\*' -or $path -match '^[A-Za-z]:\\ClusterStorage\\') { continue }
            $vol = $volumes | Where-Object { $path.StartsWith($_.Name, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
            if (-not $vol) { continue }
            if (-not $perVol.ContainsKey($vol.Name)) { $perVol[$vol.Name] = [PSCustomObject]@{ Vol = $vol; GrowGB = 0.0 } }
            # Only dynamic disks add growth. A differencing (.avhdx) leaf's
            # Size - FileSize is the parent's virtual size again, so counting
            # it would double-count.
            try {
                $vhd = Get-VHD -Path $path -ErrorAction Stop
                if ("$($vhd.VhdType)" -eq 'Dynamic') { $perVol[$vol.Name].GrowGB += ($vhd.Size - $vhd.FileSize) / 1GB }
            } catch { }
        }
        foreach ($entry in $perVol.Values) {
            $v = $entry.Vol
            $pct = [math]::Round(100 * $v.FreeGB / $v.SizeGB, 0)
            if ($pct -lt $MinFreePct) {
                $grow = [math]::Round($entry.GrowGB, 0)
                $ctx  = if ($grow -gt $v.FreeGB) { ", dynamic disks can grow ${grow}GB" } else { '' }
                & $add 4 'HV-STORAGE' "$($v.Name.TrimEnd('\')) ${pct}% free ($($v.FreeGB)GB)$ctx"
            }
        }
    } catch { $errors.Add("storage: $($_.Exception.Message)") }

    # 5. Checkpoints. Standard/production checkpoints older than
    #    $CheckpointDays, and Recovery checkpoints (what backup products
    #    create, and should remove within the job) older than a day - a stuck
    #    one means a backup left it behind. Recovery is queried explicitly as
    #    well as the default listing, deduplicated, so this doesn't depend on
    #    which types a given module version returns by default. Separately: a
    #    VM still running on an .avhdx with no checkpoint at all is a failed
    #    merge, and its differencing disk grows until the volume fills.
    try {
        $stale  = New-Object System.Collections.Generic.List[object]
        $orphan = New-Object System.Collections.Generic.List[string]
        $now    = Get-Date
        $recoveryOk = $true
        foreach ($vm in $primary) {
            $snaps = @{}
            $list  = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
            # Own try: -ErrorAction doesn't stop a parameter-binding error, so
            # a module without -SnapshotType would otherwise abort the whole
            # check for every VM.
            try { $list += @(Get-VMSnapshot -VM $vm -SnapshotType Recovery -ErrorAction Stop) }
            catch { $recoveryOk = $false }
            foreach ($s in $list) {
                if ($s -and "$($s.SnapshotType)" -notmatch 'Replica') { $snaps["$($s.Id)"] = $s }
            }
            foreach ($s in $snaps.Values) {
                $ageDays = ($now - $s.CreationTime).TotalDays
                $limit   = if ("$($s.SnapshotType)" -eq 'Recovery') { 1 } else { $CheckpointDays }
                if ($ageDays -gt $limit) { $stale.Add([PSCustomObject]@{ Vm = $vm.Name; Age = [int]$ageDays }) }
            }
            # Only when Recovery checkpoints could be listed: a VM mid-backup
            # runs on an .avhdx held by one, and would otherwise read as a
            # failed merge.
            if ($recoveryOk -and $snaps.Count -eq 0 -and @($disksByVm[$vm.Name] | Where-Object { $_.Path -like '*.avhdx' }).Count -gt 0) {
                $orphan.Add($vm.Name)
            }
        }
        if (-not $recoveryOk) { $errors.Add('checkpoints: Recovery checkpoints could not be listed - orphaned .avhdx check skipped') }
        if ($stale.Count -gt 0) {
            $oldest = $stale | Sort-Object Age -Descending | Select-Object -First 1
            & $add 5 'HV-CHECKPOINT' "$($stale.Count) old checkpoint(s), oldest $($oldest.Age)d on $($oldest.Vm)"
        }
        if ($orphan.Count -gt 0) {
            & $add 5 'HV-CHECKPOINT' ("running on .avhdx with no checkpoint (failed merge): " + ($orphan -join ', '))
        }
    } catch { $errors.Add("checkpoints: $($_.Exception.Message)") }

    # 6. Hyper-V Replica health. Get-VMReplication returns nothing on a host
    #    with no replication configured.
    try {
        $bad = @(Get-VMReplication -ErrorAction Stop | Where-Object { "$($_.Health)" -match '^(Critical|Warning)$' })
        if ($bad.Count -gt 0) {
            & $add 6 'HV-REPLICA' ("replication " + (($bad | ForEach-Object { "$($_.VMName) $($_.Health)" }) -join ', '))
        }
    } catch { $errors.Add("replication: $($_.Exception.Message)") }

    # 7. Guests not responding. LostCommunication / Error always count.
    #    NoContact is normal for appliances and Linux guests without
    #    integration services, so it only counts when the VM has been up over
    #    an hour AND its heartbeat service is enabled (i.e. it should answer).
    try {
        $silent = New-Object System.Collections.Generic.List[string]
        foreach ($vm in @($running | Where-Object { "$($_.ReplicationMode)" -ne 'Replica' })) {
            $hb = "$($vm.Heartbeat)"
            if ($hb -match '^(LostCommunication|Error)$') { $silent.Add($vm.Name); continue }
            if ($hb -eq 'NoContact' -and $vm.Uptime.TotalHours -gt 1) {
                $svcHb = Get-VMIntegrationService -VM $vm -Name 'Heartbeat' -ErrorAction SilentlyContinue
                if ($svcHb -and $svcHb.Enabled) { $silent.Add($vm.Name) }
            }
        }
        if ($silent.Count -gt 0) { & $add 7 'HV-GUEST' ("no heartbeat: " + ($silent -join ', ')) }
    } catch { $errors.Add("heartbeat: $($_.Exception.Message)") }

    # 8. vCPU over-subscription across running VMs. Above 4:1 VMs start
    #    queuing for physical cores; above 8:1 expect real contention. A
    #    reasoned starting point - calibrate against the estate.
    try {
        if ($result.LogicalProcs -gt 0) {
            $result.VcpuRatio = [math]::Round($result.VcpuRunning / $result.LogicalProcs, 1)
            if ($result.VcpuRatio -gt $MaxVcpuRatio) {
                & $add 8 'HV-CPU-RATIO' "vCPU $($result.VcpuRatio):1 ($($result.VcpuRunning) on $($result.LogicalProcs) LP)"
            }
        }
    } catch { $errors.Add("vcpu: $($_.Exception.Message)") }

    if ($errors.Count -gt 0) { $flags.Add('HV-PARTIAL') }
    $result.Findings = @(foreach ($p in 1..8) { $findings[$p] })
    $result.Flags    = @($flags)
    $result.Errors   = @($errors)
    [PSCustomObject]$result
}

# Runs Get-HyperVHealth in 64-bit PowerShell. The Hyper-V module only loads in
# a 64-bit process, and this script runs inside whatever process Datto's
# component runner uses - so from a 32-bit host on a 64-bit OS, re-run the
# health functions through sysnative and read the result back as JSON, rather
# than reporting "module missing" on every hypervisor. Never throws: any
# failure comes back as Unavailable, and the caller flags it.
function Invoke-HyperVHealth {
    param([double]$AvailableGB)
    try {
        if ([Environment]::Is64BitProcess -or -not [Environment]::Is64BitOperatingSystem) {
            return Get-HyperVHealth -AvailableGB $AvailableGB
        }
        $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
        $tmp  = Join-Path $env:TEMP ("arc-hvhealth-{0}.ps1" -f $PID)
        $body = foreach ($name in 'Get-HvVolumeSpace', 'Get-HyperVHealth') {
            "function $name {`r`n$((Get-Command $name).ScriptBlock)`r`n}"
        }
        # Invariant culture: a locale with a decimal comma would turn 3,5 into
        # an array argument
        $availText = $AvailableGB.ToString([Globalization.CultureInfo]::InvariantCulture)
        $body += "Get-HyperVHealth -AvailableGB $availText | ConvertTo-Json -Depth 4 -Compress"
        Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8
        try {
            $json = & $ps64 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        $parsed = ($json | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json
        if (-not $parsed) { throw '64-bit health run returned no result' }
        $parsed
    } catch {
        [PSCustomObject]@{
            Unavailable = "health check failed: $($_.Exception.Message)"; Findings = @(); Flags = @(); Errors = @()
            VmCount = 0; Running = 0; MemoryGB = $null; AssignedGB = 0
            LogicalProcs = $null; VcpuRunning = 0; VcpuRatio = $null; ClusterName = ''
        }
    }
}

# Whole findings joined with '; ', most actionable first, as many as fit the
# budget - always at least one - then a pointer to the flags for the rest
# (every finding sets one). Same helper as Read-ArcCapacityBuffer.ps1.
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
    $mysql    = $roleInfo.MySql
    $mysqlDetail = if ($mysql) {
        $bpText = if ($null -ne $mysql.BufferPoolGB) { "$($mysql.BufferPoolGB)GB" } else { "? ($($mysql.BufferPoolSource))" }
        "mysqld $($mysql.PrivateGB)GB, buffer pool $bpText"
    } else { '' }

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
    # Available memory is the primary evidence; the commit ratio never triggers on
    # its own. Committed bytes counts reservations the pagefile can back, and much
    # committed memory is never touched, so a host can sit well above its
    # allocation with plenty of memory free and no performance consequence. Two
    # successive runs on a real estate proved that the hard way: a ratio-only rule
    # at 90% flagged a 96GB host holding 35% available, and tightening it to 100%
    # still flagged the same host (108% commit, 30% available) plus three 32GB
    # session hosts at 23-30% available. Commit charge routinely exceeds RAM on
    # RDSH.
    #
    #   available < 1GB           - the OS is genuinely short of memory right now,
    #                               whatever the ratio says. Deliberately the same
    #                               metric and threshold Component 2 uses for
    #                               MEM-PRESSURE (Read-ArcCapacityBuffer.ps1:
    #                               availMin < 1.0), so the two components cannot
    #                               disagree about what "under memory pressure"
    #                               means. This is what catches hosts the ratio
    #                               misses entirely - S2D-DC02, a DC on 3GB with
    #                               0.37GB available, sits at only 88% commit.
    #
    #   commit > allocation AND   - over-committed AND with little headroom left.
    #   available < 20%             The second clause is what stops a busy session
    #                               host being called distressed while a quarter of
    #                               its memory is free.
    #
    # Reported, never sized: the screen says "look at this", and Component 2's
    # growth-sizing produces the actual number from a real window.
    $OverCommitAvailFraction = 0.20

    $lowAvailAbs     = ($availableGB -lt 1.0)
    $exceedsAlloc    = ($allocatedGB -gt 0) -and ($committedGB -gt $allocatedGB)
    $overCommitTight = $exceedsAlloc -and ($availableGB -lt ($allocatedGB * $OverCommitAvailFraction))
    $overCommitted   = $lowAvailAbs -or $overCommitTight

    # Hyper-V hosts get the host health checks instead of guest-side screening.
    $hv = $null
    if ($role -eq 'Hypervisor') {
        $hv = Invoke-HyperVHealth -AvailableGB $availableGB
        foreach ($f in @($hv.Flags)) { if ($f -and -not $flags.Contains([string]$f)) { $flags.Add([string]$f) } }
        if ($hv.Unavailable) { $flags.Add('HV-NO-DATA') }
    }

    if ($overCommitted -and $role -ne 'Hypervisor') {
        $flags.Add('UPSIZE')
        $pctOfAlloc  = if ($allocatedGB -gt 0) { [math]::Round(100 * $committedGB / $allocatedGB, 0) } else { 0 }
        $roleContext = if ($role -eq 'MySQL') {
            # An over-sized buffer pool is a common cause on these hosts, and
            # the fix is then lowering it rather than adding RAM. Kept short:
            # Custom73 also carries the flags and timestamp within 255 chars.
            " | MySQL ($mysqlDetail) - check pool first"
        } elseif ($RamExcludedRoles -contains $role) { " | $role - confirm against the platform-specific metrics" } else { '' }

        # Name what actually fired. The two triggers mean different things to
        # whoever reads the UDF - "the OS is out of memory now" versus
        # "over-committed and nearly out of headroom" - and reporting only a
        # commit percentage made the first look like the second, or on a
        # sub-100% host look like a mistake. Phrased so available memory is
        # never mentioned twice.
        $availPct = if ($allocatedGB -gt 0) { [math]::Round(100 * $availableGB / $allocatedGB, 0) } else { 0 }

        $reason = if ($lowAvailAbs -and $exceedsAlloc) {
            "commit ${committedGB}GB exceeds ${allocatedGB}GB allocated (${pctOfAlloc}%); only ${availableGB}GB available"
        } elseif ($lowAvailAbs) {
            "only ${availableGB}GB available"
        } else {
            "commit ${committedGB}GB exceeds ${allocatedGB}GB allocated (${pctOfAlloc}%) with only ${availableGB}GB (${availPct}%) available"
        }
        $verdict = "UPSIZE - $reason - no reclaim headroom${roleContext}"
    }
    elseif ($role -eq 'Hypervisor') {
        # Guest-side right-sizing doesn't apply to a hypervisor, so the host
        # health checks take its place. Over-commitment still raises the
        # UPSIZE flag and result field, but its guest-oriented wording is
        # replaced by HV-MEM, which reads the same shortage in host terms.
        # The verdict text itself is built at the write-back, once every flag
        # is known, since findings share Custom73's 255 characters with them.
        # Absolute trigger only: the commit-ratio branch reads root-partition
        # commit, which doesn't describe a host whose memory belongs to its
        # VMs - and the ratio is what produced every earlier UPSIZE false
        # positive. HV-MEM carries the host-level shortage.
        if ($lowAvailAbs) { $flags.Add('UPSIZE') }
        $verdict = if ($hv.Unavailable) {
            "NO SCREEN - Hyper-V host, health checks unavailable: $($hv.Unavailable)"
        } elseif (@($hv.Findings).Count -eq 0) {
            $partial = if (@($hv.Errors).Count) { " ($(@($hv.Errors).Count) check(s) failed - see job output)" } else { '' }
            "HYPER-V OK - $($hv.VmCount) VMs, $($hv.Running) running, no findings$partial"
        } else {
            ''   # filled in at the write-back
        }
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
        } elseif ($role -eq 'MySQL') {
            " ($mysqlDetail)"
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
        if ($role -eq 'Hypervisor') {
            # A hypervisor's CPU is its guests' demand - flagging it read as
            # actionable on three busy cluster nodes when it wasn't. Same rule
            # as Component 2.
            $n += ' | Hyper-V host - describes its guests'
        }
        elseif ($avgCpuPct -ge 70) {
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

    # Hyper-V hosts: the same four UDFs carry host content instead - host
    # memory and what its VMs hold, and logical processors against running
    # vCPU. The root partition's own figures would describe neither.
    if ($hv -and -not $hv.Unavailable) {
        $memText = if ($hv.MemoryGB) { "$($hv.MemoryGB)GB" } else { "${allocatedGB}GB" }
        $ramText = 'Host {0} | {1}/{2} VMs running, assigned {3}GB | Avail {4}GB | Up {5}' -f `
                   $memText, $hv.Running, $hv.VmCount, $hv.AssignedGB, $availableGB, $uptimeText
        $cpuText = if ($hv.LogicalProcs) {
            '{0} LP | {1} vCPU on running VMs = {2}:1' -f $hv.LogicalProcs, $hv.VcpuRunning, $hv.VcpuRatio
        } else { "$($hv.VcpuRunning) vCPU on running VMs | host LP count unavailable" }
        if (-not $verdict) {
            $stamp   = Get-Date -Format 'dd/MM/yyyy HH:mm'
            $head    = 'HYPER-V ATTENTION - '
            # Less 18 for Format-Findings' '(+N, see flags)' suffix, which is
            # added after the budget check - without it the cut fell on the
            # timestamp, which is how a stale UDF gets spotted
            $budget  = 255 - $head.Length - (' | ' + ($flags -join ',') + ' | ' + $stamp).Length - 18
            $verdict = $head + (Format-Findings -Findings @($hv.Findings) -Budget ([math]::Max(40, $budget)))
        }
    }

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
                MySqlPrivateGB = $(if ($mysql) { $mysql.PrivateGB } else { $null })
                InnoDbPoolGB  = $(if ($mysql) { $mysql.BufferPoolGB } else { $null })
                Verdict       = $verdict
                vCPU          = $vCPU
                AvgCpuPct     = $avgCpuPct
                EffCores      = $effCores
                TopPeakWs     = $topText
                HvCluster     = $(if ($hv) { $hv.ClusterName } else { $null })
                HvHostMemGB   = $(if ($hv) { $hv.MemoryGB } else { $null })
                HvVms         = $(if ($hv) { $hv.VmCount } else { $null })
                HvRunning     = $(if ($hv) { $hv.Running } else { $null })
                HvAssignedGB  = $(if ($hv) { $hv.AssignedGB } else { $null })
                HvLogicalProcs = $(if ($hv) { $hv.LogicalProcs } else { $null })
                HvVcpuRunning = $(if ($hv) { $hv.VcpuRunning } else { $null })
                HvVcpuRatio   = $(if ($hv) { $hv.VcpuRatio } else { $null })
                HvFindings    = $(if ($hv) { @($hv.Findings) -join '; ' } else { $null })
                HvErrors      = $(if ($hv) { (@($hv.Errors) + @($hv.Unavailable | Where-Object { $_ })) -join '; ' } else { $null })
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
    if ($hv) {
        foreach ($f in @($hv.Findings)) { Write-Output "HV finding: $f" }
        foreach ($e in @($hv.Errors))   { Write-Output "HV error  : $e" }
        if ($hv.ClusterName) { Write-Output "Cluster   : $($hv.ClusterName) (cluster-wide checks run on the core group owner only)" }
    }
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
    # From the flag, not $overCommitted: on a hypervisor only the absolute
    # trigger raises UPSIZE, and the field must agree with the flag
    Write-Output ('ScreenUpsize=' + $(if ($flags -contains 'UPSIZE') { '1' } else { '0' }))
    Write-Output ('ScreenCpuPressure=' + $(if ($flags -contains 'CPU-PRESSURE') { '1' } else { '0' }))
    # Own field for the same reason as ScreenUpsize - the stub ignores it
    Write-Output ('ScreenHvFindings=' + $(if ($hv) { @($hv.Findings).Count } else { '' }))
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
