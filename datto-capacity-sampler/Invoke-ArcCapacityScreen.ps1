<#
    Invoke-ArcCapacityScreen.ps1
    Datto capacity sampling toolset

    DATTO RMM COMPONENT 3 of 3  -  Script (PowerShell), Windows, Devices

    Purpose : Bootstrap stub. This is the ONLY thing pasted into the
              "Arc - Capacity Screen" Datto component - it fetches the current
              Get-ArcCapacityScreen.ps1 from this repo (branch named by usrBranch)
              and runs it, so a revision to the real logic only needs a git merge,
              never a re-paste into Datto. Get-ArcCapacityScreen.ps1 reads the same
              usr* environment variables Datto sets for this component, so they pass
              through unchanged (usrScreenUdfBase, usrMinUptimeHrs, usrExportPath -
              see that script's own header).

    This stub itself should rarely need touching - only if the fetch mechanism
    changes (e.g. the repo moves). The logic it fetches is the thing that evolves.
    Its retry/fetch block is duplicated (not shared) in Deploy-ArcCapacitySampler.ps1
    and Invoke-ArcCapacityAnalyse.ps1 - see the "KEEP IN SYNC" comment below.

    On a fetch failure, runs the last successfully-fetched copy cached at
    C:\ProgramData\Arc\CapacitySampler\cache\ instead of failing the whole run -
    only fails outright if there's no cached copy yet (a component's first-ever run).

    Component input variables (in addition to Get-ArcCapacityScreen.ps1's own):
              usrBranch   String   default main   Branch to fetch the script from -
                                                   point a pilot device at 'develop'
                                                   to test a revision before merging

    Version : 1.4  -  18/08/2026  (fixed a confirmed production bug on ARC-DC03:
              $LASTEXITCODE does not reliably propagate across the & $Local invocation
              in Datto's actual execution environment, so a genuinely successful run
              was being reported as a failure. Success/failure is now determined from
              the fetched script's own <-Start Result-> block - ScreenStatus whitelisted
              against known-OK values - rather than the process exit code)
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Force TLS 1.2 for the GitHub fetch on older PowerShell hosts (2012R2/2016 default
# to SSL3/TLS1.0, which raw.githubusercontent.com rejects) - same fix as gpo/Apply-Baseline.ps1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$RepoRawBase   = 'https://raw.githubusercontent.com/Arc-hub-tech/Automations'
$ScriptRelPath = 'datto-capacity-sampler/Get-ArcCapacityScreen.ps1'

$Branch = [Environment]::GetEnvironmentVariable('usrBranch')
if ([string]::IsNullOrWhiteSpace($Branch)) { $Branch = 'main' }

$Url        = "$RepoRawBase/$Branch/$ScriptRelPath"
$WorkDir    = Join-Path $env:TEMP 'ArcCapacity'
$StagingPath = Join-Path $WorkDir 'Get-ArcCapacityScreen.ps1.new'

# Last-known-good cache lives under ProgramData (not %TEMP%, which can be
# cleaned up by unrelated maintenance tasks) so a transient fetch failure runs
# the last successfully-fetched copy instead of skipping this run entirely.
$CacheDir  = 'C:\ProgramData\Arc\CapacitySampler\cache'
$CachedCopy = Join-Path $CacheDir 'Get-ArcCapacityScreen.ps1'

if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null }
Remove-Item -LiteralPath $StagingPath -Force -ErrorAction SilentlyContinue

$fetched = $false
$lastErr = $null

# KEEP THIS RETRY LOOP IN SYNC with the equivalent blocks in
# Deploy-ArcCapacitySampler.ps1 and Invoke-ArcCapacityAnalyse.ps1 - all three
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
    Write-Output "Fetched Get-ArcCapacityScreen.ps1 from the '$Branch' branch"
} elseif (Test-Path -LiteralPath $CachedCopy) {
    $Local = $CachedCopy
    $cachedDate = (Get-Item -LiteralPath $CachedCopy).LastWriteTime
    Write-Output "Git fetch failed after 3 attempts ($lastErr) - running the last successfully-fetched copy (cached $cachedDate) instead of skipping this run"
} else {
    Write-Output "Could not fetch Get-ArcCapacityScreen.ps1 from '$Branch' after 3 attempts: $lastErr"
    Write-Output "URL: $Url"
    Write-Output ''
    Write-Output '<-Start Result->'
    Write-Output 'ScreenStatus=FETCH_FAILED'
    Write-Output "ScreenError=$lastErr"
    Write-Output '<-End Result->'
    exit 1
}

Write-Output ''

# $LASTEXITCODE does not reliably propagate across this invocation in Datto's
# actual execution environment - confirmed in production (ARC-DC03): a
# genuinely successful NO_ACTION run reached its own `exit 0` and still left
# $LASTEXITCODE unset here. Whatever Datto's component runner does differs
# from a plain `powershell.exe -File` invocation in a way that breaks that
# propagation, so don't rely on it. The <-Start Result-> block Get-ArcCapacityScreen.ps1
# writes IS reliable (it's plain Write-Output, captured the same way as
# everything else this stub prints) - use that as the success/failure signal
# instead. Whitelist the known-OK statuses rather than blocklist known-bad
# ones, so a status this stub hasn't seen before (a future addition, or
# ScreenStatus=BAD_UDF_BASE, which the real script already treats as a
# failure) fails closed by default instead of silently passing.
& $Local | Tee-Object -Variable capturedOutput
$resultText = $capturedOutput -join "`n"

if ($resultText -notmatch '<-Start Result->') {
    Write-Output ''
    Write-Output 'Get-ArcCapacityScreen.ps1 produced no <-Start Result-> block - treating as a failure'
    exit 1
}
$statusMatch = [regex]::Match($resultText, 'ScreenStatus=(\S+)')
$okStatuses  = @('CANDIDATE', 'LOW_UPTIME', 'NO_ACTION')
if (-not $statusMatch.Success -or ($okStatuses -notcontains $statusMatch.Groups[1].Value)) {
    Write-Output ''
    Write-Output "Get-ArcCapacityScreen.ps1 reported ScreenStatus=$($statusMatch.Groups[1].Value) - treating as a failure"
    exit 1
}
exit 0
