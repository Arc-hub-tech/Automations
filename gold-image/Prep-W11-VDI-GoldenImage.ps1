<#
================================================================
 BEFORE YOU RUN THIS SCRIPT
================================================================
 1. Log in to this image as the persistent/standing local admin
    account you want the image to keep (e.g. ArcAdmin) - NOT the
    built-in Administrator. This is the account the script adopts
    as the standing admin and bakes into the image.
 2. Open an elevated PowerShell prompt (Run as Administrator) on
    the image, then either:

    Option A - run this local copy of the script:

       Set-ExecutionPolicy Bypass -Scope Process -Force
       .\Prep-W11-VDI-GoldenImage.ps1

    Option B - pull and run the current main-branch version directly
    (no clone needed; review the script on GitHub first if unsure):

       irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/gold-image/Prep-W11-VDI-GoldenImage.ps1 | iex

 3. Early on, the script will prompt you to set a password for the
    standing admin account - note it down, you'll need it for console
    access until LAPS rotates it away post-deploy.
================================================================

.SYNOPSIS
    Windows 11 VDI golden image prep - run once as Administrator, then sysprep/clone.
    1. Detects VMware platform (via BIOS/SMBIOS) and installs/upgrades VMware Tools if out of date
    2. Installs Microsoft 365 Apps (64-bit, Monthly Enterprise, Shared Computer Licensing for VDI)
    3. Installs new Teams machine-wide (with VDI/AVD optimisation reg key)
    4. Installs common apps (7-Zip, Foxit PDF Reader) via winget
    5. Removes provisioned + installed bloatware appx packages
    6. Disables consumer content / suggested apps so clones stay clean

.NOTES
    Run in an elevated PowerShell session:  Set-ExecutionPolicy Bypass -Scope Process -Force; .\Prep-W11-VDI-GoldenImage.ps1
    Full run is logged to C:\ArcLogs\GoldImagePrep\ (transcript, timestamped per run).
    App installs use winget so they always pull the current published version - no
    hardcoded download URLs to go stale.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is dramatically faster with the progress UI off
$Work = "$env:TEMP\VDIPrep"
New-Item -ItemType Directory -Path $Work -Force | Out-Null

# Pin the process's actual working directory to $Work. Running via `irm | iex`
# (piped, no backing script file) can leave the inherited working directory
# invalid, which breaks any native exe launch (Start-Process, or a bare
# call like `winget install ...`) with "the directory name is invalid".
Set-Location -Path $Work
[Environment]::CurrentDirectory = $Work

# Shared helper - checks the Uninstall registry (both native and WOW6432Node
# views) for a product already installed, so install steps below can skip
# work that's already done instead of always re-downloading/re-running.
function Test-InstalledProduct {
    param([string]$NameLike)
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    return [bool](Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $NameLike } | Select-Object -First 1)
}

# Shared helper - some HKLM keys (especially under \Policies) can have ACLs
# tightened past what -ErrorAction SilentlyContinue on Set-ItemProperty catches
# (it throws a terminating UnauthorizedAccessException), e.g. AllowNewsAndInterests
# under Policies\Microsoft\Dsh, which Microsoft has locked to SYSTEM/TrustedInstaller
# on some builds even for an elevated Administrator token. With $ErrorActionPreference
# = 'Stop' above, one denied write here would otherwise abort the whole run. These are
# best-effort baseline settings (see section 11 below), so warn and move on instead.
function Set-RegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    } catch {
        Write-Warning "Could not set '$Name' under '$Path' - $($_.Exception.Message). Skipping; verify manually if this setting matters."
    }
}

# ---------------------------------------------------------------
# Transcript logging - full run output captured for troubleshooting
# failed image builds. trap ensures the transcript is closed even if
# a later step throws (ErrorActionPreference is 'Stop' above).
# ---------------------------------------------------------------
$LogDir  = "$env:SystemDrive\ArcLogs\GoldImagePrep"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("Prep-W11-VDI-GoldenImage_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null
trap { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
Write-Host "Logging this run to $LogFile" -ForegroundColor DarkGray

# ---------------------------------------------------------------
# 0. Standard local admin account - ADOPTS the currently logged-in
#    user as the standing admin, so log in as the account the image
#    should keep (e.g. ArcAdmin) before running. Then disables the
#    built-in Administrator (found by SID -500, so renaming doesn't
#    fool it) - unless that's who is running the script.
# ---------------------------------------------------------------
Write-Host "== Configuring standard local admin account ==" -ForegroundColor Cyan

$AdminUser = $env:USERNAME
$cur     = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
$builtin = Get-LocalUser | Where-Object { $_.SID.Value -like "S-1-5-*-500" }
$StandingAdminReady = $false

if (-not $cur) {
    Write-Warning "'$AdminUser' is not a LOCAL account (domain/Entra?). Log in as the local admin the image should keep and rerun. Continuing without account changes."
} elseif ($builtin.Name -eq $AdminUser) {
    Write-Warning "You are logged in as the BUILT-IN Administrator. Log in as a named admin (e.g. ArcAdmin) instead - the built-in account should end up disabled, not be the standing admin. Skipping account step."
} else {
    Write-Host "  set a password for '$AdminUser' - it becomes the account's real password now," -ForegroundColor Cyan
    Write-Host "  and the same value is declared in unattend.xml later so OOBE skips account creation." -ForegroundColor Cyan
    Write-Host "  Note it down: LAPS rotates it away after first deploy, but you'll need it for console access before then." -ForegroundColor Cyan
    do {
        $AdminPasswordSecure  = Read-Host -AsSecureString "  Password for $AdminUser"
        $AdminPasswordConfirm = Read-Host -AsSecureString "  Confirm password"
        $p1 = [System.Net.NetworkCredential]::new('', $AdminPasswordSecure).Password
        $p2 = [System.Net.NetworkCredential]::new('', $AdminPasswordConfirm).Password
        if ($p1 -ne $p2) { Write-Warning "Passwords didn't match - try again." }
    } while ($p1 -ne $p2)
    $p1 = $null; $p2 = $null; $AdminPasswordConfirm = $null

    Set-LocalUser -Name $AdminUser -Password $AdminPasswordSecure -PasswordNeverExpires $true -AccountNeverExpires `
        -Description "Arc standing local admin - LAPS managed"
    if (-not (Get-LocalGroupMember -Group "Administrators" -Member $AdminUser -ErrorAction SilentlyContinue)) {
        Add-LocalGroupMember -Group "Administrators" -Member $AdminUser
    }
    Write-Host "  '$AdminUser' set as standing admin (LAPS rotates the password post-deploy)."
    if ($builtin.Enabled) {
        Disable-LocalUser -SID $builtin.SID
        Write-Host "  built-in Administrator '$($builtin.Name)' disabled."
    } else {
        Write-Host "  built-in Administrator already disabled."
    }
    $StandingAdminReady = $true
}

# ---------------------------------------------------------------
# 1. VMware platform check - detected via BIOS/SMBIOS-reported
#    manufacturer (the same data the hypervisor presents to the guest
#    that Win32_ComputerSystem/Win32_BIOS read). Compares the installed
#    version against the current version on VMware's public package feed
#    and only downloads/installs if they differ - rather than relying on
#    the in-guest "self-service upgrade" command, which only works if the
#    ESXi/vCenter host already has newer tools mounted as virtual media
#    (not guaranteed - e.g. Workstation/Fusion, or standalone ESXi) and
#    silently no-ops otherwise. The feed's filename is versioned (e.g.
#    VMware-tools-13.1.0-25218885-x64.exe), so both the filename and its
#    version are discovered from the directory listing, not hardcoded.
# ---------------------------------------------------------------
Write-Host "== Checking VMware platform / tools ==" -ForegroundColor Cyan

$biosMfr = (Get-CimInstance Win32_ComputerSystem).Manufacturer
if ($biosMfr -match 'VMware') {
    Write-Host "  VMware platform detected (BIOS manufacturer: $biosMfr)."
    $toolboxCmd   = "$env:ProgramFiles\VMware\VMware Tools\VMwareToolboxCmd.exe"
    $installedVer = $null
    if (Test-Path $toolboxCmd) {
        $toolsVer = (& $toolboxCmd -v 2>&1) -join ' '
        Write-Host "  VMware Tools currently installed: $toolsVer"
        if ($toolsVer -match '(\d+\.\d+\.\d+)') { $installedVer = [version]$Matches[1] }
    } else {
        Write-Host "  VMware Tools not currently installed."
    }

    Write-Host "  checking latest VMware Tools version at packages.vmware.com..."
    $toolsIndexUrl = "https://packages.vmware.com/tools/releases/latest/windows/x64/"
    $exeName = $null
    try {
        $html    = (Invoke-WebRequest -Uri $toolsIndexUrl -UseBasicParsing).Content
        $exeName = [regex]::Match($html, 'href="([^"/]+\.exe)"').Groups[1].Value
    } catch { }

    if (-not $exeName) {
        Write-Warning "Could not reach $toolsIndexUrl to check for updates - install/upgrade manually from vCenter/ESXi if needed (Guest > Install VMware Tools)."
    } else {
        $latestVer = $null
        if ($exeName -match '-(\d+\.\d+\.\d+)-') { $latestVer = [version]$Matches[1] }
        Write-Host "  latest available: $exeName$(if ($latestVer) { " (version $latestVer)" })"

        if ($installedVer -and $latestVer -and $installedVer -ge $latestVer) {
            Write-Host "  already up to date - skipping download/install." -ForegroundColor Green
        } else {
            $toolsExe = "$Work\$exeName"
            Invoke-WebRequest -Uri "$toolsIndexUrl$exeName" -OutFile $toolsExe
            Write-Host "  installing $exeName silently (upgrades in place if already installed; reboot before sysprep once this completes)..."
            Start-Process $toolsExe -ArgumentList '/S /v"/qn REBOOT=ReallySuppress"' -Wait -NoNewWindow -WorkingDirectory $Work
            Write-Host "  VMware Tools install/upgrade complete." -ForegroundColor Green
        }
    }
} else {
    Write-Host "  not running on VMware (BIOS manufacturer: $biosMfr) - skipping."
}

# ---------------------------------------------------------------
# 2. Microsoft 365 Apps via Office Deployment Tool
# ---------------------------------------------------------------
Write-Host "== Installing Microsoft 365 Apps ==" -ForegroundColor Cyan

$cfg      = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
$existing = Get-ItemProperty -Path $cfg -ErrorAction SilentlyContinue
if ($existing -and $existing.ProductReleaseIds -match 'O365ProPlusRetail') {
    Write-Host "  Microsoft 365 Apps already installed (version $($existing.VersionToReport)) - skipping (Click-to-Run keeps itself updated)." -ForegroundColor Green
} else {
    # ODT config: shared computer licensing ON (required for non-persistent/multi-user VDI),
    # OneDrive Groove/legacy Skype excluded. Change Channel to "Current" if preferred.
    @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-gb" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="1" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@ | Set-Content "$Work\office.xml" -Encoding UTF8

    # Evergreen ODT link (redirects to latest setup.exe)
    $odt = "$Work\odt.exe"
    Invoke-WebRequest -Uri "https://officecdn.microsoft.com/pr/wsus/setup.exe" -OutFile $odt
    # ODT's setup.exe doesn't reliably exit on all builds, so don't wait on the process
    # at all. Launch it, then poll Click-to-Run's registry: VersionToReport is written
    # when the install actually completes.
    Start-Process $odt -ArgumentList "/configure `"$Work\office.xml`"" -NoNewWindow -WorkingDirectory $Work
    $deadline = (Get-Date).AddMinutes(40)
    do {
        Start-Sleep -Seconds 20
        $ver = (Get-ItemProperty -Path $cfg -Name VersionToReport -ErrorAction SilentlyContinue).VersionToReport
        Write-Host "  waiting for Office install to complete..."
    } until ($ver -or (Get-Date) -gt $deadline)

    if ($ver) { Write-Host "  Office $ver installed." -ForegroundColor Green }
    else      { Write-Warning "Timed out after 40 min waiting for Office - verify manually; continuing anyway." }

    # Kill any lingering ODT process so it can't hold things up or interfere with sysprep
    Get-Process -Name odt, setup -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$Work*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
# 3. New Teams (machine-wide provisioning, VDI optimised)
# ---------------------------------------------------------------
Write-Host "== Installing Teams (new) ==" -ForegroundColor Cyan

# Tell Teams it's running in a VDI/AVD environment (enables media optimisation path)
Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Name "IsWVDEnvironment" -Value 1

if (Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'MSTeams') {
    Write-Host "  Teams (new) already provisioned - skipping." -ForegroundColor Green
} else {
    $boot = "$Work\teamsbootstrapper.exe"
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2243204" -OutFile $boot
    Start-Process $boot -ArgumentList "-p" -Wait -NoNewWindow -WorkingDirectory $Work   # -p provisions for all users
}

# Remote Desktop WebRTC Redirector Service - enables Teams media optimisation
# for sessions connected via AVD/W365. Harmless but inert on plain RDS; remove
# this block if these hosts will never be AVD session hosts.
if (Test-InstalledProduct -NameLike "Remote Desktop WebRTC Redirector Service*") {
    Write-Host "  WebRTC Redirector Service already installed - skipping." -ForegroundColor Green
} else {
    $rtc = "$Work\webrtc.msi"
    Invoke-WebRequest -Uri "https://aka.ms/msrdcwebrtcsvc/msi" -OutFile $rtc
    Start-Process msiexec -ArgumentList "/i `"$rtc`" /qn /norestart" -Wait -NoNewWindow -WorkingDirectory $Work
}

# ---------------------------------------------------------------
# 4. Common third-party apps via winget - no hardcoded download URLs
#    to go stale, winget always resolves the current published
#    version. Requires winget (App Installer) on the image; if it's
#    missing this just warns and skips rather than guessing a URL.
# ---------------------------------------------------------------
Write-Host "== Installing common apps (7-Zip, Foxit PDF Reader) ==" -ForegroundColor Cyan

function Test-WingetInstalled {
    param([string]$Id)
    $result = winget list --id $Id -e --accept-source-agreements 2>$null
    return ($LASTEXITCODE -eq 0) -and ($result -match [regex]::Escape($Id))
}

function Install-WingetApp {
    param([string]$Id, [string]$Name, [int]$TimeoutSec = 300)
    if (Test-WingetInstalled -Id $Id) {
        Write-Host "  $Name already installed - skipping." -ForegroundColor Green
        return
    }
    Write-Host "  installing $Name ($Id)..."
    $proc = Start-Process winget -ArgumentList @(
        "install", "--id", $Id, "-e", "--silent",
        "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"
    ) -PassThru -WindowStyle Hidden -WorkingDirectory $Work

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        # Some winget packages (Foxit.FoxitReader in particular - see
        # microsoft/winget-pkgs #10072 and #364274) hang indefinitely mid-install
        # with no CPU or network activity, stuck behind a hidden installer dialog
        # that never surfaces under --disable-interactivity. Kill the whole process
        # tree and move on rather than blocking the rest of image prep forever.
        Write-Warning "$Name install via winget did not finish within $TimeoutSec s - likely hung (known issue with some winget packages, e.g. Foxit.FoxitReader). Killed it and continuing; install manually if needed."
        Start-Process taskkill -ArgumentList "/PID", $proc.Id, "/T", "/F" -Wait -NoNewWindow -WorkingDirectory $Work | Out-Null
        return
    }

    if ($proc.ExitCode -eq 0) { Write-Host "  $Name installed." -ForegroundColor Green }
    else { Write-Warning "$Name install via winget exited with code $($proc.ExitCode) - verify manually." }
}

if (Get-Command winget -ErrorAction SilentlyContinue) {
    Install-WingetApp -Id "7zip.7zip" -Name "7-Zip"
    Install-WingetApp -Id "Foxit.FoxitReader" -Name "Foxit PDF Reader"
} else {
    Write-Warning "winget not found on this image - skipping 7-Zip/Foxit PDF Reader install. Install manually or add winget (App Installer) to the base image first."
}

# ---------------------------------------------------------------
# 5. FSLogix agent - DORMANT install. Completely inert without the
#    Enabled=1 config key, so persistent Discrete PCs behave exactly
#    as before (local profiles + OneDrive KFM). Enabling later for
#    pooled/non-persistent use is just GPO or the reg keys below.
# ---------------------------------------------------------------
Write-Host "== Installing FSLogix agent (dormant) ==" -ForegroundColor Cyan

if (Test-InstalledProduct -NameLike "Microsoft FSLogix Apps*") {
    Write-Host "  FSLogix already installed - skipping." -ForegroundColor Green
} else {
    $fsl = "$Work\fslogix.zip"
    Invoke-WebRequest -Uri "https://aka.ms/fslogix_download" -OutFile $fsl
    Expand-Archive $fsl -DestinationPath "$Work\fslogix" -Force
    $fslSetup = Get-ChildItem "$Work\fslogix" -Recurse -Filter "FSLogixAppsSetup.exe" |
        Where-Object FullName -like "*x64*" | Select-Object -First 1
    Start-Process $fslSetup.FullName -ArgumentList "/install /quiet /norestart" -Wait -NoNewWindow -WorkingDirectory $Work
}

# --- To ACTIVATE profile containers later (per environment, not in the image) ---
# $fslKey = "HKLM:\SOFTWARE\FSLogix\Profiles"
# New-Item -Path $fslKey -Force | Out-Null
# Set-ItemProperty $fslKey -Name "Enabled"      -Value 1 -Type DWord
# Set-ItemProperty $fslKey -Name "VHDLocations" -Value "\\SERVER\Profiles$" -Type MultiString
# Set-ItemProperty $fslKey -Name "SizeInMBs"    -Value 30720 -Type DWord
# Set-ItemProperty $fslKey -Name "IsDynamic"    -Value 1 -Type DWord
# Set-ItemProperty $fslKey -Name "VolumeType"   -Value "VHDX" -Type String
# Set-ItemProperty $fslKey -Name "DeleteLocalProfileWhenVHDShouldApply" -Value 1 -Type DWord
# Set-ItemProperty $fslKey -Name "FlipFlopProfileDirectoryName"         -Value 1 -Type DWord

# ---------------------------------------------------------------
# 6. Remove bloatware (provisioned = future users, installed = current)
# ---------------------------------------------------------------
Write-Host "== Removing bloatware ==" -ForegroundColor Cyan

$Bloat = @(
    "Microsoft.549981C3F5F10"          # Cortana
    "Microsoft.BingNews"
    "Microsoft.BingWeather"
    "Microsoft.BingSearch"
    "Microsoft.GamingApp"
    "Microsoft.GetHelp"
    "Microsoft.Getstarted"             # Tips
    "Microsoft.Microsoft3DViewer"
    "Microsoft.MicrosoftOfficeHub"     # "Office" ad hub (not M365 Apps)
    "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.MixedReality.Portal"
    "Microsoft.People"
    "Microsoft.PowerAutomateDesktop"
    "Microsoft.SkypeApp"
    "Microsoft.Todos"
    "Microsoft.WindowsFeedbackHub"
    "Microsoft.WindowsMaps"
    "Microsoft.Xbox.TCUI"
    "Microsoft.XboxGameOverlay"
    "Microsoft.XboxGamingOverlay"
    "Microsoft.XboxIdentityProvider"
    "Microsoft.XboxSpeechToTextOverlay"
    "Microsoft.YourPhone"              # Phone Link
    "Microsoft.ZuneMusic"              # Media Player promo
    "Microsoft.ZuneVideo"              # Movies & TV
    "Microsoft.OutlookForWindows"      # New Outlook stub (remove if deploying classic Outlook from M365)
    "MicrosoftTeams"                   # Old personal/consumer Teams
    "Clipchamp.Clipchamp"
    "MicrosoftCorporationII.QuickAssist"
    "MicrosoftCorporationII.MicrosoftFamily"
    "Microsoft.WindowsCommunicationsApps"  # Old Mail & Calendar
)

foreach ($app in $Bloat) {
    Get-AppxProvisionedPackage -Online |
        Where-Object DisplayName -eq $app |
        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
    Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue |
        Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Write-Host "  removed: $app"
}

# ---------------------------------------------------------------
# 7. Stop Windows re-adding junk on new profiles
# ---------------------------------------------------------------
Write-Host "== Disabling consumer features/suggestions ==" -ForegroundColor Cyan

Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableConsumerAccountStateContent" -Value 1

# Kill "Chat"/widgets taskbar promos for all new users via default profile policy keys
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0

# Skip the "Choose privacy settings" screen on every future new user's first
# sign-in - a machine-wide policy, so unlike the sysprep unattend.xml (which
# only covers this image's own first boot) this keeps working for every user
# who ever logs into a clone made from this image.
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" -Name "DisablePrivacyExperience" -Value 1

# ---------------------------------------------------------------
# 8. Sysprep-readiness sweep: remove appx packages that are installed
#    for a user but NOT provisioned for all users. These are the classic
#    "Sysprep was not able to validate your Windows installation" cause
#    (Store auto-updates and per-user installs create them silently).
# ---------------------------------------------------------------
Write-Host "== Sweeping unprovisioned appx packages (sysprep blockers) ==" -ForegroundColor Cyan

$Provisioned = (Get-AppxProvisionedPackage -Online).DisplayName
Get-AppxPackage -AllUsers | Where-Object {
    $_.Name -notin $Provisioned -and
    -not $_.IsFramework -and
    -not $_.NonRemovable
} | ForEach-Object {
    Write-Host "  removing unprovisioned: $($_.Name)"
    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
# 9. BitLocker: decrypt OS volume (sysprep refuses encrypted volumes)
#    and stop clones from silently self-encrypting on first sign-in
# ---------------------------------------------------------------
Write-Host "== Disabling BitLocker/device encryption ==" -ForegroundColor Cyan

$blv = Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue
if ($blv -and $blv.VolumeStatus -ne 'FullyDecrypted') {
    Disable-BitLocker -MountPoint C: -ErrorAction SilentlyContinue | Out-Null
    $deadline = (Get-Date).AddMinutes(60)
    do {
        Start-Sleep -Seconds 15
        $blv = Get-BitLockerVolume -MountPoint C:
        Write-Host "  decrypting C: ... $($blv.EncryptionPercentage)% encrypted remaining status: $($blv.VolumeStatus)"
    } until ($blv.VolumeStatus -eq 'FullyDecrypted' -or (Get-Date) -gt $deadline)
    if ($blv.VolumeStatus -ne 'FullyDecrypted') { Write-Warning "C: still not fully decrypted - do NOT sysprep until it is." }
    else { Write-Host "  C: fully decrypted." -ForegroundColor Green }
} else {
    Write-Host "  C: already fully decrypted."
}

Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker" -Name "PreventDeviceEncryption" -Value 1

# ---------------------------------------------------------------
# 10. UK regional and time settings (applied to system, welcome screen,
#     and the default profile so every clone/new user inherits them)
# ---------------------------------------------------------------
Write-Host "== Setting UK regional/time settings ==" -ForegroundColor Cyan

Set-TimeZone -Id "GMT Standard Time"
Set-Culture en-GB
Set-WinSystemLocale en-GB              # needs a reboot to fully apply
Set-WinHomeLocation -GeoId 242         # 242 = United Kingdom
Set-WinUserLanguageList en-GB -Force
# Push current user's international settings to welcome screen, system
# accounts, and the default user profile (new users inherit UK settings)
Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true

# ---------------------------------------------------------------
# 11. CE+ / ISO 27001 baseline hardening - image-safe defaults.
#     Domain/Intune policy will override any of these on managed
#     machines, which is fine; these are the floor, not the ceiling.
#     NOTE: TLS 1.0/1.1 disable is the only item with app-compat risk
#     (ancient LOB apps) - remove that block for a legacy-app image.
# ---------------------------------------------------------------
Write-Host "== Applying CE+/ISO 27001 baseline hardening ==" -ForegroundColor Cyan

# Remove legacy attack surface: SMBv1 and PowerShell v2. Disable-WindowsOptionalFeature
# throws a hard COMException for a feature name that doesn't exist on this build/edition
# (e.g. PowerShell v2 has been trimmed from newer Windows 11 images) - -ErrorAction
# SilentlyContinue does NOT suppress that, so each feature needs an actual try/catch.
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    Remove-WindowsFeature FS-SMB1 -ErrorAction SilentlyContinue | Out-Null
} else {
    foreach ($feat in "SMB1Protocol", "MicrosoftWindowsPowerShellV2Root", "MicrosoftWindowsPowerShellV2") {
        try {
            Disable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart -ErrorAction Stop | Out-Null
            Write-Host "  disabled: $feat"
        } catch {
            Write-Host "  '$feat' not present on this image/edition - skipping."
        }
    }
}

# SMB signing required both directions (default on newest builds; enforce anyway)
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force
Set-SmbClientConfiguration -RequireSecuritySignature $true -Force

# Firewall on for all profiles
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True

# Defender: PUA blocking + cloud protection
Set-MpPreference -PUAProtection Enabled -MAPSReporting Advanced -SubmitSamplesConsent SendSafeSamples -ErrorAction SilentlyContinue

# Disable TLS 1.0/1.1 and SSL 3.0 (server and client roles)
foreach ($proto in "SSL 3.0", "TLS 1.0", "TLS 1.1") {
    foreach ($role in "Server", "Client") {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\$role"
        Set-RegistryValue -Path $k -Name "Enabled" -Value 0
        Set-RegistryValue -Path $k -Name "DisabledByDefault" -Value 1
    }
}

# NTLMv2 only, refuse LM/NTLMv1; WDigest plaintext creds off
Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LmCompatibilityLevel" -Value 5
Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" -Name "UseLogonCredential" -Value 0

# LLMNR off (name-resolution poisoning mitigation)
Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Value 0

# AutoRun/AutoPlay off for all drive types
Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255
Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoAutorun" -Value 1

# UAC fully on with secure desktop; 15-minute machine inactivity lock
$sys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-RegistryValue -Path $sys -Name "EnableLUA" -Value 1
Set-RegistryValue -Path $sys -Name "ConsentPromptBehaviorAdmin" -Value 5
Set-RegistryValue -Path $sys -Name "PromptOnSecureDesktop" -Value 1
Set-RegistryValue -Path $sys -Name "InactivityTimeoutSecs" -Value 900

# RDP: require NLA, TLS security layer, high encryption
$rdp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
Set-RegistryValue -Path $rdp -Name "UserAuthentication" -Value 1
Set-RegistryValue -Path $rdp -Name "SecurityLayer" -Value 2
Set-RegistryValue -Path $rdp -Name "MinEncryptionLevel" -Value 3

# Local account lockout policy (matters on standalone/Entra-only; GPO overrides on domain)
net accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15 | Out-Null

# Guest account disabled
net user Guest /active:no 2>$null | Out-Null

# ---------------------------------------------------------------
# 12. Clear temp + Windows Update download cache to slim the clone source
# ---------------------------------------------------------------
Write-Host "== Clearing temp and WU cache ==" -ForegroundColor Cyan

Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Get-ChildItem $env:TEMP, "C:\Windows\Temp", "C:\Windows\SoftwareDistribution\Download" -Recurse -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# 13. Sysprep answer file - skips the entire OOBE (region, keyboard,
#     EULA, account creation, privacy screens). Clones boot straight
#     to the sign-in screen with the accounts baked into the image.
#     NOTE: if the image was built from a US ISO, change UILanguage
#     to en-US (display language can't be set to a pack that isn't
#     installed); everything else stays en-GB.
#
#     HideLocalAccountScreen alone is NOT reliable on Windows 11 - OOBE's
#     CloudExperienceHost still prompts to create an account unless one is
#     explicitly declared in the answer file. So when a standing admin was
#     set up in step 0, this declares that SAME account using the password
#     you set there (never a randomly generated one - a random password
#     nobody knows caused a real lockout the first time this was tried).
#     A FirstLogonCommand deletes this file immediately after specialize
#     completes, so the password doesn't linger on disk in plaintext -
#     but since you already know it from step 0, that's just cleanup, not
#     your only copy.
# ---------------------------------------------------------------
Write-Host "== Writing sysprep unattend.xml ==" -ForegroundColor Cyan

$userAccountsXml = ""
$firstLogonXml   = ""
if ($StandingAdminReady) {
    $AdminPasswordPlain = [System.Net.NetworkCredential]::new('', $AdminPasswordSecure).Password

    $userAccountsXml = @"

      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>$AdminPasswordPlain</Value>
              <PlainText>true</PlainText>
            </Password>
            <Group>Administrators</Group>
            <DisplayName>$AdminUser</DisplayName>
            <Name>$AdminUser</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
"@
    $firstLogonXml = @"

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c del /f /q C:\Windows\Panther\unattend.xml</CommandLine>
          <Description>Remove sysprep answer file (contains the admin password) immediately after first boot</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
"@
    $AdminPasswordPlain = $null
} else {
    Write-Host "  no standing admin was set up in step 0 - skipping account declaration (the account-creation screen may still appear on first boot)." -ForegroundColor Yellow
}

@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0809:00000809</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipUserOOBE>true</SkipUserOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>
      <EnableFirstLogonAnimation>false</EnableFirstLogonAnimation>
      <TimeZone>GMT Standard Time</TimeZone>$userAccountsXml$firstLogonXml
    </component>
  </settings>
</unattend>
"@ | Set-Content "C:\Windows\Panther\unattend.xml" -Encoding UTF8
Write-Host "  written to C:\Windows\Panther\unattend.xml"

# ---------------------------------------------------------------
Set-Location -Path $env:SystemDrive\
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nDone. Verify Office/Teams launch, then generalise with the EXACT command below" -ForegroundColor Green
Write-Host "(sysprep.exe is NOT on PATH - the full path is required):" -ForegroundColor Green
Write-Host "  C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /unattend:C:\Windows\Panther\unattend.xml" -ForegroundColor Green
Stop-Transcript | Out-Null
