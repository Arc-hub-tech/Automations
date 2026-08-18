<#
    Deploy-ArcCapacitySampler.ps1
    Datto capacity sampling toolset

    DATTO RMM COMPONENT 1 of 2  -  Script (PowerShell), Windows, Devices

    Purpose : Installs Arc-CapacitySampler.ps1 to C:\ProgramData\Arc\CapacitySampler
              and registers a scheduled task to run it every 15 minutes as SYSTEM.
              Idempotent - safe to re-run on schedule or after script revision.
              Schedule this component to re-run daily (Automation -> Jobs, recurring):
              the payload is fetched fresh from git on every run and only redeployed
              if it changed, so a revision merged to the branch reaches the fleet
              within a day with no re-paste into Datto required.

    Payload source : git first - fetched from this repo's raw content on the branch
              named by usrBranch. The file attachment below is a fallback only, used
              for a device's first deploy if git is briefly unreachable; a device
              that already has the sampler installed just keeps its last-good
              payload and retries the fetch on the next scheduled run.

    Component file attachment (optional - fallback only):
              Arc-CapacitySampler.ps1

    Component input variables (all optional):
              usrBranch        String   default main  Git branch to fetch the payload from
              usrInterval      Integer  default 15    Sample interval, minutes
              usrRetention     Integer  default 14    Ring buffer depth, days
              usrUninstall     Boolean  default false Remove task and payload
              usrSeedNow       Boolean  default true   Run one sample immediately on a
                                                        fresh install only - a no-op on
                                                        an already-deployed device, so
                                                        the daily schedule doesn't force
                                                        a redundant sample every run

    Version : 1.4  -  18/08/2026  (TLS 1.2; escalates to FAILED after 7 consecutive fetch
              failures instead of an indefinite WARNING; seed-on-deploy now fires only on a
              genuinely fresh install, not every daily run; removed the company-name header
              credit, scheduled task Author field, and internal team byline for
              public-repo visibility)
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Force TLS 1.2 for the GitHub fetch on older PowerShell hosts (2012R2/2016 default
# to SSL3/TLS1.0, which raw.githubusercontent.com rejects) - same fix as gpo/Apply-Baseline.ps1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------------------
# Map Datto component variables onto locals, with defaults
# ---------------------------------------------------------------------------
function Get-DattoInt {
    param([string]$Name, [int]$Default)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $Default
}
function Get-DattoBool {
    param([string]$Name, [bool]$Default)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return ($raw.Trim() -match '^(true|1|yes)$')
}
function Get-DattoString {
    param([string]$Name, [string]$Default)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw.Trim()
}

$IntervalMinutes = Get-DattoInt    -Name 'usrInterval'  -Default 15
$RetentionDays   = Get-DattoInt    -Name 'usrRetention' -Default 14
$Uninstall       = Get-DattoBool   -Name 'usrUninstall' -Default $false
$SeedNow         = Get-DattoBool   -Name 'usrSeedNow'   -Default $true
$Branch          = Get-DattoString -Name 'usrBranch'    -Default 'main'

$RepoRawBase = 'https://raw.githubusercontent.com/Arc-hub-tech/Automations'
$InstallDir  = 'C:\ProgramData\Arc\CapacitySampler'
$ScriptName  = 'Arc-CapacitySampler.ps1'
$ScriptPath  = Join-Path $InstallDir $ScriptName
$BufferPath  = Join-Path $InstallDir 'samples.csv'
$TaskName    = 'Arc Capacity Sampler'
$TaskPath    = '\Arc\'
$FullTask    = "$TaskPath$TaskName"
$FetchStatePath = Join-Path $InstallDir 'deploy-fetch-state.json'

# A single failed fetch is a non-event (fall back and try again tomorrow). But a
# fetch that fails every single day for a week means something is genuinely
# broken (bad usrBranch, a proxy permanently blocking GitHub) rather than a
# transient blip, and that deserves to surface as a real alert instead of an
# indefinite, easy-to-ignore WARNING. 7 daily runs is long enough to absorb a
# multi-day outage without false-alarming, short enough to catch real breakage
# within about a week.
$FailureEscalationThreshold = 7

$status  = 'OK'
$details = New-Object System.Collections.Generic.List[string]

function Add-Detail { param([string]$m) $details.Add($m); Write-Output $m }

function Remove-SamplerTask {
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
        return $true
    }
    # Legacy location fallback - earlier revisions registered at root
    $legacy = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($legacy) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false
        return $true
    }
    return $false
}

try {
    # =======================================================================
    # Uninstall path
    # =======================================================================
    if ($Uninstall) {
        if (Remove-SamplerTask) { Add-Detail "Removed scheduled task $FullTask" }
        else                    { Add-Detail 'No scheduled task present' }

        if (Test-Path -LiteralPath $InstallDir) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Add-Detail "Removed $InstallDir (including collected samples)"
        }

        Write-Output ''
        Write-Output '<-Start Result->'
        Write-Output 'SamplerStatus=UNINSTALLED'
        Write-Output '<-End Result->'
        exit 0
    }

    # =======================================================================
    # Payload source - git first, file attachment as fallback
    #   Git is the source of truth for the payload. On every run (recommend
    #   scheduling this component daily) it's fetched fresh; a hash compare
    #   below then decides whether the on-device copy actually needs
    #   updating. If the fetch fails (transient network blip - devices on
    #   Datto are never air-gapped, but nothing on the internet is 100%),
    #   fall back to the file attachment for a first-time deploy, or just
    #   leave an already-installed payload untouched and try again next run
    #   rather than failing the job outright.
    # =======================================================================
    $PayloadUrl  = "$RepoRawBase/$Branch/datto-capacity-sampler/$ScriptName"
    $fetchedPath = Join-Path $env:TEMP 'ArcCapacitySampler-fetch.ps1'
    Remove-Item -LiteralPath $fetchedPath -Force -ErrorAction SilentlyContinue

    $sourcePath = $null
    $skipCopy   = $false
    $fetchError = $null

    # KEEP THIS RETRY LOOP IN SYNC with the equivalent block in
    # Invoke-ArcCapacityAnalyse.ps1 and Invoke-ArcCapacityScreen.ps1 - all three
    # are pasted separately into Datto's console with no shared file, so a fix
    # here (retry count, backoff, TLS, timeout) needs manually repeating there too.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $PayloadUrl -OutFile $fetchedPath -UseBasicParsing -ErrorAction Stop
            $sourcePath = $fetchedPath
            Add-Detail "Fetched $ScriptName from the '$Branch' branch"
            break
        } catch {
            $fetchError = $_.Exception.Message
            if ($attempt -lt 3) { Start-Sleep -Seconds (3 * $attempt) }
        }
    }

    $gitFetchSucceeded = [bool]$sourcePath

    # =======================================================================
    # Consecutive-failure tracking - so a permanently broken fetch (bad
    # usrBranch, a proxy blocking GitHub) escalates past WARNING instead of
    # repeating it forever. A one-off blip resets straight back to 0 on the
    # next successful fetch, same as before this was added.
    # =======================================================================
    $consecutiveFailures = 0
    try {
        if (Test-Path -LiteralPath $FetchStatePath) {
            $consecutiveFailures = [int]((Get-Content -LiteralPath $FetchStatePath -Raw | ConvertFrom-Json).ConsecutiveFailures)
        }
    } catch { $consecutiveFailures = 0 }

    if ($gitFetchSucceeded) {
        $consecutiveFailures = 0
    } else {
        $consecutiveFailures++
    }

    try {
        [PSCustomObject]@{ ConsecutiveFailures = $consecutiveFailures; LastRun = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $FetchStatePath -Encoding UTF8
    } catch { }

    if (-not $gitFetchSucceeded -and $consecutiveFailures -ge $FailureEscalationThreshold) {
        $status = 'FAILED'
        Add-Detail "Git fetch has now failed $consecutiveFailures days in a row - escalating to FAILED (was WARNING) so this stops being easy to miss"
    }

    if (-not $sourcePath) {
        Add-Detail "Git fetch failed after 3 attempts ($fetchError) - falling back"

        $searchRoots = @($PSScriptRoot, (Get-Location).Path, $env:CentraStageTempDir) |
                       Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                       Select-Object -Unique
        $sourceCandidates = @(
            foreach ($root in $searchRoots) {
                $candidate = Join-Path $root $ScriptName
                if (Test-Path -LiteralPath $candidate) { $candidate }
            }
        )

        if ($sourceCandidates) {
            $sourcePath = $sourceCandidates[0]
            Add-Detail 'Using the file attachment for this run'
        } elseif (Test-Path -LiteralPath $ScriptPath) {
            Add-Detail 'No attachment and git unreachable - keeping the currently installed payload unchanged'
            $sourcePath = $ScriptPath
            $skipCopy   = $true
            if ($status -ne 'FAILED') { $status = 'WARNING' }
        } else {
            throw "Could not fetch $ScriptName from git ($fetchError), and no file attachment or existing install was found."
        }
    }

    # Captured before this run touches anything - distinguishes a genuinely fresh
    # deploy from a routine daily re-check, so seeding (below) doesn't force an
    # extra off-cycle sample + 12s block on every device every day once Component
    # 1 is scheduled daily rather than monthly.
    $isFreshInstall = -not (Test-Path -LiteralPath $ScriptPath)

    # =======================================================================
    # Install directory, locked down to SYSTEM and local Administrators
    # =======================================================================
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
        Add-Detail "Created $InstallDir"
    }

    try {
        $acl = Get-Acl -LiteralPath $InstallDir
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
        foreach ($identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
            $acl.AddAccessRule(
                (New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            ) | Out-Null
        }
        Set-Acl -LiteralPath $InstallDir -AclObject $acl
    } catch {
        $status = 'WARNING'
        Add-Detail "ACL hardening skipped: $($_.Exception.Message)"
    }

    # =======================================================================
    # Copy payload (only when changed, so revisions are visible in the log)
    # =======================================================================
    if ($skipCopy) {
        Add-Detail "$ScriptName left as-is (see fallback note above)"
    } else {
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $needsCopy  = $true
        if (Test-Path -LiteralPath $ScriptPath) {
            $destHash = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash
            if ($destHash -eq $sourceHash) { $needsCopy = $false }
        }

        if ($needsCopy) {
            Copy-Item -LiteralPath $sourcePath -Destination $ScriptPath -Force
            Add-Detail "Installed $ScriptName (SHA256 $($sourceHash.Substring(0,12)))"
        } else {
            Add-Detail "$ScriptName already current"
        }
    }

    # =======================================================================
    # Scheduled task
    #   Registered from XML rather than New-ScheduledTaskTrigger. Indefinite
    #   repetition on a -Once trigger behaves inconsistently across 2012R2
    #   through 2025; the XML form is deterministic on all of them.
    # =======================================================================
    $arguments = '-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden ' +
                 "-File `"$ScriptPath`" -BufferPath `"$BufferPath`" " +
                 "-RetentionDays $RetentionDays -IntervalMinutes $IntervalMinutes"

    $startBoundary = (Get-Date).Date.AddMinutes(2).ToString('yyyy-MM-ddTHH:mm:ss')

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>Datto RMM Automation</Author>
    <Description>Samples committed memory, CPU utilisation and per-core spread to a rolling buffer for platform capacity right-sizing. Managed by Datto RMM - do not modify manually.</Description>
    <URI>$FullTask</URI>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT${IntervalMinutes}M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
    <BootTrigger>
      <Delay>PT5M</Delay>
      <Enabled>true</Enabled>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT5M</Interval>
      <Count>2</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$InstallDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    [void](Remove-SamplerTask)

    Register-ScheduledTask -Xml $taskXml -TaskName $TaskName -TaskPath $TaskPath -Force | Out-Null
    Add-Detail "Registered $FullTask - every $IntervalMinutes minutes, $RetentionDays day buffer"

    # =======================================================================
    # Seed one sample so the aggregator has something on first pass
    #   Only on a genuinely fresh install - $isFreshInstall was captured before
    #   this run touched anything. Without this gate, scheduling this component
    #   daily (recommended) would force an extra off-cycle sample plus a 12s
    #   block on every device every day, forever, instead of once at deploy.
    # =======================================================================
    if ($SeedNow -and $isFreshInstall) {
        Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
        Start-Sleep -Seconds 12
        if (Test-Path -LiteralPath $BufferPath) {
            $count = [math]::Max(0, @(Get-Content -LiteralPath $BufferPath -ReadCount 0).Count - 1)
            Add-Detail "Seed sample taken - buffer now holds $count sample(s)"
        } else {
            $status = 'WARNING'
            Add-Detail 'Seed sample produced no buffer file - check sampler.log on the device'
        }
    } elseif ($SeedNow) {
        Add-Detail 'Skipping seed sample - not a fresh install (sampler is already running on its own schedule)'
    }

    $expected = [int](($RetentionDays * 24 * 60) / $IntervalMinutes)
    Add-Detail "Buffer will reach full depth ($expected samples) in $RetentionDays days"

    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output "SamplerStatus=$status"
    Write-Output "SamplerInterval=${IntervalMinutes}m"
    Write-Output "SamplerRetention=${RetentionDays}d"
    Write-Output '<-End Result->'

    if ($status -eq 'FAILED') { exit 1 }
    exit 0
}
catch {
    Write-Output "DEPLOYMENT FAILED: $($_.Exception.Message)"
    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output 'SamplerStatus=FAILED'
    Write-Output "SamplerError=$($_.Exception.Message)"
    Write-Output '<-End Result->'
    exit 1
}
