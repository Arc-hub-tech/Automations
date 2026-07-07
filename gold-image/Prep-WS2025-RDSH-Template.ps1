<#
.SYNOPSIS
    Windows Server 2025 multi-session (RD Session Host) template prep.
    Run once as Administrator, reboot, verify, then sysprep/clone.
    1. Installs the RD Session Host role
    2. Installs Microsoft 365 Apps (64-bit, Monthly Enterprise, Shared Computer Licensing - mandatory on RDSH)
    3. Installs new Teams machine-wide (VDI-optimised)
    4. Installs FSLogix agent (profile container config left as placeholders)
    5. Sweeps unprovisioned appx packages (sysprep blockers)
    6. Ensures BitLocker is off and stays off on clones
    7. Session-host QoL: no Server Manager at logon, temp/WU cache cleared

.NOTES
    Run elevated:  Set-ExecutionPolicy Bypass -Scope Process -Force; .\Prep-WS2025-RDSH-Template.ps1
    A REBOOT IS REQUIRED after this script (RDSH role) before validating and sysprepping.
    RDS licensing mode/server is intentionally NOT set here - do it via GPO on the clones,
    or uncomment the registry block at the bottom.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Work = "$env:TEMP\RDSHPrep"
New-Item -ItemType Directory -Path $Work -Force | Out-Null

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
# 1. RD Session Host role
# ---------------------------------------------------------------
Write-Host "== Installing RD Session Host role ==" -ForegroundColor Cyan
if ((Get-WindowsFeature RDS-RD-Server).Installed) {
    Write-Host "  role already installed - skipping."
} else {
    $feat = Install-WindowsFeature RDS-RD-Server -IncludeManagementTools
    Write-Host "  role installed. Restart needed: $($feat.RestartNeeded)"
}

# ---------------------------------------------------------------
# 2. Microsoft 365 Apps via ODT (Shared Computer Licensing = required on RDSH)
# ---------------------------------------------------------------
Write-Host "== Installing Microsoft 365 Apps ==" -ForegroundColor Cyan

@"
<Configuration>
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-gb" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="OneDrive" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="1" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@ | Set-Content "$Work\office.xml" -Encoding UTF8

$odt = "$Work\odt.exe"
Invoke-WebRequest -Uri "https://officecdn.microsoft.com/pr/wsus/setup.exe" -OutFile $odt
# ODT's setup.exe doesn't reliably exit - launch it and poll Click-to-Run's
# registry instead: VersionToReport is written when the install completes.
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
Get-Process -Name odt, setup -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$Work*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# 3. New Teams (machine-wide, VDI optimised)
# ---------------------------------------------------------------
Write-Host "== Installing Teams (new) ==" -ForegroundColor Cyan

New-Item -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Name "IsWVDEnvironment" -Value 1 -Type DWord

$boot = "$Work\teamsbootstrapper.exe"
Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2243204" -OutFile $boot
Start-Process $boot -ArgumentList "-p" -Wait -NoNewWindow

# Remote Desktop WebRTC Redirector Service - enables Teams media optimisation
# for sessions connected via AVD/W365. Harmless but inert on plain RDS; remove
# this block if these hosts will never be AVD session hosts.
$rtc = "$Work\webrtc.msi"
Invoke-WebRequest -Uri "https://aka.ms/msrdcwebrtcsvc/msi" -OutFile $rtc
Start-Process msiexec -ArgumentList "/i `"$rtc`" /qn /norestart" -Wait -NoNewWindow

# ---------------------------------------------------------------
# 4. FSLogix agent (profile containers for non-persistent multi-session)
#    Agent installs here; POINT IT AT YOUR PROFILE SHARE before go-live
#    (uncomment and set VHDLocations below, or push via GPO/ADMX).
# ---------------------------------------------------------------
Write-Host "== Installing FSLogix ==" -ForegroundColor Cyan

$fsl = "$Work\fslogix.zip"
Invoke-WebRequest -Uri "https://aka.ms/fslogix_download" -OutFile $fsl
Expand-Archive $fsl -DestinationPath "$Work\fslogix" -Force
$fslSetup = Get-ChildItem "$Work\fslogix" -Recurse -Filter "FSLogixAppsSetup.exe" |
    Where-Object FullName -like "*x64*" | Select-Object -First 1
Start-Process $fslSetup.FullName -ArgumentList "/install /quiet /norestart" -Wait -NoNewWindow

# --- FSLogix profile container config (EDIT ME, then uncomment) ---
# $fslKey = "HKLM:\SOFTWARE\FSLogix\Profiles"
# New-Item -Path $fslKey -Force | Out-Null
# Set-ItemProperty $fslKey -Name "Enabled"              -Value 1 -Type DWord
# Set-ItemProperty $fslKey -Name "VHDLocations"         -Value "\\SERVER\Profiles$" -Type MultiString
# Set-ItemProperty $fslKey -Name "SizeInMBs"            -Value 30720 -Type DWord          # 30GB per your standard
# Set-ItemProperty $fslKey -Name "IsDynamic"            -Value 1 -Type DWord
# Set-ItemProperty $fslKey -Name "VolumeType"           -Value "VHDX" -Type String
# Set-ItemProperty $fslKey -Name "DeleteLocalProfileWhenVHDShouldApply" -Value 1 -Type DWord
# Set-ItemProperty $fslKey -Name "FlipFlopProfileDirectoryName"         -Value 1 -Type DWord

# ---------------------------------------------------------------
# 5. Sysprep-readiness sweep: remove appx installed for a user but
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
# 6. BitLocker: ensure decrypted, prevent device encryption on clones
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
# 7. UK regional and time settings (applied to system, welcome screen,
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

# ---------------------------------------------------------------
# 8. CE+ / ISO 27001 baseline hardening - image-safe defaults.
#    Domain GPO will override any of these on joined machines,
#    which is fine; these are the floor, not the ceiling.
#    NOTE: TLS 1.0/1.1 disable is the only item with app-compat risk
#    (ancient LOB apps) - remove that block for a legacy-app image.
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

# Local account lockout policy (matters until domain GPO applies)
net accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15 | Out-Null

# Guest account disabled
net user Guest /active:no 2>$null | Out-Null

# ---------------------------------------------------------------
# 9. Session-host QoL + cleanup
# ---------------------------------------------------------------
Write-Host "== Session host tweaks and cleanup ==" -ForegroundColor Cyan

# Don't launch Server Manager for every user at logon
Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager" -Name "DoNotOpenAtLogon" -Value 1 -Type DWord

# Clear temp + Windows Update download cache
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Get-ChildItem $env:TEMP, "C:\Windows\Temp", "C:\Windows\SoftwareDistribution\Download" -Recurse -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue

# --- RDS licensing (normally set via GPO on clones; uncomment to bake in) ---
# $rcm = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Licensing Core"
# Set-ItemProperty $rcm -Name "LicensingMode" -Value 4 -Type DWord   # 4 = Per User
# New-Item "HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters\LicenseServers" -Force | Out-Null
# Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters\LicenseServers" -Name "SpecifiedLicenseServers" -Value "LICSERVER.domain.local" -Type MultiString

# ---------------------------------------------------------------
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nDone. REBOOT NOW (RDSH role), verify Office/Teams launch, then: sysprep /oobe /generalize /shutdown" -ForegroundColor Green
