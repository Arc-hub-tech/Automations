<#
================================================================
 BEFORE YOU RUN THIS SCRIPT
================================================================
 This is NOT a golden-image prep script - it's safe to run on any live,
 in-use Windows 10 or 11 machine (a new PC, an end-user laptop, a VM) any
 number of times. It does not touch local accounts, domain join,
 BitLocker, or sysprep - see gold-image/ for that.

 Open an elevated PowerShell prompt (Run as Administrator), then either:

    Option A - run this local copy of the script:

       Set-ExecutionPolicy Bypass -Scope Process -Force
       .\Debloat-Windows.ps1

    Option B - pull and run the current main-branch version directly
    (no clone needed; review the script on GitHub first if unsure):

       irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/windows-debloat/Debloat-Windows.ps1 | iex
================================================================

.SYNOPSIS
    Windows 10/11 cleanup/debloat - removes the usual detritus that comes
    with new machines. Safe to re-run; only removes/disables, never touches
    accounts, domain join, BitLocker, or security hardening.
    1. Removes bloatware appx packages - Microsoft consumer/promo apps
       (Xbox, Solitaire, Cortana, etc.) and preinstalled 3rd-party promo
       apps (Spotify, Netflix, TikTok, Candy Crush, etc.) - a package not
       present on the running OS version is just silently skipped
    2. Best-effort removal of common OEM trialware (McAfee, Norton,
       WildTangent, Dell/HP promo utilities) via each product's own
       uninstaller - only relevant on physical OEM hardware, harmlessly
       finds nothing on a clean VM/enterprise image
    3. Disables Start menu/lock screen ads, suggested apps, and other
       consumer content-delivery features (machine-wide policy plus the
       current user's profile for immediate effect)
    4. Cleans up disk space: temp files, Windows Update download cache,
       Recycle Bin, Delivery Optimization cache, a leftover Windows.old
       from a feature upgrade (if present), and the WinSxS component store

.NOTES
    Run in an elevated PowerShell session:  Set-ExecutionPolicy Bypass -Scope Process -Force; .\Debloat-Windows.ps1
    Full run is logged to C:\ArcLogs\WindowsDebloat\ (transcript, timestamped per run).
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest/installers are dramatically faster with the progress UI off

# Shared helper - some HKLM keys (especially under \Policies) can have ACLs
# tightened past what -ErrorAction SilentlyContinue on Set-ItemProperty catches
# (it throws a terminating UnauthorizedAccessException), locked to SYSTEM/
# TrustedInstaller on some builds even for an elevated Administrator token.
# With $ErrorActionPreference = 'Stop' above, one denied write here would
# otherwise abort the whole run. These are all best-effort cosmetic settings,
# not mission-critical, so warn and move on instead.
function Set-RegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    } catch {
        Write-Warning "Could not set '$Name' under '$Path' - $($_.Exception.Message). Skipping; verify manually if this setting matters."
    }
}

# Shared helper - runs a native command with a timeout and periodic
# heartbeat instead of a bare -Wait. OEM uninstallers are wildly
# inconsistent about honouring silent switches - some pop an interactive
# wizard regardless, which would otherwise hang this script indefinitely
# waiting for input nobody's watching for. Long-running commands (e.g. DISM
# component cleanup) also go silent for minutes at a time, which is
# otherwise indistinguishable from a genuine hang.
function Invoke-WithTimeout {
    param([string]$FilePath, [string]$ArgumentList, [string]$Label = $FilePath, [int]$TimeoutSec = 120, [int]$HeartbeatSec = 30)
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -NoNewWindow
    $elapsed = 0
    while (-not $proc.HasExited -and $elapsed -lt $TimeoutSec) {
        if ($proc.WaitForExit($HeartbeatSec * 1000)) { break }
        $elapsed += $HeartbeatSec
        if ($elapsed -lt $TimeoutSec) { Write-Host "  still running $Label... (${elapsed}s elapsed)" }
    }
    if (-not $proc.HasExited) {
        Start-Process taskkill -ArgumentList "/PID", $proc.Id, "/T", "/F" -Wait -NoNewWindow | Out-Null
        return $null
    }
    return $proc.ExitCode
}

# ---------------------------------------------------------------
# Transcript logging - full run output captured for troubleshooting.
# trap ensures the transcript is closed even if a later step throws
# (ErrorActionPreference is 'Stop' above).
# ---------------------------------------------------------------
$LogDir  = "$env:SystemDrive\ArcLogs\WindowsDebloat"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("Debloat-Windows_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null
trap { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
Write-Host "Logging this run to $LogFile" -ForegroundColor DarkGray

# ---------------------------------------------------------------
# 1. Remove bloatware appx packages - both provisioned (so future new
#    users on this machine don't get them either) and installed for the
#    current user(s), so this is safe to re-run and also cleans a
#    machine that already has real users on it.
# ---------------------------------------------------------------
Write-Host "== Removing bloatware apps ==" -ForegroundColor Cyan

$Bloat = @(
    # --- Microsoft first-party consumer/promo apps ---
    "Microsoft.549981C3F5F10"          # Cortana
    "Microsoft.BingNews"
    "Microsoft.BingWeather"
    "Microsoft.BingFinance"
    "Microsoft.GamingApp"              # Xbox app
    "Microsoft.XboxApp"
    "Microsoft.Xbox.TCUI"
    "Microsoft.XboxGameOverlay"
    "Microsoft.XboxGamingOverlay"
    "Microsoft.XboxIdentityProvider"
    "Microsoft.XboxSpeechToTextOverlay"
    "Microsoft.YourPhone"              # Phone Link
    "Microsoft.ZuneMusic"              # Media Player promo
    "Microsoft.ZuneVideo"              # Movies & TV
    "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.MixedReality.Portal"
    "Microsoft.People"
    "Microsoft.GetHelp"
    "Microsoft.Getstarted"
    "Microsoft.WindowsFeedbackHub"
    "Microsoft.WindowsMaps"
    "Microsoft.MicrosoftOfficeHub"     # "Get Office" promo tile - not real Office
    "Microsoft.Todos"
    "Microsoft.PowerAutomateDesktop"
    "Microsoft.SkypeApp"
    "MicrosoftTeams"                   # Old personal/consumer Teams
    "Clipchamp.Clipchamp"
    "MicrosoftCorporationII.QuickAssist"
    "MicrosoftCorporationII.MicrosoftFamily"
    "Microsoft.WindowsCommunicationsApps"  # Old Mail & Calendar
    "Microsoft.OutlookForWindows"      # New Outlook stub
    "Microsoft.MicrosoftJournal"

    # --- Preinstalled 3rd-party promo/trial apps (common on retail OEM machines) ---
    "SpotifyAB.SpotifyMusic"
    "Netflix.Netflix"
    "4DF9E0F8.Netflix"
    "Disney.37853FC22B2CE"             # Disney+
    "Amazon.com.Amazon"
    "AmazonVideo.PrimeVideo"
    "BytedancePte.Ltd.TikTok"
    "Facebook.Facebook"
    "Facebook.InstagramBeta"
    "king.com.CandyCrushSaga"
    "king.com.CandyCrushSodaSaga"
    "king.com.BubbleWitch3Saga"
    "ShazamEntertainmentLtd.Shazam"
    "Duolingo-LLC.DuolingoLearnLanguagesforFree"
    "2414FC7A.Viber"
)

foreach ($app in $Bloat) {
    Get-AppxProvisionedPackage -Online |
        Where-Object DisplayName -eq $app |
        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
    $installed = Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue
    if ($installed) {
        $installed | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Write-Host "  removed: $app"
    }
}

# ---------------------------------------------------------------
# 2. Best-effort removal of common OEM trialware, via each product's OWN
#    uninstaller found in the Uninstall registry - not a hardcoded 3rd-party
#    removal tool download. Only touches products matching these name
#    patterns; anything else found is left alone. Silent switches vary
#    wildly by vendor/installer technology, so this tries the common ones
#    and logs the outcome rather than assuming success - verify manually
#    afterwards. On a clean VM/enterprise image none of this will match
#    anything, which is expected and fine.
# ---------------------------------------------------------------
Write-Host "== Removing common OEM trialware (best effort) ==" -ForegroundColor Cyan

$TrialwarePatterns = @(
    "McAfee*", "Norton*", "WildTangent*",
    "Dell SupportAssist*", "Dell Optimizer*", "Dell Digital Delivery*", "Dell Customer Connect*", "MyDell*",
    "HP Support Assistant*", "HP Documentation*", "HP JumpStart*", "myHP*"
)

$uninstallPaths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$found = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue | Where-Object {
    $name = $_.DisplayName
    $name -and ($TrialwarePatterns | Where-Object { $name -like $_ })
}

if (-not $found) {
    Write-Host "  no known OEM trialware detected." -ForegroundColor Green
} else {
    foreach ($product in $found) {
        Write-Host "  found: $($product.DisplayName)"
        if (-not $product.UninstallString) {
            Write-Warning "  '$($product.DisplayName)' has no UninstallString - skipping, remove manually."
            continue
        }
        try {
            if ($product.UninstallString -match '^msiexec' -and $product.UninstallString -match '(\{[0-9A-Fa-f\-]+\})') {
                $exit = Invoke-WithTimeout -FilePath "msiexec.exe" -ArgumentList "/x $($Matches[1]) /qn /norestart" -Label $product.DisplayName
            } else {
                $exit = Invoke-WithTimeout -FilePath "cmd.exe" -ArgumentList "/c `"$($product.UninstallString)`" /S /verysilent /norestart" -Label $product.DisplayName
            }
            if ($null -eq $exit) {
                Write-Warning "  '$($product.DisplayName)' uninstaller did not finish within the timeout - likely hung on an interactive prompt it ignored the silent switches for. Killed it; remove manually."
            } else {
                Write-Host "  attempted silent removal of '$($product.DisplayName)' (exit code $exit) - verify it's actually gone; some installers ignore unknown switches." -ForegroundColor Yellow
            }
        } catch {
            Write-Warning "  failed to remove '$($product.DisplayName)': $($_.Exception.Message) - remove manually."
        }
    }
}

# ---------------------------------------------------------------
# 3. Disable Start menu/lock screen ads, suggested apps, and other
#    consumer content-delivery features. Machine-wide policy keys cover
#    this user and all future ones; the matching HKCU keys are also set
#    so the change is visible immediately for whoever's running this,
#    without waiting for a policy refresh.
# ---------------------------------------------------------------
Write-Host "== Disabling Start menu/lock screen ads and suggested content ==" -ForegroundColor Cyan

Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableConsumerAccountStateContent" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableCloudOptimizedContent" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableSoftLanding" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableThirdPartySuggestions" -Value 1

# Kill "Chat"/widgets taskbar promos for all new users via default profile policy keys
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0

# Skip the "Choose privacy settings" screen on every future new user's first sign-in
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" -Name "DisablePrivacyExperience" -Value 1

$cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
foreach ($name in @(
    "SystemPaneSuggestionsEnabled", "SilentInstalledAppsEnabled", "ContentDeliveryAllowed",
    "OemPreInstalledAppsEnabled", "PreInstalledAppsEnabled", "PreInstalledAppsEverEnabled",
    "RotatingLockScreenEnabled", "RotatingLockScreenOverlayEnabled", "SoftLandingEnabled",
    "SubscribedContent-338387Enabled", "SubscribedContent-338388Enabled",
    "SubscribedContent-338389Enabled", "SubscribedContent-353698Enabled"
)) {
    Set-RegistryValue -Path $cdm -Name $name -Value 0
}

# ---------------------------------------------------------------
# 4. Disk cleanup - temp files, Windows Update download cache, Recycle
#    Bin, Delivery Optimization cache, a leftover Windows.old from a
#    feature upgrade (if present), and the WinSxS component store.
#    Everything here is reclaiming space, not changing behaviour, so
#    it's safe to re-run and safe on a machine that's been in service
#    for a while (unlike the gold-image version of this step, which
#    only ever runs once on a fresh VM right before sysprep).
# ---------------------------------------------------------------
Write-Host "== Cleaning up temp files, WU cache, and disk space ==" -ForegroundColor Cyan

Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Get-ChildItem $env:TEMP, "C:\Windows\Temp", "C:\Windows\SoftwareDistribution\Download" -Recurse -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue
Write-Host "  cleared temp files and Windows Update download cache."

try {
    Clear-RecycleBin -Force -ErrorAction Stop
    Write-Host "  Recycle Bin emptied."
} catch {
    Write-Host "  Recycle Bin already empty or nothing to clear."
}

try {
    Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
    Write-Host "  Delivery Optimization cache cleared."
} catch {
    Write-Warning "  Could not clear Delivery Optimization cache - $($_.Exception.Message). Skipping."
}

if (Test-Path "C:\Windows.old") {
    Write-Host "  found C:\Windows.old (leftover from a feature upgrade) - attempting removal..."
    Remove-Item "C:\Windows.old" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path "C:\Windows.old") {
        Write-Warning "  C:\Windows.old could not be fully removed (some files are permission-locked) - use Disk Cleanup's 'Previous Windows installations' option instead."
    } else {
        Write-Host "  C:\Windows.old removed." -ForegroundColor Green
    }
}

Write-Host "  running DISM component store cleanup (this can take several minutes)..."
$exit = Invoke-WithTimeout -FilePath "Dism.exe" -ArgumentList "/Online /Cleanup-Image /StartComponentCleanup /Quiet /NoRestart" -Label "DISM component cleanup" -TimeoutSec 1200
if ($null -eq $exit) {
    Write-Warning "  DISM component cleanup did not finish within the timeout - killed it; safe to re-run manually later (Dism.exe /Online /Cleanup-Image /StartComponentCleanup)."
} elseif ($exit -eq 0) {
    Write-Host "  component store cleanup complete." -ForegroundColor Green
} else {
    Write-Warning "  DISM component cleanup exited with code $exit - verify manually."
}

Write-Host "`nDone. Some suggested-content/Start menu changes take full effect after the next sign-in." -ForegroundColor Green
Stop-Transcript | Out-Null
