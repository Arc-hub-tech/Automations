<#
    Arc-CapacitySampler.ps1
    Datto capacity sampling toolset

    Purpose : Single-shot capacity sample written to a rolling CSV ring buffer.
              Invoked by scheduled task 'Arc Capacity Sampler' every 15 minutes.
              Not a Datto component - deployed to disk by Deploy-ArcCapacitySampler.ps1

    Metrics : Memory  - Committed Bytes (real private demand), Available MBytes,
                        hard fault rate. Deliberately NOT FreePhysicalMemory, which
                        counts the standby list as consumed and understates reclaim.
              CPU     - total utilisation, highest single-core utilisation, and
                        processor queue length. Max-core is what protects
                        single-threaded workloads from being cut on a low total.
              SQL     - Total/Target Server Memory and Page Life Expectancy where
                        an instance is present, so SQL hosts stay actionable.

    Notes   : Uses CIM performance classes rather than Get-Counter for the core
              metrics - locale independent, no counter-name translation issues,
              one query per class.

              Skips the sample entirely (exit 0, logged) if the buffer's drive has
              less than $MinFreeMB (default 500MB) free - not to relieve the disk,
              the buffer/log footprint is trivial either way, but to fail clean
              rather than repeat a write error every 15 minutes. Datto's own
              low-disk-space monitor is the actual alert for that condition.

    Version : 1.6  -  19/08/2026  (ring buffer now actually trims - the row count driving the
              trim test used Get-Content -ReadCount 0, which returns the file as a single
              array object, so the count was permanently 0 and retention was never enforced.
              Recommendations were unaffected; the buffer just grew without bound)

    Version : 1.5  -  18/08/2026  (directory creation now fails clean instead of throwing
              on a critically-low first install; SQL counter cache no longer locks in a
              total resolution failure for 30 days; disk guard skips UNC/non-drive paths
              by pattern check instead of relying on a caught exception; removed the
              company-name header credit and the internal team byline for public-repo
              visibility)
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BufferPath      = 'C:\ProgramData\Arc\CapacitySampler\samples.csv',
    [int]   $RetentionDays   = 14,
    [int]   $IntervalMinutes = 15,
    [int]   $MinFreeMB       = 500
)

$ErrorActionPreference = 'Stop'
# StrictMode deliberately not enabled - CIM performance classes vary in which
# properties exist across 2012R2 through 2025, and strict property checking
# turns a missing counter into a hard failure rather than a null field.

# --- Ring buffer size -------------------------------------------------------
$ringSize = [int](($RetentionDays * 24 * 60) / $IntervalMinutes)

$bufferDir = Split-Path -Path $BufferPath -Parent
if (-not (Test-Path -LiteralPath $bufferDir)) {
    # Not wrapped by the low disk space guard below (that needs $bufferDir to
    # already exist to log to it) - if the directory itself can't be created
    # (e.g. the install folder was removed externally while the drive is
    # already critically low), fail the same clean way the guard does rather
    # than letting an unhandled exception crash the run.
    try {
        New-Item -Path $bufferDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Output "Sampler skipped: could not create $bufferDir ($($_.Exception.Message))"
        exit 0
    }
}

$logPath   = Join-Path $bufferDir 'sampler.log'
$sqlCache  = Join-Path $bufferDir 'sqlcounters.json'
$CacheDays = 30      # re-resolve counter set names monthly to pick up new instances

function Write-SamplerLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  [{1}]  {2}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        # Trim log to last 500 lines occasionally
        if ((Get-Item -LiteralPath $logPath).Length -gt 200KB) {
            $keep = Get-Content -LiteralPath $logPath -Tail 500
            Set-Content -LiteralPath $logPath -Value $keep -Encoding UTF8
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Low disk space guard
#   The buffer/log footprint is trivial (a few hundred KB), so this isn't
#   about the sampler's own contribution to a full disk - it's about not
#   throwing an ugly, repeating write failure every 15 minutes if the drive
#   is already critically low, and not doing the ring-trim's temp-file
#   rewrite when space is tight. Datto already has its own low-disk-space
#   monitor/alert for the actual incident, so this only needs to skip
#   cleanly and log why - not raise a second alert.
# ---------------------------------------------------------------------------
$driveRoot = [System.IO.Path]::GetPathRoot($BufferPath)
$freeMB    = $null

if ($driveRoot -match '^[A-Za-z]:\\?$') {
    # System.IO.DriveInfo only accepts a local drive letter - a UNC BufferPath
    # (or any other non-drive-letter root) would throw here. Check the shape
    # first rather than relying on catching that: same fail-open result (the
    # guard is cosmetic - see above - so treating "can't tell" as "assume fine"
    # is deliberate, not a UNC-specific bug), but as an intentional path
    # instead of exception-driven control flow.
    try {
        $freeMB = [math]::Round((New-Object System.IO.DriveInfo($driveRoot)).AvailableFreeSpace / 1MB, 0)
    } catch {
        Write-SamplerLog "Could not read free space on $driveRoot : $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-SamplerLog "Low disk guard not applicable - BufferPath root '$driveRoot' isn't a local drive letter" 'WARN'
}

if ($null -ne $freeMB -and $freeMB -lt $MinFreeMB) {
    Write-SamplerLog "Sample skipped - $driveRoot has ${freeMB}MB free, below the ${MinFreeMB}MB guard threshold" 'WARN'
    Write-Output "Sampler skipped: $driveRoot critically low on space (${freeMB}MB free, threshold ${MinFreeMB}MB)"
    exit 0
}

# ---------------------------------------------------------------------------
# SQL counter set resolution, cached
#   Get-Counter -ListSet enumerates every counter set on the box, which costs
#   1-3 seconds. The instance name does not change between samples, so it is
#   resolved once and cached to a sidecar. Refreshed monthly, and invalidated
#   immediately if a cached path stops resolving (instance removed or renamed).
# ---------------------------------------------------------------------------
function Get-SqlCounterCache {
    param([string]$Path, [int]$MaxAgeDays)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($cache.SchemaVersion -ne 1) { return $null }

        $resolved = [datetime]::MinValue
        if (-not [datetime]::TryParse($cache.ResolvedOn, [ref]$resolved)) { return $null }
        if (((Get-Date) - $resolved).TotalDays -gt $MaxAgeDays) { return $null }

        return $cache
    } catch {
        return $null
    }
}

function Save-SqlCounterCache {
    param([string]$Path, $Cache)
    try {
        $Cache | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Write-SamplerLog "Could not write SQL counter cache: $($_.Exception.Message)" 'WARN'
    }
}

function Resolve-SqlCounterSets {
    $result = [PSCustomObject]@{
        SchemaVersion = 1
        ResolvedOn    = (Get-Date).ToString('o')
        MemorySet     = $null
        BufferSet     = $null
    }
    try {
        $memSets = @(Get-Counter -ListSet '*:Memory Manager' -ErrorAction Stop)
        if ($memSets.Count -gt 0) { $result.MemorySet = $memSets[0].CounterSetName }
    } catch {
        Write-SamplerLog "Memory Manager counter set not found: $($_.Exception.Message)" 'WARN'
    }
    try {
        $bufSets = @(Get-Counter -ListSet '*:Buffer Manager' -ErrorAction Stop)
        if ($bufSets.Count -gt 0) { $result.BufferSet = $bufSets[0].CounterSetName }
    } catch {
        Write-SamplerLog "Buffer Manager counter set not found: $($_.Exception.Message)" 'WARN'
    }
    $result
}

# --- Helper: safe CIM query -------------------------------------------------
function Get-CimSafe {
    param([string]$ClassName, [string]$Filter)
    try {
        if ($Filter) { Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop }
        else         { Get-CimInstance -ClassName $ClassName -ErrorAction Stop }
    } catch {
        Write-SamplerLog "CIM query failed for $ClassName : $($_.Exception.Message)" 'WARN'
        $null
    }
}

try {
    # =======================================================================
    # Static facts
    # =======================================================================
    $os = Get-CimSafe -ClassName 'Win32_OperatingSystem'
    $cs = Get-CimSafe -ClassName 'Win32_ComputerSystem'

    if (-not $os -or -not $cs) { throw 'Unable to read base OS/computer system information.' }

    $allocatedGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $vCPU        = [int]$cs.NumberOfLogicalProcessors
    if ($vCPU -lt 1) { $vCPU = 1 }

    # =======================================================================
    # Memory sample
    # =======================================================================
    $mem = Get-CimSafe -ClassName 'Win32_PerfFormattedData_PerfOS_Memory'

    $committedGB = $null
    $availableGB = $null
    $hardFaults  = $null

    if ($mem) {
        $committedGB = [math]::Round([double]$mem.CommittedBytes / 1GB, 3)
        $availableGB = [math]::Round([double]$mem.AvailableMBytes / 1KB, 3)
        $hardFaults  = [math]::Round([double]$mem.PagesInputPerSec, 1)
    }

    # =======================================================================
    # CPU sample
    #   First CIM read of the processor class can return stale or zero values,
    #   so take two reads a second apart and use the second.
    # =======================================================================
    $null = Get-CimSafe -ClassName 'Win32_PerfFormattedData_PerfOS_Processor'
    Start-Sleep -Seconds 2
    $proc = Get-CimSafe -ClassName 'Win32_PerfFormattedData_PerfOS_Processor'

    $cpuTotalPct   = $null
    $cpuMaxCorePct = $null

    if ($proc) {
        $total = $proc | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        $cores = $proc | Where-Object { $_.Name -ne '_Total' }

        if ($total) { $cpuTotalPct = [math]::Round([double]$total.PercentProcessorTime, 1) }

        if ($cores) {
            $maxCore = ($cores | Measure-Object -Property PercentProcessorTime -Maximum).Maximum
            $cpuMaxCorePct = [math]::Round([double]$maxCore, 1)
        }
    }

    # Processor queue length - threads waiting for a core
    $sys       = Get-CimSafe -ClassName 'Win32_PerfFormattedData_PerfOS_System'
    $procQueue = if ($sys) { [int]$sys.ProcessorQueueLength } else { $null }

    # =======================================================================
    # RDSH session count (only meaningful where the role is present)
    # =======================================================================
    $activeSessions = $null
    $ts = Get-CimSafe -ClassName 'Win32_PerfFormattedData_TermService_TerminalServices'
    if ($ts) { $activeSessions = [int]$ts.ActiveSessions }

    # =======================================================================
    # SQL Server supplementary metrics
    #   Committed bytes on a SQL host reports the configured max server memory,
    #   not the requirement. Total/Target Server Memory plus Page Life
    #   Expectancy is what makes those hosts right-sizeable.
    # =======================================================================
    $sqlTotalGB  = $null
    $sqlTargetGB = $null
    $sqlPLE      = $null

    $sqlPresent = @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' }).Count -gt 0

    if ($sqlPresent) {
        $cache = Get-SqlCounterCache -Path $sqlCache -MaxAgeDays $CacheDays
        if (-not $cache) {
            $cache = Resolve-SqlCounterSets
            if ($cache.MemorySet -or $cache.BufferSet) {
                Save-SqlCounterCache -Path $sqlCache -Cache $cache
                Write-SamplerLog ("Resolved SQL counter sets - memory '{0}', buffer '{1}'" -f `
                    $cache.MemorySet, $cache.BufferSet)
            } else {
                # Neither counter set resolved - most likely SQL's perf counters
                # aren't registered yet (e.g. moments after install/reboot).
                # Don't cache a total failure for 30 days; retry on the next
                # 15-minute sample instead, since this is expected to be transient.
                Write-SamplerLog 'No SQL counter sets resolved - will retry next sample rather than caching the failure' 'WARN'
            }
        }

        $cacheStale = $false

        if ($cache.MemorySet) {
            try {
                $paths = @(
                    "\$($cache.MemorySet)\Total Server Memory (KB)"
                    "\$($cache.MemorySet)\Target Server Memory (KB)"
                )
                foreach ($s in (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples) {
                    if ($s.Path -like '*total server memory*')  { $sqlTotalGB  = [math]::Round($s.CookedValue / 1MB, 3) }
                    if ($s.Path -like '*target server memory*') { $sqlTargetGB = [math]::Round($s.CookedValue / 1MB, 3) }
                }
            } catch {
                $cacheStale = $true
                Write-SamplerLog "Memory Manager read failed: $($_.Exception.Message)" 'WARN'
            }
        }

        if ($cache.BufferSet) {
            try {
                $pleCounter = "\$($cache.BufferSet)\Page life expectancy"
                $sqlPLE = [int](Get-Counter -Counter $pleCounter -ErrorAction Stop).CounterSamples[0].CookedValue
            } catch {
                $cacheStale = $true
                Write-SamplerLog "Buffer Manager read failed: $($_.Exception.Message)" 'WARN'
            }
        }

        # A cached path that no longer resolves means the instance changed.
        # Drop the cache so the next sample rediscovers rather than failing forever.
        if ($cacheStale -and (Test-Path -LiteralPath $sqlCache)) {
            Remove-Item -LiteralPath $sqlCache -Force -ErrorAction SilentlyContinue
            Write-SamplerLog 'SQL counter cache invalidated - will rediscover on next sample.' 'WARN'
        }
    }

    # =======================================================================
    # Emit sample
    # =======================================================================
    $sample = [PSCustomObject][ordered]@{
        Timestamp      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')   # sortable; presentation layer formats DD/MM/YYYY
        AllocatedGB    = $allocatedGB
        CommittedGB    = $committedGB
        AvailableGB    = $availableGB
        HardFaultsSec  = $hardFaults
        vCPU           = $vCPU
        CpuTotalPct    = $cpuTotalPct
        CpuMaxCorePct  = $cpuMaxCorePct
        ProcQueue      = $procQueue
        ActiveSessions = $activeSessions
        SqlTotalGB     = $sqlTotalGB
        SqlTargetGB    = $sqlTargetGB
        SqlPLE         = $sqlPLE
    }

    # Append, then trim the ring. Header written on first run only.
    # Export-Csv -Append throws if the object schema differs from the existing
    # header, so a revision that adds a field would break every sample from then
    # on. Detect the mismatch and rotate the old buffer aside instead.
    if (Test-Path -LiteralPath $BufferPath) {
        $expectedHeader = '"' + (($sample.PSObject.Properties.Name) -join '","') + '"'
        $actualHeader   = (Get-Content -LiteralPath $BufferPath -TotalCount 1)

        if ($actualHeader -and ($actualHeader.Trim() -ne $expectedHeader)) {
            $archive = Join-Path $bufferDir ('samples-preschema-{0}.csv' -f (Get-Date -Format 'yyyyMMddHHmm'))
            Move-Item -LiteralPath $BufferPath -Destination $archive -Force
            Write-SamplerLog "Sample schema changed - previous buffer archived to $archive" 'WARN'
            $sample | Export-Csv -LiteralPath $BufferPath -NoTypeInformation -Encoding UTF8
        } else {
            $sample | Export-Csv -LiteralPath $BufferPath -NoTypeInformation -Append -Encoding UTF8
        }
    } else {
        $sample | Export-Csv -LiteralPath $BufferPath -NoTypeInformation -Encoding UTF8
    }

    # Trim only when meaningfully over, to avoid a full read/write every 15 minutes.
    #
    # Deliberately NOT -ReadCount 0: that emits the entire file as one array
    # object, so @(...).Count returns 1 regardless of how many rows the file
    # holds, and subtracting the header pinned $lineCount at 0 forever. The
    # comparison below was therefore always false and the ring never trimmed -
    # retention silently went unenforced and the buffer grew without bound.
    # Analysis was unaffected (Read-ArcCapacityBuffer.ps1 filters by timestamp
    # cutoff, not by buffer length), so this cost disk, not correctness.
    $lineCount = @(Get-Content -LiteralPath $BufferPath).Count - 1
    if ($lineCount -gt ($ringSize + 24)) {
        $rows = @(Import-Csv -LiteralPath $BufferPath | Select-Object -Last $ringSize)
        $tmp  = "$BufferPath.tmp"
        $rows | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $BufferPath -Force
        Write-SamplerLog "Ring trimmed from $lineCount to $ringSize samples."
    }

    Write-Output ('Sample captured: RAM {0}/{1} GB committed, CPU {2}% total / {3}% max-core' -f `
        $committedGB, $allocatedGB, $cpuTotalPct, $cpuMaxCorePct)
    exit 0
}
catch {
    Write-SamplerLog "Sample failed: $($_.Exception.Message)" 'ERROR'
    Write-Output "Sampler error: $($_.Exception.Message)"
    exit 1
}
