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
       .\Prep-WS2025-Server-Template.ps1

    Option B - pull and run the current main-branch version directly
    (no clone needed; review the script on GitHub first if unsure):

       irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/gold-image/Prep-WS2025-Server-Template.ps1 | iex
================================================================

.SYNOPSIS
    Windows Server 2025 general-purpose template prep - for member/app/file
    servers etc. that do NOT run the RD Session Host role or multi-user
    desktop sessions. For RDSH/VDI hosts, use Prep-WS2025-RDSH-Template.ps1
    instead - this script deliberately leaves out anything specific to
    shared sessions (no M365 Apps, Teams, WebRTC redirector, or FSLogix).
    Run once as Administrator, reboot, verify, then sysprep/clone.
    1. Detects VMware platform (via BIOS/SMBIOS) and installs/upgrades VMware Tools if out of date
    2. Removes Windows Defender (Sentinel EDR is the AV/EDR on these hosts)
    3. Sweeps unprovisioned appx packages (sysprep blockers)
    4. Ensures BitLocker is off and stays off on clones
    5. Sets UK regional/time settings
    6. Applies CE+/ISO 27001 baseline hardening
    7. Server QoL: no Server Manager at logon, temp/WU cache cleared
    8. Writes the sysprep unattend.xml

.NOTES
    Run elevated:  Set-ExecutionPolicy Bypass -Scope Process -Force; .\Prep-WS2025-Server-Template.ps1
    A REBOOT IS REQUIRED after this script (Defender removal) before validating and sysprepping.
    Windows Defender is fully removed, not just disabled - there is NO AV on the box until
    Sentinel is installed and enrolled. Deploy/enrol Sentinel immediately after sysprep/clone,
    before the host goes into service.
    Full run is logged to C:\ArcLogs\GoldImagePrep\ (transcript, timestamped per run).
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Work = "$env:TEMP\WS2025ServerPrep"
New-Item -ItemType Directory -Path $Work -Force | Out-Null

# Pin the process's actual working directory to $Work. Running via `irm | iex`
# (piped, no backing script file) can leave the inherited working directory
# invalid, which breaks any native exe launch with "the directory name is invalid".
Set-Location -Path $Work
[Environment]::CurrentDirectory = $Work

# ---------------------------------------------------------------
# Transcript logging - full run output captured for troubleshooting
# failed image builds. trap ensures the transcript is closed even if
# a later step throws (ErrorActionPreference is 'Stop' above).
# ---------------------------------------------------------------
$LogDir  = "$env:SystemDrive\ArcLogs\GoldImagePrep"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("Prep-WS2025-Server-Template_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
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
# 2. Remove Windows Defender - Sentinel is the AV/EDR for these hosts,
#    and running both simultaneously causes conflicts. Uninstalling the
#    feature (rather than just disabling it) leaves NO AV on the box
#    until Sentinel is deployed - enrol Sentinel immediately after
#    sysprep/clone, before the host goes into service.
# ---------------------------------------------------------------
Write-Host "== Removing Windows Defender (Sentinel EDR will replace it) ==" -ForegroundColor Cyan

if ((Get-WindowsFeature Windows-Defender).Installed) {
    $defFeat = Uninstall-WindowsFeature Windows-Defender
    Write-Host "  Windows Defender removed. Restart needed: $($defFeat.RestartNeeded)"
} else {
    Write-Host "  Windows Defender feature already absent."
}

# ---------------------------------------------------------------
# 3. Sysprep-readiness sweep: remove appx installed for a user but
#    not provisioned for all users (classic sysprep validation failure)
# ---------------------------------------------------------------
Write-Host "== Sweeping unprovisioned appx packages ==" -ForegroundColor Cyan

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
# 4. BitLocker: ensure decrypted, prevent device encryption on clones
# ---------------------------------------------------------------
Write-Host "== Checking BitLocker ==" -ForegroundColor Cyan

# BitLocker cmdlets only exist if the BitLocker feature is installed - and if
# it isn't, the volume can't be encrypted anyway, so just note it and move on.
if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
    $blv = Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue
    if ($blv -and $blv.VolumeStatus -ne 'FullyDecrypted') {
        Disable-BitLocker -MountPoint C: -ErrorAction SilentlyContinue | Out-Null
        $deadline = (Get-Date).AddMinutes(60)
        do {
            Start-Sleep -Seconds 15
            $blv = Get-BitLockerVolume -MountPoint C:
            Write-Host "  decrypting C: ... status: $($blv.VolumeStatus) ($($blv.EncryptionPercentage)%)"
        } until ($blv.VolumeStatus -eq 'FullyDecrypted' -or (Get-Date) -gt $deadline)
        if ($blv.VolumeStatus -ne 'FullyDecrypted') { Write-Warning "C: not fully decrypted - do NOT sysprep yet." }
    } else {
        Write-Host "  C: already fully decrypted."
    }
} else {
    Write-Host "  BitLocker feature not installed - nothing to decrypt."
}
$blKey = "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker"
if (-not (Test-Path $blKey)) { New-Item -Path $blKey | Out-Null }
Set-ItemProperty $blKey -Name "PreventDeviceEncryption" -Value 1 -Type DWord

# ---------------------------------------------------------------
# 5. UK regional and time settings (applied to system, welcome screen,
#    and the default profile so every clone/new user inherits them)
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

# Skip the "Choose privacy settings" screen on every future new user's first
# sign-in - a machine-wide policy, so unlike the sysprep unattend.xml (which
# only covers this image's own first boot) this keeps working for every user
# who ever logs into a clone made from this image.
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" -Name "DisablePrivacyExperience" -Value 1 -Type DWord

# ---------------------------------------------------------------
# 6. CE+ / ISO 27001 baseline hardening - image-safe defaults.
#    Domain GPO will override any of these on joined machines,
#    which is fine; these are the floor, not the ceiling.
#    NOTE: TLS 1.0/1.1 disable is the only item with app-compat risk
#    (ancient LOB apps) - remove that block for a legacy-app image.
# ---------------------------------------------------------------
Write-Host "== Applying CE+/ISO 27001 baseline hardening ==" -ForegroundColor Cyan

# Remove legacy attack surface: SMBv1 and PowerShell v2. Disable-WindowsOptionalFeature
# throws a hard COMException for a feature name that doesn't exist on this build/edition
# - -ErrorAction SilentlyContinue does NOT suppress that, so each feature needs an
# actual try/catch.
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    if ((Get-WindowsFeature FS-SMB1).Installed) {
        Remove-WindowsFeature FS-SMB1 -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  removed: FS-SMB1"
    } else {
        Write-Host "  FS-SMB1 already absent."
    }
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

# RDP: require NLA, TLS security layer, high encryption (for admin RDP access)
$rdp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
Set-ItemProperty $rdp -Name "UserAuthentication" -Value 1 -Type DWord
Set-ItemProperty $rdp -Name "SecurityLayer" -Value 2 -Type DWord
Set-ItemProperty $rdp -Name "MinEncryptionLevel" -Value 3 -Type DWord

# Local account lockout policy (matters until domain GPO applies)
net accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15 | Out-Null

# Guest account disabled
net user Guest /active:no 2>$null | Out-Null

# ---------------------------------------------------------------
# 7. Server QoL + cleanup
# ---------------------------------------------------------------
Write-Host "== Server tweaks and cleanup ==" -ForegroundColor Cyan

# Don't launch Server Manager for every user at logon
Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager" -Name "DoNotOpenAtLogon" -Value 1 -Type DWord

# Clear temp + Windows Update download cache
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Get-ChildItem $env:TEMP, "C:\Windows\Temp", "C:\Windows\SoftwareDistribution\Download" -Recurse -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# 8. Sysprep answer file - skips the entire OOBE (region, keyboard,
#    EULA, account creation, privacy screens). Clones boot straight
#    to the sign-in screen with the accounts baked into the image.
#    NOTE: if the image was built from a US ISO, change UILanguage
#    to en-US (display language can't be set to a pack that isn't
#    installed); everything else stays en-GB.
#
#    Windows Server's OOBE catalog doesn't have client-only elements like
#    HideLocalAccountScreen/HideOnlineAccountScreens/HideWirelessSetupInOOBE/
#    EnableFirstLogonAnimation - including them causes a hard "component or
#    setting does not exist" parse error at boot, so the OOBE block below is
#    deliberately trimmed to the Server-valid subset. Account creation is
#    instead bypassed via SkipMachineOOBE/SkipUserOOBE plus explicitly
#    declaring the standing admin account. So when a standing admin was
#    set up in step 0, this declares that SAME account with a freshly
#    generated, one-time random password (generated fresh per run, never
#    logged, never committed) purely so OOBE has an account to present at
#    the sign-in screen instead of the creation wizard. A FirstLogonCommand
#    then deletes this file immediately after specialize completes, so the
#    placeholder password only exists on disk for the few seconds of the
#    automated first-boot sequence before LAPS takes over and rotates the
#    account's real password.
# ---------------------------------------------------------------
Write-Host "== Writing sysprep unattend.xml ==" -ForegroundColor Cyan

$userAccountsXml = ""
$firstLogonXml   = ""
if ($StandingAdminReady) {
    function New-TempPassword {
        $upper  = 65..90  | Get-Random -Count 4 | ForEach-Object { [char]$_ }
        $lower  = 97..122 | Get-Random -Count 4 | ForEach-Object { [char]$_ }
        $digit  = 48..57  | Get-Random -Count 4 | ForEach-Object { [char]$_ }
        $symbol = '!','@','#','%','^','*' | Get-Random -Count 2
        -join (($upper + $lower + $digit + $symbol) | Get-Random -Count 14)
    }
    $TempPassword = New-TempPassword

    $userAccountsXml = @"

      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>$TempPassword</Value>
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
          <Description>Remove sysprep answer file (one-time placeholder password) immediately after first boot</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
"@
    $TempPassword = $null
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
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>1</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>GMT Standard Time</TimeZone>$userAccountsXml$firstLogonXml
    </component>
  </settings>
</unattend>
"@ | Set-Content "C:\Windows\Panther\unattend.xml" -Encoding UTF8
Write-Host "  written to C:\Windows\Panther\unattend.xml"

# ---------------------------------------------------------------
Set-Location -Path $env:SystemDrive\
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nDone. REBOOT NOW (Defender removal). After reboot: install/enrol Sentinel BEFORE this host serves production traffic," -ForegroundColor Green
Write-Host "then generalise with the EXACT command below (sysprep.exe is NOT on PATH - the full path is required):" -ForegroundColor Green
Write-Host "  C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /unattend:C:\Windows\Panther\unattend.xml" -ForegroundColor Green
Stop-Transcript | Out-Null
