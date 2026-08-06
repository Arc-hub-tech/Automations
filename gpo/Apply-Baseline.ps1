<#
================================================================
 Apply-Baseline.ps1  -  Arc Systems local-policy baseline applier
================================================================
.SYNOPSIS
    Applies an Arc Systems GPO baseline to a machine's LOCAL Group Policy using
    Microsoft's LGPO.exe, then forces a policy refresh. Idempotent and safe to
    re-run - re-running simply re-asserts the baseline, which is how drift
    self-heals when this runs on a schedule (see Register-DriftTask.ps1).

    This is the LOCAL-policy path of Microsoft's own baseline model: the baseline
    is stored as a diffable LGPO text file in Git, and LGPO.exe (/t) stamps it
    into local policy. No domain, no domain controller, no Import-GPO involved.

.DESCRIPTION
    On each run the script:
      1. Ensures LGPO.exe is present (bootstraps it from Microsoft if missing).
      2. Acquires the baseline file - a local -Path if given, otherwise fetched
         fresh from the repo branch (this is the Git-as-delivery step: an edit
         merged to the branch reaches every machine on its next scheduled run).
      3. Applies it with `LGPO.exe /t <file>` and runs `gpupdate /force`.
      4. Records what/when/which-version under HKLM\SOFTWARE\Arc Systems\GpoBaseline.
    Full run is logged to C:\ArcLogs\GpoBaseline\ (transcript, timestamped per run).

.PARAMETER BaselineName
    Baseline to apply, matching a folder under gpo/baselines/. Default:
    'arc-workstation-v1'. The script looks for '<BaselineName>.lgpo.txt' inside it.

.PARAMETER Branch
    Repo branch to fetch the baseline from when not using -Path. Default: 'develop'
    (production copies fetch from 'main' - see the release-cut steps in gpo/README.md).

.PARAMETER Path
    Explicit path to a baseline artifact, overriding the remote fetch. Either an
    LGPO text file (applied with /t) or a GPO backup FOLDER (applied with /g).

.PARAMETER SkipGpUpdate
    Apply the policy but don't run `gpupdate /force` afterwards (the change then
    takes effect at the next natural policy refresh / reboot).

.NOTES
    Run elevated. LGPO writes machine-wide local policy.
    Requires PowerShell 5.1+ and internet access on first run (LGPO bootstrap) and
    for the remote baseline fetch. STATUS: new tool, not yet validated on a real
    build - review before production use.
================================================================
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$BaselineName = 'arc-workstation-v1',
    [string]$Branch       = 'develop',
    [string]$Path,
    [switch]$SkipGpUpdate
)

# Version of this tool, surfaced in the run banner/transcript so a machine's
# baseline history unambiguously records which revision applied it. The GPO
# tool versions independently of the gold-image scripts. Uses a '-dev' suffix
# while work accumulates under CHANGELOG [Unreleased]; dropped at a release cut.
$ScriptVersion = '0.1.0-dev'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# GitHub raw base for remote fetches. The org/repo matches the gold-image
# one-liners; -Branch selects develop (WIP) vs main (production).
$RepoRawBase = 'https://raw.githubusercontent.com/Arc-hub-tech/Automations'

# Microsoft LGPO.zip (Security Compliance Toolkit). If Microsoft moves this,
# update the URL or stage LGPO.exe manually - see gpo/tools/LGPO/README.md.
$LgpoDownloadUrl = 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip'

# Persistent working/tools area on the machine (distinct from the transcript logs).
$WorkRoot = "$env:ProgramData\Arc Systems\GpoBaseline"
$ToolsDir = Join-Path $WorkRoot 'tools\LGPO'
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
Set-Location -Path $WorkRoot
[Environment]::CurrentDirectory = $WorkRoot

# ---------------------------------------------------------------
# Transcript logging - one timestamped file per run, so a fleet of scheduled
# re-applies leaves an auditable history. trap closes the transcript even if a
# later step throws (ErrorActionPreference is 'Stop').
# ---------------------------------------------------------------
$LogDir  = "$env:SystemDrive\ArcLogs\GpoBaseline"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("Apply-Baseline_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null
trap { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
Write-Host "Logging this run to $LogFile" -ForegroundColor DarkGray
Write-Host ("Apply-Baseline.ps1  v{0}" -f $ScriptVersion) -ForegroundColor Cyan
Write-Host ("Baseline '{0}', branch '{1}'" -f $BaselineName, $Branch) -ForegroundColor Cyan

# Force TLS 1.2 for the Microsoft/GitHub downloads on older PowerShell hosts.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------
# Ensure LGPO.exe is available. Prefer a copy sitting next to this script
# (a local repo checkout), then the persistent tools dir, then bootstrap it
# from Microsoft. Returns the full path to LGPO.exe or throws.
# ---------------------------------------------------------------
function Get-Lgpo {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $WorkRoot }

    $candidates = @(
        (Join-Path $scriptDir 'tools\LGPO\LGPO.exe'),
        (Join-Path $ToolsDir 'LGPO.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { Write-Host "  LGPO.exe found: $c" -ForegroundColor Green; return $c }
    }

    Write-Host "  LGPO.exe not staged - bootstrapping from Microsoft..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
    $zip = Join-Path $env:TEMP ("LGPO_{0}.zip" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    try {
        Invoke-WebRequest -Uri $LgpoDownloadUrl -OutFile $zip -UseBasicParsing
        $extract = Join-Path $env:TEMP ("LGPO_extract_{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        # The zip nests LGPO.exe one folder deep (e.g. LGPO_30\LGPO.exe).
        $exe = Get-ChildItem -Path $extract -Filter 'LGPO.exe' -Recurse | Select-Object -First 1
        if (-not $exe) { throw "LGPO.exe not found inside the downloaded archive." }
        $dest = Join-Path $ToolsDir 'LGPO.exe'
        Copy-Item -Path $exe.FullName -Destination $dest -Force
        Write-Host "  LGPO.exe bootstrapped to $dest" -ForegroundColor Green
        return $dest
    } catch {
        throw ("Could not obtain LGPO.exe automatically ({0}). Download the Security " +
               "Compliance Toolkit LGPO.zip manually and place LGPO.exe in '{1}', then re-run. " +
               "See gpo/tools/LGPO/README.md." -f $_.Exception.Message, $ToolsDir)
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------
# Resolve the baseline artifact to apply. -Path wins; otherwise fetch the
# LGPO text file for -BaselineName from the branch into the working area.
# Returns a hashtable: @{ Path = <path>; Kind = 'Text'|'Backup' }.
# ---------------------------------------------------------------
function Resolve-Baseline {
    if ($Path) {
        if (-not (Test-Path $Path)) { throw "Baseline -Path '$Path' does not exist." }
        $kind = if ((Get-Item $Path).PSIsContainer) { 'Backup' } else { 'Text' }
        Write-Host "  Using local baseline ($kind): $Path" -ForegroundColor Green
        return @{ Path = $Path; Kind = $kind }
    }

    # Remote fetch of the single diffable LGPO text file for this baseline.
    $fileName = "$BaselineName.lgpo.txt"
    $url  = "$RepoRawBase/$Branch/gpo/baselines/$BaselineName/$fileName"
    $dest = Join-Path $WorkRoot $fileName
    Write-Host "  Fetching baseline from $url" -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        throw ("Could not fetch baseline '{0}' from branch '{1}' ({2}). Check the name/branch, " +
               "or pass -Path to apply a local copy." -f $BaselineName, $Branch, $_.Exception.Message)
    }
    Write-Host "  Baseline downloaded: $dest" -ForegroundColor Green
    return @{ Path = $dest; Kind = 'Text' }
}

# ---------------------------------------------------------------
# Stamp a small marker of what was applied, for audit / drift-checking without
# parsing transcripts. Best-effort - a failed marker write never fails the run.
# ---------------------------------------------------------------
function Write-BaselineMarker {
    param([string]$Name, [string]$Kind, [string]$Source)
    try {
        $key = 'HKLM:\SOFTWARE\Arc Systems\GpoBaseline'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name 'AppliedBaseline' -Value $Name
        Set-ItemProperty -Path $key -Name 'AppliedKind'     -Value $Kind
        Set-ItemProperty -Path $key -Name 'AppliedSource'   -Value $Source
        Set-ItemProperty -Path $key -Name 'AppliedUtc'      -Value ((Get-Date).ToUniversalTime().ToString('o'))
        Set-ItemProperty -Path $key -Name 'ScriptVersion'   -Value $ScriptVersion
    } catch {
        Write-Warning "Could not write the baseline marker under HKLM\SOFTWARE\Arc Systems\GpoBaseline - $($_.Exception.Message)"
    }
}

# ================================================================
# MAIN
# ================================================================
try {
    $lgpo     = Get-Lgpo
    $baseline = Resolve-Baseline

    # LGPO switch depends on the artifact kind: /t for a text file, /g for a
    # GPO backup folder. Both apply into local policy.
    $lgpoArg = if ($baseline.Kind -eq 'Backup') { '/g' } else { '/t' }
    Write-Host ("Applying baseline: LGPO.exe {0} `"{1}`"" -f $lgpoArg, $baseline.Path) -ForegroundColor Cyan

    & $lgpo $lgpoArg $baseline.Path
    if ($LASTEXITCODE -ne 0) { throw "LGPO.exe exited with code $LASTEXITCODE - baseline NOT applied cleanly." }
    Write-Host "  Baseline written to local policy." -ForegroundColor Green

    if ($SkipGpUpdate) {
        Write-Host "  -SkipGpUpdate set: not forcing a refresh (takes effect at next policy refresh/reboot)." -ForegroundColor Yellow
    } else {
        Write-Host "  Forcing policy refresh (gpupdate /force)..." -ForegroundColor DarkGray
        & gpupdate.exe /force | Out-Null
    }

    Write-BaselineMarker -Name $BaselineName -Kind $baseline.Kind -Source $baseline.Path
    Write-Host ("DONE - baseline '{0}' applied (v{1})." -f $BaselineName, $ScriptVersion) -ForegroundColor Green
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
