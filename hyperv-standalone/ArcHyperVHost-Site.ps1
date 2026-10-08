<#
================================================================
 BEFORE YOU RUN THIS SCRIPT
================================================================
 On-site half of the standalone Hyper-V host build. It also brings an
 EXISTING customer Hyper-V host up to the standard (it shows the plan and asks
 before changing anything, and never rebuilds a switch or moves an IP).
 The workshop half is ArcHyperVHost-Workshop.ps1.

 1. Log on as a local administrator, on the console or the iLO remote console
    if the host network is not built yet. Open an elevated PowerShell prompt.
 2. DOWNLOAD-THEN-RUN (single line):

       $p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Site.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Site.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Next

    OR from a USB stick:

       Set-ExecutionPolicy Bypass -Scope Process -Force; & E:\ArcHyperVHost\ArcHyperVHost-Site.ps1 -Phase Next

 3. Everything is prompted. Answers that are not secret are kept in
    C:\ArcLogs\HyperVHost\state.json (shared with the Workshop script).
    Passwords are never stored or logged.

 SEQUENCE (-Phase Next runs it, stops at the gates, asks before each reboot,
 and carries on by itself when an administrator next logs on):

       Network -> Identity -> Edr -> Admin -> Baseline -> HostSettings -> Report

 Report writes an HTML as-built to C:\ArcLogs\HyperVHost\ for the engineer to
 attach to the host's Configuration in ITGlue.
================================================================

.SYNOPSIS
    On-site build and standard baseline for a standalone HPE Hyper-V host.

.DESCRIPTION
    Phases (every phase is safe to re-run):
      Next          Attended automation - runs the next phase(s), stops at gates,
                    confirms reboots, resumes at the next logon.
      Network       Sets the customer static address on the Management vNIC the
                    workshop left on DHCP; builds the SET switch if there is none.
                    Verifies an existing switch and never moves any other address.
      Identity      Domain join, or workgroup: NTP, private network profile, WinRM,
                    and remote UAC off for local accounts (Veeam with a local admin).
      Edr           Detects SentinelOne or Sophos (never installs them). Once the
                    engineer confirms it is connected, turns Defender off by
                    policy and checks after the reboot that it really is off.
      Admin         Creates a new local administrator (name and password asked),
                    checks it works, then disables the built-in Administrator.
      Baseline      Security defaults + host optimisations + BIOS workload profile.
                    Shows the plan and asks first.
      HostSettings  VM automatic stop = Shut Down, automatic start with one delay.
      Report        Checks (UPS agent, backup readiness, licensing, Defender, EDR,
                    Datto ...) and the HTML as-built.

.NOTES
    Shares its state file with ArcHyperVHost-Workshop.ps1. Logs and transcripts:
    C:\ArcLogs\HyperVHost\. Not a Datto component - an engineer runs it.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Next', 'Network', 'Identity', 'Edr', 'Admin', 'Baseline', 'HostSettings', 'Report')]
    [string]$Phase
)

# Version of this script, surfaced in the banner/transcript. Both standalone
# scripts share one version; '-dev' suffix while work accumulates under [Unreleased].
$ScriptVersion = '0.1.0-dev'
$ScriptRole    = 'Site'   # which half of the build; names the state entries and the logon task

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$LogRoot   = "$env:SystemDrive\ArcLogs\HyperVHost"
$StatePath = Join-Path $LogRoot 'state.json'
$Work      = Join-Path $env:TEMP 'ArcHyperVHost'
New-Item -ItemType Directory -Path $LogRoot, $Work -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $LogRoot "Site-$Phase-$Stamp.log") | Out-Null

Write-Host "ArcHyperVHost-Site.ps1  v$ScriptVersion  -  phase: $Phase  -  $env:COMPUTERNAME" -ForegroundColor Cyan

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
# Phase: Network
# ---------------------------------------------------------------------------

function Invoke-Network {
    Write-Step 'Host network'
    if (Invoke-ArcHostNetwork) { Save-PhaseComplete 'Network'; return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Phase: Identity (domain or workgroup)
# ---------------------------------------------------------------------------

function Get-ArcTimeSource {
    $ErrorActionPreference = 'Continue'   # native stderr must not throw (function scope only)
    return (w32tm /query /source 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
}

# Returns 'Done', 'Reboot' or 'Gate'.
function Invoke-Identity {
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Step 'Identity'
    if ($cs.PartOfDomain) {
        Write-Host "  Joined to $($cs.Domain)." -ForegroundColor Green
        Set-Answer 'IdentityMode' 'Domain'; Set-Answer 'Domain' $cs.Domain
        Write-Host "  Time source: $(Get-ArcTimeSource)"
        Save-PhaseComplete 'Identity'
        return 'Done'
    }
    Write-Host "  Workgroup: $($cs.Workgroup)"
    $mode = Get-Answer 'IdentityMode'
    if ($mode -notin 'Domain', 'Workgroup') {
        $m = Read-Value 'Join a [D]omain or stay in a [W]orkgroup' '' { param($v) $v -match '^[DdWw]$' }
        $mode = if ($m -match '^[Dd]$') { 'Domain' } else { 'Workgroup' }
    }

    if ($mode -eq 'Domain') {
        $dom = Read-Value 'Domain to join (FQDN, e.g. corp.example.local)' "$(Get-Answer 'Domain')" { param($v) $v -match '^[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+$' }
        try { Resolve-DnsName "_ldap._tcp.dc._msdcs.$dom" -Type SRV -DnsOnly -ErrorAction Stop | Out-Null; Write-Host "  Domain controllers for $dom found in DNS." -ForegroundColor Green }
        catch {
            Write-Warning "No domain controller SRV records for $dom - the management vNIC DNS must point at the customer's DCs."
            if (-not (Confirm-Action 'Try the join anyway')) { return 'Gate' }
        }
        $ou = Read-Value 'OU distinguished name (blank = default Computers container)' "$(Get-Answer 'DomainOU')" { param($v) -not $v -or $v -match '^(OU|CN)=' }
        Write-Host '  If the only domain controller will be a VM on this host, the host boots before its DC. Keep the new local admin account documented for that case.' -ForegroundColor Yellow
        $cred = Get-Credential -Message "Account allowed to join computers to $dom"
        $join = @{ DomainName = $dom; Credential = $cred; Force = $true; ErrorAction = 'Stop' }
        if ($ou) { $join.OUPath = $ou }
        Add-Computer @join
        Set-Answer 'IdentityMode' 'Domain'; Set-Answer 'Domain' $dom; Set-Answer 'DomainOU' $ou
        Write-Host "  Joined $dom - reboot to complete." -ForegroundColor Green
        Save-PhaseComplete 'Identity' $true
        return 'Reboot'
    }

    # Workgroup
    $reboot = $false
    # Defaults keep what the host already has, so Enter never changes a live host.
    $wg = Read-Value 'Workgroup name' $(if (Get-Answer 'Workgroup') { Get-Answer 'Workgroup' } else { $cs.Workgroup }) { param($v) $v -match '^[A-Za-z0-9\-]{1,15}$' }
    if ($wg -ne $cs.Workgroup) {
        if (Confirm-Action "Change the workgroup from $($cs.Workgroup) to $wg (needs a reboot)") { Add-Computer -WorkgroupName $wg -Force -ErrorAction Stop; $reboot = $true; Write-Host "  Workgroup set to $wg - applies at the next reboot." -ForegroundColor Yellow }
        else { $wg = $cs.Workgroup }
    }
    Set-Answer 'IdentityMode' 'Workgroup'; Set-Answer 'Workgroup' $wg

    Write-Step 'Time (a workgroup host has no domain hierarchy to follow)'
    Write-Host "  Current time source: $(Get-ArcTimeSource)"
    $ntp = Read-Value 'NTP servers, comma separated' $(if (Get-Answer 'NtpServers') { Get-Answer 'NtpServers' } else { 'uk.pool.ntp.org' }) { param($v) $v -match '^[A-Za-z0-9\.\-]+(,[A-Za-z0-9\.\-]+)*$' }
    if (Confirm-Action "Set the host to sync time from $ntp") {
        $peers = (($ntp -split ',' | ForEach-Object { "$($_.Trim()),0x8" }) -join ' ')
        $ErrorActionPreference = 'Continue'
        w32tm /config /manualpeerlist:"$peers" /syncfromflags:manual /reliable:no /update 2>&1 | Out-Null
        Restart-Service w32time -Force
        w32tm /resync 2>&1 | Out-Null
        $ErrorActionPreference = 'Stop'
        Set-Answer 'NtpServers' $ntp
        Write-Host "  Time source: $(Get-ArcTimeSource)"
    } else { Write-Host '  Time source left as it is.' }
    Write-Host '  If a domain controller VM runs on this host, turn off its Hyper-V time synchronisation integration service so it uses NTP instead.' -ForegroundColor Yellow

    Write-Step 'Remote management'
    $mgmt = Get-NetConnectionProfile -InterfaceAlias 'vEthernet (Management)' -ErrorAction SilentlyContinue
    $toPrivate = $mgmt -and "$($mgmt.NetworkCategory)" -eq 'Public'
    $winrmOn = (Get-Service WinRM -ErrorAction SilentlyContinue).Status -eq 'Running' -and [bool](Get-WSManInstance -ResourceURI winrm/config/listener -Enumerate -ErrorAction SilentlyContinue)
    if (-not $toPrivate -and $winrmOn) { Write-Host '  Management network profile and WinRM already set.' -ForegroundColor Green }
    else {
        if ($toPrivate) { Write-Host "  - Management network profile Public -> Private" }
        if (-not $winrmOn) { Write-Host '  - Turn on WinRM (PowerShell remoting, for remote management and Windows Admin Center)' }
        if (Confirm-Action 'Make these changes') {
            if ($toPrivate) { Set-NetConnectionProfile -InterfaceAlias 'vEthernet (Management)' -NetworkCategory Private; Write-Host '  Management network profile set to Private.' -ForegroundColor Green }
            if (-not $winrmOn) { Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null; Write-Host '  WinRM enabled.' -ForegroundColor Green }
        }
    }

    # Arc standard for workgroup hosts: remote UAC off for local accounts. Once the
    # built-in Administrator is disabled, the filtered network token would otherwise
    # block Veeam (admin share + WMI) and remote Hyper-V Manager with the local admin.
    # The trade-off is pass-the-hash with that account - so each host's local admin
    # password must be unique (recorded in ITGlue), never reused across customers.
    $filter = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
    if ($filter -eq 1) { Write-Host '  Remote UAC for local accounts already off (LocalAccountTokenFilterPolicy = 1).' -ForegroundColor Green }
    else {
        Set-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'LocalAccountTokenFilterPolicy' 1
        Write-Host '  Remote UAC for local accounts turned off (Veeam / remote Hyper-V Manager with the local admin).' -ForegroundColor Green
    }
    Write-Host '  Keep this host''s local admin password unique - never reuse it on another host.' -ForegroundColor Yellow
    Save-PhaseComplete 'Identity' $reboot
    if ($reboot) { return 'Reboot' }
    return 'Done'
}

# ---------------------------------------------------------------------------
# Phase: Edr (detect SentinelOne/Sophos, then turn Defender off and verify)
# ---------------------------------------------------------------------------

function Get-ArcEdr {
    $s1 = @(Get-Service -Name SentinelAgent -ErrorAction SilentlyContinue)
    if ($s1) { return [pscustomobject]@{ Product = 'SentinelOne'; Services = $s1; Running = ($s1[0].Status -eq 'Running') } }
    $so = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Sophos*' })
    if ($so) {
        $core = @($so | Where-Object { $_.DisplayName -like 'Sophos Endpoint Defense*' -or $_.DisplayName -like 'Sophos MCS*' })
        $check = if ($core) { $core } else { $so }
        return [pscustomobject]@{ Product = 'Sophos'; Services = $so; Running = -not @($check | Where-Object Status -ne 'Running') }
    }
    return $null
}

# 'Removed', 'Off', 'Passive' or 'Active'.
function Get-ArcDefenderState {
    $f = Get-WindowsFeature Windows-Defender -ErrorAction SilentlyContinue
    if ($f -and -not $f.Installed) { return 'Removed' }
    $svc = Get-Service WinDefend -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return 'Off' }
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        if ("$($st.AMRunningMode)" -match 'Passive') { return 'Passive' }
        if ("$($st.AMRunningMode)" -eq 'Not running') { return 'Off' }
    } catch { }
    return 'Active'
}

$DefenderPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'

# Returns 'Done', 'Reboot' or 'Gate'.
function Invoke-Edr {
    Write-Step 'Endpoint protection'
    if ((Get-Answer 'EdrProduct') -eq 'Defender') {
        Write-Host '  Recorded choice: Microsoft Defender is the antivirus on this host.' -ForegroundColor Green
        Set-ArcDefenderHyperVExclusions
        Save-PhaseComplete 'Edr'
        return 'Done'
    }

    $edr = Get-ArcEdr
    if (-not $edr) {
        Write-Warning 'Neither SentinelOne nor Sophos is installed. This script does not install them - deploy through Datto policy or the customer.'
        $c = Read-Value '[W]ait - deploy it, then -Phase Next  /  [D]efender stays as the antivirus' 'W' { param($v) $v -match '^[WwDd]$' }
        if ($c -match '^[Dd]$') {
            Set-Answer 'EdrProduct' 'Defender'
            Set-ArcDefenderHyperVExclusions
            Save-PhaseComplete 'Edr'
            return 'Done'
        }
        Stop-Next 'Deploy SentinelOne or Sophos to this host. Defender stays on meanwhile.'
        return 'Gate'
    }

    Write-Host "  Detected: $($edr.Product)"
    $edr.Services | Format-Table Name, DisplayName, Status, StartType -AutoSize | Out-String -Width 200 | Write-Host
    if ($edr.Product -eq 'SentinelOne') {
        $ctl = Get-ChildItem "$env:ProgramFiles\SentinelOne\Sentinel Agent*\SentinelCtl.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($ctl) {
            $ErrorActionPreference = 'Continue'   # SentinelCtl writes to stderr; must not throw
            & $ctl.FullName status 2>&1 | ForEach-Object { "$_" } | Out-String | Write-Host
            $ErrorActionPreference = 'Stop'
        }
    }
    if (-not $edr.Running) { Stop-Next "$($edr.Product) services are not all running. Check the install (a reboot may be needed), then run Next again. Defender stays on meanwhile."; return 'Gate' }
    Set-Answer 'EdrProduct' $edr.Product

    if ((Get-Answer 'EdrConfirmed') -ne $edr.Product) {
        Write-Host "  In the $($edr.Product) console, the host must show as connected, in the group/policy that carries the Hyper-V exclusions" -ForegroundColor Yellow
        Write-Host '  (VM folders, *.vhdx/*.avhdx/*.vmcx/*.vmrs/*.vmgs, vmms.exe, vmwp.exe, vmcompute.exe).' -ForegroundColor Yellow
        if (-not (Confirm-Action "Is $env:COMPUTERNAME connected in the $($edr.Product) console, in the right policy")) {
            Stop-Next "Get the host connected in the $($edr.Product) console and into the policy with the Hyper-V exclusions. Defender stays on meanwhile."
            return 'Gate'
        }
        Set-Answer 'EdrConfirmed' $edr.Product
    }

    Write-Step 'Microsoft Defender'
    $def = Get-ArcDefenderState
    Write-Host "  Defender: $def"
    if ($def -in 'Removed', 'Off', 'Passive') {
        Write-Host "  Defender is $($def.ToLower()) - $($edr.Product) is the only active antivirus." -ForegroundColor Green
        Save-PhaseComplete 'Edr'
        return 'Done'
    }

    $requested = (Get-State).PSObject.Properties['DefenderOffRequestedAt']
    if ($requested -and $requested.Value -and (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt [datetime]$requested.Value) {
        # Policy set and the host has rebooted since, but Defender is still active.
        Write-Warning 'Defender is still active after the policy and a reboot. Likely causes: tamper protection, a domain GPO setting it back, or the EDR re-enabling it.'
        Write-Warning 'Fix the cause, or remove the feature by hand (Uninstall-WindowsFeature Windows-Defender) once you are sure the EDR is protecting the host. The Report flags it until then.'
        Save-PhaseComplete 'Edr'
        return 'Done'
    }

    try { if ((Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected) { Write-Warning 'Defender tamper protection is on - it may ignore the policy. If so, turn tamper protection off first.' } } catch { }
    # "Turn off Microsoft Defender Antivirus" policy. On a Server not onboarded to
    # Defender for Endpoint this disables Defender (it does not go passive on its own).
    if (-not (Confirm-Action "Turn Microsoft Defender off now (policy, applies at reboot) - $($edr.Product) becomes the only antivirus")) {
        Stop-Next 'Defender left on. Run Next again when ready to turn it off.'
        return 'Gate'
    }
    Set-RegistryValue $DefenderPolicy 'DisableAntiSpyware' 1
    Set-RegistryValue "$DefenderPolicy\Real-Time Protection" 'DisableRealtimeMonitoring' 1
    Set-StateValue 'DefenderOffRequestedAt' (Get-Date -Format 's')
    Write-Host '  Defender off-policy set. After the reboot this phase checks it really is off.' -ForegroundColor Green
    Request-RebootFlag
    return 'Reboot'
}

# ---------------------------------------------------------------------------
# Phase: Admin (new local admin, then disable the built-in Administrator)
# ---------------------------------------------------------------------------

function Get-ArcBuiltinAdmin { return (Get-LocalUser | Where-Object { $_.SID.Value -match '^S-1-5-21-.*-500$' } | Select-Object -First 1) }

function Test-ArcLocalCredential {
    param([string]$User, [securestring]$Password)
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Machine)
    try { return $ctx.ValidateCredentials($User, (ConvertFrom-Secure $Password)) } finally { $ctx.Dispose() }
}

# Returns 'Done' or 'Gate'.
function Invoke-Admin {
    Write-Step 'Local administrator'
    $admins = ([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    $name = Get-Answer 'LocalAdminName'
    if ($name -and (Get-LocalUser -Name $name -ErrorAction SilentlyContinue)) {
        Write-Host "  Local admin account '$name' already set up." -ForegroundColor Green
    } else {
        $name = Read-Value 'Name for the new local administrator account' '' {
            param($v) $v -match '^[A-Za-z0-9._\-]{1,20}$' -and $v -notin 'Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount'
        } 'Up to 20 letters, digits, dot, underscore or hyphen, and not a built-in name.'
        $existing = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
        if ($existing) {
            if (-not (Confirm-Action "Local account '$name' already exists. Use it as the local admin (its password is not changed)")) { return 'Gate' }
        } else {
            while ($true) {
                $pw = Read-Secret "Password for '$name'" -Confirm
                try {
                    New-LocalUser -Name $name -Password $pw -PasswordNeverExpires -AccountNeverExpires -Description 'Arc local administrator' -ErrorAction Stop | Out-Null
                    break
                } catch { Write-Warning "Could not create the account: $($_.Exception.Message)" }
            }
            if (-not (Test-ArcLocalCredential $name $pw)) { throw "The new account '$name' did not accept its password - check it by hand before disabling the built-in Administrator." }
            Write-Host "  Created '$name' and checked its password works. Record it in ITGlue." -ForegroundColor Green
        }
        if (-not @(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.Name -like "*\$name" })) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $name }
        Write-Host "  '$name' is in $admins." -ForegroundColor Green
        Set-Answer 'LocalAdminName' $name
    }

    $builtin = Get-ArcBuiltinAdmin
    if (-not $builtin) { Write-Warning 'Could not find the built-in Administrator (RID 500).' }
    elseif (-not $builtin.Enabled) { Write-Host "  Built-in Administrator ('$($builtin.Name)') is already disabled." -ForegroundColor Green }
    elseif ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $builtin.SID.Value) {
        Register-ArcNextTask
        Stop-Next "You are logged on as the built-in Administrator, so it cannot be disabled from this session. Log off, log on as .\$name, and the next phase starts by itself."
        return 'Gate'
    } elseif (Confirm-Action "Disable the built-in Administrator account ('$($builtin.Name)')") {
        Disable-LocalUser -SID $builtin.SID
        Write-Host '  Built-in Administrator disabled.' -ForegroundColor Green
    } else { Write-Host '  Built-in Administrator left enabled - the Report flags it.' -ForegroundColor Yellow }

    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { Write-Host "  Domain host: Windows LAPS can take over '$name' (or a dedicated account) by policy." -ForegroundColor Cyan }
    Save-PhaseComplete 'Admin'
    return 'Done'
}

# ---------------------------------------------------------------------------
# Phase: HostSettings (VM automatic start/stop)
# ---------------------------------------------------------------------------

function Invoke-HostSettings {
    Write-Step 'VM automatic start and stop'
    $delay = Read-Value 'Automatic start delay for every VM, in seconds' $(if ($null -ne (Get-Answer 'StartDelay')) { "$(Get-Answer 'StartDelay')" } else { '120' }) { param($v) $v -match '^\d+$' -and [int]$v -le 3600 }
    Set-Answer 'StartDelay' ([int]$delay)
    $vms = @(Get-VM -ErrorAction SilentlyContinue)
    if (-not $vms) { Write-Host '  No VMs yet. Re-run -Phase HostSettings after the VMs are created (Hyper-V has no host-wide default for these).' -ForegroundColor Yellow }
    foreach ($vm in $vms) {
        try {
            Set-VM -VM $vm -AutomaticStartAction StartIfRunning -AutomaticStartDelay ([int]$delay) -ErrorAction Stop
            if ($vm.AutomaticStopAction -ne 'ShutDown') { Set-VM -VM $vm -AutomaticStopAction ShutDown -ErrorAction Stop }
            Write-Host "  OK   $($vm.Name): start if it was running, after ${delay}s; stop = shut down" -ForegroundColor Green
        } catch { Write-Warning "$($vm.Name): $($_.Exception.Message) - the automatic stop action can usually only be changed while the VM is off." }
    }
    $vh = Get-VMHost
    if ($vh.VirtualMachinePath -like "$env:SystemDrive*") { Write-Warning "Default VM path is on the system drive ($($vh.VirtualMachinePath)). Run the Workshop Storage phase, or set it in Hyper-V Settings." }
    Save-PhaseComplete 'HostSettings'
}

# ---------------------------------------------------------------------------
# Phase: Report (checks + HTML as-built)
# ---------------------------------------------------------------------------

function ConvertTo-Html-Safe { param($Value) return [System.Net.WebUtility]::HtmlEncode("$Value") }

function New-ArcKvTable {
    param([System.Collections.IDictionary]$Rows)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table class="kv"><tbody>')
    foreach ($k in $Rows.Keys) { [void]$sb.Append("<tr><td>$(ConvertTo-Html-Safe $k)</td><td>$(ConvertTo-Html-Safe $Rows[$k])</td></tr>") }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function New-ArcTable {
    param($Objects, [string[]]$Columns, [string]$StatusColumn)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $Columns) { [void]$sb.Append("<th>$(ConvertTo-Html-Safe $c)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($o in @($Objects)) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) {
            $v = ConvertTo-Html-Safe $o.$c
            if ($c -eq $StatusColumn) { [void]$sb.Append("<td><span class=`"status $v`">$v</span></td>") } else { [void]$sb.Append("<td>$v</td>") }
        }
        [void]$sb.Append('</tr>')
    }
    if (-not @($Objects).Count) { [void]$sb.Append("<tr><td colspan=`"$($Columns.Count)`">None</td></tr>") }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

# Sections: ordered list of @{ Title; Html }. Self-contained page with no external fonts or
# scripts (it may be opened offline). Deliberately unbranded - no logo or brand assets in a public repo.
function New-ArcAsBuiltHtml {
    param([string]$HostName, [string]$Subtitle, $Checks, [object[]]$Sections)
    $fails = @($Checks | Where-Object Status -eq 'FAIL').Count
    $warns = @($Checks | Where-Object Status -eq 'WARN').Count
    $passes = @($Checks | Where-Object Status -eq 'PASS').Count
    $body = New-Object System.Text.StringBuilder
    [void]$body.Append("<section><h2>Summary</h2><div class=`"summary`"><strong>$passes passed, $warns warnings, $fails failed.</strong> Warnings and failures are listed first in the checks below.</div></section>")
    $ordered = @($Checks | Sort-Object @{ e = { @{ FAIL = 0; WARN = 1; PASS = 2; INFO = 3 }[$_.Status] } })
    [void]$body.Append("<section><h2>Checks</h2>$(New-ArcTable $ordered @('Status', 'Check', 'Detail') 'Status')</section>")
    foreach ($s in $Sections) { [void]$body.Append("<section><h2>$(ConvertTo-Html-Safe $s.Title)</h2>$($s.Html)</section>") }
    $title = ConvertTo-Html-Safe "$HostName as-built"
    return @"
<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
:root { --dark:#1F2933; --accent:#3E7CB1; --pale:#F4F6F8; --pass:#2E9E5B; --warn:#E0A800; --fail:#D64545; --grid:#D9DCE1; }
* { box-sizing:border-box; }
body { margin:0; background:#FFFFFF; color:var(--dark); font-family:'Segoe UI', Arial, sans-serif; font-size:14px; line-height:1.5; }
header { background:var(--dark); color:#FFFFFF; padding:28px 40px 30px; }
h1 { font-weight:700; font-size:28px; line-height:1.2; margin:0; }
header p { margin:8px 0 0; }
main { padding:8px 40px 40px; max-width:1100px; }
h2 { font-weight:700; font-size:19px; margin:32px 0 10px; padding-bottom:6px; border-bottom:2px solid var(--accent); }
table { border-collapse:collapse; width:100%; margin:6px 0 4px; }
th { background:var(--dark); color:#FFFFFF; font-weight:700; text-align:left; padding:7px 10px; }
td { padding:6px 10px; border-bottom:1px solid var(--grid); vertical-align:top; text-align:left; overflow-wrap:anywhere; }
tbody tr:nth-child(even) td { background:var(--pale); }
table.kv td:first-child { width:32%; font-weight:600; }
.status { font-weight:700; white-space:nowrap; }
.status::before { content:''; display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:7px; background:var(--grid); }
.status.PASS::before { background:var(--pass); }
.status.WARN::before { background:var(--warn); }
.status.FAIL::before { background:var(--fail); }
.summary { background:var(--pale); padding:14px 18px; }
footer { padding:16px 40px 28px; font-size:12px; border-top:1px solid var(--grid); }
@media (max-width:640px) { header, main, footer { padding-left:16px; padding-right:16px; } table { display:block; overflow-x:auto; } }
@media print { header, th, tbody tr:nth-child(even) td, .status::before { -webkit-print-color-adjust:exact; print-color-adjust:exact; } }
</style>
</head>
<body>
<header>
<h1>$(ConvertTo-Html-Safe $HostName) as-built</h1>
<p>$(ConvertTo-Html-Safe $Subtitle)</p>
</header>
<main>
$($body.ToString())
</main>
<footer>Generated by ArcHyperVHost-Site.ps1 v$(ConvertTo-Html-Safe $ScriptVersion) on $(ConvertTo-Html-Safe (Get-Date -Format 'd MMMM yyyy HH:mm')). Attach to the host's Configuration in ITGlue.</footer>
</body>
</html>
"@
}

function Get-ArcVssWriters {
    $ErrorActionPreference = 'Continue'
    $raw = (vssadmin list writers 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $out = @()
    foreach ($m in [regex]::Matches($raw, "Writer name: '([^']+)'[\s\S]*?State: \[\d+\] (\w+)[\s\S]*?Last error: ([^\n]+)")) {
        $out += [pscustomobject]@{ Writer = $m.Groups[1].Value; State = $m.Groups[2].Value; LastError = $m.Groups[3].Value.Trim() }
    }
    return $out
}

function Invoke-Report {
    Write-Step 'Gathering'
    $cs   = Get-CimInstance Win32_ComputerSystem
    $os   = Get-CimInstance Win32_OperatingSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu  = @(Get-CimInstance Win32_Processor)
    $cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $state = Get-State
    $sections = @()

    # Hardware and firmware
    $iloFw = $null
    $ilo = Get-IloRest
    if ($ilo -and (Connect-ArcIlo $ilo)) {
        try { $iloFw = (Get-IloJson (Invoke-IloRest $ilo @('get', 'FirmwareVersion', '--selector=Manager.', '--json')).Output).FirmwareVersion } finally { Invoke-IloRest $ilo @('logout') | Out-Null }
    }
    $hw = [ordered]@{
        'Model'          = "$($cs.Manufacturer) $($cs.Model)"
        'Serial number'  = $bios.SerialNumber
        'Processors'     = "$($cpu.Count) x $(($cpu[0].Name -replace '\s+', ' ').Trim()) ($($cpu[0].NumberOfCores) cores each)"
        'Memory'         = "$([math]::Round($cs.TotalPhysicalMemory / 1GB)) GB"
        'System ROM'     = "$($bios.SMBIOSBIOSVersion) $($bios.ReleaseDate.ToString('yyyy-MM-dd'))"
        'BIOS workload profile' = $(if (Get-ArcWorkloadProfile) { Get-ArcWorkloadProfile } else { 'Not read (no ilorest or iLO session)' })
        'iLO firmware'   = $(if ($iloFw) { $iloFw } else { 'Not read' })
        'iLO address'    = $(if (Get-Answer 'IloIp') { "$(Get-Answer 'IloIp') ($(Get-Answer 'IloHostName'))" } else { 'Not set by these scripts' })
    }
    $sections += @{ Title = 'Hardware and firmware'; Html = (New-ArcKvTable $hw) }
    if ($cs.Manufacturer -match 'HPE|Hewlett') { Add-Result PASS 'HPE hardware' "$($cs.Model), serial $($bios.SerialNumber)" } else { Add-Result WARN 'HPE hardware' "$($cs.Manufacturer) $($cs.Model)" }
    if ($hw['BIOS workload profile'] -eq $Standard.WorkloadProfile) { Add-Result PASS 'BIOS workload profile' $Standard.WorkloadProfile } else { Add-Result WARN 'BIOS workload profile' "$($hw['BIOS workload profile']) - the standard is $($Standard.WorkloadProfile)" }
    try { if (Confirm-SecureBootUEFI) { Add-Result PASS 'Secure Boot' 'On' } else { Add-Result WARN 'Secure Boot' 'Off' } } catch { Add-Result WARN 'Secure Boot' 'Not supported or not UEFI' }
    try { $tpm = Get-Tpm; if ($tpm.TpmReady) { Add-Result PASS 'TPM' 'Ready' } else { Add-Result WARN 'TPM' 'Not ready' } } catch { Add-Result WARN 'TPM' 'Could not query' }

    # Operating system and identity
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction SilentlyContinue | Select-Object -First 1
    $activated = $lic -and $lic.LicenseStatus -eq 1
    $vms = @(Get-VM -ErrorAction SilentlyContinue)
    $lastHf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $osRows = [ordered]@{
        'Operating system' = $os.Caption
        'Build'            = "$($os.BuildNumber).$($cv.UBR)"
        'Install type'     = $cv.InstallationType
        'Activation'       = $(if ($activated) { 'Activated' } else { 'Not activated' })
        'Membership'       = $(if ($cs.PartOfDomain) { "Domain: $($cs.Domain)" } else { "Workgroup: $($cs.Workgroup)" })
        'Time source'      = Get-ArcTimeSource
        'Last update installed' = $(if ($lastHf) { "$($lastHf.HotFixID) on $($lastHf.InstalledOn.ToString('yyyy-MM-dd'))" } else { 'Unknown' })
    }
    $sections += @{ Title = 'Operating system and identity'; Html = (New-ArcKvTable $osRows) }
    if ($activated) { Add-Result PASS 'Windows activation' 'Activated' } else { Add-Result WARN 'Windows activation' 'Not activated' }
    if ($cv.InstallationType -eq 'Server') { Add-Result PASS 'Install type' 'Desktop Experience' } else { Add-Result WARN 'Install type' $cv.InstallationType }
    if ($os.Caption -match 'Standard') {
        if ($vms.Count -gt 2) { Add-Result WARN 'Licensing' "Standard edition with $($vms.Count) VMs - Standard covers 2 Windows Server guests per fully licensed host (stack licences or use Datacenter). Count excludes non-Windows guests." }
        else { Add-Result PASS 'Licensing' "Standard edition, $($vms.Count) VM(s)" }
    } else { Add-Result PASS 'Licensing' "$($os.Caption)" }
    $ts = $osRows['Time source']
    if ($ts -match 'Local CMOS|Free-running|VM IC') { Add-Result WARN 'Time source' $ts } else { Add-Result PASS 'Time source' $ts }
    if (Test-PendingReboot) { Add-Result WARN 'Pending reboot' 'Reboot to finish installing changes' } else { Add-Result PASS 'No pending reboot' }

    # Network
    $sw = Get-ArcSetSwitch
    $netRows = [ordered]@{}
    if ($sw) {
        $team = Get-VMSwitchTeam -Name $sw.Name -ErrorAction SilentlyContinue
        $netRows['Switch'] = "$($sw.Name) (SET, $($team.LoadBalancingAlgorithm), bandwidth mode $($sw.BandwidthReservationMode))"
        $netRows['Members'] = (@(Get-ArcSwitchMembers | ForEach-Object { "$($_.Name) $($_.LinkSpeed) $($_.Status)" }) -join '; ')
        Add-Result PASS 'Host network' "SET switch $($sw.Name)"
        if ((Get-Answer 'MgmtFromWorkshop') -and (Test-ArcMgmtOnDhcp)) { Add-Result WARN 'Management address' 'Still on the workshop DHCP address - run -Phase Network to set the customer static address' }
        $down = @(Get-ArcSwitchMembers | Where-Object Status -ne 'Up')
        if ($down) { Add-Result WARN 'Switch member links' "Down: $($down.Name -join ', ')" } else { Add-Result PASS 'Switch member links' 'All up' }
    } elseif (Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue) {
        $netRows['Switch'] = ((Get-VMSwitch -SwitchType External).Name -join ', ') + ' (not SET)'
        Add-Result WARN 'Host network' 'External switch is not SET'
    } else { Add-Result FAIL 'Host network' 'No external switch'; $netRows['Switch'] = 'None' }
    foreach ($v in Get-VMNetworkAdapter -ManagementOS -ErrorAction SilentlyContinue) {
        $alias = "vEthernet ($($v.Name))"
        $ip  = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object PrefixOrigin -ne 'WellKnown' | Select-Object -First 1
        $vl  = Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $v.Name
        $gw  = (Get-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $dns = @((Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) -join ', '
        $netRows["Host vNIC $($v.Name)"] = "$(if ($ip) { "$($ip.IPAddress)/$($ip.PrefixLength) ($($ip.PrefixOrigin))" } else { 'no IPv4' }), VLAN $(if ($vl.OperationMode -eq 'Access') { $vl.AccessVlanId } else { 'untagged' }), gateway $gw, DNS $dns"
    }
    $sections += @{ Title = 'Network'; Html = (New-ArcKvTable $netRows) + (New-ArcTable @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object Name, InterfaceDescription, MacAddress, LinkSpeed, Status) @('Name', 'InterfaceDescription', 'MacAddress', 'LinkSpeed', 'Status')) }

    # Storage
    $vh = Get-VMHost -ErrorAction SilentlyContinue
    $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter | ForEach-Object {
        [pscustomobject]@{ Volume = "$($_.DriveLetter):"; Label = $_.FileSystemLabel; FileSystem = $_.FileSystem; SizeGB = [math]::Round($_.Size / 1GB); FreeGB = [math]::Round($_.SizeRemaining / 1GB); Health = "$($_.HealthStatus)" }
    })
    $disks = @(Get-Disk | Sort-Object Number | ForEach-Object { [pscustomobject]@{ Disk = $_.Number; Name = $_.FriendlyName; Bus = "$($_.BusType)"; SizeGB = [math]::Round($_.Size / 1GB); Health = "$($_.HealthStatus)"; Boot = $(if ($_.IsBoot) { 'Yes' } else { '' }) } })
    $stRows = [ordered]@{ 'Default VM path' = $vh.VirtualMachinePath; 'Default VHD path' = $vh.VirtualHardDiskPath }
    $sections += @{ Title = 'Storage'; Html = (New-ArcKvTable $stRows) + (New-ArcTable $vols @('Volume', 'Label', 'FileSystem', 'SizeGB', 'FreeGB', 'Health')) + (New-ArcTable $disks @('Disk', 'Name', 'Bus', 'SizeGB', 'Health', 'Boot')) }
    if ($vh -and $vh.VirtualMachinePath -notlike "$env:SystemDrive*") { Add-Result PASS 'VM storage' "Default VM path $($vh.VirtualMachinePath)" } else { Add-Result WARN 'VM storage' "Default VM path is on the system drive ($($vh.VirtualMachinePath))" }
    $bad = @($disks | Where-Object Health -ne 'Healthy')
    if ($bad) { Add-Result FAIL 'Disk health' "Not healthy: $(($bad | ForEach-Object { "disk $($_.Disk) $($_.Health)" }) -join ', ')" } else { Add-Result PASS 'Disk health' 'All healthy' }
    foreach ($v in $vols | Where-Object { $_.SizeGB -gt 0 -and ($_.FreeGB / $_.SizeGB) -lt 0.15 }) { Add-Result WARN "Free space $($v.Volume)" "$($v.FreeGB) GB of $($v.SizeGB) GB free" }

    # Security and protection
    $edr = Get-ArcEdr
    $def = Get-ArcDefenderState
    $edrChoice = Get-Answer 'EdrProduct'
    if ($edr) { if ($edr.Running) { Add-Result PASS 'EDR' "$($edr.Product) running" } else { Add-Result FAIL 'EDR' "$($edr.Product) installed but not all services running" } }
    elseif ($edrChoice -eq 'Defender') { Add-Result INFO 'EDR' 'None - Microsoft Defender is the antivirus (engineer choice)' }
    else { Add-Result FAIL 'EDR' 'Neither SentinelOne nor Sophos found' }
    if ($edr -and $def -eq 'Active') { Add-Result WARN 'Microsoft Defender' "Still active alongside $($edr.Product) - two real-time scanners (see the Edr phase)" }
    elseif (-not $edr -and $def -ne 'Active') { Add-Result FAIL 'Microsoft Defender' "$def, and no EDR found - the host has no active antivirus" }
    else { Add-Result PASS 'Microsoft Defender' $def }
    # The off-policy outlives the EDR. Name it, so whoever removes the EDR also removes it.
    if ((Get-ItemProperty $DefenderPolicy -Name DisableAntiSpyware -ErrorAction SilentlyContinue).DisableAntiSpyware -eq 1) {
        Add-Result INFO 'Defender off-policy' "DisableAntiSpyware and Real-Time Protection\DisableRealtimeMonitoring = 1 under $($DefenderPolicy -replace '^HKLM:', 'HKLM'). If the EDR is ever removed, delete both values and reboot, or the host has no antivirus."
    }
    if (Get-Service CagService -ErrorAction SilentlyContinue) { Add-Result PASS 'Datto RMM agent' "$((Get-Service CagService).Status)" } else { Add-Result FAIL 'Datto RMM agent' 'Not installed' }
    $builtin = Get-ArcBuiltinAdmin
    if ($builtin -and $builtin.Enabled) { Add-Result WARN 'Built-in Administrator' 'Enabled - run -Phase Admin' } else { Add-Result PASS 'Built-in Administrator' 'Disabled' }
    $adminName = Get-Answer 'LocalAdminName'
    if ($adminName -and (Get-LocalUser -Name $adminName -ErrorAction SilentlyContinue)) { Add-Result PASS 'Local admin account' "$adminName (password in ITGlue)" } else { Add-Result WARN 'Local admin account' 'Not created by these scripts' }
    $left = @(Get-BaselinePlan -Facts (Get-ArcHostFacts))
    if ($left) { Add-Result WARN 'Baseline' "$($left.Count) item(s) differ from the standard: $(($left | ForEach-Object Desc) -join '; ')" } else { Add-Result PASS 'Baseline' 'Security and optimisation settings match the standard' }
    $filter = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
    if (-not $cs.PartOfDomain) {
        if ($filter -eq 1) { Add-Result PASS 'Remote UAC (workgroup)' 'Off for local accounts (Arc standard, for Veeam/remote Hyper-V Manager). The local admin password must be unique to this host.' }
        else { Add-Result WARN 'Remote UAC (workgroup)' 'On - Veeam admin-share/WMI access and remote Hyper-V Manager with the local admin account will be refused. Run -Phase Identity.' }
    }
    $secRows = [ordered]@{
        'EDR'                    = $(if ($edr) { $edr.Product } elseif ($edrChoice) { $edrChoice } else { 'None' })
        'Microsoft Defender'     = $def
        'Datto RMM agent'        = $(if (Get-Service CagService -ErrorAction SilentlyContinue) { 'Installed' } else { 'Not installed' })
        'Local admin account'    = $(if ($adminName) { $adminName } else { 'Not recorded' })
        'Built-in Administrator' = $(if ($builtin -and $builtin.Enabled) { 'Enabled' } else { 'Disabled' })
        'Firewall'               = (@(Get-NetFirewallProfile | ForEach-Object { "$($_.Name) $(if ($_.Enabled) { 'on' } else { 'off' })" }) -join ', ')
        'Baseline differences'   = "$($left.Count)"
    }
    $sections += @{ Title = 'Security and protection'; Html = (New-ArcKvTable $secRows) }

    # Backup readiness and power protection
    $writers = @(Get-ArcVssWriters)
    $hvw = $writers | Where-Object Writer -like '*Hyper-V*' | Select-Object -First 1
    if (-not $hvw) { Add-Result WARN 'Hyper-V VSS writer' 'Not listed (is the Hyper-V role installed?)' }
    elseif ($hvw.State -eq 'Stable' -and $hvw.LastError -eq 'No error') { Add-Result PASS 'Hyper-V VSS writer' 'Stable, no error' }
    else { Add-Result WARN 'Hyper-V VSS writer' "$($hvw.State), $($hvw.LastError)" }
    $badW = @($writers | Where-Object { $_.LastError -ne 'No error' })
    if ($badW) { Add-Result WARN 'VSS writers' "With errors: $(($badW | ForEach-Object Writer) -join ', ')" }
    foreach ($g in 'File and Printer Sharing', 'Windows Management Instrumentation (WMI)') {
        $r = @(Get-NetFirewallRule -DisplayGroup $g -Direction Inbound -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' })
        if ($r) { Add-Result PASS "Firewall: $g" 'Inbound rules enabled (backup proxy access)' } else { Add-Result WARN "Firewall: $g" 'Inbound rules not enabled - Veeam needs them to deploy its components' }
    }
    $veeam = @(Get-Service -ErrorAction SilentlyContinue | Where-Object DisplayName -like 'Veeam*')
    Add-Result INFO 'Veeam components' $(if ($veeam) { ($veeam.DisplayName -join ', ') } else { 'None yet - Veeam deploys them when the host is added' })
    $ups = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'PowerChute|APC |Eaton|Intelligent Power|UPS|Network Shutdown|Vertiv|CyberPower' })
    if ($ups) { Add-Result PASS 'UPS shutdown agent' ($ups.DisplayName -join ', ') } else { Add-Result WARN 'UPS shutdown agent' 'None found - the host will not shut down cleanly on a power cut' }
    $sections += @{ Title = 'Backup readiness'; Html = (New-ArcTable $writers @('Writer', 'State', 'LastError')) }

    # Virtual machines
    $vmRows = @($vms | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; State = "$($_.State)"; Generation = $_.Generation; vCPU = $_.ProcessorCount; StartupGB = [math]::Round($_.MemoryStartup / 1GB, 1); Start = "$($_.AutomaticStartAction) +$($_.AutomaticStartDelay)s"; Stop = "$($_.AutomaticStopAction)" }
    })
    $notShutdown = @($vms | Where-Object { "$($_.AutomaticStopAction)" -ne 'ShutDown' })
    if (-not $vms) { Add-Result INFO 'VM start/stop' 'No VMs yet - run -Phase HostSettings after creating them' }
    elseif ($notShutdown) { Add-Result WARN 'VM automatic stop' "Not Shut Down: $($notShutdown.Name -join ', ')" }
    else { Add-Result PASS 'VM automatic stop' 'Shut Down on every VM' }
    $sections += @{ Title = 'Virtual machines'; Html = (New-ArcTable $vmRows @('Name', 'State', 'Generation', 'vCPU', 'StartupGB', 'Start', 'Stop')) }

    # Build record
    $phases = @($state.Phases.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Phase = $_.Name; Script = $_.Value.Script; Completed = $_.Value.Completed; Version = $_.Value.Version } })
    $sections += @{ Title = 'Build record'; Html = (New-ArcTable $phases @('Phase', 'Script', 'Completed', 'Version')) }

    $name = $env:COMPUTERNAME
    $sub = "Standalone Hyper-V host. $(if ($cs.PartOfDomain) { $cs.Domain } else { "Workgroup $($cs.Workgroup)" }). Report generated $(Get-Date -Format 'd MMMM yyyy')."
    $html = New-ArcAsBuiltHtml -HostName $name -Subtitle $sub -Checks $script:Results -Sections $sections
    $path = Join-Path $LogRoot "AsBuilt-$name-$(Get-Date -Format 'yyyyMMdd-HHmm').html"
    [IO.File]::WriteAllText($path, $html, [Text.UTF8Encoding]::new($false))
    Write-Host "`n  As-built report: $path" -ForegroundColor Green
    Write-Host '  Attach it to this host''s Configuration in ITGlue.' -ForegroundColor Green
    Save-PhaseComplete 'Report'
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

    $steps = 'Network', 'Identity', 'Edr', 'Admin', 'BaselineSite', 'HostSettings', 'Report'
    while ($true) {
        $step = $steps | Where-Object { -not (Test-PhaseDone $_) } | Select-Object -First 1
        if (-not $step) { Write-Host "`nSite build complete - all phases recorded. Re-run -Phase Report any time for a fresh as-built." -ForegroundColor Green; return }
        Write-Host "`n################ Next: $step ################" -ForegroundColor Magenta
        $r = 'Done'
        switch ($step) {
            'Network'      { if (-not (Invoke-Network)) { Stop-Next 'Build the host network (on the console or iLO remote console).'; return } }
            'Identity'     { $r = Invoke-Identity }
            'Edr'          { $r = Invoke-Edr }
            'Admin'        { $r = Invoke-Admin }
            'BaselineSite' { $r = Invoke-Baseline }
            'HostSettings' { Invoke-HostSettings }
            'Report'       { $script:Results.Clear(); Invoke-Report; Write-Summary }
        }
        if ($r -eq 'Gate') { return }
        if ((Get-State).RebootPending) { Request-ArcReboot; return }
    }
}

function Write-Summary {
    if (-not $script:Results.Count) { return }
    $fails = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $warns = @($script:Results | Where-Object Status -eq 'WARN').Count
    Write-Host "`nSummary: $fails FAIL, $warns WARN." -ForegroundColor $(if ($fails) { 'Red' } elseif ($warns) { 'Yellow' } else { 'Green' })
    $script:Results | Export-Csv -Path (Join-Path $LogRoot "Site-$Phase-checks-$Stamp.csv") -NoTypeInformation
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    switch ($Phase) {
        'Next'         { Invoke-Next }
        'Network'      { if (-not (Invoke-Network)) { Write-Host 'Host network not built.' -ForegroundColor Yellow } }
        'Identity'     { if ((Invoke-Identity) -eq 'Reboot') { Write-Host "`nREBOOT REQUIRED." -ForegroundColor Yellow } }
        'Edr'          { if ((Invoke-Edr) -eq 'Reboot') { Write-Host "`nREBOOT REQUIRED, then run -Phase Edr again to check Defender is off." -ForegroundColor Yellow } }
        'Admin'        { $null = Invoke-Admin }
        'Baseline'     { $null = Invoke-Baseline; if ((Get-State).RebootPending) { Write-Host "`nREBOOT REQUIRED for some items." -ForegroundColor Yellow } }
        'HostSettings' { Invoke-HostSettings }
        'Report'       { Invoke-Report; Write-Summary }
    }
} catch {
    Write-Host "`nPHASE $Phase STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
