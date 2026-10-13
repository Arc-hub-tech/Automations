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
       .\Debloat-Windows.ps1                        # asks about new Outlook, Copilot and Norton
       .\Debloat-Windows.ps1 -NewOutlook Block -Copilot Keep -Norton Remove   # or answer up front

    Option B - pull and run the current develop-branch version directly
    (no clone needed; review the script on GitHub first if unsure):

       irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/windows-debloat/Debloat-Windows.ps1 | iex

    To pass the choices with Option B (irm | iex can't take parameters):

       & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/windows-debloat/Debloat-Windows.ps1))) -NewOutlook Block -Copilot Keep
================================================================

.SYNOPSIS
    Windows 10/11 cleanup/debloat - removes the usual detritus that comes
    with new machines. Safe to re-run; only removes/disables, never touches
    accounts, domain join, BitLocker, or security hardening.
    1. Removes bloatware appx packages - Microsoft consumer/promo apps
       (Xbox, Solitaire, Cortana, etc.) and preinstalled 3rd-party promo
       apps (Spotify, Netflix, TikTok, Candy Crush, etc.) - a package not
       present on the running OS version is just silently skipped
    2. New Outlook (the Outlook for Windows app - not classic Outlook from
       Microsoft 365 Apps): remove it, remove it and stop it coming back,
       or keep it - see -NewOutlook. The Copilot apps are removed or kept
       the same way - see -Copilot
    3. Best-effort removal of common OEM trialware (McAfee, WildTangent,
       Dell/HP promo utilities, and Norton only if asked - see -Norton) via
       each product's own uninstaller - only relevant on physical OEM
       hardware, harmlessly finds nothing on a clean VM/enterprise image
    4. Disables Start menu/lock screen ads, suggested apps, and other
       consumer content-delivery features (machine-wide policy plus every
       user profile on the machine and the default profile for new users)
    5. Cleans up disk space: temp files, Windows Update download cache,
       Recycle Bin, Delivery Optimization cache, a leftover Windows.old
       from a feature upgrade (if present), and the WinSxS component store

.PARAMETER NewOutlook
    What to do about the new Outlook for Windows app:
      Remove - uninstall it for all users and new users (default when the
               script runs unattended, e.g. from RMM)
      Block  - uninstall it, and also stop Windows Update reinstalling it
               (Windows 10) and stop classic Outlook offering it (hides the
               "Try the new Outlook" toggle and turns off automatic
               migration, for every user profile and new users)
      Keep   - leave it installed
    If omitted on an interactive run, the script asks. Keep does not undo
    an earlier Block - the block settings stay until removed by hand.

.PARAMETER Copilot
    What to do about the Copilot app (Microsoft.Copilot) and the Microsoft
    365 Copilot app (Microsoft.MicrosoftOfficeHub, formerly "Office"):
      Remove - uninstall both for all users and new users (default when
               the script runs unattended)
      Keep   - leave both installed, e.g. where the user has a Microsoft
               365 Copilot licence
    If omitted on an interactive run, the script asks.

.PARAMETER Norton
    Norton consumer products (Norton 360, Security, AntiVirus, Internet
    Security, Online Backup) - usually an OEM trial, but sometimes a
    subscription the customer pays for, and the two look the same:
      Remove - uninstall them
      Keep   - leave them installed (default when the script runs
               unattended)
    If omitted on an interactive run, the script asks only when Norton is
    actually installed.

.NOTES
    Run in an elevated PowerShell session:  Set-ExecutionPolicy Bypass -Scope Process -Force; .\Debloat-Windows.ps1
    Full run is logged to C:\ArcLogs\WindowsDebloat\ (transcript, timestamped per run).
#>

#Requires -RunAsAdministrator
# No [ValidateSet] here: under irm | iex the parameter is never bound, and
# PowerShell then rejects the empty value against the set and aborts the run.
param([string]$NewOutlook, [string]$Copilot, [string]$Norton)

$ScriptVersion = '1.0.0-dev'
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest/installers are dramatically faster with the progress UI off

# #Requires above only applies when this runs as a .ps1 file - irm | iex and
# the scriptblock form ignore it, so check elevation explicitly. throw, not
# exit: exit under iex would close the technician's console.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Debloat-Windows must run in an elevated PowerShell session (Run as Administrator)."
}

# Checks a choice parameter and returns it in canonical case for the log
# ($null if not passed, so the script asks or takes the default later).
function Resolve-Choice {
    param([string]$Name, [string]$Value, [string[]]$Choices)
    if (-not $Value) { return $null }
    if ($Value -notin $Choices) { throw "-$Name must be one of: $($Choices -join ', ') (got '$Value')." }
    return $Choices | Where-Object { $_ -eq $Value }
}
$NewOutlook = Resolve-Choice -Name NewOutlook -Value $NewOutlook -Choices 'Remove', 'Block', 'Keep'
$Copilot    = Resolve-Choice -Name Copilot    -Value $Copilot    -Choices 'Remove', 'Keep'
$Norton     = Resolve-Choice -Name Norton     -Value $Norton     -Choices 'Remove', 'Keep'

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

# Shared helper - writes per-user DWORDs to every user profile on the machine
# plus the default profile (so new users get them too), not just the HKCU of
# whoever is running this - usually a technician's admin account, not the
# person who uses the PC. Signed-in users' hives are already loaded under
# HKEY_USERS; everyone else's NTUSER.DAT is loaded, written and unloaded.
# Written with reg.exe rather than the PS registry provider: the provider
# caches key handles, which blocks the unload and can leave the writes
# unflushed to NTUSER.DAT (same lesson as the gold-image default-profile step).
function Set-AllUsersRegistryDword {
    param([object[]]$Settings)   # each @{ Key = 'Software\...'; Name = '...'; Value = 0 }
    $hives = @([pscustomobject]@{ Label = 'Default profile (new users)'; File = "$env:SystemDrive\Users\Default\NTUSER.DAT"; Sid = $null })
    # Local/domain and Entra ID users only - skips SYSTEM and service profiles.
    foreach ($key in (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | Where-Object PSChildName -match '^S-1-(5-21|12-1)-')) {
        $profilePath = $key.GetValue('ProfileImagePath')
        if ($profilePath) {
            $hives += [pscustomobject]@{ Label = (Split-Path $profilePath -Leaf); File = (Join-Path $profilePath 'NTUSER.DAT'); Sid = $key.PSChildName }
        }
    }

    $n = 0
    foreach ($hive in $hives) {
        $n++
        $mount = $null
        if ($hive.Sid -and (Test-Path "Registry::HKEY_USERS\$($hive.Sid)")) {
            $root = "HKU\$($hive.Sid)"   # user is signed in - hive already loaded
        } elseif ([IO.File]::Exists($hive.File)) {   # NTUSER.DAT is hidden; don't lean on Test-Path for it
            # Unique per hive, and cleared first, so a leftover mount from an
            # interrupted earlier run can't block this one.
            $mount = "HKU\ArcDebloat_$n"
            if (Test-Path "Registry::HKEY_USERS\ArcDebloat_$n") { & reg.exe unload $mount | Out-Null }
            & reg.exe load $mount $hive.File | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  could not load the registry hive for '$($hive.Label)' - skipped."
                continue
            }
            $root = $mount
        } else {
            continue   # stale ProfileList entry - profile folder no longer exists
        }

        try {
            $failed = 0
            foreach ($s in $Settings) {
                & reg.exe add "$root\$($s.Key)" /v $s.Name /t REG_DWORD /d $s.Value /f | Out-Null
                if ($LASTEXITCODE -ne 0) { $failed++ }
            }
            if ($failed) { Write-Warning "  $failed setting(s) could not be written for '$($hive.Label)'." }
            else         { Write-Host "  applied to: $($hive.Label)" }
        } finally {
            if ($mount) {
                & reg.exe unload $mount | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Warning "  '$($hive.Label)' hive did not unload cleanly - it will release on reboot." }
            }
        }
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
# trap closes the transcript and then stops the run if a later step
# throws (ErrorActionPreference is 'Stop' above). The break matters:
# without it PowerShell carries on after the error with logging off.
# ---------------------------------------------------------------
$LogDir  = "$env:SystemDrive\ArcLogs\WindowsDebloat"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("Debloat-Windows_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null
# (try/catch, not -ErrorAction: "not transcribing" throws regardless of it.)
trap { try { Stop-Transcript | Out-Null } catch {}; break }
Write-Host "Debloat-Windows v$ScriptVersion - logging this run to $LogFile" -ForegroundColor DarkGray

# ---------------------------------------------------------------
# Choices - settled up front so nobody is asked mid-run. A parameter
# wins; otherwise interactive runs ask and unattended runs (RMM, SYSTEM,
# redirected input) never prompt and take the default: Remove for new
# Outlook and Copilot (what the script did before these were options),
# Keep for Norton (it may be a subscription the customer pays for).
# ---------------------------------------------------------------
$Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# Numbered menu; the first option is the default (Enter). Returns the
# option's name, or the default if input can't be read.
function Read-Choice {
    param([string]$Title, [string[]]$Options, [string[]]$Descriptions)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  [{0}] {1,-7}- {2}{3}" -f ($i + 1), $Options[$i], $Descriptions[$i], $(if ($i -eq 0) { ' (default)' }))
    }
    $valid = @('') + (1..$Options.Count | ForEach-Object { "$_" })
    try {
        do { $answer = (Read-Host "Choose 1-$($Options.Count) [1]").Trim() } until ($answer -in $valid)
    } catch {
        Write-Warning "Could not read a choice - using the default ($($Options[0]))."
        $answer = ''
    }
    if ($answer) { return $Options[[int]$answer - 1] }
    return $Options[0]
}

# Uninstall-registry entries whose name matches any of the patterns.
# Trademark signs are stripped first (registered and TM - built from char
# codes to keep this file ASCII, which Windows PowerShell 5.1 needs).
$uninstallPaths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$TrademarkSigns = "[$([char]0x00AE)$([char]0x2122)]"
function Get-TrialwareEntry {
    param([string[]]$Patterns)
    Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue | Where-Object {
        $name = $_.DisplayName -replace $TrademarkSigns, ''
        $name -and ($Patterns | Where-Object { $name -like $_ })
    }
}

# OEM trialware removed in step 3. McAfee is named consumer products only,
# not "McAfee*": a blanket match would also hit a corporate McAfee/Trellix
# agent or endpoint product on a machine already in service. Norton is kept
# separate because it's only removed when asked (-Norton).
$TrialwarePatterns = @(
    "McAfee LiveSafe*", "McAfee Total Protection*", "McAfee+*", "McAfee Internet Security*",
    "McAfee AntiVirus Plus*", "McAfee Security Scan*", "McAfee WebAdvisor*", "McAfee Safe Connect*",
    "WildTangent*",
    "Dell SupportAssist*", "Dell Optimizer*", "Dell Digital Delivery*", "Dell Customer Connect*", "MyDell*",
    "HP Support Assistant*", "HP Documentation*", "HP JumpStart*", "myHP*"
)
$NortonPatterns = @("Norton 360*", "Norton Security*", "Norton AntiVirus*", "Norton Internet Security*", "Norton Online Backup*")
$NortonFound = @(Get-TrialwareEntry -Patterns $NortonPatterns)

if (-not $NewOutlook) {
    $NewOutlook = 'Remove'
    if ($Interactive) {
        $NewOutlook = Read-Choice -Title "New Outlook (the Outlook for Windows app - not classic Outlook from Microsoft 365):" `
            -Options 'Remove', 'Block', 'Keep' `
            -Descriptions 'uninstall it', 'uninstall it and stop it coming back', 'leave it installed'
    }
}
if (-not $Copilot) {
    $Copilot = 'Remove'
    if ($Interactive) {
        $Copilot = Read-Choice -Title "Copilot apps (Copilot and Microsoft 365 Copilot) - keep them if the user has a Copilot licence:" `
            -Options 'Remove', 'Keep' `
            -Descriptions 'uninstall them', 'leave them installed'
    }
}
if (-not $Norton) {
    $Norton = 'Keep'
    if ($NortonFound -and $Interactive) {
        $Norton = Read-Choice -Title "Norton is installed: $(@($NortonFound.DisplayName) -join ', '). Arc doesn't usually supply it - check it isn't a subscription the customer pays for:" `
            -Options 'Keep', 'Remove' `
            -Descriptions 'leave it installed', 'uninstall it'
    }
}
Write-Host "Choices: New Outlook = $NewOutlook, Copilot = $Copilot, Norton = $Norton$(if (-not $NortonFound) { ' (not installed)' })" -ForegroundColor DarkGray
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
    "Microsoft.Todos"
    "Microsoft.PowerAutomateDesktop"
    "Microsoft.SkypeApp"
    "MicrosoftTeams"                   # Old personal/consumer Teams
    "Clipchamp.Clipchamp"
    "MicrosoftCorporationII.QuickAssist"
    "MicrosoftCorporationII.MicrosoftFamily"
    "Microsoft.WindowsCommunicationsApps"  # Old Mail & Calendar - retired by Microsoft; also a route to new Outlook
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
if ($NewOutlook -ne 'Keep') { $Bloat += "Microsoft.OutlookForWindows" }   # New Outlook - see step 2
if ($Copilot -eq 'Remove') {
    $Bloat += "Microsoft.Copilot"               # Copilot app
    $Bloat += "Microsoft.MicrosoftOfficeHub"    # Microsoft 365 Copilot app (formerly "Office"/"Get Office") - not Office itself
}

# One provisioned-package query for the whole list: it's slow (several
# seconds a call), and the old per-app query ran it ~50 times.
$Provisioned = @(Get-AppxProvisionedPackage -Online)

foreach ($app in $Bloat) {
    foreach ($pkg in ($Provisioned | Where-Object DisplayName -eq $app)) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
            Write-Host "  deprovisioned: $app"
        } catch {
            Write-Warning "  could not deprovision '$app' - $($_.Exception.Message)"
        }
    }
    $installed = Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue
    if ($installed) {
        try {
            $installed | Remove-AppxPackage -AllUsers -ErrorAction Stop
            Write-Host "  removed: $app"
        } catch {
            Write-Warning "  could not fully remove '$app' - $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------
# 2. New Outlook. Remove/Keep are handled by step 1 (it's in the removal
#    list or not). Block adds Microsoft's documented controls so it
#    doesn't come back:
#    - Windows 10 installs it through the Windows Update orchestrator
#      (Jan/Feb 2025 updates onward); BlockedOobeUpdaters stops that.
#      Harmless on Windows 11, where the orchestrator honours the
#      deprovisioning in step 1 instead.
#    - Windows 11 23H2 builds from before the March 2024 preview update
#      ignore deprovisioning and reinstall from the OutlookUpdate key.
#    - Classic Outlook (Microsoft 365 Apps) offers it through the "Try the
#      new Outlook" toggle and automatic migration - both per-user, so set
#      for every profile and the default profile.
#    It can still be installed by hand from the Microsoft Store; blocking
#    the Store is out of scope here.
# ---------------------------------------------------------------
if ($NewOutlook -eq 'Block') {
    Write-Host "== Blocking new Outlook from coming back ==" -ForegroundColor Cyan

    $oobe = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe"
    $blocked = (Get-ItemProperty -Path $oobe -Name BlockedOobeUpdaters -ErrorAction SilentlyContinue).BlockedOobeUpdaters
    if ($blocked -notmatch 'MS_Outlook') {
        # Keep anything else already blocked - the value is a JSON array.
        $value = if ($blocked -match '^\s*\[\s*(\S.*?)\s*\]\s*$') { "[$($Matches[1]),`"MS_Outlook`"]" } else { '["MS_Outlook"]' }
        Set-RegistryValue -Path $oobe -Name "BlockedOobeUpdaters" -Value $value -Type String
    }
    Write-Host "  Windows Update orchestrator: MS_Outlook blocked."

    $outlookUpdate = "$oobe\OutlookUpdate"
    if (Test-Path $outlookUpdate) {
        try {
            Remove-Item -Path $outlookUpdate -Recurse -Force -ErrorAction Stop
            Write-Host "  removed the orchestrator's OutlookUpdate key."
        } catch {
            Write-Warning "  could not remove '$outlookUpdate' - $($_.Exception.Message)"
        }
    }

    Write-Host "  classic Outlook: hiding the 'Try the new Outlook' toggle and turning off automatic migration..."
    Set-AllUsersRegistryDword -Settings @(
        @{ Key = 'Software\Microsoft\Office\16.0\Outlook\Options\General';    Name = 'HideNewOutlookToggle';           Value = 1 }
        @{ Key = 'Software\Policies\Microsoft\Office\16.0\Outlook\Preferences'; Name = 'NewOutlookMigrationUserSetting'; Value = 0 }
    )
} elseif ($NewOutlook -eq 'Keep') {
    Write-Host "== New Outlook: kept (not removed) ==" -ForegroundColor Cyan
}

# ---------------------------------------------------------------
# 3. Best-effort removal of common OEM trialware, via each product's OWN
#    uninstaller found in the Uninstall registry - not a hardcoded 3rd-party
#    removal tool download. Only touches products matching these name
#    patterns; anything else found is left alone. Silent switches vary
#    wildly by vendor/installer technology, so this tries the common ones
#    and logs the outcome rather than assuming success - verify manually
#    afterwards. On a clean VM/enterprise image none of this will match
#    anything, which is expected and fine.
# ---------------------------------------------------------------
Write-Host "== Removing common OEM trialware (best effort) ==" -ForegroundColor Cyan

$patterns = $TrialwarePatterns
if ($Norton -eq 'Remove') {
    $patterns += $NortonPatterns
} elseif ($NortonFound) {
    Write-Host "  leaving Norton installed (-Norton Keep): $(@($NortonFound.DisplayName) -join ', ')" -ForegroundColor Yellow
}
$found = @(Get-TrialwareEntry -Patterns $patterns)
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
# 4. Disable Start menu/lock screen ads, suggested apps, and other
#    consumer content-delivery features. Several of the CloudContent
#    policies are only honoured on Enterprise/Education editions, so the
#    per-user ContentDeliveryManager values are what actually does the
#    work on Pro/Home - set for every profile on the machine and the
#    default profile, not just whoever is running this.
# ---------------------------------------------------------------
Write-Host "== Disabling Start menu/lock screen ads and suggested content ==" -ForegroundColor Cyan

Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableConsumerAccountStateContent" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableCloudOptimizedContent" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableSoftLanding" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableThirdPartySuggestions" -Value 1

# Widgets (Windows 11) and News and Interests on the taskbar (Windows 10)
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" -Name "EnableFeeds" -Value 0

# Skip the "Choose privacy settings" screen on every future new user's first sign-in
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" -Name "DisablePrivacyExperience" -Value 1

$cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
Set-AllUsersRegistryDword -Settings @(
    foreach ($name in @(
        "SystemPaneSuggestionsEnabled", "SilentInstalledAppsEnabled", "ContentDeliveryAllowed",
        "OemPreInstalledAppsEnabled", "PreInstalledAppsEnabled", "PreInstalledAppsEverEnabled",
        "RotatingLockScreenEnabled", "RotatingLockScreenOverlayEnabled", "SoftLandingEnabled",
        "SubscribedContent-338387Enabled", "SubscribedContent-338388Enabled",
        "SubscribedContent-338389Enabled", "SubscribedContent-353698Enabled"
    )) { @{ Key = $cdm; Name = $name; Value = 0 } }
)

# ---------------------------------------------------------------
# 5. Disk cleanup - temp files, Windows Update download cache, Recycle
#    Bin, Delivery Optimization cache, a leftover Windows.old from a
#    feature upgrade (if present), and the WinSxS component store.
#    Everything here is reclaiming space, not changing behaviour, so
#    it's safe to re-run and safe on a machine that's been in service
#    for a while (unlike the gold-image version of this step, which
#    only ever runs once on a fresh VM right before sysprep).
# ---------------------------------------------------------------
Write-Host "== Cleaning up temp files, WU cache, and disk space ==" -ForegroundColor Cyan

Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
# Top level only - Remove-Item -Recurse takes each folder's contents with it.
Get-ChildItem $env:TEMP, "C:\Windows\Temp", "C:\Windows\SoftwareDistribution\Download" -Force -ErrorAction SilentlyContinue |
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
