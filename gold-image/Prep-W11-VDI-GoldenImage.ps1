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
================================================================

.SYNOPSIS
    Windows 11 VDI golden image prep - run once as Administrator, then sysprep/clone.
    1. Detects VMware platform (via BIOS/SMBIOS) and installs/upgrades VMware Tools
    2. Installs Microsoft 365 Apps (64-bit, Monthly Enterprise, Shared Computer Licensing for VDI)
    3. Installs new Teams machine-wide (with VDI/AVD optimisation reg key)
    4. Installs common apps (7-Zip, Adobe Acrobat Reader DC) via winget
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
$Work = "$env:TEMP\VDIPrep"
New-Item -ItemType Directory -Path $Work -Force | Out-Null

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

if (-not $cur) {
    Write-Warning "'$AdminUser' is not a LOCAL account (domain/Entra?). Log in as the local admin the image should keep and rerun. Continuing without account changes."
} elseif ($builtin.Name -eq $AdminUser) {
    Write-Warning "You are logged in as the BUILT-IN Administrator. Log in as a named admin (e.g. ArcAdmin) instead - the built-in account should end up disabled, not be the standing admin. Skipping account step."
} else {
    Set-LocalUser -Name $AdminUser -PasswordNeverExpires $true -AccountNeverExpires `
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
}

# ---------------------------------------------------------------
# 1. VMware platform check - detected via BIOS/SMBIOS-reported
#    manufacturer (the same data the hypervisor presents to the guest
#    that Win32_ComputerSystem/Win32_BIOS read). If this is a VMware
#    VM and VMware Tools is already installed, trigger its built-in
#    self-service upgrade (pulls newer tools from host-mounted media
#    if the host has them - the in-guest equivalent of "Upgrade
#    VMware Tools" from vCenter/ESXi). If VMware Tools isn't installed
#    at all, fetch the current installer directly from VMware's public
#    package feed and install it silently (the feed's filename is
#    versioned, e.g. VMware-tools-13.1.0-25218885-x64.exe, so it's
#    discovered from the directory listing rather than hardcoded).
# ---------------------------------------------------------------
Write-Host "== Checking VMware platform / tools ==" -ForegroundColor Cyan

$biosMfr = (Get-CimInstance Win32_ComputerSystem).Manufacturer
if ($biosMfr -match 'VMware') {
    Write-Host "  VMware platform detected (BIOS manufacturer: $biosMfr)."
    $toolboxCmd = "$env:ProgramFiles\VMware\VMware Tools\VMwareToolboxCmd.exe"
    if (Test-Path $toolboxCmd) {
        $toolsVer = & $toolboxCmd -v
        Write-Host "  VMware Tools installed (version $toolsVer) - triggering self-service upgrade check..."
        & $toolboxCmd upgrade start
        Write-Host "  upgrade triggered - if the host has newer tools mounted, they'll install now; otherwise this is a no-op."
    } else {
        Write-Host "  VMware Tools not installed - fetching latest installer from packages.vmware.com..."
        $toolsIndexUrl = "https://packages.vmware.com/tools/releases/latest/windows/x64/"
        try {
            $html    = (Invoke-WebRequest -Uri $toolsIndexUrl -UseBasicParsing).Content
            $exeName = [regex]::Match($html, 'href="([^"/]+\.exe)"').Groups[1].Value
        } catch { $exeName = $null }

        if (-not $exeName) {
            Write-Warning "Could not find a VMware Tools installer at $toolsIndexUrl - install manually from vCenter/ESXi (Guest > Install VMware Tools)."
        } else {
            $toolsExe = "$Work\$exeName"
            Invoke-WebRequest -Uri "$toolsIndexUrl$exeName" -OutFile $toolsExe
            Write-Host "  installing $exeName silently (reboot before sysprep once this completes)..."
            Start-Process $toolsExe -ArgumentList '/S /v"/qn REBOOT=ReallySuppress"' -Wait -NoNewWindow
            Write-Host "  VMware Tools installed." -ForegroundColor Green
        }
    }
} else {
    Write-Host "  not running on VMware (BIOS manufacturer: $biosMfr) - skipping."
}

# ---------------------------------------------------------------
# 2. Microsoft 365 Apps via Office Deployment Tool
# ---------------------------------------------------------------
Write-Host "== Installing Microsoft 365 Apps ==" -ForegroundColor Cyan

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
Start-Process $odt -ArgumentList "/configure `"$Work\office.xml`"" -NoNewWindow
$cfg      = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
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

# ---------------------------------------------------------------
# 3. New Teams (machine-wide provisioning, VDI optimised)
# ---------------------------------------------------------------
Write-Host "== Installing Teams (new) ==" -ForegroundColor Cyan

# Tell Teams it's running in a VDI/AVD environment (enables media optimisation path)
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Name "IsWVDEnvironment" -Value 1 -Type DWord

$boot = "$Work\teamsbootstrapper.exe"
Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2243204" -OutFile $boot
Start-Process $boot -ArgumentList "-p" -Wait -NoNewWindow   # -p provisions for all users

# Remote Desktop WebRTC Redirector Service - enables Teams media optimisation
# for sessions connected via AVD/W365. Harmless but inert on plain RDS; remove
# this block if these hosts will never be AVD session hosts.
$rtc = "$Work\webrtc.msi"
Invoke-WebRequest -Uri "https://aka.ms/msrdcwebrtcsvc/msi" -OutFile $rtc
Start-Process msiexec -ArgumentList "/i `"$rtc`" /qn /norestart" -Wait -NoNewWindow

# ---------------------------------------------------------------
# 4. Common third-party apps via winget - no hardcoded download URLs
#    to go stale, winget always resolves the current published
#    version. Requires winget (App Installer) on the image; if it's
#    missing this just warns and skips rather than guessing a URL.
# ---------------------------------------------------------------
Write-Host "== Installing common apps (7-Zip, Adobe Acrobat Reader DC) ==" -ForegroundColor Cyan

function Install-WingetApp {
    param([string]$Id, [string]$Name)
    Write-Host "  installing $Name ($Id)..."
    winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  $Name installed." -ForegroundColor Green }
    else { Write-Warning "$Name install via winget exited with code $LASTEXITCODE - verify manually." }
}

if (Get-Command winget -ErrorAction SilentlyContinue) {
    Install-WingetApp -Id "7zip.7zip" -Name "7-Zip"
    Install-WingetApp -Id "Adobe.Acrobat.Reader.64-bit" -Name "Adobe Acrobat Reader DC"
} else {
    Write-Warning "winget not found on this image - skipping 7-Zip/Adobe Acrobat Reader install. Install manually or add winget (App Installer) to the base image first."
}

# ---------------------------------------------------------------
# 5. FSLogix agent - DORMANT install. Completely inert without the
#    Enabled=1 config key, so persistent Discrete PCs behave exactly
#    as before (local profiles + OneDrive KFM). Enabling later for
#    pooled/non-persistent use is just GPO or the reg keys below.
# ---------------------------------------------------------------
Write-Host "== Installing FSLogix agent (dormant) ==" -ForegroundColor Cyan

$fsl = "$Work\fslogix.zip"
Invoke-WebRequest -Uri "https://aka.ms/fslogix_download" -OutFile $fsl
Expand-Archive $fsl -DestinationPath "$Work\fslogix" -Force
$fslSetup = Get-ChildItem "$Work\fslogix" -Recurse -Filter "FSLogixAppsSetup.exe" |
    Where-Object FullName -like "*x64*" | Select-Object -First 1
Start-Process $fslSetup.FullName -ArgumentList "/install /quiet /norestart" -Wait -NoNewWindow

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

New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableConsumerAccountStateContent" -Value 1 -Type DWord

# Kill "Chat"/widgets taskbar promos for all new users via default profile policy keys
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -Type DWord

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

# Key exists by default on Win11 - do not New-Item -Force it (throws on protected keys)
$blKey = "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker"
if (-not (Test-Path $blKey)) { New-Item -Path $blKey | Out-Null }
Set-ItemProperty $blKey -Name "PreventDeviceEncryption" -Value 1 -Type DWord

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

# Remove legacy attack surface: SMBv1 and PowerShell v2
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    Remove-WindowsFeature FS-SMB1 -ErrorAction SilentlyContinue | Out-Null
} else {
    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
    Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction SilentlyContinue | Out-Null
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
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty $k -Name "Enabled" -Value 0 -Type DWord
        Set-ItemProperty $k -Name "DisabledByDefault" -Value 1 -Type DWord
    }
}

# NTLMv2 only, refuse LM/NTLMv1; WDigest plaintext creds off
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LmCompatibilityLevel" -Value 5 -Type DWord
$wd = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest"
if (-not (Test-Path $wd)) { New-Item -Path $wd | Out-Null }
Set-ItemProperty $wd -Name "UseLogonCredential" -Value 0 -Type DWord

# LLMNR off (name-resolution poisoning mitigation)
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Value 0 -Type DWord

# AutoRun/AutoPlay off for all drive types
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255 -Type DWord
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoAutorun" -Value 1 -Type DWord

# UAC fully on with secure desktop; 15-minute machine inactivity lock
$sys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty $sys -Name "EnableLUA" -Value 1 -Type DWord
Set-ItemProperty $sys -Name "ConsentPromptBehaviorAdmin" -Value 5 -Type DWord
Set-ItemProperty $sys -Name "PromptOnSecureDesktop" -Value 1 -Type DWord
Set-ItemProperty $sys -Name "InactivityTimeoutSecs" -Value 900 -Type DWord

# RDP: require NLA, TLS security layer, high encryption
$rdp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
Set-ItemProperty $rdp -Name "UserAuthentication" -Value 1 -Type DWord
Set-ItemProperty $rdp -Name "SecurityLayer" -Value 2 -Type DWord
Set-ItemProperty $rdp -Name "MinEncryptionLevel" -Value 3 -Type DWord

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
# ---------------------------------------------------------------
Write-Host "== Writing sysprep unattend.xml ==" -ForegroundColor Cyan

@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
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
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <TimeZone>GMT Standard Time</TimeZone>
    </component>
  </settings>
</unattend>
"@ | Set-Content "C:\Windows\Panther\unattend.xml" -Encoding UTF8
Write-Host "  written to C:\Windows\Panther\unattend.xml"

# ---------------------------------------------------------------
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nDone. Verify Office/Teams launch, then generalise with:" -ForegroundColor Green
Write-Host "  C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /unattend:C:\Windows\Panther\unattend.xml" -ForegroundColor Green
Stop-Transcript | Out-Null
