<#
    Invoke-ArcCapacityAnalyse.ps1
    Arc (U.K.) Systems Ltd - Platform & Infrastructure

    DATTO RMM COMPONENT 2 of 3  -  Script (PowerShell), Windows, Devices

    Purpose : Bootstrap stub. This is the ONLY thing pasted into the
              "Arc - Capacity Analyse" Datto component - it fetches the current
              Read-ArcCapacityBuffer.ps1 from this repo (branch named by usrBranch)
              and runs it, so a revision to the real logic only needs a git merge,
              never a re-paste into Datto. Read-ArcCapacityBuffer.ps1 reads the same
              usr* environment variables Datto sets for this component, so they pass
              through unchanged (usrUdfBase, usrWindowDays, usrInterval,
              usrExportPath, usrConservative - see that script's own header).

    This stub itself should rarely need touching - only if the fetch mechanism
    changes (e.g. the repo moves). The logic it fetches is the thing that evolves.
    Its retry/fetch block is duplicated (not shared) in Deploy-ArcCapacitySampler.ps1
    and Invoke-ArcCapacityScreen.ps1 - see the "KEEP IN SYNC" comment below.

    On a fetch failure, runs the last successfully-fetched copy cached at
    C:\ProgramData\Arc\CapacitySampler\cache\ instead of failing the whole run -
    only fails outright if there's no cached copy yet (a component's first-ever run).

    Component input variables (in addition to Read-ArcCapacityBuffer.ps1's own):
              usrBranch   String   default main   Branch to fetch the script from -
                                                   point a pilot device at 'develop'
                                                   to test a revision before merging

    Version : 1.1  -  17/08/2026  (TLS 1.2, fail-closed exit code, last-good-copy cache fallback)
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Force TLS 1.2 for the GitHub fetch on older PowerShell hosts (2012R2/2016 default
# to SSL3/TLS1.0, which raw.githubusercontent.com rejects) - same fix as gpo/Apply-Baseline.ps1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$RepoRawBase = 'https://raw.githubusercontent.com/Arc-hub-tech/Automations'
$ScriptRelPath = 'datto-capacity-sampler/Read-ArcCapacityBuffer.ps1'

$Branch = [Environment]::GetEnvironmentVariable('usrBranch')
if ([string]::IsNullOrWhiteSpace($Branch)) { $Branch = 'main' }

$Url        = "$RepoRawBase/$Branch/$ScriptRelPath"
$WorkDir    = Join-Path $env:TEMP 'ArcCapacity'
$StagingPath = Join-Path $WorkDir 'Read-ArcCapacityBuffer.ps1.new'

# Last-known-good cache lives under ProgramData (not %TEMP%, which can be
# cleaned up by unrelated maintenance tasks) so a transient fetch failure runs
# the last successfully-fetched copy instead of skipping the whole weekly job.
$CacheDir  = 'C:\ProgramData\Arc\CapacitySampler\cache'
$CachedCopy = Join-Path $CacheDir 'Read-ArcCapacityBuffer.ps1'

if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null }
Remove-Item -LiteralPath $StagingPath -Force -ErrorAction SilentlyContinue

$fetched = $false
$lastErr = $null

# KEEP THIS RETRY LOOP IN SYNC with the equivalent blocks in
# Deploy-ArcCapacitySampler.ps1 and Invoke-ArcCapacityScreen.ps1 - all three
# are pasted separately into Datto's console with no shared file, so a fix
# here (retry count, backoff, TLS, timeout) needs manually repeating there too.
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $StagingPath -UseBasicParsing -ErrorAction Stop
        $fetched = $true
        break
    } catch {
        $lastErr = $_.Exception.Message
        if ($attempt -lt 3) { Start-Sleep -Seconds (3 * $attempt) }
    }
}

if ($fetched) {
    Copy-Item -LiteralPath $StagingPath -Destination $CachedCopy -Force
    $Local = $CachedCopy
    Write-Output "Fetched Read-ArcCapacityBuffer.ps1 from the '$Branch' branch"
} elseif (Test-Path -LiteralPath $CachedCopy) {
    $Local = $CachedCopy
    $cachedDate = (Get-Item -LiteralPath $CachedCopy).LastWriteTime
    Write-Output "Git fetch failed after 3 attempts ($lastErr) - running the last successfully-fetched copy (cached $cachedDate) instead of skipping this run"
} else {
    Write-Output "Could not fetch Read-ArcCapacityBuffer.ps1 from '$Branch' after 3 attempts: $lastErr"
    Write-Output "URL: $Url"
    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output 'CapacityStatus=FETCH_FAILED'
    Write-Output "CapacityError=$lastErr"
    Write-Output '<-End Result->'
    exit 1
}

Write-Output ''

$LASTEXITCODE = $null
& $Local

if ($null -eq $LASTEXITCODE) {
    # Every current branch of Read-ArcCapacityBuffer.ps1 calls an explicit exit,
    # but that's an implicit contract with a file that's fetched and can change
    # independently of this stub. Fail closed rather than let a future branch
    # that returns without exiting read as a silent success.
    Write-Output 'Read-ArcCapacityBuffer.ps1 returned without an exit code - treating as a failure'
    exit 1
}
exit $LASTEXITCODE
