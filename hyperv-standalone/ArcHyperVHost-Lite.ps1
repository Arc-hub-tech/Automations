<#
================================================================
 BEFORE YOU RUN THIS SCRIPT
================================================================
 LITE standardisation for an EXISTING standalone HPE Hyper-V host that is
 already built and in service (Hyper-V role in, SPP done, network and VMs
 running). It brings the host up to the same security and Hyper-V
 optimisation standard as the Workshop and Site scripts, but:

   - it never touches the network, domain membership, EDR or accounts;
   - it NEVER reboots - anything that needs one is listed for a maintenance window;
   - anything that can interrupt service is asked for on its own, with the risk stated.

 Tested on Windows Server 2025. Older versions (2016-2022) are untested - the
 one-liner forces TLS 1.2 so the download works on them; run Check first.

 Not for failover cluster nodes: use hyperv-cluster\ArcHyperVCluster.ps1 (its
 Baseline drains the node first). For a full on-site build (static IP, domain,
 EDR, new local admin) use ArcHyperVHost-Site.ps1.

 1. Log on as an administrator and open an elevated PowerShell prompt. For
    Apply, prefer the console or the iLO remote console: the VMQ item (only if
    it is needed) restarts the switch adapters, which drops RDP for a few seconds.
 2. DOWNLOAD-THEN-RUN (single line). Check is read-only:

       [Net.ServicePointManager]::SecurityProtocol='Tls12'; $p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Lite.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Lite.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Check

    OR from a USB stick:

       Set-ExecutionPolicy Bypass -Scope Process -Force; & E:\ArcHyperVHost\ArcHyperVHost-Lite.ps1 -Phase Check

 3. Read the plan and the HTML report it writes to C:\ArcLogs\HyperVHost\, get
    the change approved, then:

       Set-ExecutionPolicy Bypass -Scope Process -Force; & "$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Lite.ps1" -Phase Apply
================================================================

.SYNOPSIS
    Lite security and Hyper-V optimisation standard for a live standalone Hyper-V host.

.DESCRIPTION
    Phases:
      Check   Read-only. Shows what Apply would change, runs the live-host checks
              (old checkpoints, backup readiness, licensing, EDR/Defender, UPS ...)
              and writes an HTML report. Changes nothing.
      Apply   Shows the same plan, then asks: once for the live-safe items, once for
              the items that only take effect at a reboot, and separately for each
              item that can interrupt service. Then the VM automatic start/stop
              changes. Applies VMQ last, never reboots, and writes the report again.

.NOTES
    Same standard (and the same code) as ArcHyperVHost-Workshop.ps1 and
    ArcHyperVHost-Site.ps1; shares their state file. Logs and reports:
    C:\ArcLogs\HyperVHost\. Not a Datto component - an engineer runs it.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Apply')]
    [string]$Phase = 'Check'
)

# Version of this script, surfaced in the banner/transcript. All three standalone
# scripts share one version; '-dev' suffix while work accumulates under [Unreleased].
$ScriptVersion = '0.2.0-dev'
$ScriptRole    = 'Lite'   # names the state entries, logs and report

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$LogRoot   = "$env:SystemDrive\ArcLogs\HyperVHost"
$StatePath = Join-Path $LogRoot 'state.json'
$Work      = Join-Path $env:TEMP 'ArcHyperVHost'
New-Item -ItemType Directory -Path $LogRoot, $Work -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $LogRoot "Lite-$Phase-$Stamp.log") | Out-Null

Write-Host "ArcHyperVHost-Lite.ps1  v$ScriptVersion  -  phase: $Phase  -  $env:COMPUTERNAME" -ForegroundColor Cyan

# Keep a local copy, so Apply can be run later from the same place once a USB stick is removed.
$ScriptCopy = Join-Path $LogRoot "ArcHyperVHost-$ScriptRole.ps1"
if ($PSCommandPath -and $PSCommandPath -ne $ScriptCopy) { Copy-Item $PSCommandPath $ScriptCopy -Force }

# ---- start of shared helpers ----
# Everything down to "end of shared helpers" is identical in ArcHyperVHost-Workshop.ps1,
# ArcHyperVHost-Site.ps1 and ArcHyperVHost-Lite.ps1 (each file is self-contained). Change all three together.
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
        # 802.3 Ethernet. Most drivers report physical medium 14; some (and Hyper-V's synthetic NIC) report 0 = unspecified.
        $_.MediaType -eq '802.3' -and $_.NdisPhysicalMedium -in 0, 14 -and
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
    $members = if ($pick -match '^\d+$') { @(($groups | Where-Object Number -eq ([int]$pick)).Names) } else { @($pick -split ',' | ForEach-Object Trim | Where-Object { $_ }) }
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

# '@'-prefixed entries are resource-string group names (language independent).
function Get-ArcFirewallGroupRules {
    param([string]$Group)
    if ($Group -like '@*') { return @(Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue) }
    return @(Get-NetFirewallRule -DisplayGroup $Group -ErrorAction SilentlyContinue)
}

function Enable-ArcFirewallGroups {
    foreach ($g in $FirewallGroups) {
        $rules = @(Get-ArcFirewallGroupRules $g)
        if ($rules) { $rules | Enable-NetFirewallRule; Write-Host "    firewall rules enabled: $($rules[0].DisplayGroup)" }
    }
}

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
    # A fresh install already has the firewall on, so the management rule groups are checked on their own.
    $closed = @($FirewallGroups | Where-Object { $r = @(Get-ArcFirewallGroupRules $_); $r -and -not @($r | Where-Object Enabled -eq 'True') })
    $closed = @($closed | ForEach-Object { if ($_ -like '@*') { @(Get-ArcFirewallGroupRules $_)[0].DisplayGroup } else { $_ } })
    $c['Sec.FirewallRules'] = if ($closed) { "Off: $($closed -join '; ')" } else { 'All enabled' }
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
        # A NIC with no VMQ settings doesn't support it (e.g. Hyper-V's synthetic NIC) - not drift.
        $vmq = @($members | ForEach-Object { Get-NetAdapterVmq -Name $_.Name -ErrorAction SilentlyContinue })
        $vmqOff = @($vmq | Where-Object { -not $_.Enabled })
        $c['Opt.VMQ'] = if (-not $vmq) { 'Not supported' } elseif ($vmqOff) { "Disabled on $($vmqOff.Name -join ', ')" } else { 'Enabled' }
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
    if ($c['Sec.FirewallRules'] -and $c['Sec.FirewallRules'] -ne 'All enabled') { $items.Add((New-PlanItem 'Security' 'Sec.FirewallRules' 'Firewall rules for management (Hyper-V, WinRM, SMB, WMI, Remote Desktop) enabled' $c['Sec.FirewallRules'] 'All enabled' $false 'FirewallRules')) }
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
    if ($c['Opt.VMQ'] -and $c['Opt.VMQ'] -notin 'Enabled', 'Not supported') { $items.Add((New-PlanItem 'Optimisation' 'Opt.VMQ' 'VMQ on (switch members; adapter restarts - VMs lose network for a few seconds)' $c['Opt.VMQ'] 'Enabled' $false 'Vmq')) }

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
        'Firewall'         { Enable-ArcFirewallGroups; Set-NetFirewallProfile -Profile $a.Profile -Enabled True }
        'FirewallRules'    { Enable-ArcFirewallGroups }
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
        'Vmq'              { foreach ($n in Get-ArcSwitchMembers) { $q = Get-NetAdapterVmq -Name $n.Name -ErrorAction SilentlyContinue; if ($q -and -not $q.Enabled) { Enable-NetAdapterVmq -Name $n.Name -ErrorAction Stop } } }
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

# ---- start of report helpers ----
# Everything down to "end of report helpers" is identical in ArcHyperVHost-Site.ps1
# and ArcHyperVHost-Lite.ps1 (the Workshop script has no report). Change both together.
# ---------------------------------------------------------------------------

function Get-ArcTimeSource {
    $ErrorActionPreference = 'Continue'   # native stderr must not throw (function scope only)
    return (w32tm /query /source 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
}

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

# Older builds turned Defender off by policy instead of removing it. The reports still
# look for that policy on existing hosts.
$DefenderPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'

function Get-ArcBuiltinAdmin { return (Get-LocalUser | Where-Object { $_.SID.Value -match '^S-1-5-21-.*-500$' } | Select-Object -First 1) }

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
    param([string]$HostName, [string]$Subtitle, $Checks, [object[]]$Sections, [string]$Kind = 'as-built')
    $fails = @($Checks | Where-Object Status -eq 'FAIL').Count
    $warns = @($Checks | Where-Object Status -eq 'WARN').Count
    $passes = @($Checks | Where-Object Status -eq 'PASS').Count
    $body = New-Object System.Text.StringBuilder
    [void]$body.Append("<section><h2>Summary</h2><div class=`"summary`"><strong>$passes passed, $warns warnings, $fails failed.</strong> Warnings and failures are listed first in the checks below.</div></section>")
    $ordered = @($Checks | Sort-Object @{ e = { @{ FAIL = 0; WARN = 1; PASS = 2; INFO = 3 }[$_.Status] } })
    [void]$body.Append("<section><h2>Checks</h2>$(New-ArcTable $ordered @('Status', 'Check', 'Detail') 'Status')</section>")
    foreach ($s in $Sections) { [void]$body.Append("<section><h2>$(ConvertTo-Html-Safe $s.Title)</h2>$($s.Html)</section>") }
    $title = ConvertTo-Html-Safe "$HostName $Kind"
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
<h1>$title</h1>
<p>$(ConvertTo-Html-Safe $Subtitle)</p>
</header>
<main>
$($body.ToString())
</main>
<footer>Generated by ArcHyperVHost-$ScriptRole.ps1 v$(ConvertTo-Html-Safe $ScriptVersion) on $(ConvertTo-Html-Safe (Get-Date -Format 'd MMMM yyyy HH:mm')). Attach to the host's Configuration in ITGlue.</footer>
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

# ---- end of report helpers ----

# ---------------------------------------------------------------------------
# Guards - an existing standalone Hyper-V host only
# ---------------------------------------------------------------------------

function Assert-LiteHost {
    # The feature, not just a running ClusSvc: a node down for maintenance still needs the cluster
    # firewall rules and the drain. A standalone host has no reason to have it.
    $fc = Get-WindowsFeature Failover-Clustering -ErrorAction SilentlyContinue
    if ($fc -and $fc.Installed) { throw 'Failover Clustering is installed - this is (or was) a cluster node. Use hyperv-cluster\ArcHyperVCluster.ps1 instead - its Baseline drains the node before changing anything.' }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 26100) { Write-Warning "Tested on Windows Server 2025 only - this is $($os.Caption). Run Check first and read the plan carefully." }
    $hv = Get-WindowsFeature Hyper-V -ErrorAction SilentlyContinue
    if (-not $hv -or -not $hv.Installed) { throw 'The Hyper-V role is not installed. This script is for hosts that are already built - use ArcHyperVHost-Workshop.ps1 for a new build.' }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'The Hyper-V PowerShell module is missing (Install-WindowsFeature Hyper-V-PowerShell).' }
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.Manufacturer -notmatch 'HPE|Hewlett') { Write-Warning "Not HPE hardware ($($cs.Manufacturer) $($cs.Model)) - the BIOS workload profile is not checked." }
    elseif (-not (Get-IloRest)) { Write-Host '  ilorest is not installed - the BIOS workload profile is not checked (set it in RBSU, or install ilorest from the SPP).' -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------
# Plan - the shared baseline, plus Defender exclusions, sorted by how safe it is live
# ---------------------------------------------------------------------------

# Items that can interrupt service on a live host. Each group is asked for on its own,
# with the risk stated; anything not matched here is safe to apply with VMs running.
# Listed in the order they are asked; VMQ is also applied last.
$LiteRiskGroups = @(
    @{ Key = 'Firewall'; Match = '^Sec\.Firewall\.'; Title = 'Turn the Windows Firewall on'
       Risk = 'The Hyper-V, WinRM, file sharing, WMI and Remote Desktop rules are enabled first, but any other inbound traffic is blocked from then on: Hyper-V Replica listeners (their own rule groups), Veeam data movers, the UPS agent, SNMP, monitoring, agents on custom ports. Check what connects to this host first.' }
    @{ Key = 'Uac'; Match = '^Sec\.UAC\.EnableLUA$'; Title = 'UAC turned back on'
       Risk = 'UAC is off on this host today. From the next reboot, remote UAC filtering applies again: on a workgroup host without LocalAccountTokenFilterPolicy = 1, Veeam and remote Hyper-V Manager using a local admin account get access denied (ArcHyperVHost-Site.ps1 -Phase Identity sets it). Tools that expect to run elevated without a prompt may also break.' }
    @{ Key = 'Ntlm'; Match = '^Sec\.LmCompatibilityLevel$'; Title = 'NTLMv2 only'
       Risk = 'Devices or old software that authenticate with LM or NTLMv1 (old NAS boxes, scanners, legacy agents) are refused.' }
    @{ Key = 'Tls'; Match = '^Sec\.Tls\.'; Title = 'SSL 3.0, TLS 1.0 and TLS 1.1 off'
       Risk = 'From the next reboot, agents, management tools or backup software that only speak TLS 1.0/1.1 can no longer connect to or from this host.' }
    @{ Key = 'SmbSigning'; Match = '^Sec\.Smb(Server|Client)Signing$'; Title = 'SMB signing required'
       Risk = 'SMB connections that cannot sign are refused, in both directions. Check older NAS backup repositories and anything that maps a share on this host.' }
    @{ Key = 'Legacy'; Match = '^Sec\.(SMB1Protocol|Feature\.)'; Title = 'SMBv1 and PowerShell 2.0 removed'
       Risk = 'Anything still using SMBv1 (very old NAS boxes or copiers) or PowerShell 2.0 stops working. Feature removals finish at the next reboot.' }
    @{ Key = 'Bios'; Match = '^HPE\.'; Title = 'BIOS workload profile'
       Risk = 'Changes the BIOS power and processor settings at the next reboot (through an iLO session).' }
    @{ Key = 'Vmq'; Match = '^Opt\.VMQ$'; Title = 'VMQ on the switch adapters'
       Risk = 'Each switch adapter restarts: VM and management networking drop for a few seconds, and an RDP or remote PowerShell session may drop. Applied last. Prefer the console or the iLO remote console. If VMQ was turned off deliberately (e.g. the known problems with some Broadcom 1GbE NICs), say no.' }
)

# Defender's role auto-exclusions and the VM folders (Set-ArcDefenderHyperVExclusions), as a plan item.
function Get-LiteDefenderItem {
    if ((Get-ArcDefenderState) -ne 'Active') { return $null }
    $pref = Get-MpPreference -ErrorAction SilentlyContinue
    if (-not $pref) { return $null }
    $vmPath = (Get-VMHost -ErrorAction SilentlyContinue).VirtualMachinePath
    $missing = @(@($vmPath, "$env:ProgramData\Microsoft\Windows\Hyper-V") | Where-Object { $_ -and $_ -notin @($pref.ExclusionPath) })
    if (-not $pref.DisableAutoExclusions -and -not $missing) { return $null }
    $cur = @()
    if ($pref.DisableAutoExclusions) { $cur += 'role auto-exclusions off' }
    if ($missing) { $cur += "not excluded: $($missing -join ', ')" }
    return (New-PlanItem 'Hyper-V' 'HyperV.DefenderExclusions' 'Defender Hyper-V exclusions (role auto-exclusions on, VM folders excluded)' ($cur -join '; ') 'In place' $false 'DefenderExclusions')
}

function Get-LitePlan {
    $plan = @(Get-BaselinePlan -Facts (Get-ArcHostFacts))
    $d = Get-LiteDefenderItem
    if ($d) { $plan += $d }
    foreach ($i in $plan) {
        $g = $LiteRiskGroups | Where-Object { $i.Id -match $_.Match } | Select-Object -First 1
        $i | Add-Member -NotePropertyName RiskGroup -NotePropertyValue $(if ($g) { $g.Key } else { $null }) -Force
        $i | Add-Member -NotePropertyName When -NotePropertyValue $(if ($g) { "Ask: $($g.Title)" } elseif ($i.Restart) { 'At reboot' } else { 'Now' }) -Force
    }
    return $plan
}

function Show-LitePlan {
    param($Plan)
    $Plan | Sort-Object @{ e = { if ($_.RiskGroup) { 2 } elseif ($_.Restart) { 1 } else { 0 } } }, Area, Id |
        Format-Table Area, Desc, Current, Desired, When -AutoSize -Wrap | Out-String -Width 220 | Write-Host
}

function Invoke-LiteItem {
    param([Parameter(Mandatory)]$Item)
    if ($Item.Kind -eq 'DefenderExclusions') { Set-ArcDefenderHyperVExclusions; return }
    Invoke-PlanItem $Item
}

# ---------------------------------------------------------------------------
# VM automatic start/stop - only VMs that differ. A start delay the customer has set
# (e.g. a staggered DC-first order) is kept; only zero delays are given the default.
# ---------------------------------------------------------------------------

function Get-LiteDefaultDelay { $d = Get-Answer 'StartDelay'; if ($null -ne $d) { return [int]$d } return 120 }

function Get-LiteVmPlan {
    param([int]$Delay)
    $rows = @()
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ("$($vm.AutomaticStartAction)" -eq 'Nothing') {
            $rows += [pscustomobject]@{ VM = $vm.Name; Setting = 'Automatic start'; Current = 'Nothing'; Desired = 'StartIfRunning'; Value = 'StartIfRunning'; Apply = $true; Note = 'Starts after a host reboot only if it was running before' }
        }
        if ($vm.AutomaticStartDelay -eq 0 -and $Delay -gt 0) {
            $rows += [pscustomobject]@{ VM = $vm.Name; Setting = 'Start delay'; Current = '0 s'; Desired = "$Delay s"; Value = $Delay; Apply = $true; Note = '' }
        }
        if ("$($vm.AutomaticStopAction)" -ne 'ShutDown') {
            $off = "$($vm.State)" -eq 'Off'
            $rows += [pscustomobject]@{ VM = $vm.Name; Setting = 'Automatic stop'; Current = "$($vm.AutomaticStopAction)"; Desired = 'ShutDown'; Value = 'ShutDown'; Apply = $off
                Note = $(if ($off) { '' } else { "VM is $($vm.State) - set it when the VM is next shut down" }) }
        }
    }
    return $rows
}

function Show-LiteVmPlan {
    param($Rows)
    $Rows | Format-Table VM, Setting, Current, Desired, Note -AutoSize -Wrap | Out-String -Width 220 | Write-Host
}

function Invoke-LiteVmItem {
    param([Parameter(Mandatory)]$Row)
    switch ($Row.Setting) {
        'Automatic start' { Set-VM -Name $Row.VM -AutomaticStartAction StartIfRunning -ErrorAction Stop }
        'Start delay'     { Set-VM -Name $Row.VM -AutomaticStartDelay ([int]$Row.Value) -ErrorAction Stop }
        'Automatic stop'  { Set-VM -Name $Row.VM -AutomaticStopAction ShutDown -ErrorAction Stop }
    }
}

# Records the run without clearing a reboot another script is still waiting for.
function Save-LiteRun {
    param([bool]$RebootNeeded)
    $s = Get-State
    $s.Phases | Add-Member -NotePropertyName 'BaselineLite' -NotePropertyValue ([pscustomobject]@{ Completed = (Get-Date -Format 's'); Version = $ScriptVersion; Script = $ScriptRole }) -Force
    if ($RebootNeeded) {
        $s | Add-Member -NotePropertyName RebootPending -NotePropertyValue $true -Force
        $s | Add-Member -NotePropertyName RebootRequestedAt -NotePropertyValue (Get-Date -Format 's') -Force
    }
    Save-State $s
}

# ---------------------------------------------------------------------------
# Phase: Check (read-only)
# ---------------------------------------------------------------------------

function Invoke-LiteCheck {
    Write-Step "Standards plan for $env:COMPUTERNAME (read-only - nothing is changed)"
    $plan = @(Get-LitePlan)
    if ($plan) { Show-LitePlan $plan } else { Write-Host '  The host matches the security and optimisation standard.' -ForegroundColor Green }
    $vmPlan = @(Get-LiteVmPlan -Delay (Get-LiteDefaultDelay))
    if ($vmPlan) { Write-Host '  VM automatic start/stop:'; Show-LiteVmPlan $vmPlan }
    Invoke-LiteReport -Stage 'Check' -Plan $plan -VmPlan $vmPlan
    Write-Host "`n  Nothing was changed. When the change is approved, run:  -Phase Apply" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Phase: Apply
# ---------------------------------------------------------------------------

function Invoke-LiteApply {
    Write-Step "Standards plan for $env:COMPUTERNAME"
    $plan = @(Get-LitePlan)
    if ($plan) { Show-LitePlan $plan } else { Write-Host '  The host already matches the security and optimisation standard.' -ForegroundColor Green }
    $running = @(Get-VM -ErrorAction SilentlyContinue | Where-Object State -eq 'Running')
    if ($running -and $plan) { Write-Host "  $($running.Count) VM(s) are running. Nothing here restarts them; items marked At reboot wait for a reboot you plan yourself." -ForegroundColor Yellow }

    # Every question first, then everything is applied in one go (VMQ last).
    $chosen   = New-Object System.Collections.Generic.List[object]
    $declined = New-Object System.Collections.Generic.List[string]

    $now = @($plan | Where-Object { -not $_.RiskGroup -and -not $_.Restart })
    if ($now) {
        if (Confirm-Action "Apply the $($now.Count) live-safe change(s) marked Now") { foreach ($i in $now) { $chosen.Add($i) } } else { $declined.Add('Live-safe changes') }
    }
    $boot = @($plan | Where-Object { -not $_.RiskGroup -and $_.Restart })
    if ($boot) {
        Write-Host "`n  Items marked At reboot are set now and take effect at the next reboot. This script does not reboot." -ForegroundColor Cyan
        if (Confirm-Action "Apply the $($boot.Count) change(s) marked At reboot") { foreach ($i in $boot) { $chosen.Add($i) } } else { $declined.Add('At-reboot changes') }
    }
    foreach ($g in $LiteRiskGroups) {
        $items = @($plan | Where-Object RiskGroup -eq $g.Key)
        if (-not $items) { continue }
        Write-Host "`n  $($g.Title) ($($items.Count) item(s))" -ForegroundColor Yellow
        Write-Host "  Risk: $($g.Risk)" -ForegroundColor Yellow
        if (Confirm-Action "  Apply '$($g.Title)'") { foreach ($i in $items) { $chosen.Add($i) } } else { $declined.Add($g.Title) }
    }

    Write-Step 'VM automatic start and stop'
    $delay = Get-LiteDefaultDelay
    if (@(Get-VM -ErrorAction SilentlyContinue | Where-Object AutomaticStartDelay -eq 0)) {
        $delay = [int](Read-Value 'Start delay for VMs that have none, in seconds (existing delays are kept)' "$delay" { param($v) $v -match '^\d+$' -and [int]$v -le 3600 })
        Set-Answer 'StartDelay' $delay
    }
    $vmPlan = @(Get-LiteVmPlan -Delay $delay)
    $vmApply = @()
    if (-not $vmPlan) { Write-Host '  Every VM already matches (or there are no VMs).' -ForegroundColor Green }
    else {
        Show-LiteVmPlan $vmPlan
        $vmApply = @($vmPlan | Where-Object Apply)
        if ($vmApply -and -not (Confirm-Action "Apply the $($vmApply.Count) VM setting change(s)")) { $vmApply = @(); $declined.Add('VM start/stop') }
    }

    if (-not $chosen.Count -and -not $vmApply) {
        Write-Host "`n  Nothing chosen - no changes made." -ForegroundColor Yellow
        Invoke-LiteReport -Stage 'Apply' -Plan $plan -VmPlan $vmPlan
        return
    }

    Write-Step 'Applying'
    $failed = 0
    foreach ($i in @($chosen | Where-Object RiskGroup -ne 'Vmq' | Sort-Object Area, Id)) {
        try { Invoke-LiteItem $i; Write-Host "  OK   $($i.Desc)" -ForegroundColor Green }
        catch { $failed++; Write-Host "  FAIL $($i.Desc) - $($_.Exception.Message)" -ForegroundColor Red }
    }
    foreach ($r in $vmApply) {
        try { Invoke-LiteVmItem $r; Write-Host "  OK   $($r.VM): $($r.Setting) = $($r.Desired)" -ForegroundColor Green }
        catch { $failed++; Write-Host "  FAIL $($r.VM): $($r.Setting) - $($_.Exception.Message)" -ForegroundColor Red }
    }
    foreach ($i in @($chosen | Where-Object RiskGroup -eq 'Vmq')) {
        Write-Host '  VMQ: the switch adapters restart now - networking drops for a few seconds.' -ForegroundColor Yellow
        try { Invoke-LiteItem $i; Write-Host "  OK   $($i.Desc)" -ForegroundColor Green }
        catch { $failed++; Write-Host "  FAIL $($i.Desc) - $($_.Exception.Message)" -ForegroundColor Red }
    }

    $script:WorkloadProfileRead = $false
    $planAfter = @(Get-LitePlan)
    $ids = @($chosen | ForEach-Object Id)
    $still = @($planAfter | Where-Object { $_.Id -in $ids -and (-not $_.Restart -or $_.Kind -eq 'Registry') })
    if ($still) {
        Write-Host "`n  Still different after applying (a domain GPO may be setting these - GPO wins; fix it there):" -ForegroundColor Yellow
        Show-LitePlan $still
    }
    if ($failed) { Write-Warning "$failed change(s) failed - see above. The report lists anything still different." }
    if ($declined.Count) { Write-Host "  Left as they were (declined): $($declined -join '; ')" -ForegroundColor Yellow }

    $reboot = [bool]@($chosen | Where-Object Restart).Count
    Save-LiteRun $reboot
    Invoke-LiteReport -Stage 'Apply' -Plan $planAfter -VmPlan @(Get-LiteVmPlan -Delay $delay)
    if (@($script:Results | Where-Object { $_.Check -eq 'Pending reboot' })) { Write-Host "`nREBOOT NEEDED for some changes to take effect. Plan it in a maintenance window - this script does not reboot." -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
# Report - live-host checks and the HTML
# ---------------------------------------------------------------------------

function Invoke-LiteReport {
    param([ValidateSet('Check', 'Apply')][string]$Stage, $Plan, $VmPlan)
    Write-Step 'Live-host checks'
    $cs   = Get-CimInstance Win32_ComputerSystem
    $os   = Get-CimInstance Win32_OperatingSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu  = @(Get-CimInstance Win32_Processor)
    $cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $vms  = @(Get-VM -ErrorAction SilentlyContinue)
    $sections = @()

    # The standard
    $Plan = @($Plan); $VmPlan = @($VmPlan)
    if ($Plan) { Add-Result WARN 'Security and optimisation standard' "$($Plan.Count) item(s) differ: $(($Plan | ForEach-Object Desc) -join '; ')" }
    else { Add-Result PASS 'Security and optimisation standard' 'Matches' }
    $planRows = @($Plan | Sort-Object @{ e = { if ($_.RiskGroup) { 2 } elseif ($_.Restart) { 1 } else { 0 } } }, Area, Id | Select-Object Area, Desc, Current, Desired, When)
    $sections += @{ Title = $(if ($Stage -eq 'Check') { 'What Apply would change' } else { 'Still different from the standard' }); Html = (New-ArcTable $planRows @('Area', 'Desc', 'Current', 'Desired', 'When')) }

    # Hardware
    $wp = Get-ArcWorkloadProfile
    $hw = [ordered]@{
        'Model'                 = "$($cs.Manufacturer) $($cs.Model)"
        'Serial number'         = $bios.SerialNumber
        'Processors'            = "$($cpu.Count) x $(($cpu[0].Name -replace '\s+', ' ').Trim()) ($($cpu[0].NumberOfCores) cores each)"
        'Memory'                = "$([math]::Round($cs.TotalPhysicalMemory / 1GB)) GB"
        'System ROM'            = "$($bios.SMBIOSBIOSVersion) $($bios.ReleaseDate.ToString('yyyy-MM-dd'))"
        'BIOS workload profile' = $(if ($wp) { $wp } else { 'Not read (no ilorest or iLO session)' })
    }
    $sections += @{ Title = 'Hardware'; Html = (New-ArcKvTable $hw) }
    if ($cs.Manufacturer -match 'HPE|Hewlett') { Add-Result PASS 'HPE hardware' "$($cs.Model), serial $($bios.SerialNumber)" } else { Add-Result WARN 'HPE hardware' "$($cs.Manufacturer) $($cs.Model)" }
    if (-not $wp) { Add-Result INFO 'BIOS workload profile' 'Not read - no ilorest or iLO session. The standard is Virtualization-MaxPerformance (RBSU > Workload Profile).' }
    elseif ($wp -eq $Standard.WorkloadProfile) { Add-Result PASS 'BIOS workload profile' $wp }
    else { Add-Result WARN 'BIOS workload profile' "$wp - the standard is $($Standard.WorkloadProfile)" }
    try { if (Confirm-SecureBootUEFI) { Add-Result PASS 'Secure Boot' 'On' } else { Add-Result WARN 'Secure Boot' 'Off' } } catch { Add-Result WARN 'Secure Boot' 'Not supported or not UEFI' }
    try { $tpm = Get-Tpm; if ($tpm.TpmReady) { Add-Result PASS 'TPM' 'Ready' } else { Add-Result WARN 'TPM' 'Not ready' } } catch { Add-Result WARN 'TPM' 'Could not query' }

    # Operating system
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction SilentlyContinue | Select-Object -First 1
    $activated = $lic -and $lic.LicenseStatus -eq 1
    $lastHf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $osRows = [ordered]@{
        'Operating system'      = $os.Caption
        'Build'                 = "$($os.BuildNumber).$($cv.UBR)"
        'Activation'            = $(if ($activated) { 'Activated' } else { 'Not activated' })
        'Membership'            = $(if ($cs.PartOfDomain) { "Domain: $($cs.Domain)" } else { "Workgroup: $($cs.Workgroup)" })
        'Time source'           = Get-ArcTimeSource
        'Last update installed' = $(if ($lastHf) { "$($lastHf.HotFixID) on $($lastHf.InstalledOn.ToString('yyyy-MM-dd'))" } else { 'Unknown' })
        'Last boot'             = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
    }
    $sections += @{ Title = 'Operating system'; Html = (New-ArcKvTable $osRows) }
    if ($activated) { Add-Result PASS 'Windows activation' 'Activated' } else { Add-Result WARN 'Windows activation' 'Not activated' }
    if ($os.Caption -match 'Standard') {
        if ($vms.Count -gt 2) { Add-Result WARN 'Licensing' "Standard edition with $($vms.Count) VMs - Standard covers 2 Windows Server guests per fully licensed host (stack licences or use Datacenter). Count excludes non-Windows guests." }
        else { Add-Result PASS 'Licensing' "Standard edition, $($vms.Count) VM(s)" }
    } else { Add-Result PASS 'Licensing' "$($os.Caption)" }
    $ts = $osRows['Time source']
    if ($ts -match 'Local CMOS|Free-running|VM IC') { Add-Result WARN 'Time source' $ts } else { Add-Result PASS 'Time source' $ts }
    if (-not $lastHf) { Add-Result WARN 'Windows updates' 'Could not read the last installed update' }
    elseif ($lastHf.InstalledOn -lt (Get-Date).AddDays(-45)) { Add-Result WARN 'Windows updates' "Last update installed $($lastHf.InstalledOn.ToString('yyyy-MM-dd')) - more than 45 days ago" }
    else { Add-Result PASS 'Windows updates' "Last update installed $($lastHf.InstalledOn.ToString('yyyy-MM-dd'))" }
    # Registry-only changes (inactivity lock, TLS ...) leave no Windows pending-reboot flag, so
    # also count a reboot these scripts asked for that hasn't happened since.
    $st = Get-State
    $asked = $st.RebootPending -and $st.PSObject.Properties['RebootRequestedAt'] -and $st.RebootRequestedAt -and ([datetime]$st.RebootRequestedAt -gt $os.LastBootUpTime)
    if (Test-PendingReboot) { Add-Result WARN 'Pending reboot' 'Reboot (in a maintenance window) to finish installing changes' }
    elseif ($asked) { Add-Result WARN 'Pending reboot' "Changes made $($st.RebootRequestedAt) take effect at the next reboot - plan one in a maintenance window" }
    else { Add-Result PASS 'No pending reboot' }

    # Network
    $netRows = [ordered]@{}
    $ext = @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue)
    if (-not $ext) { Add-Result WARN 'Host network' 'No external virtual switch'; $netRows['Switch'] = 'None' }
    foreach ($sw in $ext) {
        if ($sw.EmbeddedTeamingEnabled) {
            $team = Get-VMSwitchTeam -Name $sw.Name -ErrorAction SilentlyContinue
            $netRows["Switch $($sw.Name)"] = "SET, $($team.LoadBalancingAlgorithm), bandwidth mode $($sw.BandwidthReservationMode)"
            Add-Result PASS 'Host network' "SET switch $($sw.Name)"
        } elseif ($sw.NetAdapterInterfaceDescription -match 'Multiplexor') {
            $netRows["Switch $($sw.Name)"] = "On an LBFO team ($($sw.NetAdapterInterfaceDescription))"
            Add-Result WARN 'Host network' "Switch $($sw.Name) is on an LBFO team - deprecated under a Hyper-V switch (new ones are blocked from WS2022). Moving to SET is an outage; plan it separately."
        } else {
            $netRows["Switch $($sw.Name)"] = "Single adapter ($($sw.NetAdapterInterfaceDescription))"
            Add-Result WARN 'Host network' "Switch $($sw.Name) is on a single adapter - no NIC redundancy"
        }
    }
    $members = @(Get-ArcSwitchMembers)
    if ($members) {
        $netRows['Switch members'] = (@($members | ForEach-Object { "$($_.Name) $($_.LinkSpeed) $($_.Status)" }) -join '; ')
        $down = @($members | Where-Object Status -ne 'Up')
        if ($down) { Add-Result WARN 'Switch member links' "Down: $($down.Name -join ', ')" } else { Add-Result PASS 'Switch member links' 'All up' }
    }
    foreach ($v in Get-VMNetworkAdapter -ManagementOS -ErrorAction SilentlyContinue) {
        $alias = "vEthernet ($($v.Name))"
        $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object PrefixOrigin -ne 'WellKnown' | Select-Object -First 1
        $netRows["Host vNIC $($v.Name)"] = $(if ($ip) { "$($ip.IPAddress)/$($ip.PrefixLength) ($($ip.PrefixOrigin))" } else { 'no IPv4' })
    }
    $sections += @{ Title = 'Network'; Html = (New-ArcKvTable $netRows) }

    # Storage
    $vh = Get-VMHost -ErrorAction SilentlyContinue
    $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter | ForEach-Object {
        [pscustomobject]@{ Volume = "$($_.DriveLetter):"; Label = $_.FileSystemLabel; FileSystem = $_.FileSystem; SizeGB = [math]::Round($_.Size / 1GB); FreeGB = [math]::Round($_.SizeRemaining / 1GB); Health = "$($_.HealthStatus)" }
    })
    $disks = @(Get-Disk | Sort-Object Number | ForEach-Object { [pscustomobject]@{ Disk = $_.Number; Name = $_.FriendlyName; Bus = "$($_.BusType)"; SizeGB = [math]::Round($_.Size / 1GB); Health = "$($_.HealthStatus)" } })
    $sections += @{ Title = 'Storage'; Html = (New-ArcKvTable ([ordered]@{ 'Default VM path' = $vh.VirtualMachinePath; 'Default VHD path' = $vh.VirtualHardDiskPath })) + (New-ArcTable $vols @('Volume', 'Label', 'FileSystem', 'SizeGB', 'FreeGB', 'Health')) + (New-ArcTable $disks @('Disk', 'Name', 'Bus', 'SizeGB', 'Health')) }
    if ($vh -and $vh.VirtualMachinePath -notlike "$env:SystemDrive*") { Add-Result PASS 'Default VM path' $vh.VirtualMachinePath } else { Add-Result WARN 'Default VM path' "On the system drive ($($vh.VirtualMachinePath)) - change it in Hyper-V Settings" }
    $bad = @($disks | Where-Object Health -ne 'Healthy')
    if ($bad) { Add-Result FAIL 'Disk health' "Not healthy: $(($bad | ForEach-Object { "disk $($_.Disk) $($_.Health)" }) -join ', ')" } else { Add-Result PASS 'Disk health' 'All healthy' }
    foreach ($v in $vols | Where-Object { $_.SizeGB -gt 0 -and ($_.FreeGB / $_.SizeGB) -lt 0.15 }) { Add-Result WARN "Free space $($v.Volume)" "$($v.FreeGB) GB of $($v.SizeGB) GB free" }

    # Protection (reported only - removing Defender for an EDR is the Site script's Edr phase)
    $edr = Get-ArcEdr
    $def = Get-ArcDefenderState
    if ($edr) { if ($edr.Running) { Add-Result PASS 'EDR' "$($edr.Product) running" } else { Add-Result FAIL 'EDR' "$($edr.Product) installed but not all services running" } }
    elseif ($def -eq 'Active') { Add-Result INFO 'EDR' 'None - Microsoft Defender is the antivirus' }
    if ($edr -and $def -eq 'Active') { Add-Result WARN 'Microsoft Defender' "Still active alongside $($edr.Product) - two real-time scanners on the VM disks. Run ArcHyperVHost-Site.ps1 -Phase Edr to remove it." }
    elseif (-not $edr -and $def -ne 'Active') { Add-Result FAIL 'Microsoft Defender' "$def, and no EDR found - the host has no active antivirus" }
    else { Add-Result PASS 'Microsoft Defender' $def }
    if ((Get-ItemProperty $DefenderPolicy -Name DisableAntiSpyware -ErrorAction SilentlyContinue).DisableAntiSpyware -eq 1) {
        Add-Result INFO 'Defender off-policy' "DisableAntiSpyware = 1 under $($DefenderPolicy -replace '^HKLM:', 'HKLM'). If the EDR is ever removed, delete the value and run Start-Service WinDefend (a reboot alone does not restart it)."
    }
    if (Get-Service CagService -ErrorAction SilentlyContinue) { Add-Result PASS 'Datto RMM agent' "$((Get-Service CagService).Status)" } else { Add-Result WARN 'Datto RMM agent' 'Not installed' }
    $builtin = Get-ArcBuiltinAdmin
    if ($builtin -and $builtin.Enabled) { Add-Result WARN 'Built-in Administrator' 'Enabled - the standard disables it (ArcHyperVHost-Site.ps1 -Phase Admin creates a named local admin first)' } else { Add-Result PASS 'Built-in Administrator' 'Disabled' }
    if (-not $cs.PartOfDomain) {
        $filter = (Get-ItemProperty $Sys -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
        if ($filter -eq 1) { Add-Result INFO 'Remote UAC (workgroup)' 'Off for local accounts - the local admin password must be unique to this host' }
        else { Add-Result WARN 'Remote UAC (workgroup)' 'On (or will be once UAC is on) - Veeam and remote Hyper-V Manager with a local account are refused. ArcHyperVHost-Site.ps1 -Phase Identity sets the Arc standard.' }
    }
    $secRows = [ordered]@{
        'EDR'                    = $(if ($edr) { $edr.Product } else { 'None' })
        'Microsoft Defender'     = $def
        'Datto RMM agent'        = $(if (Get-Service CagService -ErrorAction SilentlyContinue) { 'Installed' } else { 'Not installed' })
        'Built-in Administrator' = $(if ($builtin -and $builtin.Enabled) { 'Enabled' } else { 'Disabled' })
        'Firewall'               = (@(Get-NetFirewallProfile | ForEach-Object { "$($_.Name) $(if ($_.Enabled) { 'on' } else { 'off' })" }) -join ', ')
    }
    $sections += @{ Title = 'Security and protection'; Html = (New-ArcKvTable $secRows) }

    # Backup readiness and power protection
    $writers = @(Get-ArcVssWriters)
    $hvw = $writers | Where-Object Writer -like '*Hyper-V*' | Select-Object -First 1
    if (-not $hvw) { Add-Result WARN 'Hyper-V VSS writer' 'Not listed' }
    elseif ($hvw.State -eq 'Stable' -and $hvw.LastError -eq 'No error') { Add-Result PASS 'Hyper-V VSS writer' 'Stable, no error' }
    else { Add-Result WARN 'Hyper-V VSS writer' "$($hvw.State), $($hvw.LastError)" }
    $badW = @($writers | Where-Object { $_.LastError -ne 'No error' })
    if ($badW) { Add-Result WARN 'VSS writers' "With errors: $(($badW | ForEach-Object Writer) -join ', ')" }
    foreach ($g in 'File and Printer Sharing', 'Windows Management Instrumentation (WMI)') {
        $r = @(Get-NetFirewallRule -DisplayGroup $g -Direction Inbound -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' })
        if ($r) { Add-Result PASS "Firewall: $g" 'Inbound rules enabled (backup proxy access)' } else { Add-Result WARN "Firewall: $g" 'Inbound rules not enabled - Veeam needs them to deploy its components' }
    }
    # Hyper-V Replica listeners have their own rule groups (not in the baseline's set). Resource names: language independent.
    $rs = Get-VMReplicationServer -ErrorAction SilentlyContinue
    $repl = @(Get-VMReplication -ErrorAction SilentlyContinue)
    if ($rs.ReplicationEnabled) {
        $open = @('@%systemroot%\system32\vmms.exe,-251', '@%systemroot%\system32\vmms.exe,-253' | ForEach-Object { Get-NetFirewallRule -Group $_ -ErrorAction SilentlyContinue } | Where-Object Enabled -eq 'True')
        if ($open) { Add-Result PASS 'Hyper-V Replica' "Replica server, listener rules enabled ($(($open.DisplayName) -join ', '))" }
        else { Add-Result WARN 'Hyper-V Replica' 'This host is a Replica server, but the Hyper-V Replica HTTP/HTTPS listener firewall rules are off - inbound replication fails while the firewall is on' }
    } elseif ($repl) { Add-Result INFO 'Hyper-V Replica' "$($repl.Count) replicated VM(s): $(($repl | ForEach-Object { "$($_.VMName) ($($_.Mode), $($_.Health))" }) -join ', ')" }
    $veeam = @(Get-Service -ErrorAction SilentlyContinue | Where-Object DisplayName -like 'Veeam*')
    Add-Result INFO 'Veeam components' $(if ($veeam) { ($veeam.DisplayName -join ', ') } else { 'None found' })
    $ups = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'PowerChute|APC |Eaton|Intelligent Power|UPS|Network Shutdown|Vertiv|CyberPower' })
    if ($ups) { Add-Result PASS 'UPS shutdown agent' ($ups.DisplayName -join ', ') } else { Add-Result WARN 'UPS shutdown agent' 'None found - the host will not shut down cleanly on a power cut' }
    $sections += @{ Title = 'Backup readiness'; Html = (New-ArcTable $writers @('Writer', 'State', 'LastError')) }

    # Virtual machines: start/stop, checkpoints, leftover differencing disks, files on C:
    $cpRows = @()
    foreach ($vm in $vms) {
        $snaps = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
        foreach ($s in $snaps) { $cpRows += [pscustomobject]@{ VM = $vm.Name; Checkpoint = $s.Name; Type = "$($s.SnapshotType)"; Created = $s.CreationTime.ToString('yyyy-MM-dd HH:mm'); AgeDays = [int]((Get-Date) - $s.CreationTime).TotalDays } }
        $avhdx = @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*.avhdx' })
        if ($avhdx -and -not $snaps) { Add-Result WARN "Disk chain: $($vm.Name)" "Runs on differencing disk(s) with no checkpoint - a backup merge probably failed: $(($avhdx | ForEach-Object { Split-Path $_.Path -Leaf }) -join ', ')" }
    }
    $old = @($cpRows | Where-Object AgeDays -gt 7)
    if ($old) { Add-Result WARN 'Checkpoints' "$($old.Count) older than 7 days: $(($old | ForEach-Object { "$($_.VM) ($($_.Created))" }) -join ', ')" }
    elseif ($cpRows) { Add-Result INFO 'Checkpoints' "$($cpRows.Count), none older than 7 days" }
    else { Add-Result PASS 'Checkpoints' 'None' }
    $onSys = @($vms | Where-Object { $_.Path -like "$env:SystemDrive\*" -or @(Get-VMHardDiskDrive -VM $_ -ErrorAction SilentlyContinue | Where-Object Path -like "$env:SystemDrive\*") })
    if ($onSys) { Add-Result WARN 'VM files on the system drive' ($onSys.Name -join ', ') }
    $notShutdown = @($vms | Where-Object { "$($_.AutomaticStopAction)" -ne 'ShutDown' })
    if (-not $vms) { Add-Result INFO 'VMs' 'None on this host' }
    elseif ($notShutdown) { Add-Result WARN 'VM automatic stop' "Not Shut Down: $($notShutdown.Name -join ', ')" }
    else { Add-Result PASS 'VM automatic stop' 'Shut Down on every VM' }
    $vmRows = @($vms | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; State = "$($_.State)"; Generation = $_.Generation; Version = $_.Version; vCPU = $_.ProcessorCount; StartupGB = [math]::Round($_.MemoryStartup / 1GB, 1); Start = "$($_.AutomaticStartAction) +$($_.AutomaticStartDelay)s"; Stop = "$($_.AutomaticStopAction)" }
    })
    $sections += @{ Title = 'Virtual machines'; Html = (New-ArcTable $vmRows @('Name', 'State', 'Generation', 'Version', 'vCPU', 'StartupGB', 'Start', 'Stop')) + (New-ArcTable $cpRows @('VM', 'Checkpoint', 'Type', 'Created', 'AgeDays')) }
    if ($VmPlan) { $sections += @{ Title = $(if ($Stage -eq 'Check') { 'VM settings Apply would change' } else { 'VM settings still different' }); Html = (New-ArcTable $VmPlan @('VM', 'Setting', 'Current', 'Desired', 'Note')) } }

    # Run record (all three scripts share the state file)
    $phases = @((Get-State).Phases.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Phase = $_.Name; Script = $_.Value.Script; Completed = $_.Value.Completed; Version = $_.Value.Version } })
    $sections += @{ Title = 'Run record'; Html = (New-ArcTable $phases @('Phase', 'Script', 'Completed', 'Version')) }

    $name = $env:COMPUTERNAME
    $when = if ($Stage -eq 'Check') { 'Check (before changes)' } else { 'after Apply' }
    $sub = "Standalone Hyper-V host - lite standards report, $when. $(if ($cs.PartOfDomain) { $cs.Domain } else { "Workgroup $($cs.Workgroup)" }). $(Get-Date -Format 'd MMMM yyyy')."
    $html = New-ArcAsBuiltHtml -HostName $name -Subtitle $sub -Checks $script:Results -Sections $sections -Kind 'standards report'
    $path = Join-Path $LogRoot "Lite-$Stage-$name-$(Get-Date -Format 'yyyyMMdd-HHmm').html"
    [IO.File]::WriteAllText($path, $html, [Text.UTF8Encoding]::new($false))
    $fails = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $warns = @($script:Results | Where-Object Status -eq 'WARN').Count
    Write-Host "`nSummary: $fails FAIL, $warns WARN." -ForegroundColor $(if ($fails) { 'Red' } elseif ($warns) { 'Yellow' } else { 'Green' })
    $script:Results | Export-Csv -Path (Join-Path $LogRoot "Lite-$Stage-checks-$Stamp.csv") -NoTypeInformation
    Write-Host "  Report: $path" -ForegroundColor Green
    Write-Host '  Attach it to the change request, or to the host''s Configuration in ITGlue.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Assert-LiteHost
    switch ($Phase) {
        'Check' { Invoke-LiteCheck }
        'Apply' { Invoke-LiteApply }
    }
} catch {
    Write-Host "`nPHASE $Phase STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
