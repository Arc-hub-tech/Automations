<#
================================================================
 BEFORE YOU RUN THIS SCRIPT
================================================================
 Workshop half of the standalone Hyper-V host build. Run it at Arc, on the
 iLO remote console or a local keyboard and screen, with internet access.
 The on-site half is ArcHyperVHost-Site.ps1.

 1. Log on as a local administrator. Open an elevated PowerShell prompt.
 2. DOWNLOAD-THEN-RUN (single line):

       $p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Workshop.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Workshop.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Next

    OR from a USB stick (no internet for the script itself):

       Set-ExecutionPolicy Bypass -Scope Process -Force; & E:\ArcHyperVHost\ArcHyperVHost-Workshop.ps1 -Phase Next

    Media is looked for under -MediaPath, else next to the script. The SPP is
    picked by ProLiant generation: <MediaPath>\SPP\Gen10|Gen10Plus|Gen11|Gen12\*.iso
    (then <MediaPath>\SPP\*.iso), and <MediaPath>\HPE\ilorest*.msi. The stick must be
    NTFS or exFAT (SPP ISOs are over 4 GB). Anything not found is prompted for.

 3. Everything is prompted - there is no config file. Answers that are not
    secret (host name, Datto site, IPs) are kept in
    C:\ArcLogs\HyperVHost\state.json so a re-run, and the Site script, do not
    ask again. Passwords are never stored or logged.

 SEQUENCE (-Phase Next runs it, stops at the gates, asks before each reboot,
 and carries on by itself when you next log on):

       PreFlight -> Hpe -> Base -> Storage -> Agents -> Updates -> Network -> Baseline -> Ship

 The workshop network is DHCP: the host builds its SET switch there and ships on
 a DHCP address. The Site script sets the customer static address on site.
 Ship is the LAST step before switching off: optionally set the customer address
 (if known) and the iLO network, then shut down.
================================================================

.SYNOPSIS
    Workshop build of a standalone HPE ProLiant Hyper-V host for a customer site.

.DESCRIPTION
    Phases (every phase is safe to re-run):
      Next       Attended automation - runs the next phase(s), stops at gates,
                 confirms reboots, resumes at the next logon.
      PreFlight  Read-only. HPE hardware, OS edition/install type, VT-x, Secure
                 Boot, TPM, NICs and disks.
      Hpe        SPP via SUM unattended; CHIF/AMS; ilorest; boot RAID report;
                 iLO Administrator password; iLO IPMI/SSDP off.
      Base       Host name, power plan, BIOS workload profile, Hyper-V role.
      Storage    Pick the VM disk (asked, never formats a disk with data), format
                 a RAW disk NTFS 64K, set the default VM/VHD paths.
      Agents     Datto RMM agent; Defender stays on, with the VM folder excluded.
      Updates    Windows Update (software only - no drivers over the SPP) until
                 nothing is left.
      Network    SET switch over the chosen NICs + Management host vNIC on the
                 workshop DHCP (untagged). The Site script sets the customer
                 static address. Needs the console (the DHCP address changes).
      Baseline   The security and optimisation standard (same code as the Site
                 script), so the host ships with it in place. Shows the plan first.
      Ship       Pre-ship checks; optional customer static address (normally set on
                 site) and iLO network/host name, then shut down.

.NOTES
    Shares its state file with ArcHyperVHost-Site.ps1. Logs and transcripts:
    C:\ArcLogs\HyperVHost\. Not a Datto component - an engineer runs it.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Next', 'PreFlight', 'Hpe', 'Base', 'Storage', 'Agents', 'Updates', 'Network', 'Baseline', 'Ship')]
    [string]$Phase,

    # Folder holding SPP\*.iso and HPE\ilorest*.msi (USB stick or share). Remembered.
    [string]$MediaPath
)

# Version of this script, surfaced in the banner/transcript. Both standalone
# scripts share one version; '-dev' suffix while work accumulates under [Unreleased].
$ScriptVersion = '0.1.0-dev'
$ScriptRole    = 'Workshop'   # which half of the build; names the state entries and the logon task

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$LogRoot   = "$env:SystemDrive\ArcLogs\HyperVHost"
$StatePath = Join-Path $LogRoot 'state.json'
$Work      = Join-Path $env:TEMP 'ArcHyperVHost'
New-Item -ItemType Directory -Path $LogRoot, $Work -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $LogRoot "Workshop-$Phase-$Stamp.log") | Out-Null

Write-Host "ArcHyperVHost-Workshop.ps1  v$ScriptVersion  -  phase: $Phase  -  $env:COMPUTERNAME" -ForegroundColor Cyan

# Keep a local copy, so the resume-at-logon task still works once a USB stick is removed.
$ScriptCopy = Join-Path $LogRoot "ArcHyperVHost-$ScriptRole.ps1"
if ($PSCommandPath -and $PSCommandPath -ne $ScriptCopy) { Copy-Item $PSCommandPath $ScriptCopy -Force }

# ---- start of shared helpers ----
# Everything down to "end of shared helpers" is identical in ArcHyperVHost-Workshop.ps1
# and ArcHyperVHost-Site.ps1 (each file is self-contained). Change both together.
# ---------------------------------------------------------------------------

function Write-Step { param([string]$Text) Write-Host "`n== $Text ==" -ForegroundColor Cyan }

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Check, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail })
    $colour = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$Status]
    Write-Host ("  [{0}] {1}{2}" -f $Status, $Check, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor $colour
}

function Confirm-Action {
    param([string]$Prompt)
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^(y|yes)$')
}

# Prompt with a default shown in brackets; Enter keeps the default.
function Read-Value {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate, [string]$Hint = 'Not valid - try again.')
    while ($true) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $v = (Read-Host "  $label").Trim()
        if (-not $v) { $v = $Default }
        if (-not $Validate -or (& $Validate $v)) { return $v }
        Write-Host "  $Hint" -ForegroundColor Yellow
    }
}

function Read-Secret {
    param([string]$Prompt, [switch]$Confirm)
    while ($true) {
        $a = Read-Host "  $Prompt (input hidden)" -AsSecureString
        if ($a.Length -eq 0) { Write-Host '  Nothing entered.' -ForegroundColor Yellow; continue }
        if (-not $Confirm) { return $a }
        $b = Read-Host '  Again to confirm (input hidden)' -AsSecureString
        if ((ConvertFrom-Secure $a) -ceq (ConvertFrom-Secure $b)) { return $a }
        Write-Host '  They do not match - try again.' -ForegroundColor Yellow
    }
}

function ConvertFrom-Secure {
    param([securestring]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Test-IPv4 { param([string]$Value) return [bool]($Value -match '^(\d{1,3}\.){3}\d{1,3}$' -and [System.Net.IPAddress]::TryParse($Value, [ref]$null)) }

function Set-RegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    } catch {
        Write-Warning "Could not set '$Name' under '$Path' - $($_.Exception.Message). Skipping; verify manually."
    }
}

# Start-Process -Wait looks identical to a hang during a long silent install -
# poll with a heartbeat instead.
function Start-ProcessWithHeartbeat {
    param([string]$FilePath, $ArgumentList, [string]$Label, [int]$HeartbeatSec = 30, [string]$WorkingDirectory = $Work)
    $spArgs = @{ FilePath = $FilePath; PassThru = $true; NoNewWindow = $true; WorkingDirectory = $WorkingDirectory }
    if ($ArgumentList) { $spArgs.ArgumentList = $ArgumentList }
    $proc = Start-Process @spArgs
    $elapsed = 0
    while (-not $proc.WaitForExit($HeartbeatSec * 1000)) {
        $elapsed += $HeartbeatSec
        Write-Host "  still running $Label... (${elapsed}s elapsed)"
    }
    return $proc.ExitCode
}

function Get-State {
    $s = if (Test-Path $StatePath) { Get-Content $StatePath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    foreach ($p in 'Phases', 'Answers') { if (-not $s.PSObject.Properties[$p]) { $s | Add-Member -NotePropertyName $p -NotePropertyValue ([pscustomobject]@{}) } }
    if (-not $s.PSObject.Properties['RebootPending']) { $s | Add-Member -NotePropertyName RebootPending -NotePropertyValue $false }
    return $s
}

function Save-State { param($State) $State | ConvertTo-Json -Depth 6 | Set-Content -Path $StatePath -Encoding UTF8 }

function Set-StateValue {
    param([string]$Name, $Value)
    $s = Get-State
    $s | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Save-State $s
}

function Save-PhaseComplete {
    param([string]$Name, [bool]$RebootNeeded = $false)
    $s = Get-State
    $s.Phases | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{ Completed = (Get-Date -Format 's'); Version = $ScriptVersion; Script = $ScriptRole }) -Force
    $s | Add-Member -NotePropertyName RebootPending -NotePropertyValue $RebootNeeded -Force
    $s | Add-Member -NotePropertyName RebootRequestedAt -NotePropertyValue $(if ($RebootNeeded) { Get-Date -Format 's' } else { $null }) -Force
    Save-State $s
}

function Request-RebootFlag {
    $s = Get-State
    $s | Add-Member -NotePropertyName RebootPending -NotePropertyValue $true -Force
    $s | Add-Member -NotePropertyName RebootRequestedAt -NotePropertyValue (Get-Date -Format 's') -Force
    Save-State $s
}

function Test-PhaseDone { param([string]$Name) return [bool](Get-State).Phases.PSObject.Properties[$Name] }

# Non-secret answers, remembered so a re-run (or the Site script) does not ask again.
function Get-Answer { param([string]$Name) $a = (Get-State).Answers.PSObject.Properties[$Name]; if ($a) { return $a.Value } return $null }
function Set-Answer {
    param([string]$Name, $Value)
    $s = Get-State
    $s.Answers | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Save-State $s
}

function Test-PendingReboot {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return [bool]$pfro
}

# True when this process runs in the physical/iLO console session (not RDP).
# $env:SESSIONNAME is not reliable when started from a scheduled task.
function Test-ConsoleSession {
    if (-not ('ArcNative.Wts' -as [type])) {
        Add-Type -Namespace ArcNative -Name Wts -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();'
    }
    return ((Get-Process -Id $PID).SessionId -eq [ArcNative.Wts]::WTSGetActiveConsoleSessionId())
}

function Get-IloRest {
    $ilo = (Get-Command ilorest.exe -ErrorAction SilentlyContinue).Source
    if (-not $ilo) { $ilo = Get-ChildItem "$env:ProgramFiles\Hewlett Packard Enterprise\RESTful Interface Tool\ilorest.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    return $ilo
}

# Runs ilorest from the work folder (it may drop a log there, removed afterwards).
function Invoke-IloRest {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'   # ilorest writes to stderr on a refused login; must not throw
    Push-Location $Work
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    } finally {
        Pop-Location
        Remove-Item (Join-Path $Work 'iLOrest.log') -Force -ErrorAction SilentlyContinue
    }
}

# In-band (CHIF) login, falling back to credentials if the iLO requires host authentication.
function Connect-ArcIlo {
    param([string]$Exe)
    $login = Invoke-IloRest $Exe @('login')
    if ($login.ExitCode -ne 0) {
        Write-Warning "In-band iLO login refused (likely 'Require Host Authentication' is on, or the iLO is not in Production security state):`n$($login.Output)"
        if (Confirm-Action 'Log in to iLO with credentials instead?') {
            $cred = Get-Credential -Message 'iLO account with configure rights'
            # ilorest only takes the password as an argument - it is visible on this
            # process's command line for the duration of the login call.
            $login = Invoke-IloRest $Exe @('login', '-u', $cred.UserName, '-p', $cred.GetNetworkCredential().Password)
        }
    }
    return ($login.ExitCode -eq 0)
}

function Get-IloJson {
    param([string]$Output)
    $s = $Output.IndexOf('{'); $e = $Output.LastIndexOf('}')
    if ($s -ge 0 -and $e -gt $s) { try { return ($Output.Substring($s, $e - $s + 1) | ConvertFrom-Json) } catch { } }
    return $null
}

# Patch one Redfish resource through ilorest rawpatch. The body must never hold a secret
# (it is written to a temp file).
function Invoke-IloRawPatch {
    param([string]$Exe, [string]$Path, [hashtable]$Body)
    $file = Join-Path $Work "rawpatch-$([guid]::NewGuid().ToString('N')).json"
    try {
        @{ path = $Path; body = $Body } | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding ASCII
        return Invoke-IloRest $Exe @('rawpatch', $file)
    } finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

$NextTaskName = "ArcHyperVHost${ScriptRole}Next"

# One-shot logon task for ANY member of local Administrators, so it still fires when
# the engineer logs back on with a different account (after a domain join, or once
# the built-in Administrator is disabled). Invoke-Next removes it when it starts.
function Register-ArcNextTask {
    if (-not (Test-Path $ScriptCopy)) { Write-Host '  (No script copy on disk - at your next logon, run -Phase Next yourself.)' -ForegroundColor Yellow; return }
    $admins    = ([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$ScriptCopy`" -Phase Next"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId $admins -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
    Register-ScheduledTask -TaskName $NextTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "  At your next logon with an administrator account, the next phase starts by itself (one-shot task '$NextTaskName')." -ForegroundColor Cyan
}

function Request-ArcReboot {
    param([string]$Reason = 'The last phase needs a reboot.')
    Write-Host "`n$Reason" -ForegroundColor Yellow
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        $running = @(Get-VM -ErrorAction SilentlyContinue | Where-Object State -eq 'Running')
        if ($running) { Write-Warning "$($running.Count) VM(s) are running ($($running.Name -join ', ')). A reboot stops them using each VM's automatic stop action - do it in a maintenance window." }
    }
    Register-ArcNextTask
    if (Confirm-Action 'Reboot now') {
        Write-Host '  Rebooting...'
        Stop-Transcript | Out-Null
        Restart-Computer -Force
        exit 0
    }
    Write-Host '  Not rebooting now - reboot when ready; the next phase picks up at your next logon.' -ForegroundColor Yellow
}

function Stop-Next {
    param([string]$Message)
    Write-Host "`n>> ACTION NEEDED: $Message" -ForegroundColor Yellow
    Write-Host '>> Then run:  -Phase Next' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# NICs and the host network (the Site script carries the same functions)
# ---------------------------------------------------------------------------

# Physical Ethernet ports that can join a SET switch: not the iLO virtual NIC (RNDIS),
# not USB, Wi-Fi or Bluetooth. Grouped by model, because SET members must match.
function Get-ArcNicGroups {
    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.NdisPhysicalMedium -eq 14 -and
        $_.InterfaceDescription -notmatch 'Virtual NIC|RNDIS|Remote NDIS|USB|Bluetooth|Wi-?Fi|Wireless'
    })
    $groups = @($nics | Group-Object { $_.InterfaceDescription -replace '\s#\d+$', '' } | ForEach-Object {
        $up = @($_.Group | Where-Object Status -eq 'Up')
        [pscustomobject]@{
            Model   = $_.Name
            Names   = @($_.Group | Sort-Object Name | ForEach-Object Name)
            Count   = $_.Count
            Up      = $up.Count
            Speed   = (@($up | ForEach-Object LinkSpeed) | Sort-Object -Unique) -join ', '
            # Rank: 10/25GbE parts first (by model name, since unplugged ports report 0 bps), then more ports.
            Rank    = $(if ($_.Name -match '10G|25G|40G|SFP|10Gb|25Gb|536FLR|562|566|631|640|621|534') { 0 } else { 1 })
        }
    } | Sort-Object Rank, @{ e = { -$_.Count } })
    for ($i = 0; $i -lt $groups.Count; $i++) { $groups[$i] | Add-Member -NotePropertyName Number -NotePropertyValue ($i + 1) }
    return $groups
}

function Show-ArcNics {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object Name |
        Format-Table Name, InterfaceDescription, MacAddress, LinkSpeed, Status -AutoSize | Out-String -Width 220 | Write-Host
}

function Get-ArcSetSwitch {
    return (Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Where-Object EmbeddedTeamingEnabled | Select-Object -First 1)
}

function Test-ArcMgmtOnDhcp {
    $i = Get-NetIPInterface -InterfaceAlias 'vEthernet (Management)' -AddressFamily IPv4 -ErrorAction SilentlyContinue
    return ($i -and "$($i.Dhcp)" -eq 'Enabled')
}

function Confirm-ArcConsoleForNetwork {
    if (Test-ConsoleSession) { return $true }
    Write-Warning 'This is not the console session. This change moves the host address and drops an RDP session (and a VLAN change may not come back).'
    $a = Read-Host '  Use the iLO remote console instead. Type REMOTE to carry on here anyway'
    return ($a -ceq 'REMOTE')
}

# Sets the Management vNIC's VLAN and address (static by default). Used on site to
# move a workshop-built host from the workshop DHCP address to its customer address.
function Set-ArcMgmtAddress {
    param([switch]$SkipConsoleCheck)
    $alias = 'vEthernet (Management)'
    if (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue)) { Write-Warning "No '$alias' host vNIC on this host."; return $false }
    if (-not $SkipConsoleCheck -and -not (Confirm-ArcConsoleForNetwork)) { return $false }
    $vlan = Read-Value 'Management VLAN ID (blank = untagged)' "$(Get-Answer 'MgmtVlan')" { param($v) -not $v -or ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 4094) }
    $mode = Read-Value 'Management IP: [S]tatic or [D]HCP' 'S' { param($v) $v -match '^[SsDd]$' }
    $ip = $null; $prefix = $null; $gw = $null; $dns = @()
    if ($mode -match '^[Ss]$') {
        $ip     = Read-Value 'Management IP address' "$(Get-Answer 'MgmtIp')" { param($v) Test-IPv4 $v }
        $prefix = Read-Value 'Prefix length (e.g. 24)' $(if (Get-Answer 'MgmtPrefix') { "$(Get-Answer 'MgmtPrefix')" } else { '24' }) { param($v) $v -match '^\d+$' -and [int]$v -ge 8 -and [int]$v -le 30 }
        $gw     = Read-Value 'Default gateway' "$(Get-Answer 'MgmtGateway')" { param($v) Test-IPv4 $v }
        $dnsIn  = Read-Value 'DNS servers, comma separated' "$((@(Get-Answer 'MgmtDns') | Where-Object { $_ }) -join ',')" { param($v) @($v -split ',' | ForEach-Object Trim | Where-Object { -not (Test-IPv4 $_) }).Count -eq 0 }
        $dns    = @($dnsIn -split ',' | ForEach-Object Trim | Where-Object { $_ })
    }
    Write-Host "`n  Plan: host vNIC 'Management', VLAN $(if ($vlan) { $vlan } else { 'untagged' }), $(if ($ip) { "$ip/$prefix gw $gw dns $($dns -join ',')" } else { 'DHCP' })"
    if (-not (Confirm-Action 'Apply it now')) { return $false }

    if ($vlan) { Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName 'Management' -Access -VlanId ([int]$vlan) }
    else { Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName 'Management' -Untagged }
    if ($ip) {
        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Disabled
        Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $ip -PrefixLength ([int]$prefix) -DefaultGateway $gw | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $dns
    } else {
        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses
    }
    Write-Host '  Management address set.' -ForegroundColor Green
    Set-Answer 'MgmtVlan' $vlan; Set-Answer 'MgmtIp' $ip; Set-Answer 'MgmtPrefix' $prefix; Set-Answer 'MgmtGateway' $gw; Set-Answer 'MgmtDns' $dns
    Set-Answer 'MgmtFromWorkshop' $false
    return $true
}

# Builds the SET switch and the Management host vNIC, or verifies an existing one.
# -Workshop: the Management vNIC stays on DHCP, untagged, so the workshop network (and
# internet) keeps working; the Site script sets the customer static address on it.
# Never rebuilds a switch, and only moves an address the workshop left on DHCP.
function Invoke-ArcHostNetwork {
    param([switch]$Workshop)
    if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) { throw 'Hyper-V is not installed (the Workshop script''s Base phase installs it).' }
    $existing = Get-ArcSetSwitch
    $anyExternal = @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue)
    if ($existing -or $anyExternal) {
        $sw = if ($existing) { $existing } else { $anyExternal[0] }
        Write-Host "  External switch '$($sw.Name)' already exists - this script never rebuilds a switch." -ForegroundColor Green
        if (-not $sw.EmbeddedTeamingEnabled) { Write-Warning "'$($sw.Name)' is not a SET switch. Rebuilding it is a manual, maintenance-window job." }
        Get-VMNetworkAdapter -ManagementOS | ForEach-Object {
            $ip = Get-NetIPAddress -InterfaceAlias "vEthernet ($($_.Name))" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            $vl = Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $_.Name
            Write-Host ("  host vNIC {0,-14} VLAN {1,-9} {2}" -f $_.Name, $(if ($vl.OperationMode -eq 'Access') { $vl.AccessVlanId } else { 'untagged' }), $(if ($ip) { "$($ip.IPAddress)/$($ip.PrefixLength) ($($ip.PrefixOrigin))" } else { 'no IPv4' }))
        }
        if (-not $Workshop -and (Get-Answer 'MgmtFromWorkshop') -and (Test-ArcMgmtOnDhcp)) {
            Write-Host '  The Management vNIC still has its workshop DHCP address - set the customer address now.' -ForegroundColor Yellow
            return (Set-ArcMgmtAddress)
        }
        return $true
    }
    if (@(Get-VM -ErrorAction SilentlyContinue).Count) { Write-Warning 'VMs exist on this host but there is no external switch - left alone; build the network by hand in a maintenance window. The Report flags it.'; return $true }
    if (-not (Confirm-ArcConsoleForNetwork)) { return $false }

    Write-Step 'Physical NICs'
    Show-ArcNics
    $groups = @(Get-ArcNicGroups)
    if (-not $groups) { throw 'No physical Ethernet NICs found.' }
    foreach ($g in $groups) { Write-Host ("  [{0}] {1}  x{2} ({3} up{4})  {5}" -f $g.Number, $g.Model, $g.Count, $g.Up, $(if ($g.Speed) { ", $($g.Speed)" } else { '' }), ($g.Names -join ', ')) }
    Write-Host '  SET members must be the same make, model and speed. The suggested group is [1].'
    $pick = Read-Value 'Group number, or NIC names separated by commas' '1' { param($v) $v -match '^\d+$' -or $v -match '\S' }
    $members = if ($pick -match '^\d+$') { @(($groups | Where-Object Number -eq [int]$pick).Names) } else { @($pick -split ',' | ForEach-Object Trim | Where-Object { $_ }) }
    foreach ($m in $members) { if (-not (Get-NetAdapter -Name $m -ErrorAction SilentlyContinue)) { throw "NIC '$m' not found." } }
    if (-not $members) { throw 'No NICs chosen.' }
    $models = @($members | ForEach-Object { (Get-NetAdapter -Name $_).InterfaceDescription -replace '\s#\d+$', '' } | Sort-Object -Unique)
    if ($models.Count -gt 1 -and -not (Confirm-Action "Members are different models ($($models -join '; ')). SET needs matching NICs. Carry on anyway")) { return $false }
    if (-not @($members | Where-Object { (Get-NetAdapter -Name $_).Status -eq 'Up' })) {
        Write-Warning $(if ($Workshop) { 'None of the chosen NICs has a link - cable one to the workshop network, or the host loses internet access.' } else { 'None of the chosen NICs has a link - the host will be unreachable until one is cabled.' })
    }
    $swName = Read-Value 'Switch name' $(if (Get-Answer 'SwitchName') { Get-Answer 'SwitchName' } else { 'SET' }) { param($v) $v -match '^[\w\- ]{1,40}$' }

    Write-Host "`n  Plan: SET switch '$swName' over $($members -join ', ') (Hyper-V port load balancing, weight mode)"
    Write-Host "        host vNIC 'Management' - $(if ($Workshop) { 'DHCP, untagged (workshop network; the customer address is set on site)' } else { 'address asked next' })"
    if (-not (Confirm-Action 'Build it now')) { return $false }

    New-VMSwitch -Name $swName -NetAdapterName $members -EnableEmbeddedTeaming $true -AllowManagementOS $false -MinimumBandwidthMode Weight | Out-Null
    Set-VMSwitchTeam -Name $swName -LoadBalancingAlgorithm HyperVPort
    Add-VMNetworkAdapter -ManagementOS -SwitchName $swName -Name 'Management'
    $alias = 'vEthernet (Management)'
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue)) { throw "'$alias' did not appear." }
    Write-Host "  Switch '$swName' and host vNIC 'Management' built." -ForegroundColor Green
    Set-Answer 'SwitchName' $swName; Set-Answer 'SwitchMembers' $members

    if ($Workshop) {
        Set-Answer 'MgmtFromWorkshop' $true
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object PrefixOrigin -eq 'Dhcp') -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
        $lease = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object PrefixOrigin -eq 'Dhcp' | Select-Object -First 1
        if ($lease) { Write-Host "  Workshop DHCP address: $($lease.IPAddress)" -ForegroundColor Green } else { Write-Warning 'No DHCP address yet on the Management vNIC - check the workshop cabling.' }
        return $true
    }
    return (Set-ArcMgmtAddress -SkipConsoleCheck)
}

function Set-ArcWorkloadProfile {
    param([string]$Target = 'Virtualization-MaxPerformance')
    $ilo = Get-IloRest
    if (-not $ilo) { Write-Warning 'ilorest not installed - set the workload profile in RBSU by hand (System Configuration > BIOS > Workload Profile).'; return $false }
    if (-not (Connect-ArcIlo $ilo)) { Write-Warning 'Skipping the BIOS step - no iLO session. Set the workload profile by hand.'; return $false }
    $changed = $false
    try {
        $current = (Get-IloJson (Invoke-IloRest $ilo @('get', 'WorkloadProfile', '--selector=Bios.', '--json')).Output).WorkloadProfile
        Write-Host "  Current workload profile: $current"
        if ($current -eq $Target) { Write-Host '  Already set.' -ForegroundColor Green }
        else {
            # The profile locks its dependent settings (power regulator, C-states, VT-x/VT-d).
            $set = Invoke-IloRest $ilo @('set', "WorkloadProfile=$Target", '--selector=Bios.', '--commit')
            if ($set.ExitCode -ne 0) { Write-Warning "Setting the workload profile failed:`n$($set.Output)" }
            else { Write-Host "  Workload profile set to $Target - applies at next reboot." -ForegroundColor Green; $changed = $true }
        }
    } finally { Invoke-IloRest $ilo @('logout') | Out-Null }
    return $changed
}

# Defender's automatic Hyper-V role exclusions cover the VM file types and processes
# wherever they live; add the VM folder too, and make sure auto-exclusions are on.
function Set-ArcDefenderHyperVExclusions {
    $svc = Get-Service WinDefend -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { Write-Host '  Defender is not running - no exclusions to set.'; return }
    $pref = Get-MpPreference
    if ($pref.DisableAutoExclusions) { Set-MpPreference -DisableAutoExclusions $false; Write-Host '  Server role auto-exclusions turned back on.' -ForegroundColor Yellow }
    $vmPath = (Get-VMHost -ErrorAction SilentlyContinue).VirtualMachinePath
    $paths = @($vmPath, "$env:ProgramData\Microsoft\Windows\Hyper-V") | Where-Object { $_ -and $_ -notin @($pref.ExclusionPath) }
    if ($paths) { Add-MpPreference -ExclusionPath $paths; Write-Host "  Defender exclusions added: $($paths -join ', ')" -ForegroundColor Green }
    else { Write-Host '  Defender Hyper-V exclusions already in place.' -ForegroundColor Green }
}

# ---------------------------------------------------------------------------
# Baseline catalogue - registry-backed security defaults and optimisations. ONE list,
# used to read current values and to apply. Lifted from the cluster standard, minus
# the cluster, FC/MPIO and NUMA items.
# ---------------------------------------------------------------------------

$Standard = [pscustomobject]@{
    InactivityTimeoutSecs = 900
    LockoutThreshold      = 10
    WorkloadProfile       = 'Virtualization-MaxPerformance'
}

$Sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$Rdp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$RegCatalogue = @(
    @{ Id = 'Sec.LmCompatibilityLevel';    Group = 'Security';      Restart = $false; Desc = 'NTLMv2 only, refuse LM/NTLMv1';          Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'LmCompatibilityLevel'; Value = 5 }
    @{ Id = 'Sec.WDigest';                 Group = 'Security';      Restart = $false; Desc = 'WDigest plaintext credentials off';      Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'; Name = 'UseLogonCredential'; Value = 0 }
    @{ Id = 'Sec.LLMNR';                   Group = 'Security';      Restart = $false; Desc = 'LLMNR off';                              Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; Name = 'EnableMulticast'; Value = 0 }
    @{ Id = 'Sec.NoDriveTypeAutoRun';      Group = 'Security';      Restart = $false; Desc = 'AutoRun off (all drive types)';          Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun'; Value = 255 }
    @{ Id = 'Sec.NoAutorun';               Group = 'Security';      Restart = $false; Desc = 'AutoPlay off';                           Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoAutorun'; Value = 1 }
    @{ Id = 'Sec.UAC.EnableLUA';           Group = 'Security';      Restart = $true;  Desc = 'UAC on';                                 Path = $Sys; Name = 'EnableLUA'; Value = 1 }
    @{ Id = 'Sec.UAC.ConsentAdmin';        Group = 'Security';      Restart = $false; Desc = 'UAC prompt for admins';                  Path = $Sys; Name = 'ConsentPromptBehaviorAdmin'; Value = 5 }
    @{ Id = 'Sec.UAC.SecureDesktop';       Group = 'Security';      Restart = $false; Desc = 'UAC on the secure desktop';              Path = $Sys; Name = 'PromptOnSecureDesktop'; Value = 1 }
    @{ Id = 'Sec.InactivityTimeoutSecs';   Group = 'Security';      Restart = $true;  Desc = 'Machine inactivity lock (seconds)';      Path = $Sys; Name = 'InactivityTimeoutSecs'; Value = $Standard.InactivityTimeoutSecs }
    @{ Id = 'Sec.RDP.Allow';               Group = 'Security';      Restart = $false; Desc = 'Remote Desktop allowed (admin access)';  Path = $Rdp; Name = 'fDenyTSConnections'; Value = 0 }
    @{ Id = 'Sec.RDP.NLA';                 Group = 'Security';      Restart = $false; Desc = 'RDP requires NLA';                       Path = "$Rdp\WinStations\RDP-Tcp"; Name = 'UserAuthentication'; Value = 1 }
    @{ Id = 'Sec.RDP.TLS';                 Group = 'Security';      Restart = $false; Desc = 'RDP TLS security layer';                 Path = "$Rdp\WinStations\RDP-Tcp"; Name = 'SecurityLayer'; Value = 2 }
    @{ Id = 'Sec.RDP.Encryption';          Group = 'Security';      Restart = $false; Desc = 'RDP high encryption';                    Path = "$Rdp\WinStations\RDP-Tcp"; Name = 'MinEncryptionLevel'; Value = 3 }
    @{ Id = 'Opt.8dot3';                   Group = 'Optimisation';  Restart = $true;  Desc = 'NTFS 8.3 short-name creation off';       Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'NtfsDisable8dot3NameCreation'; Value = 1 }
    @{ Id = 'Opt.ServerManagerAtLogon';    Group = 'Optimisation';  Restart = $false; Desc = 'Server Manager not opened at logon';     Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager'; Name = 'DoNotOpenAtLogon'; Value = 1 }
)
foreach ($proto in 'SSL 3.0', 'TLS 1.0', 'TLS 1.1') {
    foreach ($role in 'Server', 'Client') {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\$role"
        $RegCatalogue += @{ Id = "Sec.Tls.$proto.$role.Enabled"; Group = 'Security'; Restart = $true; Desc = "$proto ($role) disabled"; Path = $k; Name = 'Enabled'; Value = 0 }
        $RegCatalogue += @{ Id = "Sec.Tls.$proto.$role.DisabledByDefault"; Group = 'Security'; Restart = $true; Desc = "$proto ($role) off by default"; Path = $k; Name = 'DisabledByDefault'; Value = 1 }
    }
}

# Telemetry / CEIP / Maps / error-report tasks - pure overhead on a Hyper-V host.
# NOT the scheduled defrag task (it also does the retrim on SSD arrays).
$OptTasks = @(
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
    @('\Microsoft\Windows\Maps\', 'MapsUpdateTask'),
    @('\Microsoft\Windows\Maps\', 'MapsToastTask'),
    @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload')
)

# Rule groups a standalone Hyper-V host needs open before the firewall goes on.
$FirewallGroups = @('Hyper-V', 'Windows Remote Management', 'File and Printer Sharing', 'Windows Management Instrumentation (WMI)', '@FirewallAPI.dll,-28752')

function Get-ArcSwitchMembers {
    $out = @()
    foreach ($sw in Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue) {
        try {
            $desc = @((Get-VMSwitchTeam -Name $sw.Name -ErrorAction Stop).NetAdapterInterfaceDescription)
            $out += @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -in $desc })
        } catch {
            if ($sw.NetAdapterInterfaceDescription) { $out += @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -eq $sw.NetAdapterInterfaceDescription }) }
        }
    }
    return $out
}

# The BIOS profile needs an iLO session (which may prompt) - read it once per run.
$script:WorkloadProfileRead = $false
$script:WorkloadProfile = $null
function Get-ArcWorkloadProfile {
    if ($script:WorkloadProfileRead) { return $script:WorkloadProfile }
    $script:WorkloadProfileRead = $true
    $ilo = Get-IloRest
    if (-not $ilo) { return $null }
    if (-not (Connect-ArcIlo $ilo)) { return $null }
    try { $script:WorkloadProfile = (Get-IloJson (Invoke-IloRest $ilo @('get', 'WorkloadProfile', '--selector=Bios.', '--json')).Output).WorkloadProfile }
    finally { Invoke-IloRest $ilo @('logout') | Out-Null }
    return $script:WorkloadProfile
}

# Current values of everything the baseline looks at.
function Get-ArcHostFacts {
    $c = @{}
    foreach ($r in $RegCatalogue) {
        try { $c[$r.Id] = "$((Get-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction Stop).($r.Name))" } catch { $c[$r.Id] = '(not set)' }
    }
    try {
        $smb = Get-SmbServerConfiguration
        $c['Sec.SMB1Protocol']     = "$($smb.EnableSMB1Protocol)"
        $c['Sec.SmbServerSigning'] = "$($smb.RequireSecuritySignature)"
        $c['Sec.SmbClientSigning'] = "$((Get-SmbClientConfiguration).RequireSecuritySignature)"
    } catch { }
    foreach ($f in Get-WindowsFeature -Name FS-SMB1, PowerShell-V2 -ErrorAction SilentlyContinue) { $c["Sec.Feature.$($f.Name)"] = if ($f.Installed) { 'Installed' } else { 'Not installed' } }
    try { foreach ($p in Get-NetFirewallProfile) { $c["Sec.Firewall.$($p.Name)"] = "$($p.Enabled)" } } catch { }
    try {
        $na = (net accounts) | Out-String
        if ($na -match 'Lockout threshold:\s+(\S+)') { $c['Sec.LockoutThreshold'] = if ($Matches[1] -eq 'Never') { '0' } else { $Matches[1] } }
    } catch { }
    try { $c['Sec.GuestEnabled'] = "$((Get-LocalUser -Name Guest -ErrorAction Stop).Enabled)" } catch { }
    try { $c['Sec.Spooler'] = "$((Get-Service Spooler -ErrorAction Stop).StartType)" } catch { $c['Sec.Spooler'] = 'Absent' }
    try { $c['Opt.Hibernate'] = "$((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled)" } catch { $c['Opt.Hibernate'] = '(not set)' }
    try {
        $la = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name NtfsDisableLastAccessUpdate -ErrorAction Stop).NtfsDisableLastAccessUpdate
        $c['Opt.LastAccess'] = if (([int64]$la -band 1) -eq 1) { 'Disabled' } else { 'Enabled' }
    } catch { $c['Opt.LastAccess'] = '(not set)' }
    $on = 0
    foreach ($t in $OptTasks) {
        $task = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
        if ($task -and $task.State -ne 'Disabled') { $on++ }
    }
    $c['Opt.TelemetryTasks'] = if ($on) { "$on enabled" } else { 'All disabled' }
    $pc = (powercfg /getactivescheme) | Out-String
    if ($pc -match 'GUID:\s*([0-9a-fA-F-]+)\s+\(([^)]+)\)') { $c['Power.ActivePlan'] = "$($Matches[2]) ($($Matches[1]))" }
    $members = @(Get-ArcSwitchMembers)
    if ($members) {
        $pmOn = @($members | Where-Object { (Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue).AllowComputerToTurnOffDevice -eq 'Enabled' })
        $c['Opt.NicPowerManagement'] = if ($pmOn) { "Enabled on $($pmOn.Name -join ', ')" } else { 'Disabled' }
        $vmqOff = @($members | Where-Object { -not (Get-NetAdapterVmq -Name $_.Name -ErrorAction SilentlyContinue).Enabled })
        $c['Opt.VMQ'] = if ($vmqOff) { "Disabled on $($vmqOff.Name -join ', ')" } else { 'Enabled' }
    }
    $wp = Get-ArcWorkloadProfile
    if ($wp) { $c['HPE.Bios.WorkloadProfile'] = $wp }
    return $c
}

function New-PlanItem {
    param([string]$Area, [string]$Id, [string]$Desc, $Current, $Desired, [bool]$Restart, [string]$Kind, [hashtable]$Arguments = @{})
    [pscustomobject]@{ Area = $Area; Id = $Id; Desc = $Desc; Current = "$Current"; Desired = "$Desired"; Restart = $Restart; Kind = $Kind; Arguments = $Arguments }
}

# Everything on this host that differs from the standard. Pure - reads the facts only.
function Get-BaselinePlan {
    param([Parameter(Mandatory)][hashtable]$Facts)
    $c = $Facts
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($r in $RegCatalogue) {
        $cur = "$($c[$r.Id])"
        # The inactivity lock is a maximum - a shorter lock already set is stricter, so keep it.
        if ($r.Id -eq 'Sec.InactivityTimeoutSecs' -and $cur -match '^\d+$' -and [int]$cur -gt 0 -and [int]$cur -le [int]$r.Value) { continue }
        if ($cur -ne "$($r.Value)") {
            $items.Add((New-PlanItem $r.Group $r.Id $r.Desc $c[$r.Id] $r.Value $r.Restart 'Registry' @{ Path = $r.Path; Name = $r.Name; Value = [int]$r.Value }))
        }
    }
    if ($c['Sec.SMB1Protocol'] -eq 'True') { $items.Add((New-PlanItem 'Security' 'Sec.SMB1Protocol' 'SMBv1 protocol off' 'True' 'False' $false 'Smb1Protocol')) }
    foreach ($f in 'FS-SMB1', 'PowerShell-V2') {
        if ($c["Sec.Feature.$f"] -eq 'Installed') { $items.Add((New-PlanItem 'Security' "Sec.Feature.$f" "Remove $f" 'Installed' 'Not installed' $true 'RemoveFeature' @{ Name = $f })) }
    }
    if ($c['Sec.SmbServerSigning'] -eq 'False') { $items.Add((New-PlanItem 'Security' 'Sec.SmbServerSigning' 'SMB signing required (server)' 'False' 'True' $false 'SmbServerSigning')) }
    if ($c['Sec.SmbClientSigning'] -eq 'False') { $items.Add((New-PlanItem 'Security' 'Sec.SmbClientSigning' 'SMB signing required (client)' 'False' 'True' $false 'SmbClientSigning')) }
    foreach ($p in 'Domain', 'Private', 'Public') {
        if ($c["Sec.Firewall.$p"] -eq 'False') { $items.Add((New-PlanItem 'Security' "Sec.Firewall.$p" "Firewall on ($p) - Hyper-V/WinRM/SMB/WMI/RDP rules enabled first" 'False' 'True' $false 'Firewall' @{ Profile = $p })) }
    }
    # Lockout threshold is a maximum too: a lower non-zero value is stricter.
    $lt = "$($c['Sec.LockoutThreshold'])"
    if (-not ($lt -match '^\d+$' -and [int]$lt -gt 0 -and [int]$lt -le $Standard.LockoutThreshold)) {
        $items.Add((New-PlanItem 'Security' 'Sec.LockoutThreshold' 'Local account lockout threshold (15 min)' $c['Sec.LockoutThreshold'] $Standard.LockoutThreshold $false 'Lockout' @{ Threshold = $Standard.LockoutThreshold }))
    }
    if ($c['Sec.GuestEnabled'] -eq 'True') { $items.Add((New-PlanItem 'Security' 'Sec.GuestEnabled' 'Guest account disabled' 'True' 'False' $false 'GuestDisable')) }
    if ($c['Sec.Spooler'] -and $c['Sec.Spooler'] -notin 'Disabled', 'Absent') { $items.Add((New-PlanItem 'Security' 'Sec.Spooler' 'Print Spooler disabled (not needed on a Hyper-V host)' $c['Sec.Spooler'] 'Disabled' $false 'SpoolerDisable')) }

    if ($c['Power.ActivePlan'] -notmatch '8c5e7fda') { $items.Add((New-PlanItem 'Optimisation' 'Opt.PowerPlan' 'High Performance power plan' $c['Power.ActivePlan'] 'High performance' $false 'PowerPlan')) }
    if ($c['Opt.Hibernate'] -ne '0') { $items.Add((New-PlanItem 'Optimisation' 'Opt.Hibernate' 'Hibernation off' $c['Opt.Hibernate'] '0' $false 'Hibernate')) }
    if ($c['Opt.LastAccess'] -ne 'Disabled') { $items.Add((New-PlanItem 'Optimisation' 'Opt.LastAccess' 'NTFS last-access updates off' $c['Opt.LastAccess'] 'Disabled' $true 'LastAccess')) }
    if ($c['Opt.TelemetryTasks'] -ne 'All disabled') { $items.Add((New-PlanItem 'Optimisation' 'Opt.TelemetryTasks' 'Telemetry/CEIP/Maps/WER tasks off (defrag/retrim left on)' $c['Opt.TelemetryTasks'] 'All disabled' $false 'Tasks')) }
    if ($c['Opt.NicPowerManagement'] -and $c['Opt.NicPowerManagement'] -ne 'Disabled') { $items.Add((New-PlanItem 'Optimisation' 'Opt.NicPowerManagement' 'NIC power management off (switch members)' $c['Opt.NicPowerManagement'] 'Disabled' $false 'NicPower')) }
    if ($c['Opt.VMQ'] -and $c['Opt.VMQ'] -ne 'Enabled') { $items.Add((New-PlanItem 'Optimisation' 'Opt.VMQ' 'VMQ on (switch members; adapter restarts - VMs lose network for a few seconds)' $c['Opt.VMQ'] 'Enabled' $false 'Vmq')) }

    if ($c.ContainsKey('HPE.Bios.WorkloadProfile') -and $c['HPE.Bios.WorkloadProfile'] -ne $Standard.WorkloadProfile) {
        $items.Add((New-PlanItem 'HPE' 'HPE.WorkloadProfile' 'BIOS workload profile' $c['HPE.Bios.WorkloadProfile'] $Standard.WorkloadProfile $true 'WorkloadProfile' @{ Target = $Standard.WorkloadProfile }))
    }
    return $items
}

function Invoke-PlanItem {
    param([Parameter(Mandatory)]$Item)
    $a = $Item.Arguments
    switch ($Item.Kind) {
        'Registry'         { Set-RegistryValue -Path $a.Path -Name $a.Name -Value $a.Value }
        'Smb1Protocol'     { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force }
        'RemoveFeature'    { Uninstall-WindowsFeature -Name $a.Name | Out-Null }
        'SmbServerSigning' { Set-SmbServerConfiguration -RequireSecuritySignature $true -Force }
        'SmbClientSigning' { Set-SmbClientConfiguration -RequireSecuritySignature $true -Force }
        'Firewall' {
            foreach ($g in $FirewallGroups) {
                $rules = if ($g -like '@*') { Get-NetFirewallRule -Group $g -ErrorAction SilentlyContinue } else { Get-NetFirewallRule -DisplayGroup $g -ErrorAction SilentlyContinue }
                if ($rules) { $rules | Enable-NetFirewallRule; Write-Host "    firewall rules enabled: $g" }
            }
            Set-NetFirewallProfile -Profile $a.Profile -Enabled True
        }
        'Lockout'          { net accounts /lockoutthreshold:$($a.Threshold) /lockoutduration:15 /lockoutwindow:15 | Out-Null }
        'GuestDisable'     { Disable-LocalUser -Name Guest }
        'SpoolerDisable'   { Stop-Service Spooler -Force -ErrorAction SilentlyContinue; Set-Service Spooler -StartupType Disabled }
        'PowerPlan'        { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
        'Hibernate'        { powercfg /hibernate off | Out-Null }
        'LastAccess'       { fsutil behavior set disablelastaccess 1 | Out-Null }
        'Tasks' {
            foreach ($t in $OptTasks) {
                $task = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
                if ($task -and $task.State -ne 'Disabled') { $task | Disable-ScheduledTask | Out-Null }
            }
        }
        'NicPower'         { foreach ($n in Get-ArcSwitchMembers) { Disable-NetAdapterPowerManagement -Name $n.Name -NoRestart -ErrorAction SilentlyContinue } }
        'Vmq'              { foreach ($n in Get-ArcSwitchMembers) { if (-not (Get-NetAdapterVmq -Name $n.Name).Enabled) { Enable-NetAdapterVmq -Name $n.Name } } }
        'WorkloadProfile'  { Set-ArcWorkloadProfile -Target $a.Target | Out-Null }
        default            { throw "Unknown plan item kind '$($Item.Kind)'." }
    }
}

function Show-Plan {
    param($Plan)
    $Plan | Sort-Object Area, Id | Format-Table Area, Desc, Current, Desired, @{ n = 'Restart'; e = { if ($_.Restart) { 'yes' } else { '' } } } -AutoSize -Wrap | Out-String -Width 220 | Write-Host
}

# Returns 'Done' or 'Gate'.
function Invoke-Baseline {
    Write-Step "Baseline plan for $env:COMPUTERNAME"
    $plan = @(Get-BaselinePlan -Facts (Get-ArcHostFacts))
    if (-not $plan) { Write-Host '  Nothing to change - this host matches the standard.' -ForegroundColor Green; Save-PhaseComplete "Baseline$ScriptRole"; return 'Done' }
    Show-Plan $plan
    $running = @(Get-VM -ErrorAction SilentlyContinue | Where-Object State -eq 'Running')
    if ($running) { Write-Host "  $($running.Count) VM(s) are running. Items marked Restart need a reboot, which stops them; the VMQ item blips VM networking." -ForegroundColor Yellow }
    if (-not (Confirm-Action "Apply these $($plan.Count) change(s)")) { Stop-Next 'Baseline not applied. Run Next again when ready.'; return 'Gate' }

    Write-Step 'Applying'
    $failed = @()
    foreach ($i in ($plan | Sort-Object Area, Id)) {
        try { Invoke-PlanItem $i; Write-Host "  OK   $($i.Desc)" -ForegroundColor Green }
        catch { $failed += $i; Write-Host "  FAIL $($i.Desc) - $($_.Exception.Message)" -ForegroundColor Red }
    }
    $script:WorkloadProfileRead = $false
    $after = @(Get-BaselinePlan -Facts (Get-ArcHostFacts) | Where-Object { -not $_.Restart -or $_.Kind -eq 'Registry' })
    if ($after) {
        Write-Host "`n  Still different after applying (a domain GPO may be setting these - GPO wins; fix it there):" -ForegroundColor Yellow
        Show-Plan $after
    }
    if ($failed) { Write-Warning "$($failed.Count) item(s) failed - see above. The Report lists anything still different." }
    Save-PhaseComplete "Baseline$ScriptRole" ([bool]($plan | Where-Object Restart))
    return 'Done'
}

# ---- end of shared helpers ----

# ---------------------------------------------------------------------------
# Media (USB stick or share)
# ---------------------------------------------------------------------------

function Resolve-ArcMediaPath {
    if ($MediaPath) { Set-Answer 'MediaPath' $MediaPath; return $MediaPath }
    $saved = Get-Answer 'MediaPath'
    if ($saved -and (Test-Path $saved)) { return $saved }
    if ($PSScriptRoot -and $PSScriptRoot -ne $LogRoot -and ((Test-Path (Join-Path $PSScriptRoot 'SPP')) -or (Test-Path (Join-Path $PSScriptRoot 'HPE')))) {
        Set-Answer 'MediaPath' $PSScriptRoot
        return $PSScriptRoot
    }
    return $null
}

# Newest matching file under the media folder, else ask (blank = skip).
function Find-ArcMedia {
    param([string]$Sub, [string]$Filter, [string]$What, [string]$AnswerName)
    $saved = Get-Answer $AnswerName
    if ($saved -and (Test-Path $saved)) { return $saved }
    $media = Resolve-ArcMediaPath
    if ($media) {
        $f = Get-ChildItem (Join-Path $media $Sub) -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($f -and (Confirm-Action "Use $What $($f.FullName)")) { Set-Answer $AnswerName $f.FullName; return $f.FullName }
    }
    $p = Read-Value "Full path to the $What (blank to skip)" '' { param($v) -not $v -or (Test-Path $v) } 'File not found.'
    if ($p) { Set-Answer $AnswerName $p }
    return $p
}

# ProLiant generation from the model string: 'ProLiant DL380 Gen10 Plus' -> 'Gen10Plus'.
function Get-ArcHpeGeneration {
    param([string]$Model = (Get-CimInstance Win32_ComputerSystem).Model)
    if ($Model -match 'Gen\s?(\d+)(\s*Plus)?') { return "Gen$($Matches[1])$(if ($Matches[2]) { 'Plus' })" }
    return $null
}

# SPP folders a generation looks in, most specific first. A Gen10 Plus also tries Gen10
# (one SPP has covered both); the flat SPP folder is the last resort for a single-
# generation stick.
function Get-ArcSppFolders {
    param([string]$Generation)
    $list = @()
    if ($Generation) {
        $list += "SPP\$Generation"
        if ($Generation -match '^(Gen\d+)Plus$') { $list += "SPP\$($Matches[1])" }
    }
    return $list + 'SPP'
}

# The SPP ISO for THIS server's generation. One stick can carry several:
#   SPP\Gen10\<spp>.iso  SPP\Gen10Plus\<spp>.iso  SPP\Gen11\<spp>.iso  SPP\Gen12\<spp>.iso
function Find-ArcSpp {
    $gen = Get-ArcHpeGeneration
    Write-Host "  Server generation: $(if ($gen) { $gen } else { 'not recognised from the model name' })"
    $saved = Get-Answer 'SppIsoPath'
    if ($saved -and (Test-Path $saved)) { return $saved }
    $media = Resolve-ArcMediaPath
    if ($media) {
        foreach ($sub in Get-ArcSppFolders $gen) {
            $f = Get-ChildItem (Join-Path $media $sub) -Filter '*.iso' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
            if (-not $f) { continue }
            # A generation in the file name that isn't this server's is almost certainly the wrong SPP.
            if ($gen -and $f.Name -match 'Gen\s?(\d+)' -and "Gen$($Matches[1])" -ne ($gen -replace 'Plus$', '')) {
                Write-Warning "$($f.FullName) looks like an SPP for Gen$($Matches[1]), but this server is $gen."
            }
            if ($sub -eq 'SPP' -and $gen) { Write-Warning "No SPP\$gen folder - found $($f.Name) in the top SPP folder. Check it covers $gen." }
            if (Confirm-Action "Use SPP $($f.FullName)") { Set-Answer 'SppIsoPath' $f.FullName; return $f.FullName }
            break
        }
    }
    $p = Read-Value "Full path to the SPP ISO for $(if ($gen) { $gen } else { 'this server' }) (blank to skip)" '' { param($v) -not $v -or (Test-Path $v) } 'File not found.'
    if ($p) { Set-Answer 'SppIsoPath' $p }
    return $p
}

# ---------------------------------------------------------------------------
# Phase: PreFlight (read-only)
# ---------------------------------------------------------------------------

function Invoke-PreFlight {
    Write-Step 'Host checks'
    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)
    $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    if ($cs.Manufacturer -match 'HPE|Hewlett') {
        Add-Result PASS 'HPE hardware' "$($cs.Manufacturer) $($cs.Model)"
        $gen = Get-ArcHpeGeneration $cs.Model
        $media = Resolve-ArcMediaPath
        if (-not $gen) { Add-Result WARN 'ProLiant generation' "Not recognised from '$($cs.Model)' - the Hpe phase will ask for the SPP ISO" }
        elseif ($media) {
            $hit = Get-ArcSppFolders $gen | Where-Object { Get-ChildItem (Join-Path $media $_) -Filter '*.iso' -File -ErrorAction SilentlyContinue } | Select-Object -First 1
            if ($hit -and $hit -ne 'SPP') { Add-Result PASS 'SPP on the media' "$gen - $hit" }
            elseif ($hit) { Add-Result WARN 'SPP on the media' "No SPP\$gen folder; an ISO in the top SPP folder will be offered" }
            else { Add-Result WARN 'SPP on the media' "No SPP for $gen under $media\SPP" }
        } else { Add-Result INFO 'ProLiant generation' "$gen (no media folder found yet - the Hpe phase asks)" }
    }
    else { Add-Result FAIL 'HPE hardware' "$($cs.Manufacturer) $($cs.Model) - this script is for HPE ProLiant only" }

    if ($os.Caption -match 'Server 2025 (Standard|Datacenter)') { Add-Result PASS 'OS edition' $os.Caption }
    elseif ($os.Caption -match 'Server 20\d\d (Standard|Datacenter)') { Add-Result WARN 'OS edition' "$($os.Caption) - the standard is Windows Server 2025" }
    else { Add-Result FAIL 'OS edition' "Expected Windows Server Standard or Datacenter, found '$($os.Caption)'" }
    if ($cv.InstallationType -eq 'Server') { Add-Result PASS 'Install type' 'Desktop Experience' }
    else { Add-Result FAIL 'Install type' "$($cv.InstallationType) - the standard is Desktop Experience" }
    if ($os.Caption -match 'Standard') { Add-Result INFO 'Licensing' 'Standard edition covers 2 Windows Server guest VMs per fully licensed host - check the planned VM count' }

    if ($cs.HypervisorPresent -or $cpu[0].VirtualizationFirmwareEnabled) { Add-Result PASS 'Virtualisation enabled in firmware' }
    else { Add-Result WARN 'Virtualisation enabled in firmware' 'VT-x is off - Base sets the workload profile, and installs Hyper-V on its re-run after the reboot' }
    try { if (Confirm-SecureBootUEFI) { Add-Result PASS 'Secure Boot' } else { Add-Result WARN 'Secure Boot' 'Off' } } catch { Add-Result WARN 'Secure Boot' 'Not supported or not UEFI' }
    try { $tpm = Get-Tpm; if ($tpm.TpmReady) { Add-Result PASS 'TPM' 'Ready' } else { Add-Result WARN 'TPM' "Present=$($tpm.TpmPresent) Ready=$($tpm.TpmReady)" } } catch { Add-Result WARN 'TPM' 'Could not query' }
    if (Test-PendingReboot) { Add-Result WARN 'Pending reboot' 'Reboot before continuing' } else { Add-Result PASS 'No pending reboot' }
    if (Test-ConsoleSession) { Add-Result PASS 'Console session' } else { Add-Result WARN 'Console session' 'Running over RDP - use the iLO remote console for the Ship network step' }
    Add-Result INFO 'Hardware' ("{0} socket(s), {1} cores/socket, {2} GB RAM, ROM {3}" -f $cpu.Count, $cpu[0].NumberOfCores, [math]::Round($cs.TotalPhysicalMemory / 1GB), (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)

    try {
        $null = Invoke-WebRequest -Uri 'https://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
        Add-Result PASS 'Internet access' 'Needed for the Datto agent and Windows Update'
    } catch { Add-Result WARN 'Internet access' 'No internet - the Datto agent and Windows Update will fail' }

    $hpeDone = Test-PhaseDone 'Hpe'
    $missSev = if ($hpeDone) { 'WARN' } else { 'INFO' }
    if (Get-IloRest) { Add-Result PASS 'HPE ilorest' (Get-IloRest) } else { Add-Result $missSev 'HPE ilorest' 'Not installed - the Hpe phase installs it' }
    if (Get-Service | Where-Object { $_.DisplayName -like '*Agentless Management*' }) { Add-Result PASS 'HPE Agentless Management Service' }
    else { Add-Result $missSev 'HPE Agentless Management Service' 'Not installed - ships in the SPP' }

    Write-Step 'Physical NICs'
    Show-ArcNics
    foreach ($g in Get-ArcNicGroups) { Add-Result INFO "NIC group [$($g.Number)]" "$($g.Model) x$($g.Count), $($g.Up) up" }

    Write-Step 'Disks'
    Get-Disk | Sort-Object Number | Format-Table Number, FriendlyName, BusType, @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }, PartitionStyle, IsBoot, IsSystem -AutoSize | Out-String | Write-Host
}

# ---------------------------------------------------------------------------
# Phase: Hpe (SPP via SUM, CHIF/AMS, ilorest, boot RAID, iLO password + protocols)
# ---------------------------------------------------------------------------

function Invoke-Hpe {
    $reboot = $false
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.Manufacturer -notmatch 'HPE|Hewlett') { throw "This host reports manufacturer '$($cs.Manufacturer)' - the Hpe phase is for HPE ProLiant only." }
    Write-Host "  $($cs.Manufacturer) $($cs.Model)"

    Write-Step 'Service Pack for ProLiant (SUM, unattended)'
    $iso = Find-ArcSpp
    if (-not $iso) { Write-Warning 'No SPP ISO - skipping the SPP. Firmware and drivers stay as shipped.' }
    else {
        Write-Host '  SUM applies every component in the SPP that is newer than what is installed (no downgrades).' -ForegroundColor Yellow
        Write-Host '  NIC firmware/driver updates bounce the links briefly.' -ForegroundColor Yellow
        if (-not (Confirm-Action 'Run SUM unattended against this host now')) { throw 'Stopped by engineer.' }
        $copied = $null
        try {
            try { $img = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop }
            catch {
                Write-Warning "Could not mount the ISO in place ($($_.Exception.Message)) - copying it locally first."
                $copied = Join-Path $Work (Split-Path $iso -Leaf)
                Copy-Item $iso $copied -Force
                $img = Mount-DiskImage -ImagePath $copied -PassThru
            }
            $drive = ($img | Get-Volume).DriveLetter
            if (-not $drive) { throw 'The mounted SPP has no drive letter.' }
            $sum = Get-ChildItem "${drive}:\" -Filter smartupdate.bat -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $sum) { throw "smartupdate.bat not found on the SPP (${drive}:). Is this an SPP ISO?" }
            Write-Host "  Running $($sum.FullName) /silent - this can take 30-60 minutes."
            # No /reboot - the script decides when to reboot so the phase state stays accurate.
            $code = Start-ProcessWithHeartbeat -FilePath 'cmd.exe' -ArgumentList "/c `"`"$($sum.FullName)`" /silent`"" -Label 'SUM' -HeartbeatSec 60 -WorkingDirectory $sum.DirectoryName
        } finally {
            Dismount-DiskImage -ImagePath $(if ($copied) { $copied } else { $iso }) -ErrorAction SilentlyContinue | Out-Null
            if ($copied) { Remove-Item $copied -Force -ErrorAction SilentlyContinue }
        }
        # SUM return codes (SUM CLI guide, "Return codes", Windows values)
        switch ([int]$code) {
            0  { Write-Host '  SUM: installation successful.' -ForegroundColor Green }
            1  { Write-Host '  SUM: installation successful - reboot required.' -ForegroundColor Yellow; $reboot = $true }
            3  { Write-Host '  SUM: all components already current.' -ForegroundColor Green }
            -1 { throw 'SUM: general failure (-1). See the SUM logs under C:\cpqsystem\sum\log.' }
            -2 { throw 'SUM: bad input parameter (-2).' }
            -3 { throw 'SUM: a component failed or was blocked by a failed dependency (-3). See C:\cpqsystem\sum\log, fix, and re-run -Phase Hpe.' }
            -4 { throw 'SUM: CLI command execution failed (-4).' }
            default { throw "SUM: unexpected exit code $code. See the SUM logs under C:\cpqsystem\sum\log." }
        }
    }

    Write-Step 'HPE components on the host'
    $chif = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -like '*Channel Interface*' } | Select-Object -First 1
    if ($chif) { Write-Host "  iLO Channel Interface driver (CHIF): $($chif.DriverVersion)" -ForegroundColor Green }
    else { Write-Warning 'iLO Channel Interface driver (CHIF) not found - AMS and in-band ilorest need it. It ships in the SPP.' }
    if (Get-Service | Where-Object { $_.DisplayName -like '*Agentless Management*' }) { Write-Host '  Agentless Management Service: present' -ForegroundColor Green }
    else { Write-Warning 'Agentless Management Service not found - it ships in the SPP.' }

    if (Get-IloRest) { Write-Host "  ilorest: $(Get-IloRest)" -ForegroundColor Green }
    else {
        $msi = Find-ArcMedia 'HPE' 'ilorest*.msi' 'ilorest MSI' 'IloRestMsiPath'
        if ($msi) {
            $local = Join-Path $Work (Split-Path $msi -Leaf)
            Copy-Item $msi $local -Force
            try {
                $sig = Get-AuthenticodeSignature $local
                if ($sig.Status -ne 'Valid') { throw "ilorest MSI signature is '$($sig.Status)' - refusing to run it." }
                Write-Host "  Installing ilorest (signed by: $($sig.SignerCertificate.Subject))"
                $c = Start-ProcessWithHeartbeat -FilePath 'msiexec.exe' -ArgumentList "/i `"$local`" /qn /norestart" -Label 'ilorest install'
                if ($c -notin 0, 3010) { throw "ilorest install failed with exit code $c." }
            } finally { Remove-Item $local -Force -ErrorAction SilentlyContinue }
            if (Get-IloRest) { Write-Host '  ilorest installed.' -ForegroundColor Green } else { Write-Warning 'ilorest installed but ilorest.exe not found in the expected folder.' }
        } else { Write-Warning 'No ilorest - the BIOS workload profile and iLO steps will be skipped.' }
    }

    Write-Step 'Boot volume (report)'
    $boot = Get-Disk | Where-Object IsBoot | Select-Object -First 1
    if ($boot) { Write-Host "  Boot disk: $($boot.FriendlyName)  $([math]::Round($boot.Size / 1GB)) GB  bus $($boot.BusType)  health $($boot.HealthStatus)" }
    $ssacli = Get-ChildItem "$env:ProgramFiles\Smart Storage Administrator\ssacli\bin\ssacli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ssacli) {
        $ErrorActionPreference = 'Continue'
        $cfg = & $ssacli.FullName ctrl all show config 2>&1 | ForEach-Object { "$_" } | Out-String
        $ErrorActionPreference = 'Stop'
        Write-Host $cfg
        if ($cfg -match 'logicaldrive\s+\d+\s+\([^)]*RAID 1[^)]*OK\)') { Write-Host '  A RAID 1 logical drive reports OK.' -ForegroundColor Green }
        else { Write-Warning 'No RAID 1 logical drive reporting OK in ssacli output - check the boot volume by hand (an NS204i M.2 boot device is not managed by ssacli).' }
    } else { Write-Warning 'ssacli not installed (it ships in the SPP) - check the RAID config in iLO > System Information > Storage.' }

    Write-Step 'iLO: Administrator password and unused protocols'
    $ilo = Get-IloRest
    if (-not $ilo) { Write-Warning 'ilorest not installed - set the iLO password and protocols by hand.' }
    elseif (Connect-ArcIlo $ilo) {
        try {
            if (Confirm-Action 'Set a new iLO Administrator password now (the factory password is on the pull-out tag)') {
                $user = Read-Value 'iLO account to change' 'Administrator' { param($v) $v -match '\S' }
                $pw = ConvertFrom-Secure (Read-Secret "New password for iLO account '$user'" -Confirm)
                try {
                    # Passed as an argument (the only way ilorest takes it) - visible on this
                    # process's command line for the call. Never echoed or written to disk.
                    $r = Invoke-IloRest $ilo @('iloaccounts', 'changepass', $user, $pw)
                } finally { $pw = $null }
                if ($r.ExitCode -eq 0) { Write-Host '  iLO password changed. Record it in ITGlue.' -ForegroundColor Green }
                else { Write-Warning "Changing the iLO password failed (exit $($r.ExitCode)). Set it in the iLO web UI." }
            }
            # IPMI over LAN and SSDP are not used for these hosts.
            $r = Invoke-IloRawPatch $ilo '/redfish/v1/Managers/1/NetworkProtocol/' @{ IPMI = @{ ProtocolEnabled = $false }; SSDP = @{ ProtocolEnabled = $false } }
            if ($r.ExitCode -eq 0) { Write-Host '  IPMI over LAN and SSDP turned off (may apply at the next iLO reset).' -ForegroundColor Green }
            else { Write-Warning "Could not turn off IPMI/SSDP:`n$($r.Output)" }
        } finally { Invoke-IloRest $ilo @('logout') | Out-Null }
    } else { Write-Warning 'No iLO session - set the iLO password and protocols in the iLO web UI.' }

    Save-PhaseComplete 'Hpe' $reboot
    if ($reboot) { Write-Host "`nREBOOT REQUIRED. Then -Phase Base." -ForegroundColor Yellow } else { Write-Host "`nNext: -Phase Base." -ForegroundColor Green }
}

# ---------------------------------------------------------------------------
# Phase: Base (host name, power plan, BIOS workload profile, Hyper-V)
# ---------------------------------------------------------------------------

function Invoke-Base {
    $reboot = $false

    Write-Step 'Host name'
    $current = $env:COMPUTERNAME
    $want = Read-Value 'Host name for this server' $(if (Get-Answer 'HostName') { Get-Answer 'HostName' } else { $current }) { param($v) $v -match '^[A-Za-z0-9][A-Za-z0-9\-]{0,14}$' -and $v -notmatch '^\d+$' } 'Up to 15 letters, digits and hyphens, not all digits.'
    Set-Answer 'HostName' $want.ToUpper()
    if ($want -ne $current) {
        Rename-Computer -NewName $want -Force
        Write-Host "  Renamed to $want - applies at the next reboot." -ForegroundColor Yellow
        $reboot = $true
    } else { Write-Host "  $current - unchanged." }

    Write-Step 'Power plan'
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
    if ($LASTEXITCODE -eq 0) { Write-Host '  High Performance plan active.' } else { Write-Warning 'Could not activate the High Performance plan.' }

    Write-Step 'HPE BIOS workload profile'
    if (Set-ArcWorkloadProfile) { $reboot = $true }

    # The Hyper-V role won't install while VT-x is off, and the workload profile that
    # turns it on only applies at the next reboot.
    Write-Step 'Hyper-V role'
    if ((Get-WindowsFeature Hyper-V).Installed) { Write-Host '  Hyper-V already installed.' -ForegroundColor Green }
    else {
        $vtOn = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent -or (@(Get-CimInstance Win32_Processor)[0].VirtualizationFirmwareEnabled)
        if (-not $vtOn) {
            Write-Warning 'VT-x is off in firmware - Hyper-V is deferred until Base runs again after the reboot.'
            Request-RebootFlag
            Write-Host "`nREBOOT, then re-run -Phase Base to install Hyper-V." -ForegroundColor Yellow
            return
        }
        $r = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
        if (-not $r.Success) { throw "Hyper-V install failed: $($r.ExitCode)" }
        $reboot = $true
    }

    Save-PhaseComplete 'Base' $reboot
    if ($reboot) { Write-Host "`nREBOOT REQUIRED. Then -Phase Storage." -ForegroundColor Yellow } else { Write-Host "`nNext: -Phase Storage." -ForegroundColor Green }
}

# ---------------------------------------------------------------------------
# Phase: Storage (VM volume - asked, never formats a disk with data)
# ---------------------------------------------------------------------------

function Invoke-Storage {
    if (-not (Get-Command Set-VMHost -ErrorAction SilentlyContinue)) { throw 'Hyper-V is not installed - run -Phase Base first.' }
    $vh = Get-VMHost
    Write-Host "  Current default paths: VMs $($vh.VirtualMachinePath)  |  VHDs $($vh.VirtualHardDiskPath)"
    $saved = Get-Answer 'VmVolume'
    if ($saved -and (Test-Path "${saved}:\") -and $vh.VirtualMachinePath -like "${saved}:\*") {
        Write-Host "  VM volume ${saved}: already set up." -ForegroundColor Green
        Save-PhaseComplete 'Storage'
        return
    }

    # Never offer the boot/system disk, a USB stick, a mounted ISO, or the disk the media is on.
    $mediaDisk = $null
    $media = Resolve-ArcMediaPath
    if ($media -and $media -match '^([A-Za-z]):') { try { $mediaDisk = (Get-Partition -DriveLetter $Matches[1] -ErrorAction Stop).DiskNumber } catch { } }
    $disks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and "$($_.BusType)" -notin 'USB', 'File Backed Virtual', 'SD', 'MMC' -and $_.Number -ne $mediaDisk } | Sort-Object Number)

    Write-Step 'Candidate disks for the VMs'
    if (-not $disks) { Write-Warning 'No candidate data disks. Create the data array in the RAID controller (or use the boot array) first.' }
    foreach ($d in $disks) {
        $vols = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter):" })
        Write-Host ("  Disk {0}  {1,7} GB  {2,-10} {3,-5} {4}  {5}" -f $d.Number, [math]::Round($d.Size / 1GB), $d.BusType, $d.PartitionStyle, $d.FriendlyName, $(if ($vols) { "volumes $($vols -join ' ')" } elseif ($d.PartitionStyle -eq 'RAW') { 'EMPTY (RAW)' } else { 'no lettered volume' }))
    }
    Write-Host "`n  Enter a disk number to use it, a drive letter (e.g. E) to use an existing volume, or SKIP."
    $choice = Read-Value 'Choice' '' { param($v) $v -match '^(\d+|[A-Za-z]|skip)$' }
    if ($choice -eq 'skip') { Write-Warning 'Skipped - the default VM paths are unchanged.'; return }

    $letter = $null
    if ($choice -match '^\d+$') {
        $d = $disks | Where-Object Number -eq ([int]$choice)
        if (-not $d) { throw "Disk $choice is not a candidate." }
        if ($d.PartitionStyle -ne 'RAW') {
            throw "Disk $choice is not empty (partition style $($d.PartitionStyle)). This script never formats a disk that has data - pick its drive letter instead, or clear it by hand."
        }
        $confirm = Read-Host "  Disk $choice ($([math]::Round($d.Size / 1GB)) GB $($d.FriendlyName)) will be initialised GPT and formatted NTFS 64K. Type the disk number again to confirm"
        if ($confirm -ne $choice) { throw 'Not confirmed - nothing changed.' }
        $free = @(68..90 | ForEach-Object { [char]$_ } | Where-Object { -not (Test-Path "${_}:\") })
        $default = if ($free -contains 'V') { 'V' } else { $free[0] }
        $letter = (Read-Value 'Drive letter for the VM volume' $default { param($v) $v -match '^[D-Zd-z]$' -and -not (Test-Path "${v}:\") } 'Pick a free letter D-Z.').ToUpper()
        Initialize-Disk -Number $d.Number -PartitionStyle GPT
        New-Partition -DiskNumber $d.Number -UseMaximumSize -DriveLetter $letter | Out-Null
        Format-Volume -DriveLetter $letter -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel 'VMs' -Confirm:$false | Out-Null
        Write-Host "  ${letter}: formatted NTFS 64K, label VMs." -ForegroundColor Green
    } else {
        $letter = $choice.ToUpper()
        $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if (-not $vol -or $vol.DriveType -ne 'Fixed') { throw "${letter}: is not a fixed volume." }
        if ($vol.FileSystem -ne 'NTFS' -and $vol.FileSystem -ne 'ReFS') { throw "${letter}: is $($vol.FileSystem) - use NTFS or ReFS." }
        Write-Host "  Using existing volume ${letter}: ($($vol.FileSystemLabel), $([math]::Round($vol.Size / 1GB)) GB, $($vol.FileSystem), not reformatted)."
    }

    $vmPath  = "${letter}:\Hyper-V"
    $vhdPath = "${letter}:\Hyper-V\Virtual Hard Disks"
    New-Item -ItemType Directory -Path $vmPath, $vhdPath -Force | Out-Null
    Set-VMHost -VirtualMachinePath $vmPath -VirtualHardDiskPath $vhdPath
    Set-Answer 'VmVolume' $letter
    Write-Host "  Default VM path $vmPath, VHD path $vhdPath." -ForegroundColor Green
    Save-PhaseComplete 'Storage'
}

# ---------------------------------------------------------------------------
# Phase: Agents (Datto RMM; Defender stays on until the Site script confirms the EDR)
# ---------------------------------------------------------------------------

function Install-ArcDattoAgent {
    param([Parameter(Mandatory)][string]$Platform, [Parameter(Mandatory)][string]$SiteID)
    if (Get-Service CagService -ErrorAction SilentlyContinue) { Write-Host '  Datto RMM agent already installed - skipping.' -ForegroundColor Green; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $installer = Join-Path $Work 'DRMMSetup.exe'
    try {
        Write-Host '  Downloading the Datto RMM agent...'
        Invoke-WebRequest -Uri "https://$Platform.rmm.datto.com/download-agent/windows/$SiteID" -OutFile $installer -UseBasicParsing
        $sig = Get-AuthenticodeSignature $installer
        if ($sig.Status -ne 'Valid') { throw "Datto installer signature is '$($sig.Status)' - refusing to run it." }
        Write-Host "  Installer signed by: $($sig.SignerCertificate.Subject)"
        $code = Start-ProcessWithHeartbeat -FilePath $installer -ArgumentList @() -Label 'Datto RMM agent install'
        if ($code -ne 0) { throw "Datto installer exited with code $code." }
    } finally { Remove-Item $installer -Force -ErrorAction SilentlyContinue }
    $deadline = (Get-Date).AddMinutes(2)
    while (-not (Get-Service CagService -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    if (-not (Get-Service CagService -ErrorAction SilentlyContinue)) { throw 'CagService not present 2 minutes after the Datto install.' }
    Write-Host '  Datto RMM agent installed.' -ForegroundColor Green
}

function Invoke-Agents {
    if ((Get-State).PSObject.Properties['NetworkFinal'] -and (Get-State).NetworkFinal) { Write-Warning 'Ship has already set the customer network - internet may not work here.' }

    Write-Step 'Datto RMM agent'
    if (Get-Service CagService -ErrorAction SilentlyContinue) { Write-Host '  Already installed.' -ForegroundColor Green }
    else {
        # The Datto tenants we use live on one of these two platforms (the subdomain in
        # https://<platform>.rmm.datto.com).
        $platforms = 'pinotage', 'merlot'
        $platform = Get-Answer 'DattoPlatform'
        if ($platform -notin $platforms) {
            $choice = Read-Value 'Datto platform for this customer - [1] Pinotage  [2] Merlot' '' { param($v) $v -in '1', '2' }
            $platform = $platforms[[int]$choice - 1]
        }
        $siteId = Read-Value 'Datto site ID for this customer (from the site settings in Datto)' "$(Get-Answer 'DattoSiteId')" { param($v) $v -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' } 'A site ID looks like 8-4-4-4-12 hex characters.'
        Set-Answer 'DattoPlatform' $platform; Set-Answer 'DattoSiteId' $siteId
        Install-ArcDattoAgent -Platform $platform -SiteID $siteId
    }

    Write-Step 'Microsoft Defender (stays on until the Site script confirms the EDR)'
    Set-ArcDefenderHyperVExclusions

    Save-PhaseComplete 'Agents'
    Write-Host "`nNext: -Phase Updates." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Phase: Updates (Windows Update API, software only - drivers stay as the SPP left them)
# ---------------------------------------------------------------------------

# Returns 'None' when nothing is left, 'Reboot' when a reboot is needed, else 'More'.
function Invoke-Updates {
    if ((Get-State).PSObject.Properties['NetworkFinal'] -and (Get-State).NetworkFinal) { Write-Warning 'Ship has already set the customer network - Windows Update may not reach the internet.' }
    if (Test-PendingReboot) {
        # Some components leave a pending-reboot marker that survives the reboot - don't loop on it.
        $s = Get-State
        $asked = if ($s.PSObject.Properties['RebootRequestedAt'] -and $s.RebootRequestedAt) { [datetime]$s.RebootRequestedAt } else { $null }
        if ($asked -and (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt $asked) { Write-Warning 'A reboot still shows as pending although the host has rebooted since it was asked for - carrying on.' }
        else { Write-Warning 'A reboot is already pending - reboot first.'; Request-RebootFlag; return 'Reboot' }
    }

    Write-Step 'Searching Windows Update (software only, no optional or preview updates)'
    $session  = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'ArcHyperVHost'
    $searcher = $session.CreateUpdateSearcher()
    $found = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0 and BrowseOnly=0").Updates
    $list = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found) {
        if ($u.BrowseOnly) { Write-Host "  skipping (optional): $($u.Title)"; continue }
        if ($u.InstallationBehavior.CanRequestUserInput) { Write-Host "  skipping (needs user input): $($u.Title)"; continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$list.Add($u)
        Write-Host "  $($u.Title)"
    }
    if ($list.Count -eq 0) {
        Write-Host '  No updates left.' -ForegroundColor Green
        Save-PhaseComplete 'Updates'
        return 'None'
    }

    Write-Host "  Downloading $($list.Count) update(s)..."
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $list
    $null = $dl.Download()
    Write-Host '  Installing - this can take a while, with no progress output...'
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $list
    $res = $inst.Install()
    $codes = @{ 2 = 'Succeeded'; 3 = 'Succeeded with errors'; 4 = 'Failed'; 5 = 'Aborted' }
    Write-Host "  Result: $($codes[[int]$res.ResultCode])"
    for ($i = 0; $i -lt $list.Count; $i++) {
        $r = $res.GetUpdateResult($i)
        if ($r.ResultCode -ne 2) { Write-Warning "$($list.Item($i).Title): $($codes[[int]$r.ResultCode]) (HRESULT $('{0:X8}' -f $r.HResult))" }
    }
    if ($res.RebootRequired) { Request-RebootFlag; return 'Reboot' }
    return 'More'
}

# ---------------------------------------------------------------------------
# Phase: Ship - last step before switching off
# ---------------------------------------------------------------------------

function Set-ArcIloNetwork {
    $ilo = Get-IloRest
    if (-not $ilo) { Write-Warning 'ilorest not installed - set the iLO network in the iLO web UI.'; return }
    Write-Warning 'Changing the iLO network resets the iLO. An iLO remote console session (including this one, if that is how you are connected) drops for a minute or two.'
    $ip   = Read-Value 'iLO IP address' "$(Get-Answer 'IloIp')" { param($v) Test-IPv4 $v }
    $mask = Read-Value 'iLO subnet mask (e.g. 255.255.255.0)' $(if (Get-Answer 'IloMask') { Get-Answer 'IloMask' } else { '255.255.255.0' }) { param($v) Test-IPv4 $v }
    $gw   = Read-Value 'iLO gateway' "$(Get-Answer 'IloGateway')" { param($v) Test-IPv4 $v }
    $dnsIn = Read-Value 'iLO DNS servers, comma separated (blank to leave)' "$((@(Get-Answer 'IloDns') | Where-Object { $_ }) -join ',')" { param($v) -not $v -or @($v -split ',' | ForEach-Object Trim | Where-Object { -not (Test-IPv4 $_) }).Count -eq 0 }
    $name = Read-Value 'iLO host name (no dots)' $(if (Get-Answer 'IloHostName') { Get-Answer 'IloHostName' } else { "$(Get-Answer 'HostName')-ILO" }) { param($v) $v -match '^[A-Za-z0-9][A-Za-z0-9\-]{0,48}$' }
    if (-not (Confirm-Action "Set iLO to $ip / $mask gw $gw, name $name, then reset the iLO")) { return }
    Set-Answer 'IloIp' $ip; Set-Answer 'IloMask' $mask; Set-Answer 'IloGateway' $gw; Set-Answer 'IloHostName' $name
    Set-Answer 'IloDns' @($dnsIn -split ',' | ForEach-Object Trim | Where-Object { $_ })

    if (-not (Connect-ArcIlo $ilo)) { Write-Warning 'No iLO session - set the iLO network in the iLO web UI.'; return }
    try {
        $r = Invoke-IloRawPatch $ilo '/redfish/v1/Managers/1/EthernetInterfaces/1/' @{ HostName = $name }
        if ($r.ExitCode -ne 0) { Write-Warning "Setting the iLO host name failed:`n$($r.Output)" } else { Write-Host '  iLO host name set.' -ForegroundColor Green }
        if ($dnsIn) {
            $r = Invoke-IloRest $ilo @('ethernet', '--nameservers', (($dnsIn -split ',' | ForEach-Object Trim) -join ','))
            if ($r.ExitCode -ne 0) { Write-Warning "Setting the iLO DNS servers failed:`n$($r.Output)" } else { Write-Host '  iLO DNS servers set.' -ForegroundColor Green }
        }
        $r = Invoke-IloRest $ilo @('ethernet', '--network_ipv4', "$ip,$gw,$mask")
        if ($r.ExitCode -ne 0) { Write-Warning "Setting the iLO IPv4 address failed - set it in the iLO web UI:`n$($r.Output)"; return }
        Write-Host '  iLO IPv4 set. Resetting the iLO to apply...' -ForegroundColor Green
        Invoke-IloRest $ilo @('iloreset') | Out-Null
    } finally { Invoke-IloRest $ilo @('logout') | Out-Null }
    Write-Host '  iLO reset requested. Check the new address from the customer network once on site.' -ForegroundColor Yellow
}

function Invoke-Ship {
    Write-Step 'Before shipping'
    foreach ($p in 'Hpe', 'Base', 'Storage', 'Agents', 'Updates', 'NetworkWorkshop', 'BaselineWorkshop') {
        if (Test-PhaseDone $p) { Add-Result PASS "Phase $p" 'done' } else { Add-Result WARN "Phase $p" 'not recorded as complete' }
    }
    if (-not (Get-Service CagService -ErrorAction SilentlyContinue)) { Add-Result WARN 'Datto RMM agent' 'Not installed' }
    if (Test-PendingReboot) { Add-Result WARN 'Pending reboot' 'Reboot before shipping' }

    # The host normally ships on the workshop DHCP address; the Site script sets the
    # customer static address. Setting it here is for when the customer IP is known and
    # nothing else needs the workshop network.
    Write-Step 'Customer management address (normally set on site)'
    if (-not (Get-ArcSetSwitch)) { Add-Result WARN 'Host network' 'No SET switch - the Site script builds it' }
    elseif (Test-ArcMgmtOnDhcp) {
        if (Confirm-Action 'Set the customer static address now (the host loses the workshop network)') {
            if (Set-ArcMgmtAddress) { Set-StateValue 'NetworkFinal' $true }
        } else { Write-Host '  Ships on DHCP - the Site script sets the customer address.' }
    } else { Write-Host '  The Management vNIC already has a static address.' }

    Write-Step 'iLO network (optional)'
    if (Confirm-Action 'Set the customer iLO IP address and host name now') { Set-ArcIloNetwork } else { Write-Host '  Left as it is - set it on site in the iLO web UI if needed.' }

    Save-PhaseComplete 'Ship'
    $hn = Get-Answer 'HostName'
    Write-Host "`n  Workshop build complete for $(if ($hn) { $hn } else { $env:COMPUTERNAME })." -ForegroundColor Green
    Write-Host '  On site, run ArcHyperVHost-Site.ps1 -Phase Next (network if not done here, domain/workgroup, EDR, local admin, baseline, VM start/stop, as-built report).' -ForegroundColor Green
    if (Confirm-Action 'Shut down now') {
        Stop-Transcript | Out-Null
        Stop-Computer -Force
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Phase: Next - attended automation
# ---------------------------------------------------------------------------

function Invoke-Next {
    Unregister-ScheduledTask -TaskName $NextTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $state = Get-State
    if ($state.RebootPending -and $state.PSObject.Properties['RebootRequestedAt'] -and $state.RebootRequestedAt) {
        if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -lt [datetime]$state.RebootRequestedAt) {
            Request-ArcReboot "A reboot requested at $($state.RebootRequestedAt) hasn't happened yet."
            return
        }
        $state | Add-Member -NotePropertyName RebootPending -NotePropertyValue $false -Force
        Save-State $state
    }

    $steps = 'PreFlight', 'Hpe', 'Base', 'Storage', 'Agents', 'Updates', 'NetworkWorkshop', 'BaselineWorkshop', 'Ship'
    $updateRounds = 0
    while ($true) {
        $step = $steps | Where-Object { -not (Test-PhaseDone $_) } | Select-Object -First 1
        if (-not $step) { Write-Host "`nWorkshop build complete - all phases recorded. Next: ArcHyperVHost-Site.ps1 on site." -ForegroundColor Green; return }
        Write-Host "`n################ Next: $step ################" -ForegroundColor Magenta
        $script:Results.Clear()
        switch ($step) {
            'PreFlight' {
                Invoke-PreFlight
                if (@($script:Results | Where-Object Status -eq 'FAIL').Count) { Stop-Next 'Fix the FAIL items above.'; return }
                Save-PhaseComplete 'PreFlight'
            }
            'Hpe'     { Invoke-Hpe }
            'Base'    { Invoke-Base }
            'Storage' {
                Invoke-Storage
                if (-not (Test-PhaseDone 'Storage')) { Stop-Next 'Set up the VM volume (create the data array in the RAID controller if needed).'; return }
            }
            'Agents'  { Invoke-Agents }
            'Updates' {
                # 'More' loops round for another search; stop if it never settles (failing updates).
                $updateRounds++
                if ($updateRounds -gt 4) { Stop-Next 'Windows Update keeps offering updates that do not install - check the warnings above and the WindowsUpdate log.'; return }
                $null = Invoke-Updates
            }
            'NetworkWorkshop'  {
                if (-not (Invoke-ArcHostNetwork -Workshop)) { Stop-Next 'Build the SET switch on the iLO remote console or a local console.'; return }
                Save-PhaseComplete 'NetworkWorkshop'
            }
            'BaselineWorkshop' { if ((Invoke-Baseline) -eq 'Gate') { return } }
            'Ship'    { Invoke-Ship; return }
        }
        if ((Get-State).RebootPending) { Request-ArcReboot; return }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    switch ($Phase) {
        'Next'      { Invoke-Next }
        'PreFlight' { Invoke-PreFlight; Save-PhaseComplete 'PreFlight' }
        'Hpe'       { Invoke-Hpe }
        'Base'      { Invoke-Base }
        'Storage'   { Invoke-Storage }
        'Agents'    { Invoke-Agents }
        'Updates'   {
            $u = Invoke-Updates
            if ($u -eq 'Reboot') { Write-Host "`nREBOOT REQUIRED, then run -Phase Updates again." -ForegroundColor Yellow }
            elseif ($u -eq 'More') { Write-Host "`nRun -Phase Updates again - more may be offered." -ForegroundColor Yellow }
        }
        'Network'   { if (Invoke-ArcHostNetwork -Workshop) { Save-PhaseComplete 'NetworkWorkshop' } }
        'Baseline'  { $null = Invoke-Baseline; if ((Get-State).RebootPending) { Write-Host "`nREBOOT REQUIRED for some items, then -Phase Ship." -ForegroundColor Yellow } }
        'Ship'      { Invoke-Ship }
    }
    if ($script:Results.Count) {
        $fails = @($script:Results | Where-Object Status -eq 'FAIL').Count
        $warns = @($script:Results | Where-Object Status -eq 'WARN').Count
        Write-Host "`nSummary: $fails FAIL, $warns WARN." -ForegroundColor $(if ($fails) { 'Red' } elseif ($warns) { 'Yellow' } else { 'Green' })
        $script:Results | Export-Csv -Path (Join-Path $LogRoot "Workshop-$Phase-checks-$Stamp.csv") -NoTypeInformation
    }
} catch {
    Write-Host "`nPHASE $Phase STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
