<#
================================================================
 BEFORE YOU RUN THIS SCRIPT
================================================================
 1. Log on with an account that is a local admin on every cluster node and
    has rights to change the cluster / add nodes.
 2. Open an elevated PowerShell prompt and DOWNLOAD-THEN-RUN (single line):

       $p="$env:SystemDrive\ArcLogs\HyperVClusterOnboard\ArcHyperVCluster.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-cluster/ArcHyperVCluster.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Capture -SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>

 3. Settings live in ONE cluster.json per cluster, on that deployment's share next
    to the SPP ISO and MSIs (installer paths in it are relative to its folder).
    Give -SettingsShare once; later phases on the host remember it and keep a
    local copy under C:\ArcLogs\HyperVClusterOnboard. The file holds hostnames,
    IPs, VLANs and the Datto site ID - customer data. Keep it on the share,
    restricted to engineers, and OUTSIDE this repo (public).

 EXISTING CLUSTER - define the standard and bring every node up to it:

       Capture          (on any node - writes the config from the live cluster)
       -> edit the config toward best practice
       Baseline         (on each node in turn: drains, applies, stops)
       -> reboot if it says so, then Resume
       ClusterBaseline  (once, from any node)

 NEW NODE - join it to the standard:

       PreFlight -> Hpe -> PreFlight -> Base -> Network -> Storage -> Agents
       -> Baseline -> Join -> HyperV -> Report

 EASIEST: just run -Phase Next (attended automation). It works out where this
 host is, runs phases back to back, STOPS at the human gates (add MACs/IPs,
 iLO console for Network, FC zoning, Sentinel connected, JOIN), ASKS before
 every reboot, and carries on by itself when you next log on. On an existing
 node it does Baseline, then Resume after the reboot.

    The Network phase MUST be run from the iLO remote console (not RDP) -
    building the SET vSwitch moves the management IP off the physical NIC and
    drops any remote session.
================================================================

.SYNOPSIS
    Defines, applies and checks a best-practice standard for HPE ProLiant Gen10 /
    Windows Server 2025 Datacenter Hyper-V failover clusters on 3PAR/Primera FC
    storage and plain (non-RDMA) Ethernet, and onboards new nodes to it.

.DESCRIPTION
    The CONFIG FILE is the standard. Capture writes it from a live node; you edit
    it; Baseline and ClusterBaseline apply it. Where a config value is null the
    script falls back to the PeerNode's value (and, with no peer, leaves the
    setting alone). PreFlight/Report diff a node against the peer to show drift.

    Phases (every phase is safe to re-run):
      Next             Attended automation - runs the right next phase(s) for this host,
                       stops at human gates, confirms reboots, resumes at next logon.
      Capture         Reads this node + the cluster (every node's NICs/IPs, vNIC roles,
                       MPIO, Hyper-V, BIOS profile) and writes <SettingsShare>\cluster.json.
      Baseline         Security defaults + Hyper-V host optimisations + BIOS profile + MPIO
                       + Hyper-V host settings from the config. Shows the change plan and
                       asks first. On a cluster member it health-checks the cluster and
                       DRAINS the node before changing anything, then stops - reboot if it
                       says so and run Resume. Never touches the vSwitch, vNICs or IPs.
      Resume           After a Baseline reboot: checks the node, resumes it into the cluster.
      ClusterBaseline  Cluster-wide: names/roles of cluster networks by subnet, live
                       migration network order, DrainOnShutdown; optional CSV cache and
                       cluster security level. Reports quorum witness and CAU.
      PreFlight        Read-only. Checks this host and diffs it against the peer. Lists NICs
                       and FC WWPNs.
      Hpe              SPP via SUM unattended from an ISO on the share; CHIF/AMS check;
                       ilorest from its MSI; boot volume report.
      Base             BIOS workload profile, then Hyper-V/Failover Clustering/MPIO.
      Network          SET vSwitch + host vNICs (new node only). Console only.
      Storage          WWPNs, MPIO claim/policy/timers, LUN visibility vs the peer.
      Agents           Datto RMM, SentinelOne, then Defender removal.
      Join             Test-Cluster (no storage tests), engineer JOIN gate, Add-ClusterNode.
      HyperV           Hyper-V host settings once the CSV paths exist (after Join).
      Report           Final peer diff + checks, exported to CSV.

.NOTES
    Version is independent of the gold-image scripts. Full run logged to
    C:\ArcLogs\HyperVClusterOnboard\ (transcript per phase, timestamped).
    Not a Datto component: it is interactive (confirmations, a SecureString
    token prompt) and needs domain/cluster rights, so an engineer runs it.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Next', 'Capture', 'Baseline', 'Resume', 'ClusterBaseline',
                 'PreFlight', 'Hpe', 'Base', 'Network', 'Storage', 'Agents', 'Join', 'HyperV', 'Report')]
    [string]$Phase,

    # The deployment's share/folder holding cluster.json next to the SPP ISO and MSIs.
    # Give it once; later phases on this host remember it (state.json).
    [string]$SettingsShare,

    # Alternative to -SettingsShare: an explicit config file (testing / one-offs).
    [string]$ConfigPath,

    # Capture only: write the config here instead of <SettingsShare>\cluster.json.
    [string]$OutPath,

    # Credential for WinRM to the peer/other nodes if the logged-on account isn't enough.
    # (The cluster cmdlets always run as the logged-on account.)
    [pscredential]$PeerCredential,

    # Network phase only: run even though this is not a console session. Only use
    # this if you have out-of-band access that survives losing the management IP.
    [switch]$AllowRemoteSession
)

# Version of this script, surfaced in the banner/transcript. Independent of the
# gold-image version; '-dev' suffix while work accumulates under [Unreleased].
$ScriptVersion = '0.3.0-dev'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$LogRoot   = "$env:SystemDrive\ArcLogs\HyperVClusterOnboard"
$StatePath = Join-Path $LogRoot 'state.json'
$Work      = Join-Path $env:TEMP 'HyperVClusterOnboard'
New-Item -ItemType Directory -Path $LogRoot, $Work -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $LogRoot "$Phase-$Stamp.log") | Out-Null

Write-Host "ArcHyperVCluster.ps1  v$ScriptVersion  -  phase: $Phase  -  $env:COMPUTERNAME" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

function Write-Step { param([string]$Text) Write-Host "`n== $Text ==" -ForegroundColor Cyan }

# Collected by checks in PreFlight/Report; summarised at the end of the phase.
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
    if ($ArgumentList) { $spArgs.ArgumentList = $ArgumentList }   # Start-Process rejects an empty -ArgumentList
    $proc = Start-Process @spArgs
    $elapsed = 0
    while (-not $proc.WaitForExit($HeartbeatSec * 1000)) {
        $elapsed += $HeartbeatSec
        Write-Host "  still running $Label... (${elapsed}s elapsed)"
    }
    return $proc.ExitCode
}

function Get-State {
    if (Test-Path $StatePath) { return (Get-Content $StatePath -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{ Phases = [pscustomobject]@{}; RebootPending = $false }
}

function Save-PhaseComplete {
    param([string]$Name, [bool]$RebootNeeded = $false)
    $state = Get-State
    $entry = [pscustomobject]@{ Completed = (Get-Date -Format 's'); Version = $ScriptVersion }
    $state.Phases | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
    $state | Add-Member -NotePropertyName RebootPending -NotePropertyValue $RebootNeeded -Force
    $state | Add-Member -NotePropertyName RebootRequestedAt -NotePropertyValue $(if ($RebootNeeded) { Get-Date -Format 's' } else { $null }) -Force
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
}

# Warn (not block) if an earlier phase hasn't been recorded - an engineer may
# have done that step by hand, so let them carry on after confirming.
function Assert-PriorPhase {
    param([string[]]$Required)
    $state = Get-State
    if ($state.RebootPending -and $state.RebootRequestedAt) {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($boot -lt [datetime]$state.RebootRequestedAt) {
            if (-not (Confirm-Action "The last phase asked for a reboot (at $($state.RebootRequestedAt)) and the host has not rebooted since. Continue anyway?")) { throw 'Stopped: reboot first.' }
        }
    }
    foreach ($r in $Required) {
        if (-not $state.Phases.PSObject.Properties[$r]) {
            if (-not (Confirm-Action "Phase '$r' has not been recorded as complete on this host. Continue anyway?")) { throw "Stopped: run -Phase $r first." }
        }
    }
}

function Test-PendingReboot {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return [bool]$pfro
}

function ConvertTo-MacKey { param([string]$Mac) return ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper() }

function Get-SubnetKey {
    param([string]$IPAddress, [int]$PrefixLength)
    $bytes = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
    [Array]::Reverse($bytes)
    $ip   = [BitConverter]::ToUInt32($bytes, 0)
    $mask = if ($PrefixLength -eq 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $PrefixLength)) }
    $net  = [BitConverter]::GetBytes([uint32]($ip -band $mask))
    [Array]::Reverse($net)
    return "{0}/{1}" -f ([System.Net.IPAddress]::new($net)).ToString(), $PrefixLength
}

# Pick a value: the config's if set, otherwise the peer's. Returns $null if neither.
function Resolve-Setting {
    param($ConfigValue, $PeerValue, [string]$Name)
    if ($null -ne $ConfigValue -and "$ConfigValue" -ne '') { Write-Host "  $Name = $ConfigValue (config)"; return $ConfigValue }
    if ($null -ne $PeerValue -and "$PeerValue" -ne '')     { Write-Host "  $Name = $PeerValue (peer)";   return $PeerValue }
    Write-Warning "$Name - no config value and none read from the peer; leaving as-is."
    return $null
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Called inside the main try so a bad config stops the transcript cleanly.
$SettingsFileName = 'cluster.json'
$SettingsCache    = Join-Path $LogRoot 'settings-last.json'
$RedactedToken    = '<stored on the deployment share - not copied locally>'

# A usable Sentinel site token: set, and not a placeholder or redaction marker.
function Test-ArcSiteToken { param($Token) return (-not [string]::IsNullOrWhiteSpace("$Token")) -and ("$Token" -notlike '<*') }

# Where the settings come from: -ConfigPath, else <SettingsShare>\cluster.json, else
# whatever this host used last time (remembered in state.json).
function Resolve-ArcSettingsPath {
    if ($ConfigPath)    { return $ConfigPath }
    if ($SettingsShare) { return (Join-Path $SettingsShare $SettingsFileName) }
    $s = Get-State
    if ($s.PSObject.Properties['SettingsPath'] -and $s.SettingsPath) {
        Write-Host "  Settings: $($s.SettingsPath) (remembered from an earlier phase)"
        return $s.SettingsPath
    }
    return $null
}

function Save-ArcSettingsPath {
    param([string]$Path)
    $s = Get-State
    $s | Add-Member -NotePropertyName SettingsPath -NotePropertyValue $Path -Force
    $s | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
}

# Installer paths in the config may be relative to the config file's folder
# (e.g. "SPP\<version>.iso"), so one share folder holds everything.
function Resolve-ArcRelativePath {
    param([string]$Path, [string]$Base)
    if (-not $Path -or $Path -like '*<*' -or [System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $Base $Path)
}

function Import-ArcConfig {
    $script:PeerParams = $null
    if ($Phase -eq 'Capture') { return }   # Capture creates the config
    $src = Resolve-ArcSettingsPath
    if (-not $src) { throw "No settings found. Pass -SettingsShare <folder holding $SettingsFileName> once (or -ConfigPath <file>); later phases on this host remember it." }

    $raw = $null
    $from = $src
    try { $raw = Get-Content $src -Raw -ErrorAction Stop }
    catch {
        # The share can be briefly unreachable (e.g. right after the Network phase
        # rebuilt the NICs). Offer the last local copy rather than stopping cold.
        if (-not (Test-Path $SettingsCache)) { throw "Cannot read settings from ${src}: $($_.Exception.Message)" }
        Write-Warning "Cannot read $src ($($_.Exception.Message))."
        Write-Host "  Last local copy: $SettingsCache (saved $((Get-Item $SettingsCache).LastWriteTime))"
        if (-not (Confirm-Action 'Use the last local copy of the settings')) { throw 'Stopped - settings unavailable.' }
        $raw = Get-Content $SettingsCache -Raw
        $from = "$SettingsCache (local copy of $src)"
    }
    $script:Config = $raw | ConvertFrom-Json
    Save-ArcSettingsPath $src
    # Local record of exactly what this run used, plus the fallback copy above. The
    # Sentinel site token stays on the share only - local copies get a redaction
    # marker, so a run from the local copy falls back to the prompt.
    $local = $raw | ConvertFrom-Json
    if ($local.Agents -and $local.Agents.Sentinel -and $local.Agents.Sentinel.PSObject.Properties['SiteToken'] -and (Test-ArcSiteToken $local.Agents.Sentinel.SiteToken)) {
        $local.Agents.Sentinel.SiteToken = $RedactedToken
    }
    $localJson = $local | ConvertTo-Json -Depth 10
    Set-Content -Path $SettingsCache -Value $localJson -Encoding UTF8
    Set-Content -Path (Join-Path $LogRoot "settings-used-$Phase-$Stamp.json") -Value $localJson -Encoding UTF8
    Write-Host "  Settings loaded from $from."

    $base = Split-Path $src -Parent
    foreach ($ref in @(@($Config.Hpe, 'SppIsoPath'), @($Config.Hpe, 'IloRestMsiPath'), @($Config.Agents.Sentinel, 'MsiPath'))) {
        $obj = $ref[0]; $prop = $ref[1]
        if ($obj -and $obj.PSObject.Properties[$prop]) { $obj.$prop = Resolve-ArcRelativePath $obj.$prop $base }
    }

    $script:NodeConfig = if ($Config.Nodes -and $Config.Nodes.PSObject.Properties[$env:COMPUTERNAME]) { $Config.Nodes.PSObject.Properties[$env:COMPUTERNAME].Value } else { $null }
    if (-not $NodeConfig -and $Phase -in 'Network', 'Storage', 'Agents', 'Join', 'HyperV') {
        throw "No entry for '$env:COMPUTERNAME' under Nodes in $src - add this host (MACs from -Phase PreFlight, IPs) to the file."
    }
    if (-not $Config.ClusterName -or $Config.ClusterName -like '<*>') { throw "Config value 'ClusterName' is missing or still a placeholder." }

    # PeerNode: required for the new-node diff phases, optional elsewhere (no peer =
    # null config values leave the setting alone). A node is never its own peer.
    $peerSet = $Config.PeerNode -and $Config.PeerNode -notlike '<*>' -and ($Config.PeerNode -split '\.')[0] -ne $env:COMPUTERNAME
    if ($peerSet) {
        $script:PeerParams = @{ ComputerName = $Config.PeerNode }
        if ($PeerCredential) { $PeerParams.Credential = $PeerCredential }
    } elseif ($Phase -in 'PreFlight', 'Network', 'Storage', 'HyperV', 'Report') {
        throw "Config value 'PeerNode' must name another existing cluster node for -Phase $Phase."
    }
}

# ---------------------------------------------------------------------------
# Baseline catalogue - the registry-backed security defaults and optimisations.
# ONE list, used by the fingerprint (to read current values, locally and on the
# peer) and by Baseline (to apply). Mirrors the gold-image CE+/ISO 27001 block
# item for item, minus image-only items (BitLocker, appx, sysprep, WU cache).
# Group = the config switch that turns the item on (Security.* / Optimisation.*).
# Restart = the change only fully takes effect after a reboot.
# Value $null = supplied from config at plan time (see Get-BaselinePlan).
# ---------------------------------------------------------------------------

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
    @{ Id = 'Sec.InactivityTimeoutSecs';   Group = 'Security';      Restart = $true;  Desc = 'Machine inactivity lock (seconds)';      Path = $Sys; Name = 'InactivityTimeoutSecs'; Value = $null }
    @{ Id = 'Sec.RDP.Allow';               Group = 'Security';      Restart = $false; Desc = 'Remote Desktop allowed (admin access)';  Path = $Rdp; Name = 'fDenyTSConnections'; Value = 0 }
    @{ Id = 'Sec.RDP.NLA';                 Group = 'Security';      Restart = $false; Desc = 'RDP requires NLA';                       Path = "$Rdp\WinStations\RDP-Tcp"; Name = 'UserAuthentication'; Value = 1 }
    @{ Id = 'Sec.RDP.TLS';                 Group = 'Security';      Restart = $false; Desc = 'RDP TLS security layer';                 Path = "$Rdp\WinStations\RDP-Tcp"; Name = 'SecurityLayer'; Value = 2 }
    @{ Id = 'Sec.RDP.Encryption';          Group = 'Security';      Restart = $false; Desc = 'RDP high encryption';                    Path = "$Rdp\WinStations\RDP-Tcp"; Name = 'MinEncryptionLevel'; Value = 3 }
    @{ Id = 'Opt.8dot3';                   Group = 'Optimisation';  Restart = $true;  Desc = 'NTFS 8.3 short-name creation off';       Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'NtfsDisable8dot3NameCreation'; Value = 1 }
    @{ Id = 'Opt.ServerManagerAtLogon';    Group = 'Optimisation';  Restart = $false; Desc = 'Server Manager not opened at logon';     Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager'; Name = 'DoNotOpenAtLogon'; Value = 1 }
)
# SSL 3.0 / TLS 1.0 / TLS 1.1 off, server and client (Security.DisableLegacyTls)
foreach ($proto in 'SSL 3.0', 'TLS 1.0', 'TLS 1.1') {
    foreach ($role in 'Server', 'Client') {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\$role"
        $RegCatalogue += @{ Id = "Sec.Tls.$proto.$role.Enabled"; Group = 'Security.DisableLegacyTls'; Restart = $true; Desc = "$proto ($role) disabled"; Path = $k; Name = 'Enabled'; Value = 0 }
        $RegCatalogue += @{ Id = "Sec.Tls.$proto.$role.DisabledByDefault"; Group = 'Security.DisableLegacyTls'; Restart = $true; Desc = "$proto ($role) off by default"; Path = $k; Name = 'DisabledByDefault'; Value = 1 }
    }
}

# Telemetry / CEIP / Maps / error-report tasks - pure overhead on a Hyper-V host.
# NOT the scheduled defrag task: on thin-provisioned 3PAR/Primera volumes it also
# does the retrim (UNMAP) that hands freed space back to the array.
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

# ---------------------------------------------------------------------------
# Fingerprint - runs locally AND on the peer via Invoke-Command, so it must be
# self-contained (no calls to functions defined above). Every section is
# best-effort: a fresh host won't have Hyper-V/MPIO/clustering yet.
# Returns Compare (string values diffed against the peer) and Detail
# (host-specific data: NICs, WWPNs, disks, IPs).
# ---------------------------------------------------------------------------

$FingerprintBlock = {
    param($RegItems, $TaskList)
    $ErrorActionPreference = 'Stop'
    $c = @{}
    $d = @{}

    # Registry-backed baseline items (catalogue passed in by the caller)
    foreach ($r in @($RegItems)) {
        try {
            $v = (Get-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction Stop).($r.Name)
            $c[$r.Id] = "$v"
        } catch { $c[$r.Id] = '(not set)' }
    }

    # Security items that aren't plain registry values
    try {
        $smb = Get-SmbServerConfiguration
        $c['Sec.SMB1Protocol']     = "$($smb.EnableSMB1Protocol)"
        $c['Sec.SmbServerSigning'] = "$($smb.RequireSecuritySignature)"
        $c['Sec.SmbClientSigning'] = "$((Get-SmbClientConfiguration).RequireSecuritySignature)"
    } catch { }
    try {
        foreach ($f in Get-WindowsFeature -Name FS-SMB1, PowerShell-V2 -ErrorAction SilentlyContinue) {
            $c["Sec.Feature.$($f.Name)"] = if ($f.Installed) { 'Installed' } else { 'Not installed' }
        }
    } catch { }
    try { foreach ($p in Get-NetFirewallProfile) { $c["Sec.Firewall.$($p.Name)"] = "$($p.Enabled)" } } catch { }
    try {
        $na = (net accounts) | Out-String
        if ($na -match 'Lockout threshold:\s+(\S+)') { $c['Sec.LockoutThreshold'] = if ($Matches[1] -eq 'Never') { '0' } else { $Matches[1] } }
    } catch { }
    try { $c['Sec.GuestEnabled'] = "$((Get-LocalUser -Name Guest -ErrorAction Stop).Enabled)" } catch { }
    try { $c['Sec.Spooler'] = "$((Get-Service Spooler -ErrorAction Stop).StartType)" } catch { $c['Sec.Spooler'] = 'Absent' }
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        $c['Sec.VBS.Status']              = "$($dg.VirtualizationBasedSecurityStatus)"   # 0 off, 1 configured, 2 running
        $c['Sec.CredentialGuard.Running'] = "$(@($dg.SecurityServicesRunning) -contains 1)"
        $c['Sec.HVCI.Running']            = "$(@($dg.SecurityServicesRunning) -contains 2)"
    } catch { }

    # Optimisation items that aren't plain registry values
    try { $c['Opt.Hibernate'] = "$((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled)" } catch { $c['Opt.Hibernate'] = '(not set)' }
    try {
        $la = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name NtfsDisableLastAccessUpdate -ErrorAction Stop).NtfsDisableLastAccessUpdate
        $c['Opt.LastAccess'] = if (([int64]$la -band 1) -eq 1) { 'Disabled' } else { 'Enabled' }
    } catch { $c['Opt.LastAccess'] = '(not set)' }
    try {
        $on = 0
        foreach ($t in @($TaskList)) {
            $task = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
            if ($task -and $task.State -ne 'Disabled') { $on++ }
        }
        $c['Opt.TelemetryTasks'] = if ($on) { "$on enabled" } else { 'All disabled' }
    } catch { }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $c['OS.Caption'] = $os.Caption
        $c['OS.Build']   = "$($os.BuildNumber).$($cv.UBR)"
    } catch { $c['OS.Error'] = $_.Exception.Message }

    try {
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = @(Get-CimInstance Win32_Processor)
        $c['Hardware.Model']          = "$($cs.Manufacturer) $($cs.Model)"
        $c['Hardware.CPU']            = ($cpu[0].Name -replace '\s+', ' ').Trim()
        $c['Hardware.CPUVendor']      = $cpu[0].Manufacturer
        $c['Hardware.Sockets']        = "$($cpu.Count)"
        $c['Hardware.CoresPerSocket'] = "$($cpu[0].NumberOfCores)"
        $c['Hardware.RAMGB']          = "$([math]::Round($cs.TotalPhysicalMemory / 1GB))"
        $d['PartOfDomain'] = $cs.PartOfDomain
        $d['Domain']       = $cs.Domain
        $d['HypervisorPresent'] = $cs.HypervisorPresent
        $d['VirtualizationFirmwareEnabled'] = $cpu[0].VirtualizationFirmwareEnabled
        $bios = Get-CimInstance Win32_BIOS
        $c['Firmware.SystemROM'] = "$($bios.SMBIOSBIOSVersion) $($bios.ReleaseDate.ToString('yyyy-MM-dd'))"
    } catch { $c['Hardware.Error'] = $_.Exception.Message }

    try {
        $drivers = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in 'NET', 'SCSIADAPTER' -and $_.DeviceName -and $_.DriverProviderName -ne 'Microsoft' }
        foreach ($g in ($drivers | Group-Object { $_.DeviceName -replace '\s#\d+$', '' })) {
            $c["Driver.$($g.Name)"] = (($g.Group.DriverVersion | Sort-Object -Unique) -join ', ')
        }
    } catch { $c['Driver.Error'] = $_.Exception.Message }

    try {
        foreach ($f in Get-WindowsFeature -Name Hyper-V, Failover-Clustering, Multipath-IO, Windows-Defender, RSAT-Clustering-PowerShell, Hyper-V-PowerShell) {
            $c["Feature.$($f.Name)"] = if ($f.Installed) { 'Installed' } else { 'Not installed' }
        }
    } catch { $c['Feature.Error'] = $_.Exception.Message }

    try {
        foreach ($hf in Get-HotFix) { $c["Hotfix.$($hf.HotFixID)"] = 'Installed' }
    } catch { }

    try {
        $pc = (powercfg /getactivescheme) | Out-String
        if ($pc -match 'GUID:\s*([0-9a-fA-F-]+)\s+\(([^)]+)\)') { $c['Power.ActivePlan'] = "$($Matches[2]) ($($Matches[1]))" }
    } catch { }

    try {
        $c['Service.HPE-AMS'] = if (Get-Service | Where-Object { $_.DisplayName -like '*Agentless Management*' }) { 'Present' } else { 'Absent' }
        $c['Service.SentinelAgent'] = if (Get-Service SentinelAgent -ErrorAction SilentlyContinue) { 'Present' } else { 'Absent' }
        $c['Service.DattoCagService'] = if (Get-Service CagService -ErrorAction SilentlyContinue) { 'Present' } else { 'Absent' }
    } catch { }

    # MPIO
    try {
        foreach ($hw in Get-MSDSMSupportedHW) { $c["MPIO.SupportedHW.$($hw.VendorId.Trim())|$($hw.ProductId.Trim())"] = 'Claimed' }
        $c['MPIO.GlobalLBPolicy'] = "$(Get-MSDSMGlobalDefaultLoadBalancePolicy)"
        $ms = Get-MPIOSetting
        foreach ($p in 'PathVerificationState', 'PathVerificationPeriod', 'PDORemovePeriod', 'RetryCount', 'RetryInterval', 'UseCustomPathRecoveryTime', 'CustomPathRecoveryTime', 'DiskTimeoutValue') {
            $c["MPIO.$p"] = "$($ms.$p)"
        }
    } catch { }

    # Hyper-V host settings
    try {
        $vh = Get-VMHost
        $c['HyperV.NumaSpanningEnabled']              = "$($vh.NumaSpanningEnabled)"
        $c['HyperV.MaximumVirtualMachineMigrations']  = "$($vh.MaximumVirtualMachineMigrations)"
        $c['HyperV.MaximumStorageMigrations']         = "$($vh.MaximumStorageMigrations)"
        $c['HyperV.MigrationPerformanceOption']       = "$($vh.VirtualMachineMigrationPerformanceOption)"
        $c['HyperV.VirtualMachineMigrationEnabled']   = "$($vh.VirtualMachineMigrationEnabled)"
        $c['HyperV.VirtualMachinePath']               = $vh.VirtualMachinePath
        $c['HyperV.VirtualHardDiskPath']              = $vh.VirtualHardDiskPath
    } catch { }

    # vSwitch + host vNICs
    try {
        $vnics = @()
        foreach ($sw in Get-VMSwitch -SwitchType External) {
            $c["Switch.$($sw.Name).EmbeddedTeaming"]   = "$($sw.EmbeddedTeamingEnabled)"
            $c["Switch.$($sw.Name).BandwidthMode"]     = "$($sw.BandwidthReservationMode)"
            $c["Switch.$($sw.Name).DefaultFlowWeight"] = "$($sw.DefaultFlowMinimumBandwidthWeight)"
            try {
                $team = Get-VMSwitchTeam -Name $sw.Name
                $c["Switch.$($sw.Name).LBAlgorithm"] = "$($team.LoadBalancingAlgorithm)"
                $c["Switch.$($sw.Name).MemberCount"] = "$(@($team.NetAdapterInterfaceDescription).Count)"
                $members = @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -in @($team.NetAdapterInterfaceDescription) })
                $d['SwitchName'] = $sw.Name
                $d['SwitchMemberMacs'] = @($members.MacAddress)
                try {
                    $jp = Get-NetAdapterAdvancedProperty -Name $members[0].Name -RegistryKeyword '*JumboPacket' -ErrorAction Stop
                    $d['SwitchJumboPacket'] = [int]$jp.RegistryValue[0]
                } catch { }
                $pmOn = @($members | Where-Object { (Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue).AllowComputerToTurnOffDevice -eq 'Enabled' })
                $c['Opt.NicPowerManagement'] = if ($pmOn) { "Enabled on $($pmOn.Name -join ', ')" } else { 'Disabled' }
                $vmqOff = @($members | Where-Object { -not (Get-NetAdapterVmq -Name $_.Name -ErrorAction SilentlyContinue).Enabled })
                $c['Opt.VMQ'] = if ($vmqOff) { "Disabled on $($vmqOff.Name -join ', ')" } else { 'Enabled' }
            } catch { }
        }
        foreach ($v in Get-VMNetworkAdapter -ManagementOS) {
            $vlan = Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $v.Name
            $c["VNic.$($v.Name).Vlan"]   = if ($vlan.OperationMode -eq 'Access') { "$($vlan.AccessVlanId)" } else { "$($vlan.OperationMode)" }
            $c["VNic.$($v.Name).Weight"] = "$($v.BandwidthSetting.MinimumBandwidthWeight)"
            $alias = "vEthernet ($($v.Name))"
            $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
            if ($ip) {
                $bytes = $ip.IPAddress.Split('.') | ForEach-Object { [int]$_ }
                $mask  = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $ip.PrefixLength))
                $ipInt = [uint32](($bytes[0] * 16777216) + ($bytes[1] * 65536) + ($bytes[2] * 256) + $bytes[3])
                $n = $ipInt -band $mask
                $c["VNic.$($v.Name).Subnet"] = "{0}.{1}.{2}.{3}/{4}" -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255), $ip.PrefixLength
                $gw  = (Get-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
                $srv = @((Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
                $jmb = $null
                try { $jmb = [int](Get-NetAdapterAdvancedProperty -Name $alias -RegistryKeyword '*JumboPacket' -ErrorAction Stop).RegistryValue[0] } catch { }
                $vlanId = if ($vlan.OperationMode -eq 'Access') { [int]$vlan.AccessVlanId } else { 0 }
                $vnics += [pscustomobject]@{
                    Name = $v.Name; IPAddress = $ip.IPAddress; PrefixLength = $ip.PrefixLength; VlanId = $vlanId
                    Weight = $v.BandwidthSetting.MinimumBandwidthWeight; Gateway = $gw; DnsServers = $srv; JumboPacket = $jmb
                    RegisterInDns = [bool](Get-DnsClient -InterfaceAlias $alias -ErrorAction SilentlyContinue).RegisterThisConnectionsAddress
                }
            }
            $dns = Get-DnsClient -InterfaceAlias $alias -ErrorAction SilentlyContinue
            if ($dns) { $c["VNic.$($v.Name).RegisterInDns"] = "$($dns.RegisterThisConnectionsAddress)" }
        }
        $d['HostVNics'] = $vnics
    } catch { }

    # Physical NICs, FC ports, disks - host-specific, reported not diffed
    try {
        $hw = @{}
        foreach ($h in Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue) { $hw[$h.Name] = $h }
        $d['Adapters'] = @(Get-NetAdapter -Physical | Sort-Object Name | ForEach-Object {
            $h = $hw[$_.Name]
            [pscustomobject]@{
                Name = $_.Name; Description = $_.InterfaceDescription; MacAddress = $_.MacAddress
                LinkSpeed = $_.LinkSpeed; Status = "$($_.Status)"
                PciLocation = if ($h) { "Slot $($h.SlotNumber) Bus $($h.BusNumber) Dev $($h.DeviceNumber) Fn $($h.FunctionNumber)" } else { '' }
            }
        })
    } catch { }
    try {
        $d['FcPorts'] = @(Get-InitiatorPort -ErrorAction Stop | Where-Object { $_.ConnectionType -eq 'Fibre Channel' } | ForEach-Object {
            [pscustomobject]@{ NodeAddress = $_.NodeAddress; PortAddress = $_.PortAddress; Description = $_.InstanceName }
        })
    } catch { }
    try {
        $d['Disks'] = @(Get-Disk | Where-Object { $_.BusType -ne 'RAID' -and -not $_.IsBoot } | ForEach-Object {
            [pscustomobject]@{ Number = $_.Number; UniqueId = $_.UniqueId; SizeGB = [math]::Round($_.Size / 1GB); IsClustered = $_.IsClustered; BusType = "$($_.BusType)"; FriendlyName = $_.FriendlyName }
        })
    } catch { }

    # HPE BIOS / iLO via the RESTful Interface Tool (in-band). Optional.
    # Native stderr under 'Stop' becomes a terminating error in 5.1 - relax it for ilorest.
    $ErrorActionPreference = 'Continue'
    try {
        $ilo = (Get-Command ilorest.exe -ErrorAction SilentlyContinue).Source
        if (-not $ilo) { $ilo = Get-ChildItem "$env:ProgramFiles\Hewlett Packard Enterprise\RESTful Interface Tool\ilorest.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
        if ($ilo) {
            & $ilo login 2>&1 | Out-Null
            $raw = & $ilo get WorkloadProfile PowerRegulator ProcVirtualization IntelProcVtd Sriov SubNumaClustering MinProcIdlePower EnergyPerfBias --selector=Bios. --json 2>&1 | ForEach-Object { "$_" } | Out-String
            $s = $raw.IndexOf('{'); $e = $raw.LastIndexOf('}')
            if ($s -ge 0 -and $e -gt $s) {
                $bios = $raw.Substring($s, $e - $s + 1) | ConvertFrom-Json
                foreach ($p in $bios.PSObject.Properties) { $c["HPE.Bios.$($p.Name)"] = "$($p.Value)" }
            } else { $c['HPE.Bios'] = 'ilorest returned no data (in-band login refused?)' }
            $raw = & $ilo get FirmwareVersion --selector=Manager. --json 2>&1 | ForEach-Object { "$_" } | Out-String
            $s = $raw.IndexOf('{'); $e = $raw.LastIndexOf('}')
            if ($s -ge 0 -and $e -gt $s) { $c['HPE.iLOFirmware'] = "$(($raw.Substring($s, $e - $s + 1) | ConvertFrom-Json).FirmwareVersion)" }
            & $ilo logout 2>&1 | Out-Null
        } else { $c['HPE.ilorest'] = 'Not installed' }
    } catch { $c['HPE.Error'] = $_.Exception.Message }

    @{ ComputerName = $env:COMPUTERNAME; Compare = $c; Detail = $d }
}

function Get-LocalFingerprint { & $FingerprintBlock $RegCatalogue $OptTasks }

# Fingerprint any node over WinRM (the peer, or every node during Capture).
function Get-RemoteFingerprint {
    param([Parameter(Mandatory)][string]$ComputerName)
    $p = @{ ComputerName = $ComputerName }
    if ($PeerCredential) { $p.Credential = $PeerCredential }
    try { return Invoke-Command @p -ScriptBlock $FingerprintBlock -ArgumentList $RegCatalogue, $OptTasks }
    catch { throw "Could not read $ComputerName over WinRM: $($_.Exception.Message)" }
}

function Get-PeerFingerprint {
    if (-not $PeerParams) { throw 'No PeerNode configured.' }
    Write-Host "  Reading fingerprint from peer $($Config.PeerNode)..."
    return Get-RemoteFingerprint -ComputerName $Config.PeerNode
}

# Diff two fingerprints' Compare sections. A key present on only one side
# shows as '(absent)' there.
function Compare-Fingerprint {
    param($Peer, $Local)
    $keys = @($Peer.Compare.Keys) + @($Local.Compare.Keys) | Sort-Object -Unique
    foreach ($k in $keys) {
        $p = if ($Peer.Compare.ContainsKey($k))  { "$($Peer.Compare[$k])" }  else { '(absent)' }
        $l = if ($Local.Compare.ContainsKey($k)) { "$($Local.Compare[$k])" } else { '(absent)' }
        [pscustomobject]@{ Setting = $k; Peer = $p; Local = $l; Match = ($p -eq $l) }
    }
}

function Export-Diff {
    param($Diff, [string]$Label)
    $path = Join-Path $LogRoot "$Label-diff-$Stamp.csv"
    $Diff | Export-Csv -Path $path -NoTypeInformation
    $mismatch = @($Diff | Where-Object { -not $_.Match })
    Write-Host "`n  $($mismatch.Count) of $(@($Diff).Count) compared settings differ from the peer. Full diff: $path"
    if ($mismatch.Count) { $mismatch | Format-Table Setting, Peer, Local -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
}

function Get-Peer {
    param($PeerFp, [string]$Key)
    if ($PeerFp.Compare.ContainsKey($Key)) { return $PeerFp.Compare[$Key] }
    return $null
}

# ---------------------------------------------------------------------------
# Phase: PreFlight (read-only)
# ---------------------------------------------------------------------------

function Invoke-PreFlight {
    Write-Step 'Local checks'
    $local = Get-LocalFingerprint

    if ($local.Compare['OS.Caption'] -like '*Server 2025 Datacenter*') { Add-Result PASS 'OS edition' $local.Compare['OS.Caption'] }
    else { Add-Result FAIL 'OS edition' "Expected Windows Server 2025 Datacenter, found '$($local.Compare['OS.Caption'])'" }

    if ($local.Detail.PartOfDomain) { Add-Result PASS 'Domain joined' $local.Detail.Domain } else { Add-Result FAIL 'Domain joined' 'Host is not domain joined' }

    if ($local.Detail.HypervisorPresent -or $local.Detail.VirtualizationFirmwareEnabled) { Add-Result PASS 'Virtualisation enabled in firmware' }
    else { Add-Result WARN 'Virtualisation enabled in firmware' 'VT-x is off - the Base phase sets the workload profile first and installs Hyper-V on its re-run after the reboot' }

    try { if (Confirm-SecureBootUEFI) { Add-Result PASS 'Secure Boot' } else { Add-Result WARN 'Secure Boot' 'Off' } } catch { Add-Result WARN 'Secure Boot' 'Not supported or not UEFI' }
    try { $tpm = Get-Tpm; if ($tpm.TpmReady) { Add-Result PASS 'TPM' 'Ready' } else { Add-Result WARN 'TPM' "Present=$($tpm.TpmPresent) Ready=$($tpm.TpmReady)" } } catch { Add-Result WARN 'TPM' 'Could not query' }

    if (Test-PendingReboot) { Add-Result WARN 'Pending reboot' 'A reboot is pending - reboot before continuing' } else { Add-Result PASS 'No pending reboot' }

    $ErrorActionPreference = 'Continue'   # native stderr must not throw (function scope only)
    $src = (w32tm /query /source 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
    $ErrorActionPreference = 'Stop'
    if ($src -match 'Local CMOS|Free-running') { Add-Result WARN 'Time source' $src } else { Add-Result PASS 'Time source' $src }

    $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    try {
        $fwd = Resolve-DnsName $fqdn -Type A -DnsOnly | Where-Object Type -eq 'A'
        Add-Result PASS 'DNS forward lookup' "$fqdn -> $(($fwd.IPAddress) -join ', ')"
        foreach ($a in $fwd.IPAddress) {
            try { $ptr = Resolve-DnsName $a -Type PTR -DnsOnly; Add-Result PASS 'DNS reverse lookup' "$a -> $($ptr.NameHost)" }
            catch { Add-Result WARN 'DNS reverse lookup' "No PTR for $a" }
        }
    } catch { Add-Result FAIL 'DNS forward lookup' "$fqdn does not resolve" }

    # The HPE tooling arrives in the Hpe phase, so on the first pre-flight its absence is
    # expected (INFO). Once Hpe has run, a missing component is a real problem (WARN).
    $hpeDone  = [bool](Get-State).Phases.PSObject.Properties['Hpe']
    $missSev  = if ($hpeDone) { 'WARN' } else { 'INFO' }
    $missNote = if ($hpeDone) { 'still missing after -Phase Hpe' } else { 'expected before -Phase Hpe, which installs it' }
    if ($local.Compare['HPE.ilorest'] -eq 'Not installed') { Add-Result $missSev 'HPE ilorest' "Not installed - $missNote (HPE BIOS values are left out of the peer comparison until then)" }
    elseif ($local.Compare.ContainsKey('HPE.Bios.WorkloadProfile')) { Add-Result PASS 'HPE ilorest in-band' "WorkloadProfile=$($local.Compare['HPE.Bios.WorkloadProfile'])" }
    elseif ($hpeDone) { Add-Result WARN 'HPE ilorest in-band' 'Could not read BIOS - check the iLO CHIF driver is installed and iLO "Require Host Authentication" is off' }
    else { Add-Result INFO 'HPE ilorest in-band' 'Could not read BIOS - usually the iLO CHIF driver, which the SPP installs in -Phase Hpe' }

    if ($local.Compare['Service.HPE-AMS'] -eq 'Present') { Add-Result PASS 'HPE Agentless Management Service' }
    else { Add-Result $missSev 'HPE Agentless Management Service' "Not installed - $missNote" }

    Write-Step 'Physical NICs (fill Nodes.<hostname>.AdapterMacs from this)'
    $local.Detail.Adapters | Format-Table Name, MacAddress, LinkSpeed, Status, PciLocation, Description -AutoSize | Out-String -Width 220 | Write-Host

    if ($NodeConfig) {
        $want = @($NodeConfig.AdapterMacs | ForEach-Object { ConvertTo-MacKey $_ })
        foreach ($m in $want) {
            $a = $local.Detail.Adapters | Where-Object { (ConvertTo-MacKey $_.MacAddress) -eq $m }
            if (-not $a) { Add-Result FAIL "Adapter $m" 'Not found on this host' ; continue }
            if ($a.Status -ne 'Up') { Add-Result FAIL "Adapter $m ($($a.Name))" "Link is $($a.Status)" }
            elseif ($a.LinkSpeed -notmatch '^10 Gbps$|^\d{2,} Gbps$') { Add-Result WARN "Adapter $m ($($a.Name))" "Link speed $($a.LinkSpeed) - expected 10 Gbps" }
            else { Add-Result PASS "Adapter $m ($($a.Name))" $a.LinkSpeed }
        }
    } else {
        Add-Result WARN 'Node config' "No Nodes entry for $env:COMPUTERNAME yet - add one using the NIC list above"
    }

    Write-Step 'FC initiator ports (WWPNs for zoning)'
    if ($local.Detail.FcPorts) { $local.Detail.FcPorts | Format-Table -AutoSize | Out-String | Write-Host }
    else { Add-Result $missSev 'FC ports' "No Fibre Channel initiator ports found - check the HBA driver ($missNote)" }

    Write-Step "Peer comparison ($($Config.PeerNode))"
    try { Test-WSMan -ComputerName $Config.PeerNode | Out-Null; Add-Result PASS 'Peer WinRM reachable' $Config.PeerNode }
    catch { Add-Result FAIL 'Peer WinRM reachable' $_.Exception.Message; return }
    $peer = Get-PeerFingerprint

    # Hard blockers / strong warnings pulled out of the diff
    if ($peer.Compare['Hardware.CPUVendor'] -ne $local.Compare['Hardware.CPUVendor']) { Add-Result FAIL 'CPU vendor matches peer' "$($local.Compare['Hardware.CPUVendor']) vs peer $($peer.Compare['Hardware.CPUVendor']) - live migration impossible" }
    elseif ($peer.Compare['Hardware.CPU'] -ne $local.Compare['Hardware.CPU']) { Add-Result WARN 'CPU model matches peer' "$($local.Compare['Hardware.CPU']) vs $($peer.Compare['Hardware.CPU']) - may need processor compatibility mode" }
    else { Add-Result PASS 'CPU model matches peer' $local.Compare['Hardware.CPU'] }

    if ($peer.Compare['OS.Build'] -eq $local.Compare['OS.Build']) { Add-Result PASS 'OS build matches peer' $local.Compare['OS.Build'] }
    else { Add-Result WARN 'OS build matches peer' "$($local.Compare['OS.Build']) vs peer $($peer.Compare['OS.Build']) - patch to match before joining" }

    if ($peer.Compare['Firmware.SystemROM'] -eq $local.Compare['Firmware.SystemROM']) { Add-Result PASS 'System ROM matches peer' }
    else { Add-Result $missSev 'System ROM matches peer' "$($local.Compare['Firmware.SystemROM']) vs peer $($peer.Compare['Firmware.SystemROM']) - $(if ($hpeDone) { 'SPP did not bring it level' } else { '-Phase Hpe should bring it level' })" }

    $drv = @(@($peer.Compare.Keys) + @($local.Compare.Keys) | Where-Object { $_ -like 'Driver.*' } | Sort-Object -Unique)
    foreach ($k in $drv) {
        $p = $peer.Compare[$k]; $l = $local.Compare[$k]
        if ($p -and $l -and $p -ne $l) { Add-Result $missSev "Driver version: $($k.Substring(7))" "$l vs peer $p" }
    }

    $missingKb = @($peer.Compare.Keys | Where-Object { $_ -like 'Hotfix.*' -and -not $local.Compare.ContainsKey($_) } | ForEach-Object { $_.Substring(7) })
    if ($missingKb.Count) { Add-Result WARN 'Hotfixes on peer but not here' ($missingKb -join ', ') } else { Add-Result PASS 'No hotfixes missing vs peer' }

    # Host network subnets must match the peer's per role, or the join creates new cluster networks
    if ($NodeConfig) {
        foreach ($net in $Config.HostNetworks) {
            $ip = $NodeConfig.IPs.PSObject.Properties[$net.Role].Value
            if (-not $ip) { Add-Result FAIL "IP for $($net.Role)" "No Nodes.$env:COMPUTERNAME.IPs.$($net.Role) in config"; continue }
            $mine  = Get-SubnetKey $ip ([int]$net.PrefixLength)
            $peerS = $peer.Compare["VNic.$($net.Role).Subnet"]
            if (-not $peerS) { Add-Result WARN "Subnet for $($net.Role)" "Peer has no host vNIC named '$($net.Role)' - check the role names match the peer's vNIC names" }
            elseif ($peerS -eq $mine) { Add-Result PASS "Subnet for $($net.Role)" $mine }
            else { Add-Result FAIL "Subnet for $($net.Role)" "$mine vs peer $peerS - would create a new cluster network" }
            $peerVlan = $peer.Compare["VNic.$($net.Role).Vlan"]
            if ($peerVlan -and $peerVlan -ne "$($net.VlanId)" -and -not ($peerVlan -eq 'Untagged' -and [int]$net.VlanId -eq 0)) {
                Add-Result WARN "VLAN for $($net.Role)" "Config $($net.VlanId) vs peer $peerVlan"
            }
        }
    }

    $diff = Compare-Fingerprint -Peer $peer -Local $local
    if ($local.Compare['HPE.ilorest'] -eq 'Not installed' -and -not $hpeDone) {
        # Without ilorest there's nothing local to compare - every HPE.* row would be a false mismatch.
        $diff = $diff | Where-Object { $_.Setting -notlike 'HPE.*' }
    }
    Export-Diff $diff 'preflight'
}

# ---------------------------------------------------------------------------
# Phase: Base
# ---------------------------------------------------------------------------

function Get-IloRest {
    $ilo = (Get-Command ilorest.exe -ErrorAction SilentlyContinue).Source
    if (-not $ilo) { $ilo = Get-ChildItem "$env:ProgramFiles\Hewlett Packard Enterprise\RESTful Interface Tool\ilorest.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    return $ilo
}

function Invoke-IloRest {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'   # ilorest writes to stderr on a refused login; must not throw
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

# ---------------------------------------------------------------------------
# Phase: Hpe (SPP via SUM unattended, CHIF/AMS/ilorest, boot RAID)
# ---------------------------------------------------------------------------

function Invoke-Hpe {
    $reboot = $false
    $hpe = $Config.Hpe
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.Manufacturer -notmatch 'HPE|Hewlett') { throw "This host reports manufacturer '$($cs.Manufacturer)' - the Hpe phase is for HPE ProLiant only." }
    Write-Host "  $($cs.Manufacturer) $($cs.Model)"

    Write-Step 'Service Pack for ProLiant (SUM, unattended)'
    if (-not $hpe.SppIsoPath -or $hpe.SppIsoPath -like '*<*') { Write-Warning 'Hpe.SppIsoPath not configured - skipping the SPP.' }
    else {
        if (-not (Test-Path $hpe.SppIsoPath)) { throw "SPP ISO not found: $($hpe.SppIsoPath)" }
        Write-Host "  SPP: $($hpe.SppIsoPath)"
        Write-Host '  SUM applies every component in the SPP that is newer than what is installed (no downgrades).' -ForegroundColor Yellow
        Write-Host '  NIC firmware/driver updates bounce the links briefly - an RDP session may drop and reconnect; SUM keeps running.' -ForegroundColor Yellow
        if (-not (Confirm-Action 'Run SUM unattended against this host now')) { throw 'Stopped by engineer.' }

        $iso = $hpe.SppIsoPath
        $copied = $null
        try {
            try { $img = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop }
            catch {
                # Some shares won't mount in place - fall back to a local copy.
                Write-Warning "Could not mount the ISO from the share ($($_.Exception.Message)) - copying it locally first."
                $copied = Join-Path $Work (Split-Path $iso -Leaf)
                Copy-Item $iso $copied -Force
                $img = Mount-DiskImage -ImagePath $copied -PassThru
            }
            $drive = ($img | Get-Volume).DriveLetter
            if (-not $drive) { throw 'The mounted SPP has no drive letter.' }
            $sum = Get-ChildItem "${drive}:\" -Filter smartupdate.bat -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $sum) { throw "smartupdate.bat not found on the SPP (${drive}:). Is this an SPP ISO?" }
            Write-Host "  Running $($sum.FullName) /silent - this can take 30-60 minutes."

            # 'smartupdate /silent' from its own folder = apply the baseline in that folder to
            # localhost (SUM CLI guide, "Updating the local host"). No /reboot - the script
            # decides when to reboot so the phase state stays accurate.
            $code = Start-ProcessWithHeartbeat -FilePath 'cmd.exe' -ArgumentList "/c `"`"$($sum.FullName)`" /silent`"" -Label 'SUM' -HeartbeatSec 60 -WorkingDirectory $sum.DirectoryName
        } finally {
            if ($iso) { Dismount-DiskImage -ImagePath $(if ($copied) { $copied } else { $iso }) -ErrorAction SilentlyContinue | Out-Null }
            if ($copied) { Remove-Item $copied -Force -ErrorAction SilentlyContinue }
        }

        # SUM return codes (SUM CLI guide, "Return codes", Windows values)
        switch ([int]$code) {
            0  { Write-Host '  SUM: installation successful.' -ForegroundColor Green }
            1  { Write-Host '  SUM: installation successful - reboot required.' -ForegroundColor Yellow; $reboot = $true }
            3  { Write-Host '  SUM: all components already current.' -ForegroundColor Green }
            -1 { throw 'SUM: general failure (-1). See the SUM logs under C:\cpqsystem\sum\log.' }
            -2 { throw 'SUM: bad input parameter (-2).' }
            -3 { throw 'SUM: a component failed or was blocked by a failed dependency (-3). See the SUM logs under C:\cpqsystem\sum\log, fix, and re-run -Phase Hpe.' }
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
    elseif ($hpe.IloRestMsiPath -and $hpe.IloRestMsiPath -notlike '*<*') {
        if (-not (Test-Path $hpe.IloRestMsiPath)) { throw "ilorest MSI not found: $($hpe.IloRestMsiPath)" }
        $local = Join-Path $Work (Split-Path $hpe.IloRestMsiPath -Leaf)
        Copy-Item $hpe.IloRestMsiPath $local -Force
        try {
            $sig = Get-AuthenticodeSignature $local
            if ($sig.Status -ne 'Valid') { throw "ilorest MSI signature is '$($sig.Status)' - refusing to run it." }
            Write-Host "  Installing ilorest (signed by: $($sig.SignerCertificate.Subject))"
            $c = Start-ProcessWithHeartbeat -FilePath 'msiexec.exe' -ArgumentList "/i `"$local`" /qn /norestart" -Label 'ilorest install'
            if ($c -notin 0, 3010) { throw "ilorest install failed with exit code $c." }
        } finally { Remove-Item $local -Force -ErrorAction SilentlyContinue }
        # Fresh install isn't on this session's PATH - Get-IloRest falls back to the install folder.
        if (Get-IloRest) { Write-Host '  ilorest installed.' -ForegroundColor Green } else { Write-Warning 'ilorest installed but ilorest.exe not found in the expected folder.' }
    } else { Write-Warning 'ilorest not installed and Hpe.IloRestMsiPath not configured - the Base phase BIOS step will be skipped.' }

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
    } else { Write-Warning 'ssacli not installed (it ships in the SPP) - check the boot volume RAID in iLO > System Information > Storage.' }

    Save-PhaseComplete 'Hpe' $reboot
    if ($reboot) { Write-Host "`nREBOOT REQUIRED. Then -Phase PreFlight again to compare firmware/drivers with the peer, then -Phase Base." -ForegroundColor Yellow }
    else { Write-Host "`nNext: -Phase Base (re-run -Phase PreFlight first to compare firmware/drivers with the peer)." -ForegroundColor Green }
}

# Sets the HPE BIOS workload profile in-band. Returns $true if it was changed
# (applies at next reboot). Shared by Base and Baseline.
function Set-ArcWorkloadProfile {
    param([string]$Target)
    $changed = $false
    $ilo = Get-IloRest
    if (-not $ilo) {
        Write-Warning 'ilorest not installed - set the workload profile in RBSU/iLO by hand (System Configuration > BIOS > Workload Profile).'
    } elseif (-not $Target) {
        Write-Warning 'Hpe.WorkloadProfile not set in config - skipping.'
    } else {
        $target = $Target
        $login = Invoke-IloRest $ilo @('login')
        if ($login.ExitCode -ne 0) {
            Write-Warning "In-band iLO login refused (likely 'Require Host Authentication' is on):`n$($login.Output)"
            if (Confirm-Action 'Log in to iLO with credentials instead?') {
                $cred = Get-Credential -Message 'iLO account with BIOS configure rights'
                # ilorest only takes the password as an argument - it is visible on this
                # process's command line for the duration of the login call.
                $login = Invoke-IloRest $ilo @('login', '-u', $cred.UserName, '-p', $cred.GetNetworkCredential().Password)
            }
        }
        if ($login.ExitCode -ne 0) {
            Write-Warning 'Skipping BIOS step - no iLO session. Set the workload profile by hand.'
        } else {
            $get = Invoke-IloRest $ilo @('get', 'WorkloadProfile', '--selector=Bios.', '--json')
            $s = $get.Output.IndexOf('{'); $e = $get.Output.LastIndexOf('}')
            $current = if ($s -ge 0) { ($get.Output.Substring($s, $e - $s + 1) | ConvertFrom-Json).WorkloadProfile } else { $null }
            Write-Host "  Current workload profile: $current"
            if ($current -eq $target) {
                Write-Host '  Already set.' -ForegroundColor Green
            } else {
                # Set the profile only - it locks its dependent settings (power regulator,
                # C-states, VT-x/VT-d etc.). PreFlight/Report verify those afterwards.
                $set = Invoke-IloRest $ilo @('set', "WorkloadProfile=$target", '--selector=Bios.', '--commit')
                if ($set.ExitCode -ne 0) { Write-Warning "Setting the workload profile failed:`n$($set.Output)" }
                else { Write-Host "  Workload profile set to $target - applies at next reboot." -ForegroundColor Green; $changed = $true }
            }
            Invoke-IloRest $ilo @('logout') | Out-Null
        }
    }
    return $changed
}

function Set-ArcHighPerformancePower {
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
    if ($LASTEXITCODE -eq 0) { Write-Host '  High Performance plan active.' } else { Write-Warning 'Could not activate the High Performance plan.' }
}

function Invoke-Base {
    Assert-PriorPhase 'Hpe'
    $reboot = $false
    $hyperVDeferred = $false

    Write-Step 'Power plan'
    Set-ArcHighPerformancePower

    Write-Step 'HPE BIOS workload profile'
    if (Set-ArcWorkloadProfile -Target $Config.Hpe.WorkloadProfile) { $reboot = $true }

    # After the BIOS step: the Hyper-V role won't install while VT-x is off, and the
    # workload profile that turns it on only applies at the next reboot.
    Write-Step 'Roles and features'
    $cs  = Get-CimInstance Win32_ComputerSystem
    $vtOn = $cs.HypervisorPresent -or (@(Get-CimInstance Win32_Processor)[0].VirtualizationFirmwareEnabled)
    $features = 'Hyper-V', 'Failover-Clustering', 'Multipath-IO'
    if (-not $vtOn -and -not (Get-WindowsFeature Hyper-V).Installed) {
        Write-Warning 'VT-x is off in firmware - installing the other features now; Hyper-V is deferred until you re-run -Phase Base after the reboot.'
        $features = 'Failover-Clustering', 'Multipath-IO'
        $hyperVDeferred = $true
        $reboot = $true
    }
    $missing = @(Get-WindowsFeature -Name $features | Where-Object { -not $_.Installed })
    if ($missing) {
        Write-Host "  Installing: $($missing.Name -join ', ')"
        $r = Install-WindowsFeature -Name $missing.Name -IncludeManagementTools
        if (-not $r.Success) { throw "Feature install failed: $($r.ExitCode)" }
        if ("$($r.RestartNeeded)" -ne 'No') { $reboot = $true }
    } else { Write-Host '  All required features already installed.' }

    Write-Step 'iLO (report only)'
    Write-Host '  iLO network/hostname/directory changes are not automated (they reset the iLO mid-session).'
    Write-Host '  Check in the iLO web UI: hostname, DNS, NTP, SNMP/alert destinations, directory auth, licence.'

    if ($hyperVDeferred) {
        # Don't record Base as complete - Hyper-V still needs installing.
        $state = Get-State
        $state | Add-Member -NotePropertyName RebootPending -NotePropertyValue $true -Force
        $state | Add-Member -NotePropertyName RebootRequestedAt -NotePropertyValue (Get-Date -Format 's') -Force
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
        Write-Host "`nREBOOT, check VT-x is now on, then RE-RUN -Phase Base to install Hyper-V." -ForegroundColor Yellow
        return
    }
    Save-PhaseComplete 'Base' $reboot
    if ($reboot) { Write-Host "`nREBOOT REQUIRED. After the reboot, run -Phase Network from the iLO remote console." -ForegroundColor Yellow }
    else { Write-Host "`nNext: -Phase Network (from the iLO remote console)." -ForegroundColor Green }
}

# ---------------------------------------------------------------------------
# Phase: Network (console only)
# ---------------------------------------------------------------------------

function Invoke-Network {
    Assert-PriorPhase 'Base'
    if (-not (Test-ArcConsoleSession) -and -not $AllowRemoteSession) {
        throw "This is not the console session. Building the SET vSwitch drops remote sessions - run this from the iLO remote console, or pass -AllowRemoteSession if you have other out-of-band access."
    }
    if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) { throw 'Hyper-V module not available - run -Phase Base and reboot first.' }

    $sw = $Config.Switch
    $macs = @($NodeConfig.AdapterMacs | ForEach-Object { ConvertTo-MacKey $_ })
    $adapters = @(Get-NetAdapter -Physical | Where-Object { (ConvertTo-MacKey $_.MacAddress) -in $macs })
    if ($adapters.Count -ne $macs.Count) {
        throw "Found $($adapters.Count) of $($macs.Count) configured adapters by MAC. Run -Phase PreFlight to list this host's NICs."
    }
    Write-Step "SET vSwitch '$($sw.Name)'"
    Write-Host "  Members: $(($adapters | ForEach-Object { "$($_.Name) [$($_.MacAddress)]" }) -join ', ')"

    $existing = Get-VMSwitch -Name $sw.Name -ErrorAction SilentlyContinue
    if ($existing) {
        # Bandwidth mode can only be chosen at creation - never try to fix it in place.
        if (-not $existing.EmbeddedTeamingEnabled) { throw "Switch '$($sw.Name)' exists but is not a SET switch. Remove it by hand and re-run." }
        if ("$($existing.BandwidthReservationMode)" -ne 'Weight') { throw "Switch '$($sw.Name)' exists with bandwidth mode '$($existing.BandwidthReservationMode)', not Weight. That can only be set at creation - remove it by hand and re-run." }
        $members = @((Get-VMSwitchTeam -Name $sw.Name).NetAdapterInterfaceDescription)
        $wanted  = @($adapters.InterfaceDescription)
        if (Compare-Object ($members | Sort-Object) ($wanted | Sort-Object)) { throw "Switch '$($sw.Name)' exists with different team members ($($members -join ', ')). Fix by hand." }
        Write-Host '  Switch already exists with the right members and mode.' -ForegroundColor Green
    } else {
        if (-not (Confirm-Action "Create SET switch '$($sw.Name)' on $($adapters.Count) NICs? Any IP on those NICs will be removed")) { throw 'Stopped by engineer.' }
        New-VMSwitch -Name $sw.Name -NetAdapterName $adapters.Name -EnableEmbeddedTeaming $true -AllowManagementOS $false -MinimumBandwidthMode Weight | Out-Null
        Write-Host '  Switch created.' -ForegroundColor Green
    }
    $lb = if ($sw.LoadBalancingAlgorithm) { $sw.LoadBalancingAlgorithm } else { 'HyperVPort' }
    Set-VMSwitchTeam -Name $sw.Name -LoadBalancingAlgorithm $lb
    if ($null -ne $sw.DefaultFlowWeight) { Set-VMSwitch -Name $sw.Name -DefaultFlowMinimumBandwidthWeight ([int]$sw.DefaultFlowWeight) }

    Write-Step 'Physical NIC tuning'
    foreach ($a in $adapters) {
        try { Disable-NetAdapterPowerManagement -Name $a.Name -NoRestart -ErrorAction Stop; Write-Host "  Power management off: $($a.Name)" }
        catch { Write-Warning "Power management on $($a.Name): $($_.Exception.Message)" }
        if ($sw.JumboPacket) {
            try { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*JumboPacket' -RegistryValue ([string]$sw.JumboPacket) -NoRestart -ErrorAction Stop; Write-Host "  Jumbo $($sw.JumboPacket): $($a.Name)" }
            catch { Write-Warning "Jumbo frames on $($a.Name): $($_.Exception.Message)" }
        }
    }

    Write-Step 'Host vNICs'
    foreach ($net in $Config.HostNetworks) {
        $role = $net.Role
        $alias = "vEthernet ($role)"
        $ip = $NodeConfig.IPs.PSObject.Properties[$role].Value
        if (-not $ip) { throw "No Nodes.$env:COMPUTERNAME.IPs.$role in config." }

        if (-not (Get-VMNetworkAdapter -ManagementOS -Name $role -ErrorAction SilentlyContinue)) {
            Add-VMNetworkAdapter -ManagementOS -SwitchName $sw.Name -Name $role
            Write-Host "  Added vNIC $role"
        }
        if ([int]$net.VlanId -gt 0) { Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $role -Access -VlanId ([int]$net.VlanId) }
        else { Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $role -Untagged }
        if ($null -ne $net.Weight) { Set-VMNetworkAdapter -ManagementOS -Name $role -MinimumBandwidthWeight ([int]$net.Weight) }

        # The vNIC's NIC object can take a few seconds to appear after creation
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }

        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Disabled
        $current = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' }
        $ok = $current | Where-Object { $_.IPAddress -eq $ip -and $_.PrefixLength -eq [int]$net.PrefixLength }
        if (-not $ok) {
            $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            $ipArgs = @{ InterfaceAlias = $alias; IPAddress = $ip; PrefixLength = [int]$net.PrefixLength }
            if ($net.Gateway) { $ipArgs.DefaultGateway = $net.Gateway }
            New-NetIPAddress @ipArgs | Out-Null
        }
        if ($net.DnsServers) { Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses @($net.DnsServers) }
        else { Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses }
        Set-DnsClient -InterfaceAlias $alias -RegisterThisConnectionsAddress ([bool]$net.RegisterInDns)
        if ($sw.JumboPacket -and $net.Jumbo) {
            try { Set-NetAdapterAdvancedProperty -Name $alias -RegistryKeyword '*JumboPacket' -RegistryValue ([string]$sw.JumboPacket) -ErrorAction Stop } catch { Write-Warning "Jumbo on ${alias}: $($_.Exception.Message)" }
        }
        Write-Host "  $role : $ip/$($net.PrefixLength) VLAN $($net.VlanId) weight $($net.Weight) DNS-register $([bool]$net.RegisterInDns)" -ForegroundColor Green
    }

    Write-Step 'Connectivity to the peer on each network'
    Start-Sleep -Seconds 5
    try {
        $peer = Get-PeerFingerprint
        foreach ($v in $peer.Detail.HostVNics) {
            $ok = Test-Connection -ComputerName $v.IPAddress -Count 2 -Quiet
            Write-Host ("  {0,-15} {1,-16} {2}" -f $v.Name, $v.IPAddress, $(if ($ok) { 'OK' } else { 'NO REPLY' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
            if ($ok -and $sw.JumboPacket -and ($Config.HostNetworks | Where-Object { $_.Role -eq $v.Name -and $_.Jumbo })) {
                $size = [int]$sw.JumboPacket - 42
                $j = ping.exe -n 2 -f -l $size $v.IPAddress | Out-String
                Write-Host "    jumbo ($size bytes, DF): $(if ($j -match 'TTL=') { 'OK' } else { 'FAILED - check switch MTU' })"
            }
        }
    } catch { Write-Warning "Could not test against the peer: $($_.Exception.Message)" }

    Save-PhaseComplete 'Network'
    Write-Host "`nNext: -Phase Storage." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Phase: Storage (FC + MPIO)
# ---------------------------------------------------------------------------

function Invoke-Storage {
    Assert-PriorPhase 'Base'
    if (-not (Get-WindowsFeature Multipath-IO).Installed) { throw 'Multipath-IO is not installed - run -Phase Base first.' }
    $reboot = $false
    $st = $Config.Storage
    $peer = Get-PeerFingerprint

    Write-Step 'FC initiator ports - zone these and add them to the 3PAR/Primera host object (persona 15 / WindowsServer)'
    Get-InitiatorPort | Where-Object ConnectionType -eq 'Fibre Channel' |
        Select-Object @{ n = 'WWPN'; e = { ($_.PortAddress -replace '(..)(?!$)', '$1:') } }, @{ n = 'WWNN'; e = { ($_.NodeAddress -replace '(..)(?!$)', '$1:') } }, InstanceName |
        Format-Table -AutoSize | Out-String | Write-Host

    Write-Step 'MPIO device claim'
    $vid = $st.MpioVendorId; $pid_ = $st.MpioProductId
    if (-not $vid -or -not $pid_) { throw 'Storage.MpioVendorId / MpioProductId must be set in config.' }
    $claimed = Get-MSDSMSupportedHW | Where-Object { $_.VendorId.Trim() -eq $vid -and $_.ProductId.Trim() -eq $pid_ }
    if ($claimed) { Write-Host "  $vid / $pid_ already claimed." -ForegroundColor Green }
    else {
        New-MSDSMSupportedHW -VendorId $vid -ProductId $pid_ | Out-Null
        Write-Host "  Claimed $vid / $pid_ - reboot required for MSDSM to take the disks." -ForegroundColor Yellow
        $reboot = $true
    }
    if (-not (Get-Peer $peer "MPIO.SupportedHW.$vid|$pid_")) { Write-Warning "The peer does not list $vid / $pid_ in its MSDSM claim list - check the IDs against the peer (mpclaim -h)." }

    Write-Step 'MPIO load-balance policy and timers (peer is the source of truth)'
    $lb = Resolve-Setting $st.LoadBalancePolicy (Get-Peer $peer 'MPIO.GlobalLBPolicy') 'Global load-balance policy'
    if ($lb) { Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy $lb }

    $ov = $st.MpioSettings
    $map = [ordered]@{
        PathVerificationState  = 'NewPathVerificationState'
        PathVerificationPeriod = 'NewPathVerificationPeriod'
        PDORemovePeriod        = 'NewPDORemovePeriod'
        RetryCount             = 'NewRetryCount'
        RetryInterval          = 'NewRetryInterval'
        DiskTimeoutValue       = 'NewDiskTimeout'
    }
    # Only change what differs, so a re-run doesn't ask for a reboot every time.
    $cur = Get-MPIOSetting
    $setArgs = @{}
    foreach ($k in $map.Keys) {
        $cfgVal = if ($ov) { $ov.$k } else { $null }
        $v = Resolve-Setting $cfgVal (Get-Peer $peer "MPIO.$k") "MPIO $k"
        if ($null -ne $v -and "$v" -ne "$($cur.$k)") { $setArgs[$map[$k]] = if ($k -eq 'PathVerificationState') { "$v" } else { [int]$v } }
    }
    $useCustom = Resolve-Setting $(if ($ov) { $ov.UseCustomPathRecoveryTime } else { $null }) (Get-Peer $peer 'MPIO.UseCustomPathRecoveryTime') 'MPIO UseCustomPathRecoveryTime'
    if ($useCustom) {
        $rec = $null
        if ("$useCustom" -eq 'Enabled') { $rec = Resolve-Setting $(if ($ov) { $ov.CustomPathRecoveryTime } else { $null }) (Get-Peer $peer 'MPIO.CustomPathRecoveryTime') 'MPIO CustomPathRecoveryTime' }
        if ("$useCustom" -ne "$($cur.UseCustomPathRecoveryTime)" -or ($null -ne $rec -and "$rec" -ne "$($cur.CustomPathRecoveryTime)")) {
            $setArgs.CustomPathRecovery = "$useCustom"
            if ($null -ne $rec) { $setArgs.NewPathRecoveryInterval = [int]$rec }
        }
    }
    if ($setArgs.Count) { Set-MPIOSetting @setArgs | Out-Null; Write-Host "  MPIO settings changed ($($setArgs.Keys -join ', ')) - reboot required." -ForegroundColor Yellow; $reboot = $true }
    else { Write-Host '  MPIO timers already match.' -ForegroundColor Green }

    Write-Step 'LUN visibility vs the peer'
    Update-HostStorageCache
    $peerLuns = @($peer.Detail.Disks | Where-Object IsClustered)
    $localIds = @(Get-Disk | ForEach-Object UniqueId)
    if (-not $peerLuns) { Write-Warning 'The peer reported no clustered disks - cannot compare.' }
    $missing = @($peerLuns | Where-Object { $_.UniqueId -notin $localIds })
    $script:StorageMissing = if ($peerLuns) { $missing.Count } else { -1 }   # -1 = peer had none to compare
    foreach ($l in $peerLuns) {
        $seen = $l.UniqueId -in $localIds
        Write-Host ("  {0,-8} {1,6} GB  {2}  {3}" -f $(if ($seen) { 'VISIBLE' } else { 'MISSING' }), $l.SizeGB, $l.UniqueId, $l.FriendlyName) -ForegroundColor $(if ($seen) { 'Green' } else { 'Red' })
    }
    if ($missing) { Write-Warning "$($missing.Count) cluster LUN(s) not visible here. Finish zoning / LUN export, then re-run -Phase Storage." }

    Write-Step 'Paths per MPIO disk (expect the same path count as the peer)'
    try { mpclaim.exe -s -d | Out-String | Write-Host } catch { Write-Warning 'mpclaim not available.' }

    Save-PhaseComplete 'Storage' $reboot
    if ($reboot) { Write-Host "`nREBOOT REQUIRED for the MPIO changes. Then re-run -Phase Storage to confirm LUNs and paths, then -Phase Agents." -ForegroundColor Yellow }
    elseif ($missing) { Write-Host "`nResolve the missing LUNs before -Phase Join." -ForegroundColor Yellow }
    else { Write-Host "`nNext: -Phase Agents." -ForegroundColor Green }
}

# ---------------------------------------------------------------------------
# Phase: Agents (Datto RMM, SentinelOne, Defender removal)
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

function Test-SentinelInstalled {
    if (Get-Service SentinelAgent -ErrorAction SilentlyContinue) { return $true }
    return [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -eq 'Sentinel Agent')
}

# Returns $true if a reboot is needed.
function Install-ArcSentinelAgent {
    param([Parameter(Mandatory)][string]$MsiPath, [string]$StoredToken)
    if (Test-SentinelInstalled) { Write-Host '  SentinelOne already installed - skipping install.' -ForegroundColor Green; return $false }
    if (-not (Test-Path $MsiPath)) { throw "Sentinel MSI not found: $MsiPath" }

    $local = Join-Path $Work 'SentinelInstaller.msi'
    Copy-Item $MsiPath $local -Force
    $bstr = [IntPtr]::Zero
    $plain = $null
    try {
        $sig = Get-AuthenticodeSignature $local
        if ($sig.Status -ne 'Valid') { throw "Sentinel MSI signature is '$($sig.Status)' - refusing to run it." }
        Write-Host "  MSI signed by: $($sig.SignerCertificate.Subject)"

        # Site token from cluster.json on the share if it's there; otherwise (not set,
        # placeholder, or this run is using the redacted local copy) prompt for it.
        if (Test-ArcSiteToken $StoredToken) {
            $plain = $StoredToken
            Write-Host '  Using the SentinelOne site token from the deployment settings (not shown).'
        } else {
            if ($StoredToken -eq $RedactedToken) { Write-Host '  Settings came from the local copy, which does not hold the site token.' -ForegroundColor Yellow }
            $token = Read-Host '  SentinelOne site token (input hidden)' -AsSecureString
            $bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        if ([string]::IsNullOrWhiteSpace($plain)) { throw 'No site token entered.' }

        # The token is an MSI property, so it is on msiexec's command line while it runs
        # (visible to process auditing/EDR telemetry). No verbose MSI log - /lv* would
        # write the token to disk. The token is never echoed.
        Write-Host '  Installing SentinelOne (token present, not shown)...'
        $code = Start-ProcessWithHeartbeat -FilePath 'msiexec.exe' -ArgumentList "/i `"$local`" /quiet /norestart SITE_TOKEN=$plain" -Label 'SentinelOne install'
    } finally {
        $plain = $null
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        Remove-Item $local -Force -ErrorAction SilentlyContinue
    }

    switch ($code) {
        0     { Write-Host '  SentinelOne installed.' -ForegroundColor Green; return $false }
        3010  { Write-Host '  SentinelOne installed - reboot required.' -ForegroundColor Yellow; return $true }
        1618  { throw 'Another installation is in progress (1618) - is Datto deploying Sentinel at the same time? Wait for it, or reboot, then re-run -Phase Agents.' }
        1602  { throw 'Sentinel install cancelled (1602). Check the Application event log (MsiInstaller).' }
        default { throw "Sentinel install failed with exit code $code. Check the Application event log (MsiInstaller) - do not add /lv* logging with the token on the command line." }
    }
}

function Show-SentinelStatus {
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Service SentinelAgent -ErrorAction SilentlyContinue).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    $svc = Get-Service SentinelAgent -ErrorAction SilentlyContinue
    Write-Host "  SentinelAgent service: $(if ($svc) { $svc.Status } else { 'not present' })"
    $ctl = Get-ChildItem "$env:ProgramFiles\SentinelOne\Sentinel Agent*\SentinelCtl.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    $ErrorActionPreference = 'Continue'
    if ($ctl) { & $ctl.FullName status 2>&1 | ForEach-Object { "$_" } | Out-String | Write-Host }
    $ErrorActionPreference = 'Stop'
    else { Write-Warning 'SentinelCtl.exe not found.' }
    return ($svc -and $svc.Status -eq 'Running')
}

function Invoke-Agents {
    $reboot = $false
    $ag = $Config.Agents

    Write-Step 'Datto RMM agent'
    if ($ag.Datto -and $ag.Datto.SiteID -and $ag.Datto.SiteID -notlike '<*>') {
        # The Datto tenants we use live on one of these two platforms (the subdomain in
        # https://<platform>.rmm.datto.com). Prompt if the config leaves it unset.
        $platforms = 'pinotage', 'merlot'
        $platform = "$($ag.Datto.Platform)".Trim().ToLower()
        if (-not $platform -or $platform -like '<*') {
            do { $choice = Read-Host '  Datto platform for this site - [1] Pinotage  [2] Merlot' } until ($choice -in '1', '2')
            $platform = $platforms[[int]$choice - 1]
        }
        if ($platform -notin $platforms) { throw "Agents.Datto.Platform '$($ag.Datto.Platform)' is not one of: $($platforms -join ', ')." }
        Write-Host "  Datto platform: $platform"
        Install-ArcDattoAgent -Platform $platform -SiteID $ag.Datto.SiteID
    }
    else { Write-Warning 'Agents.Datto not configured - skipping.' }

    Write-Step 'SentinelOne agent'
    if ($ag.Sentinel -and $ag.Sentinel.MsiPath -and $ag.Sentinel.MsiPath -notlike '*<*') {
        $stored = if ($ag.Sentinel.PSObject.Properties['SiteToken']) { $ag.Sentinel.SiteToken } else { $null }
        if (Install-ArcSentinelAgent -MsiPath $ag.Sentinel.MsiPath -StoredToken $stored) { $reboot = $true }
    } elseif (-not (Test-SentinelInstalled)) { Write-Warning 'Agents.Sentinel.MsiPath not configured and Sentinel is not installed - skipping.' }

    if (Test-SentinelInstalled) {
        $running = Show-SentinelStatus
        Write-Host '  Move this host into the SentinelOne group/policy that carries the Hyper-V + cluster exclusions' -ForegroundColor Yellow
        Write-Host '  (VM config/VHDX paths, C:\ClusterStorage, vmms.exe, vmwp.exe, vmcompute.exe, %SystemRoot%\Cluster) BEFORE it takes VM workload.' -ForegroundColor Yellow

        Write-Step 'Windows Defender removal'
        $def = Get-WindowsFeature Windows-Defender
        if (-not $def.Installed) { Write-Host '  Defender already removed.' -ForegroundColor Green }
        elseif ($ag.Sentinel.RemoveDefender -eq $false) { Write-Host '  Agents.Sentinel.RemoveDefender is false - leaving Defender installed.' }
        elseif ($reboot) { Write-Host '  Sentinel needs its reboot first - re-run -Phase Agents after rebooting to remove Defender.' -ForegroundColor Yellow }
        elseif (-not $running) { Write-Warning 'SentinelAgent is not running - NOT removing Defender.' }
        elseif (Confirm-Action 'Is this host showing as connected/online in the SentinelOne console? Remove Windows Defender now') {
            $r = Uninstall-WindowsFeature Windows-Defender
            if ($r.RestartNeeded -ne 'No') { $reboot = $true }
            Write-Host '  Defender removed.' -ForegroundColor Green
        } else { Write-Host '  Left Defender installed - re-run -Phase Agents once the agent shows as connected.' }
    }

    Save-PhaseComplete 'Agents' $reboot
    if ($reboot) { Write-Host "`nREBOOT REQUIRED. Then -Phase Baseline (security + optimisation), then -Phase Join." -ForegroundColor Yellow } else { Write-Host "`nNext: -Phase Baseline, then -Phase Join." -ForegroundColor Green }
}

# ---------------------------------------------------------------------------
# Phase: Join
# ---------------------------------------------------------------------------

function Invoke-Join {
    Assert-PriorPhase 'Network', 'Storage', 'Agents', 'Baseline'
    Import-Module FailoverClusters
    $cluster = $Config.ClusterName

    $nodes = @(Get-ClusterNode -Cluster $cluster)
    if ($nodes.Name -contains $env:COMPUTERNAME) { Write-Host "  $env:COMPUTERNAME is already a member of $cluster." -ForegroundColor Green }
    else {
        $down = @($nodes | Where-Object State -ne 'Up')
        if ($down) { Write-Warning "Cluster nodes not Up: $($down.Name -join ', ')" }
        $netsBefore = @(Get-ClusterNetwork -Cluster $cluster)

        Write-Step "Test-Cluster ($($nodes.Name -join ', ') + $env:COMPUTERNAME)"
        # Storage tests are excluded: on a live cluster they take the disks under test offline.
        $report = Join-Path $LogRoot "Test-Cluster-$Stamp"
        $tw = $null
        $result = Test-Cluster -Node (@($nodes.Name) + $env:COMPUTERNAME) -Ignore 'Storage' -ReportName $report -WarningVariable tw -WarningAction SilentlyContinue
        Write-Host "  Report: $($result.FullName)"
        if ($tw) { Write-Host "  Validation warnings:" -ForegroundColor Yellow; $tw | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow } }
        else { Write-Host '  No validation warnings.' -ForegroundColor Green }
        try { Start-Process $result.FullName } catch { }
        Write-Host "`n  Review the report. Any FAILED test must be fixed before joining." -ForegroundColor Yellow
        $answer = Read-Host "  Type JOIN to add $env:COMPUTERNAME to $cluster (anything else stops)"
        if ($answer -cne 'JOIN') { throw 'Stopped by engineer before Add-ClusterNode.' }

        Write-Step 'Add-ClusterNode'
        Add-ClusterNode -Cluster $cluster -Name $env:COMPUTERNAME -NoStorage | Out-Null
        Write-Host "  Added $env:COMPUTERNAME to $cluster." -ForegroundColor Green

        $netsAfter = @(Get-ClusterNetwork -Cluster $cluster)
        if ($netsAfter.Count -gt $netsBefore.Count) {
            Write-Warning "New cluster network(s) appeared: $(($netsAfter | Where-Object { $_.Name -notin $netsBefore.Name }).Name -join ', ') - a vNIC subnet does not match the existing networks."
        }
    }

    Write-Step 'Post-join checks'
    Get-ClusterNode -Cluster $cluster | Format-Table Name, State, DynamicWeight -AutoSize | Out-String | Write-Host
    Get-ClusterNetwork -Cluster $cluster | Format-Table Name, Role, State, Address, AddressMask -AutoSize | Out-String | Write-Host
    Get-ClusterNetworkInterface -Cluster $cluster -Node $env:COMPUTERNAME | Format-Table Name, Network, State -AutoSize | Out-String | Write-Host
    try { Get-ClusterSharedVolumeState -Cluster $cluster -Node $env:COMPUTERNAME | Format-Table Name, StateInfo, FileSystemRedirectedIOReason, BlockRedirectedIOReason -AutoSize | Out-String | Write-Host }
    catch { Write-Warning "CSV state: $($_.Exception.Message)" }

    Save-PhaseComplete 'Join'
    Write-Host "`nNext: -Phase HyperV." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Phase: HyperV (after Join - CSV paths only exist on a member node)
# ---------------------------------------------------------------------------

function Invoke-HyperV {
    Assert-PriorPhase 'Join'
    $hv = $Config.HyperV
    $peer = Get-PeerFingerprint

    Write-Step 'Hyper-V host settings (config overrides, otherwise the peer)'
    $args_ = @{}
    $vmPath  = Resolve-Setting $hv.VirtualMachinePath  (Get-Peer $peer 'HyperV.VirtualMachinePath')  'VirtualMachinePath'
    $vhdPath = Resolve-Setting $hv.VirtualHardDiskPath (Get-Peer $peer 'HyperV.VirtualHardDiskPath') 'VirtualHardDiskPath'
    foreach ($p in @(@{ n = 'VirtualMachinePath'; v = $vmPath }, @{ n = 'VirtualHardDiskPath'; v = $vhdPath })) {
        if (-not $p.v) { continue }
        if ($p.v -like "$env:SystemDrive\*" -and $p.v -notlike "$env:SystemDrive\ClusterStorage\*") { Write-Warning "$($p.n) '$($p.v)' is on the system drive - VMs created here will not be highly available." }
        if (Test-Path $p.v) { $args_[$p.n] = $p.v } else { Write-Warning "$($p.n) '$($p.v)' does not exist on this node - skipping." }
    }
    $m = Resolve-Setting $hv.MaxVMMigrations      (Get-Peer $peer 'HyperV.MaximumVirtualMachineMigrations') 'MaximumVirtualMachineMigrations'
    if ($m) { $args_.MaximumVirtualMachineMigrations = [int]$m }
    $s = Resolve-Setting $hv.MaxStorageMigrations (Get-Peer $peer 'HyperV.MaximumStorageMigrations') 'MaximumStorageMigrations'
    if ($s) { $args_.MaximumStorageMigrations = [int]$s }
    $perf = Resolve-Setting $hv.MigrationPerformance (Get-Peer $peer 'HyperV.MigrationPerformanceOption') 'VirtualMachineMigrationPerformanceOption'
    if ($perf) { $args_.VirtualMachineMigrationPerformanceOption = $perf }
    $numa = Resolve-Setting $hv.NumaSpanningEnabled (Get-Peer $peer 'HyperV.NumaSpanningEnabled') 'NumaSpanningEnabled'
    if ($numa) { $args_.NumaSpanningEnabled = ("$numa" -eq 'True') }
    $numaBefore = (Get-VMHost).NumaSpanningEnabled
    if ($args_.Count) { Set-VMHost @args_; Write-Host '  Hyper-V host settings applied.' -ForegroundColor Green }
    if ($args_.ContainsKey('NumaSpanningEnabled') -and $args_.NumaSpanningEnabled -ne $numaBefore) {
        # NUMA spanning only takes effect when VMMS restarts - safe while the node hosts no VMs.
        if (@(Get-VM).Count -eq 0) { Restart-Service vmms; Write-Host '  NUMA spanning changed - VMMS restarted.' -ForegroundColor Green }
        else { Write-Warning 'NUMA spanning changed but VMs are on this node - drain it and restart the vmms service for it to take effect.' }
    }

    if ((Get-Peer $peer 'HyperV.VirtualMachineMigrationEnabled') -eq 'True') { Enable-VMMigration; Write-Host '  Live migration enabled (matches peer).' }
    Write-Host '  Note: in a cluster, the live migration network is chosen cluster-wide (Failover Cluster Manager > Networks > Live Migration Settings), not per host.'

    Save-PhaseComplete 'HyperV'
    Write-Host "`nNext: -Phase Report." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Phase: Capture - write the config from the live cluster
# ---------------------------------------------------------------------------

function Invoke-Capture {
    Import-Module FailoverClusters
    $cluster = Get-Cluster
    $nodes = @(Get-ClusterNode | Sort-Object Name)
    Write-Step "Capturing cluster $($cluster.Name) ($($nodes.Count) nodes) from $env:COMPUTERNAME"

    $local = Get-LocalFingerprint
    $fps = [ordered]@{}
    foreach ($n in $nodes) {
        if ($n.Name -eq $env:COMPUTERNAME) { $fps[$n.Name] = $local; continue }
        if ("$($n.State)" -ne 'Up') { Write-Warning "$($n.Name) is $($n.State) - not captured; add its Nodes entry by hand."; continue }
        Write-Host "  Reading $($n.Name)..."
        try { $fps[$n.Name] = Get-RemoteFingerprint -ComputerName $n.Name } catch { Write-Warning $_.Exception.Message }
    }

    $vnics = @($local.Detail.HostVNics | Sort-Object Name)
    if (-not $vnics) { throw 'This node has no host vNICs with an IPv4 address - Capture expects a SET/converged host.' }

    # Host networks from THIS node's vNICs - role names = real vNIC names, so new
    # nodes and the subnet checks line up with what the cluster already has.
    $hostNetworks = @(foreach ($v in $vnics) {
        $isMgmt = [bool]$v.Gateway
        [ordered]@{
            Role          = $v.Name
            VlanId        = [int]$v.VlanId
            PrefixLength  = [int]$v.PrefixLength
            Weight        = $v.Weight
            Gateway       = if ($v.Gateway) { $v.Gateway } else { $null }
            DnsServers    = if ($isMgmt -and $v.DnsServers) { @($v.DnsServers) } else { $null }
            RegisterInDns = [bool]$v.RegisterInDns
            Jumbo         = ([int]$v.JumboPacket -gt 1514)
            ClusterRole   = if ($isMgmt) { 'ClusterAndClient' } else { 'Cluster' }
        }
    })
    $mgmt = @($hostNetworks | Where-Object { $_.Gateway })
    if ($mgmt.Count -ne 1) { Write-Warning "Expected exactly one host vNIC with a default gateway (management), found $($mgmt.Count) - check the ClusterRole values in the config." }

    # Live migration preference: anything that looks like an LM network first, then the
    # other cluster-only networks. Management is excluded.
    $lmOrder = @($hostNetworks | Where-Object { -not $_.Gateway } | Sort-Object { if ($_.Role -match 'migrat|^lm') { 0 } else { 1 } } | ForEach-Object { $_.Role })

    $nodesCfg = [ordered]@{}
    foreach ($name in $fps.Keys) {
        $fp = $fps[$name]
        $ips = [ordered]@{}
        foreach ($v in @($fp.Detail.HostVNics)) { $ips[$v.Name] = $v.IPAddress }
        $nodesCfg[$name] = [ordered]@{ AdapterMacs = @($fp.Detail.SwitchMemberMacs); IPs = $ips }
    }

    $sw = $local.Detail.SwitchName
    $claim = @($local.Compare.Keys | Where-Object { $_ -like 'MPIO.SupportedHW.*' } | ForEach-Object { $_.Substring(17) }) | Where-Object { $_ -like '3PARdata|*' } | Select-Object -First 1
    $mpioSettings = [ordered]@{}
    foreach ($k in 'PathVerificationState', 'PathVerificationPeriod', 'PDORemovePeriod', 'RetryCount', 'RetryInterval', 'DiskTimeoutValue', 'UseCustomPathRecoveryTime', 'CustomPathRecoveryTime') {
        $v = $local.Compare["MPIO.$k"]
        if ($null -ne $v -and $v -ne '') { $mpioSettings[$k] = if ($v -match '^\d+$') { [int]$v } else { $v } }
    }
    $asInt = { param($v) if ("$v" -match '^\d+$') { [int]$v } else { $null } }

    $cfg = [ordered]@{
        ClusterName = $cluster.Name
        PeerNode    = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
        Switch = [ordered]@{
            Name                   = $sw
            LoadBalancingAlgorithm = $local.Compare["Switch.$sw.LBAlgorithm"]
            DefaultFlowWeight      = & $asInt $local.Compare["Switch.$sw.DefaultFlowWeight"]
            JumboPacket            = if ([int]$local.Detail.SwitchJumboPacket -gt 1514) { [int]$local.Detail.SwitchJumboPacket } else { $null }
        }
        HostNetworks = $hostNetworks
        Nodes        = $nodesCfg
        Hpe = [ordered]@{
            SppIsoPath      = 'SPP\<SPP_VERSION>.iso'          # relative to this file's folder
            IloRestMsiPath  = 'HPE\ilorest-<VERSION>.msi'
            WorkloadProfile = 'Virtualization-MaxPerformance'
        }
        Storage = [ordered]@{
            MpioVendorId      = if ($claim) { $claim.Split('|')[0] } else { '3PARdata' }
            MpioProductId     = if ($claim) { $claim.Split('|')[1] } else { 'VV' }
            LoadBalancePolicy = $local.Compare['MPIO.GlobalLBPolicy']
            MpioSettings      = if ($mpioSettings.Count) { $mpioSettings } else { $null }
        }
        HyperV = [ordered]@{
            VirtualMachinePath   = $local.Compare['HyperV.VirtualMachinePath']
            VirtualHardDiskPath  = $local.Compare['HyperV.VirtualHardDiskPath']
            MaxVMMigrations      = & $asInt $local.Compare['HyperV.MaximumVirtualMachineMigrations']
            MaxStorageMigrations = & $asInt $local.Compare['HyperV.MaximumStorageMigrations']
            MigrationPerformance = $local.Compare['HyperV.MigrationPerformanceOption']
            NumaSpanningEnabled  = if ($local.Compare['HyperV.NumaSpanningEnabled']) { $local.Compare['HyperV.NumaSpanningEnabled'] -eq 'True' } else { $null }
        }
        Security = [ordered]@{
            Apply = $true; DisableLegacyTls = $true; RequireSmbSigning = $true; DisablePrintSpooler = $true
            InactivityTimeoutSecs = 900; LockoutThreshold = 10; CredentialGuard = $false; Hvci = $false
        }
        Optimisation = [ordered]@{ Apply = $true }
        Cluster = [ordered]@{
            LiveMigrationNetworks = $lmOrder
            DrainOnShutdown       = $true
            BlockCacheSizeMB      = $null
            SecurityLevel         = $null
        }
        Agents = [ordered]@{
            Datto    = [ordered]@{ Platform = '<pinotage|merlot>'; SiteID = '<SITE_ID>' }
            Sentinel = [ordered]@{ MsiPath = 'SentinelOne\SentinelInstaller-<VERSION>.msi'; SiteToken = '<SENTINEL_SITE_TOKEN>'; RemoveDefender = $true }
        }
    }

    $out = if ($OutPath) { $OutPath } elseif ($SettingsShare) { Join-Path $SettingsShare $SettingsFileName } else { Join-Path $LogRoot $SettingsFileName }
    if (Test-Path $out) {
        if (-not (Confirm-Action "$out exists - re-capturing replaces the captured values (and any edits to them). Agents (Datto, Sentinel token) and the Hpe installer paths are kept. Overwrite?")) { throw 'Stopped - config not written.' }
        # Keep the hand-entered sections, so a re-capture doesn't lose the site token / Site ID.
        try {
            $old = Get-Content $out -Raw | ConvertFrom-Json
            if ($old.Agents) { $cfg.Agents = $old.Agents; Write-Host '  Kept Agents from the existing file.' }
            if ($old.Hpe) {
                foreach ($k in 'SppIsoPath', 'IloRestMsiPath') { if ($old.Hpe.$k) { $cfg.Hpe[$k] = $old.Hpe.$k } }
                Write-Host '  Kept Hpe installer paths from the existing file.'
            }
        } catch { Write-Warning "Could not read the existing $out ($($_.Exception.Message)) - Agents/Hpe paths reset to placeholders." }
    }
    $json = $cfg | ConvertTo-Json -Depth 10
    $json | Set-Content -Path $out -Encoding UTF8
    $localCopy = $json | ConvertFrom-Json
    if ($localCopy.Agents.Sentinel -and (Test-ArcSiteToken $localCopy.Agents.Sentinel.SiteToken)) { $localCopy.Agents.Sentinel.SiteToken = $RedactedToken }
    $localCopy | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $LogRoot "settings-captured-$Stamp.json") -Encoding UTF8
    Save-ArcSettingsPath $out
    Write-Host "`n  Config written: $out (local copy in $LogRoot)" -ForegroundColor Green
    if (-not $SettingsShare -and -not $OutPath) { Write-Host "  Move it to the deployment share next to the SPP ISO and MSIs, then run later phases with -SettingsShare <that folder>." -ForegroundColor Yellow }

    Write-Step 'Captured values that differ from the recommended baseline - review before applying'
    $bios = $local.Compare['HPE.Bios.WorkloadProfile']
    if ($bios -and $bios -ne 'Virtualization-MaxPerformance') { Write-Host "  BIOS workload profile is '$bios' - config set to Virtualization-MaxPerformance." -ForegroundColor Yellow }
    if ($local.Compare['Power.ActivePlan'] -notmatch '8c5e7fda') { Write-Host "  Power plan is '$($local.Compare['Power.ActivePlan'])' - Baseline sets High performance." -ForegroundColor Yellow }
    if ($local.Compare['HyperV.MigrationPerformanceOption'] -and $local.Compare['HyperV.MigrationPerformanceOption'] -ne 'Compression') { Write-Host "  Live migration performance is '$($local.Compare['HyperV.MigrationPerformanceOption'])' - Compression is the usual choice without RDMA." -ForegroundColor Yellow }
    if ($local.Compare['HyperV.VirtualMachinePath'] -notlike '*ClusterStorage*') { Write-Host "  Default VM path '$($local.Compare['HyperV.VirtualMachinePath'])' is not on a CSV - set HyperV.VirtualMachinePath/VirtualHardDiskPath to a CSV folder." -ForegroundColor Yellow }
    $script:Config = $cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json   # plan builder reads $Config
    $plan = @(Get-BaselinePlan -Fp $local)
    Write-Host "  Security/optimisation: $($plan.Count) item(s) on $env:COMPUTERNAME differ from the baseline (run -Phase Baseline to see them)."

    Write-Step 'Drift between nodes (vs this node)'
    foreach ($name in $fps.Keys) {
        if ($name -eq $env:COMPUTERNAME) { continue }
        $diff = @(Compare-Fingerprint -Peer $local -Local $fps[$name] | Where-Object { -not $_.Match -and $_.Setting -notlike 'Hotfix.*' })
        $kb   = @(Compare-Fingerprint -Peer $local -Local $fps[$name] | Where-Object { -not $_.Match -and $_.Setting -like 'Hotfix.*' })
        Write-Host ("  {0,-20} {1} setting(s) differ, {2} hotfix difference(s)" -f $name, $diff.Count, $kb.Count) -ForegroundColor $(if ($diff.Count -or $kb.Count) { 'Yellow' } else { 'Green' })
        if ($diff.Count) { $diff | Export-Csv -Path (Join-Path $LogRoot "capture-drift-$name-$Stamp.csv") -NoTypeInformation }
    }
    Write-Host "`nNext: edit $out (Agents, Hpe share paths, anything flagged above), then -Phase Baseline on each node in turn." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Baseline - plan (what differs from the config) and apply
# ---------------------------------------------------------------------------

# The value to aim for: config wins, else the peer's (Baseline on an existing node
# usually has no peer - then a null config value means "leave it alone").
function Get-Desired {
    param($ConfigValue, [string]$PeerKey)
    if ($null -ne $ConfigValue -and "$ConfigValue" -ne '') { return $ConfigValue }
    if ($script:PeerFp -and $PeerKey -and $script:PeerFp.Compare.ContainsKey($PeerKey)) { return $script:PeerFp.Compare[$PeerKey] }
    return $null
}

function New-PlanItem {
    param([string]$Area, [string]$Id, [string]$Desc, $Current, $Desired, [bool]$Restart, [string]$Kind, [hashtable]$Arguments = @{})
    [pscustomobject]@{ Area = $Area; Id = $Id; Desc = $Desc; Current = "$Current"; Desired = "$Desired"; Restart = $Restart; Kind = $Kind; Arguments = $Arguments }
}

# Everything on this host that differs from the config. Pure - reads the fingerprint only.
function Get-BaselinePlan {
    param([Parameter(Mandatory)]$Fp)
    $c = $Fp.Compare
    $sec = $Config.Security
    $opt = $Config.Optimisation
    $secOn = $sec -and $sec.Apply -ne $false
    $optOn = $opt -and $opt.Apply -ne $false
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($r in $RegCatalogue) {
        $on = switch ($r.Group) {
            'Security'                  { $secOn }
            'Security.DisableLegacyTls' { $secOn -and $sec.DisableLegacyTls -ne $false }
            'Optimisation'              { $optOn }
        }
        if (-not $on) { continue }
        $want = if ($r.Id -eq 'Sec.InactivityTimeoutSecs') { $sec.InactivityTimeoutSecs } else { $r.Value }
        if ($null -eq $want) { continue }
        $cur = "$($c[$r.Id])"
        # The inactivity lock is a maximum - a shorter lock already on the node is stricter, so keep it.
        if ($r.Id -eq 'Sec.InactivityTimeoutSecs' -and $cur -match '^\d+$' -and [int]$cur -gt 0 -and [int]$cur -le [int]$want) { continue }
        if ($cur -ne "$want") {
            $area = if ($r.Group -like 'Security*') { 'Security' } else { 'Optimisation' }
            $items.Add((New-PlanItem $area $r.Id $r.Desc $c[$r.Id] $want $r.Restart 'Registry' @{ Path = $r.Path; Name = $r.Name; Value = [int]$want }))
        }
    }

    if ($secOn) {
        if ($c['Sec.SMB1Protocol'] -eq 'True') { $items.Add((New-PlanItem 'Security' 'Sec.SMB1Protocol' 'SMBv1 protocol off' 'True' 'False' $false 'Smb1Protocol')) }
        foreach ($f in 'FS-SMB1', 'PowerShell-V2') {
            if ($c["Sec.Feature.$f"] -eq 'Installed') { $items.Add((New-PlanItem 'Security' "Sec.Feature.$f" "Remove $f" 'Installed' 'Not installed' $true 'RemoveFeature' @{ Name = $f })) }
        }
        if ($sec.RequireSmbSigning -ne $false) {
            if ($c['Sec.SmbServerSigning'] -eq 'False') { $items.Add((New-PlanItem 'Security' 'Sec.SmbServerSigning' 'SMB signing required (server)' 'False' 'True' $false 'SmbServerSigning')) }
            if ($c['Sec.SmbClientSigning'] -eq 'False') { $items.Add((New-PlanItem 'Security' 'Sec.SmbClientSigning' 'SMB signing required (client)' 'False' 'True' $false 'SmbClientSigning')) }
        }
        foreach ($p in 'Domain', 'Private', 'Public') {
            if ($c["Sec.Firewall.$p"] -eq 'False') { $items.Add((New-PlanItem 'Security' "Sec.Firewall.$p" "Firewall on ($p) - cluster/Hyper-V/WinRM/SMB/RDP rules enabled first" 'False' 'True' $false 'Firewall' @{ Profile = $p })) }
        }
        # Lockout threshold is a maximum too: a lower non-zero value (locks out sooner) is stricter.
        $lt = "$($c['Sec.LockoutThreshold'])"
        $ltOk = $lt -match '^\d+$' -and [int]$lt -gt 0 -and $null -ne $sec.LockoutThreshold -and [int]$lt -le [int]$sec.LockoutThreshold
        if ($null -ne $sec.LockoutThreshold -and -not $ltOk) {
            $items.Add((New-PlanItem 'Security' 'Sec.LockoutThreshold' 'Local account lockout threshold (15 min)' $c['Sec.LockoutThreshold'] $sec.LockoutThreshold $false 'Lockout' @{ Threshold = [int]$sec.LockoutThreshold }))
        }
        if ($c['Sec.GuestEnabled'] -eq 'True') { $items.Add((New-PlanItem 'Security' 'Sec.GuestEnabled' 'Guest account disabled' 'True' 'False' $false 'GuestDisable')) }
        if ($sec.DisablePrintSpooler -ne $false -and $c['Sec.Spooler'] -and $c['Sec.Spooler'] -notin 'Disabled', 'Absent') {
            $items.Add((New-PlanItem 'Security' 'Sec.Spooler' 'Print Spooler disabled (not needed on a Hyper-V host)' $c['Sec.Spooler'] 'Disabled' $false 'SpoolerDisable'))
        }
        # Opt-in only. Never turned OFF by the script if already running.
        if ($sec.CredentialGuard -eq $true -and $c['Sec.CredentialGuard.Running'] -ne 'True') {
            $items.Add((New-PlanItem 'Security' 'Sec.CredentialGuard' 'Credential Guard on (VBS, no UEFI lock)' 'Not running' 'Running' $true 'CredentialGuard'))
        }
        if ($sec.Hvci -eq $true -and $c['Sec.HVCI.Running'] -ne 'True') {
            $items.Add((New-PlanItem 'Security' 'Sec.HVCI' 'Memory integrity (HVCI) on - check HPE driver compatibility first' 'Not running' 'Running' $true 'Hvci'))
        }
    }

    if ($optOn) {
        if ($c['Power.ActivePlan'] -notmatch '8c5e7fda') { $items.Add((New-PlanItem 'Optimisation' 'Opt.PowerPlan' 'High Performance power plan' $c['Power.ActivePlan'] 'High performance' $false 'PowerPlan')) }
        if ($c['Opt.Hibernate'] -ne '0') { $items.Add((New-PlanItem 'Optimisation' 'Opt.Hibernate' 'Hibernation off' $c['Opt.Hibernate'] '0' $false 'Hibernate')) }
        if ($c['Opt.LastAccess'] -ne 'Disabled') { $items.Add((New-PlanItem 'Optimisation' 'Opt.LastAccess' 'NTFS last-access updates off' $c['Opt.LastAccess'] 'Disabled' $true 'LastAccess')) }
        if ($c['Opt.TelemetryTasks'] -and $c['Opt.TelemetryTasks'] -ne 'All disabled') { $items.Add((New-PlanItem 'Optimisation' 'Opt.TelemetryTasks' 'Telemetry/CEIP/Maps/WER tasks off (defrag/retrim left on)' $c['Opt.TelemetryTasks'] 'All disabled' $false 'Tasks')) }
        if ($c['Opt.NicPowerManagement'] -and $c['Opt.NicPowerManagement'] -ne 'Disabled') { $items.Add((New-PlanItem 'Optimisation' 'Opt.NicPowerManagement' 'NIC power management off (SET members)' $c['Opt.NicPowerManagement'] 'Disabled' $false 'NicPower')) }
        if ($c['Opt.VMQ'] -and $c['Opt.VMQ'] -ne 'Enabled') { $items.Add((New-PlanItem 'Optimisation' 'Opt.VMQ' 'VMQ on (SET members; adapter restarts)' $c['Opt.VMQ'] 'Enabled' $false 'Vmq')) }
    }

    # HPE BIOS workload profile (needs ilorest to read)
    $wp = $Config.Hpe.WorkloadProfile
    if ($wp -and $c.ContainsKey('HPE.Bios.WorkloadProfile') -and $c['HPE.Bios.WorkloadProfile'] -ne $wp) {
        $items.Add((New-PlanItem 'HPE' 'HPE.WorkloadProfile' 'BIOS workload profile' $c['HPE.Bios.WorkloadProfile'] $wp $true 'WorkloadProfile' @{ Target = $wp }))
    }

    # MPIO (only once the feature is in)
    if ($c['Feature.Multipath-IO'] -eq 'Installed') {
        $st = $Config.Storage
        if ($st.MpioVendorId -and $st.MpioProductId -and -not $c.ContainsKey("MPIO.SupportedHW.$($st.MpioVendorId)|$($st.MpioProductId)")) {
            $items.Add((New-PlanItem 'MPIO' 'MPIO.Claim' "MSDSM claim $($st.MpioVendorId)/$($st.MpioProductId)" 'Not claimed' 'Claimed' $true 'MpioClaim' @{ VendorId = $st.MpioVendorId; ProductId = $st.MpioProductId }))
        }
        $lb = Get-Desired $st.LoadBalancePolicy 'MPIO.GlobalLBPolicy'
        if ($lb -and "$($c['MPIO.GlobalLBPolicy'])" -ne "$lb") { $items.Add((New-PlanItem 'MPIO' 'MPIO.GlobalLBPolicy' 'Global load-balance policy' $c['MPIO.GlobalLBPolicy'] $lb $false 'MpioPolicy' @{ Policy = "$lb" })) }
        $map = [ordered]@{ PathVerificationState = 'NewPathVerificationState'; PathVerificationPeriod = 'NewPathVerificationPeriod'; PDORemovePeriod = 'NewPDORemovePeriod'; RetryCount = 'NewRetryCount'; RetryInterval = 'NewRetryInterval'; DiskTimeoutValue = 'NewDiskTimeout' }
        foreach ($k in $map.Keys) {
            $cfgVal = if ($st.MpioSettings) { $st.MpioSettings.$k } else { $null }
            $want = Get-Desired $cfgVal "MPIO.$k"
            if ($null -ne $want -and "$($c["MPIO.$k"])" -ne "$want") {
                $val = if ($k -eq 'PathVerificationState') { "$want" } else { [int]$want }
                $items.Add((New-PlanItem 'MPIO' "MPIO.$k" "MPIO $k" $c["MPIO.$k"] $want $true 'MpioSetting' @{ Parameter = $map[$k]; Value = $val }))
            }
        }
    }

    # Hyper-V host settings (only once Hyper-V is in; paths only if they exist here)
    if ($c['Feature.Hyper-V'] -eq 'Installed' -and $c.ContainsKey('HyperV.NumaSpanningEnabled')) {
        $hv = $Config.HyperV
        $hvMap = @(
            @{ Key = 'VirtualMachinePath';  Peer = 'HyperV.VirtualMachinePath';  Cfg = $hv.VirtualMachinePath;  Param = 'VirtualMachinePath';  Restart = $false; Path = $true }
            @{ Key = 'VirtualHardDiskPath'; Peer = 'HyperV.VirtualHardDiskPath'; Cfg = $hv.VirtualHardDiskPath; Param = 'VirtualHardDiskPath'; Restart = $false; Path = $true }
            @{ Key = 'MaxVMMigrations';      Peer = 'HyperV.MaximumVirtualMachineMigrations'; Cfg = $hv.MaxVMMigrations;      Param = 'MaximumVirtualMachineMigrations'; Restart = $false }
            @{ Key = 'MaxStorageMigrations'; Peer = 'HyperV.MaximumStorageMigrations';        Cfg = $hv.MaxStorageMigrations; Param = 'MaximumStorageMigrations';        Restart = $false }
            @{ Key = 'MigrationPerformance'; Peer = 'HyperV.MigrationPerformanceOption';      Cfg = $hv.MigrationPerformance; Param = 'VirtualMachineMigrationPerformanceOption'; Restart = $false }
            @{ Key = 'NumaSpanningEnabled';  Peer = 'HyperV.NumaSpanningEnabled';             Cfg = $hv.NumaSpanningEnabled;  Param = 'NumaSpanningEnabled'; Restart = $true }
        )
        foreach ($h in $hvMap) {
            $want = Get-Desired $h.Cfg $h.Peer
            if ($null -eq $want -or "$($c[$h.Peer])" -eq "$want") { continue }
            if ($h.Path -and -not (Test-Path "$want")) { Write-Host "  (skipping $($h.Key): '$want' does not exist on this node yet)" -ForegroundColor DarkGray; continue }
            $val = switch ($h.Key) {
                'NumaSpanningEnabled' { "$want" -eq 'True' }
                { $_ -like 'Max*' }   { [int]$want }
                default               { "$want" }
            }
            $items.Add((New-PlanItem 'Hyper-V' "HyperV.$($h.Key)" $h.Key $c[$h.Peer] $want $h.Restart 'VMHost' @{ Parameter = $h.Param; Value = $val }))
        }
    }
    return $items
}

# Rule groups a Hyper-V cluster node needs open before the firewall goes on. Enabled
# only where the group exists on this host.
$FirewallGroups = @('Failover Clusters', 'Hyper-V', 'Windows Remote Management', 'File and Printer Sharing', 'Windows Management Instrumentation (WMI)', '@FirewallAPI.dll,-28752')

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
        'CredentialGuard' {
            Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Value 1
            Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'RequirePlatformSecurityFeatures' -Value 1
            Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LsaCfgFlags' -Value 2   # 2 = on without UEFI lock (reversible)
        }
        'Hvci' {
            Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Value 1
            Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 1
        }
        'PowerPlan'        { Set-ArcHighPerformancePower }
        'Hibernate'        { powercfg /hibernate off | Out-Null }
        'LastAccess'       { fsutil behavior set disablelastaccess 1 | Out-Null }
        'Tasks' {
            foreach ($t in $OptTasks) {
                $task = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
                if ($task -and $task.State -ne 'Disabled') { $task | Disable-ScheduledTask | Out-Null }
            }
        }
        'NicPower' {
            foreach ($n in Get-ArcSwitchMembers) { Disable-NetAdapterPowerManagement -Name $n.Name -NoRestart -ErrorAction SilentlyContinue }
        }
        'Vmq' {
            foreach ($n in Get-ArcSwitchMembers) { if (-not (Get-NetAdapterVmq -Name $n.Name).Enabled) { Enable-NetAdapterVmq -Name $n.Name } }
        }
        'WorkloadProfile'  { Set-ArcWorkloadProfile -Target $a.Target | Out-Null }
        'MpioClaim'        { New-MSDSMSupportedHW -VendorId $a.VendorId -ProductId $a.ProductId | Out-Null }
        'MpioPolicy'       { Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy $a.Policy }
        'MpioSetting'      { $p = @{ $a.Parameter = $a.Value }; Set-MPIOSetting @p | Out-Null }
        'VMHost'           { $p = @{ $a.Parameter = $a.Value }; Set-VMHost @p }
        default            { throw "Unknown plan item kind '$($Item.Kind)'." }
    }
}

function Get-ArcSwitchMembers {
    $out = @()
    foreach ($sw in Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue) {
        try {
            $desc = @((Get-VMSwitchTeam -Name $sw.Name).NetAdapterInterfaceDescription)
            $out += @(Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -in $desc })
        } catch { }
    }
    return $out
}

function Show-Plan {
    param($Plan)
    $Plan | Sort-Object Area, Id | Format-Table Area, Desc, Current, Desired, @{ n = 'Restart'; e = { if ($_.Restart) { 'yes' } else { '' } } } -AutoSize -Wrap | Out-String -Width 220 | Write-Host
}

function Test-ArcClusterMember {
    if (-not (Get-Command Get-ClusterNode -ErrorAction SilentlyContinue)) { return $false }
    try { return [bool](Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction Stop) } catch { return $false }
}

# Health gate before draining a live node. Hard blockers throw; softer problems
# (capacity, failed resources, witness) need the engineer to type DRAIN.
function Assert-ArcClusterHealthyForDrain {
    Write-Step 'Cluster health before drain'
    $others = @(Get-ClusterNode | Where-Object Name -ne $env:COMPUTERNAME)
    if (-not $others) { throw 'Single-node cluster - there is nowhere to drain to. Apply in a maintenance window instead.' }
    $down = @($others | Where-Object { "$($_.State)" -ne 'Up' })
    if ($down) { throw "Other node(s) not Up: $(($down | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ', '). Fix before draining this one." }
    Write-Host "  Other nodes Up: $($others.Name -join ', ')" -ForegroundColor Green

    $soft = @()
    $csv = @(Get-ClusterSharedVolume -ErrorAction SilentlyContinue | Where-Object { "$($_.State)" -ne 'Online' })
    if ($csv) { $soft += "CSV(s) not Online: $($csv.Name -join ', ')" }
    $failed = @(Get-ClusterResource | Where-Object { "$($_.State)" -eq 'Failed' })
    if ($failed) { $soft += "Failed cluster resource(s): $($failed.Name -join ', ')" }
    $q = Get-ClusterQuorum
    if ($q.QuorumResource) {
        if ("$($q.QuorumResource.State)" -ne 'Online') { $soft += "Quorum witness '$($q.QuorumResource.Name)' is $($q.QuorumResource.State)" }
    } elseif (($others.Count + 1) -eq 2) { $soft += 'Two-node cluster with NO witness - losing a node during this work could lose quorum' }

    # Capacity: memory of running VMs here vs free memory on the other Up nodes
    $need = [double](@(Get-VM | Where-Object State -eq 'Running') | Measure-Object -Property MemoryAssigned -Sum).Sum
    $free = 0.0
    foreach ($o in $others) {
        try { $free += [double](Get-CimInstance Win32_OperatingSystem -ComputerName $o.Name -ErrorAction Stop).FreePhysicalMemory * 1KB }
        catch { $soft += "Could not read free memory on $($o.Name)" }
    }
    Write-Host ("  Running VM memory here: {0:N0} GB; free on other nodes: {1:N0} GB" -f ($need / 1GB), ($free / 1GB))
    if ($need -gt ($free * 0.9)) { $soft += 'The other nodes may not have enough free memory for every VM on this node - some may fail to move (they stay here)' }

    if ($soft) {
        $soft | ForEach-Object { Write-Warning $_ }
        $answer = Read-Host '  Type DRAIN to drain anyway (anything else stops)'
        if ($answer -cne 'DRAIN') { throw 'Stopped by engineer before drain.' }
    } else { Write-Host '  CSVs online, no failed resources, witness online, capacity OK.' -ForegroundColor Green }
}

function Invoke-ArcDrain {
    Write-Step "Draining $env:COMPUTERNAME"
    Suspend-ClusterNode -Name $env:COMPUTERNAME -Drain -Wait -ErrorAction Stop | Out-Null
    $n = Get-ClusterNode -Name $env:COMPUTERNAME
    if ("$($n.DrainStatus)" -ne 'Completed') {
        $left = @(Get-ClusterGroup | Where-Object { $_.OwnerNode.Name -eq $env:COMPUTERNAME -and "$($_.GroupType)" -eq 'VirtualMachine' })
        throw "Drain did not complete (status $($n.DrainStatus)). Still on this node: $($left.Name -join ', '). Node is paused - move those by hand, or run -Phase Resume to undo."
    }
    Write-Host '  Drain completed - node is paused with no VMs.' -ForegroundColor Green
}

function Invoke-Baseline {
    $local = Get-LocalFingerprint
    $script:PeerFp = $null
    if ($PeerParams) { try { $script:PeerFp = Get-PeerFingerprint } catch { Write-Warning "$($_.Exception.Message) - null config values will be left alone." } }

    Write-Step "Baseline plan for $env:COMPUTERNAME"
    $plan = @(Get-BaselinePlan -Fp $local)
    if (-not $plan) {
        Write-Host '  Nothing to change - this node matches the baseline.' -ForegroundColor Green
        Save-PhaseComplete 'Baseline'
        return
    }
    Show-Plan $plan
    $restart = [bool]($plan | Where-Object Restart)
    $member = Test-ArcClusterMember
    if ($member) { Write-Host "  $env:COMPUTERNAME is a cluster member - it will be health-checked and DRAINED before any change." -ForegroundColor Yellow }
    if (-not (Confirm-Action "Apply these $($plan.Count) change(s)")) { throw 'Stopped by engineer - nothing changed.' }

    if ($member) {
        Assert-ArcClusterHealthyForDrain
        Invoke-ArcDrain
        $state = Get-State
        $state | Add-Member -NotePropertyName Drained -NotePropertyValue $true -Force
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
    }

    Write-Step 'Applying'
    $failed = @()
    foreach ($i in ($plan | Sort-Object Area, Id)) {
        try { Invoke-PlanItem $i; Write-Host "  OK   $($i.Desc)" -ForegroundColor Green }
        catch { $failed += $i; Write-Host "  FAIL $($i.Desc) - $($_.Exception.Message)" -ForegroundColor Red }
    }

    # What still differs: restart-pending items, failures, or values GPO sets differently.
    # Registry values read back as soon as they're written (only their effect waits for
    # the reboot), so they're always re-checked - Set-RegistryValue warns rather than throws.
    $after = @(Get-BaselinePlan -Fp (Get-LocalFingerprint) | Where-Object { -not $_.Restart -or $_.Kind -eq 'Registry' })
    if ($after) {
        Write-Host "`n  Still different after applying (a domain GPO may be setting these - GPO wins; fix it there):" -ForegroundColor Yellow
        Show-Plan $after
    }

    Save-PhaseComplete 'Baseline' $restart
    if ($member) {
        $s = Get-State; $s | Add-Member -NotePropertyName Drained -NotePropertyValue $true -Force
        $s | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
        if ($restart) { Write-Host "`nNode is DRAINED. REBOOT it now, then run -Phase Resume to bring it back into the cluster." -ForegroundColor Yellow }
        elseif (Confirm-Action 'No reboot needed. Resume the node into the cluster now') { Invoke-Resume }
        else { Write-Host "`nNode left paused. Run -Phase Resume when ready." -ForegroundColor Yellow }
    } elseif ($restart) { Write-Host "`nREBOOT REQUIRED (not a cluster member, no drain needed). Then continue with -Phase Join." -ForegroundColor Yellow }
    else { Write-Host "`nNext: -Phase Join (new node) - or nothing more for this node." -ForegroundColor Green }
    if ($failed) { Write-Warning "$($failed.Count) item(s) failed - see above. Re-run -Phase Baseline after fixing." }
}

# ---------------------------------------------------------------------------
# Phase: Resume - after a Baseline reboot
# ---------------------------------------------------------------------------

function Invoke-Resume {
    $state = Get-State
    if ($state.RebootPending -and $state.RebootRequestedAt) {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($boot -lt [datetime]$state.RebootRequestedAt -and -not (Confirm-Action 'Baseline asked for a reboot and the node has not rebooted since. Resume anyway')) { throw 'Stopped - reboot first.' }
    }
    $n = Get-ClusterNode -Name $env:COMPUTERNAME
    Write-Host "  Node state: $($n.State)"
    if ("$($n.State)" -eq 'Up') { Write-Host '  Already Up - nothing to resume.' -ForegroundColor Green }
    else {
        if ((Get-Service ClusSvc).Status -ne 'Running') { throw 'Cluster service is not running on this node.' }
        # Baseline may have just switched the firewall on - prove cluster traffic still flows
        # on every network before VMs come back.
        $ifs = @(Get-ClusterNetworkInterface -Node $env:COMPUTERNAME)
        $ifs | Format-Table Name, Network, State -AutoSize | Out-String | Write-Host
        $bad = @($ifs | Where-Object { "$($_.State)" -ne 'Up' })
        if ($bad) { throw "Cluster network interface(s) not Up: $(($bad | ForEach-Object { "$($_.Network)=$($_.State)" }) -join ', '). Check the firewall rules / cabling before resuming - the node stays paused." }
        $failback = if (Confirm-Action 'Move the VMs that were drained off this node back now') { 'Immediate' } else { 'NoFailback' }
        Resume-ClusterNode -Name $env:COMPUTERNAME -Failback $failback | Out-Null
        Write-Host "  Resumed ($failback)." -ForegroundColor Green
    }
    $s = Get-State
    $s | Add-Member -NotePropertyName Drained -NotePropertyValue $false -Force
    $s | Add-Member -NotePropertyName RebootPending -NotePropertyValue $false -Force
    $s | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8

    $left = @(Get-BaselinePlan -Fp (Get-LocalFingerprint))
    if ($left) { Write-Host "`n  $($left.Count) baseline item(s) still differ:" -ForegroundColor Yellow; Show-Plan $left }
    else { Write-Host '  Node matches the baseline.' -ForegroundColor Green }
    Write-Host "`nNext: -Phase Baseline on the next node." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Phase: ClusterBaseline - cluster-wide settings, run once
# ---------------------------------------------------------------------------

function ConvertTo-PrefixLength {
    param([string]$Mask)
    $bits = 0
    foreach ($o in $Mask.Split('.')) { $bits += ([Convert]::ToString([int]$o, 2) -replace '0', '').Length }
    return $bits
}

function Invoke-ClusterBaseline {
    Import-Module FailoverClusters
    $cl = Get-Cluster -Name $Config.ClusterName
    $nets = @(Get-ClusterNetwork -Cluster $cl.Name)
    $changes = New-Object System.Collections.Generic.List[object]

    Write-Step 'Cluster networks (matched to HostNetworks by subnet)'
    $roleMap = @{ ClusterAndClient = 3; Cluster = 1 }
    $matched = @{}
    # Networks carrying a cluster IP Address resource (the cluster name, or a role's
    # client access point) must stay ClusterAndClient - otherwise that IP fails and
    # the name drops off the network.
    $ipNets = @{}
    foreach ($res in @(Get-ClusterResource -Cluster $cl.Name | Where-Object { "$($_.ResourceType)" -like 'IP Address' })) {
        try {
            $addr = ($res | Get-ClusterParameter -Name Address -ErrorAction Stop).Value
            foreach ($n in $nets) {
                $pl = ConvertTo-PrefixLength $n.AddressMask
                if ((Get-SubnetKey $addr $pl) -eq "$($n.Address)/$pl") { $ipNets[$n.Id] = "$($res.Name) ($addr)" }
            }
        } catch { Write-Warning "Could not read the address of IP resource '$($res.Name)' - role changes will be refused on every network to be safe."; $ipNets['*'] = $res.Name }
    }
    foreach ($hn in $Config.HostNetworks) {
        $ip = $null
        foreach ($np in $Config.Nodes.PSObject.Properties) { $v = $np.Value.IPs.PSObject.Properties[$hn.Role]; if ($v) { $ip = $v.Value; break } }
        if (-not $ip) { Write-Warning "No node IP for role '$($hn.Role)' - cannot match it to a cluster network."; continue }
        $sub = Get-SubnetKey $ip ([int]$hn.PrefixLength)
        $net = $nets | Where-Object { "$($_.Address)/$(ConvertTo-PrefixLength $_.AddressMask)" -eq $sub } | Select-Object -First 1
        if (-not $net) { Write-Warning "No cluster network on $sub for role '$($hn.Role)'."; continue }
        $matched[$hn.Role] = $net
        $wantRole = if ($hn.ClusterRole) { "$($hn.ClusterRole)" } elseif ($hn.Gateway) { 'ClusterAndClient' } else { 'Cluster' }
        if ($wantRole -notin $roleMap.Keys) { throw "HostNetworks '$($hn.Role)': ClusterRole must be ClusterAndClient or Cluster ('None' would stop heartbeats on it)." }
        Write-Host ("  {0,-16} {1,-18} name '{2}' role {3}" -f $hn.Role, $sub, $net.Name, $net.Role)
        if ($net.Name -ne $hn.Role) { $changes.Add([pscustomobject]@{ Desc = "Rename cluster network '$($net.Name)' ($sub) to '$($hn.Role)'"; Kind = 'NetName'; Net = $net; Value = $hn.Role }) }
        if ([int]$net.Role -ne $roleMap[$wantRole]) {
            $carrier = if ($ipNets.ContainsKey('*')) { $ipNets['*'] } else { $ipNets[$net.Id] }
            if ($wantRole -ne 'ClusterAndClient' -and $carrier) {
                Add-Result WARN "Role change refused: $($hn.Role)" "$sub carries cluster IP resource $carrier - it must stay ClusterAndClient. Check ClusterRole/Gateway for this role in the config."
            } else {
                $changes.Add([pscustomobject]@{ Desc = "Cluster network $sub role $($net.Role) -> $wantRole"; Kind = 'NetRole'; Net = $net; Value = $roleMap[$wantRole] })
            }
        }
    }
    foreach ($n in $nets | Where-Object { $_.Id -notin @($matched.Values.Id) }) { Write-Warning "Cluster network '$($n.Name)' ($($n.Address)) matches no HostNetworks role - left alone." }

    Write-Step 'Live migration networks'
    $lm = @($Config.Cluster.LiveMigrationNetworks | Where-Object { $_ })
    $order = @($lm | Where-Object { $matched[$_] } | ForEach-Object { $matched[$_].Id })
    $unmatched = @($lm | Where-Object { -not $matched[$_] })
    if ($unmatched) { Add-Result WARN 'Live migration networks' "Not matched to a cluster network: $($unmatched -join ', ')" }
    # Guard: never leave live migration with no allowed network - every drain would fail.
    if ($lm -and -not $order) {
        Add-Result WARN 'Live migration networks' 'None of Cluster.LiveMigrationNetworks matched a cluster network - live migration settings left unchanged.'
    } elseif ($lm) {
        $lm = @($lm | Where-Object { $matched[$_] })
        $exclude = @($nets | Where-Object { $_.Id -notin $order } | ForEach-Object Id)
        if ($exclude.Count -ge $nets.Count) { throw 'Internal check failed: the live migration exclusion list would cover every cluster network.' }
        $rt = Get-ClusterResourceType -Cluster $cl.Name -Name 'Virtual Machine'
        $curOrder   = "$(($rt | Get-ClusterParameter -Name MigrationNetworkOrder -ErrorAction SilentlyContinue).Value)"
        $curExclude = "$(($rt | Get-ClusterParameter -Name MigrationExcludeNetworks -ErrorAction SilentlyContinue).Value)"
        $wantOrder = $order -join ';'; $wantExclude = $exclude -join ';'
        Write-Host "  Wanted order: $($lm -join ' > '); excluded: $((($nets | Where-Object { $_.Id -in $exclude }).Name) -join ', ')"
        if ($order -and $curOrder -ne $wantOrder) { $changes.Add([pscustomobject]@{ Desc = "Live migration network order: $($lm -join ' > ')"; Kind = 'LmOrder'; Value = $wantOrder }) }
        if ($curExclude -ne $wantExclude) { $changes.Add([pscustomobject]@{ Desc = "Live migration excluded networks: $((($nets | Where-Object { $_.Id -in $exclude }).Name) -join ', ')"; Kind = 'LmExclude'; Value = $wantExclude }) }
    }

    Write-Step 'Cluster properties'
    $cc = $Config.Cluster
    if ($cc.DrainOnShutdown -ne $false -and [int]$cl.DrainOnShutdown -ne 1) { $changes.Add([pscustomobject]@{ Desc = 'DrainOnShutdown on (VMs live-migrate off a node that is shut down)'; Kind = 'ClusterProp'; Name = 'DrainOnShutdown'; Value = 1 }) }
    if ($null -ne $cc.BlockCacheSizeMB -and [int]$cl.BlockCacheSize -ne [int]$cc.BlockCacheSizeMB) { $changes.Add([pscustomobject]@{ Desc = "CSV block cache $($cl.BlockCacheSize) MB -> $($cc.BlockCacheSizeMB) MB"; Kind = 'ClusterProp'; Name = 'BlockCacheSize'; Value = [int]$cc.BlockCacheSizeMB }) }
    if ($null -ne $cc.SecurityLevel -and [int]$cl.SecurityLevel -ne [int]$cc.SecurityLevel) { $changes.Add([pscustomobject]@{ Desc = "Intra-cluster traffic security level $($cl.SecurityLevel) -> $($cc.SecurityLevel) (0 clear, 1 signed, 2 encrypted)"; Kind = 'ClusterProp'; Name = 'SecurityLevel'; Value = [int]$cc.SecurityLevel }) }
    Write-Host "  DrainOnShutdown=$($cl.DrainOnShutdown)  BlockCacheSize=$($cl.BlockCacheSize) MB  SecurityLevel=$($cl.SecurityLevel)  FunctionalLevel=$($cl.ClusterFunctionalLevel)"

    Write-Step 'Report only'
    $q = Get-ClusterQuorum -Cluster $cl.Name
    if ($q.QuorumResource) { Add-Result PASS 'Quorum witness' "$($q.QuorumType): $($q.QuorumResource.Name) ($($q.QuorumResource.State))" }
    else { Add-Result WARN 'Quorum witness' "$($q.QuorumType) with no witness - add a file share or cloud witness (critical on a 2-node cluster)" }
    try {
        Import-Module ClusterAwareUpdating -ErrorAction Stop
        $cau = Get-CauClusterRole -ClusterName $cl.Name -ErrorAction Stop
        Add-Result PASS 'Cluster-Aware Updating' 'Self-updating role configured'
    } catch { Add-Result INFO 'Cluster-Aware Updating' 'No self-updating CAU role (fine if patching is done another way)' }
    foreach ($n in Get-ClusterNode -Cluster $cl.Name) { Add-Result $(if ("$($n.State)" -eq 'Up') { 'PASS' } else { 'WARN' }) "Node $($n.Name)" "$($n.State)" }

    if (-not $changes.Count) { Write-Host "`n  Cluster settings already match." -ForegroundColor Green; Save-PhaseComplete 'ClusterBaseline'; return }
    Write-Step 'Planned cluster changes (live, no node restarts)'
    $changes | ForEach-Object { Write-Host "  - $($_.Desc)" }
    if (-not (Confirm-Action "Apply these $($changes.Count) cluster change(s)")) { throw 'Stopped by engineer - nothing changed.' }
    foreach ($ch in $changes) {
        try {
            switch ($ch.Kind) {
                'NetName'     { $ch.Net.Name = $ch.Value }
                'NetRole'     { $ch.Net.Role = $ch.Value }
                'LmOrder'     { Get-ClusterResourceType -Cluster $cl.Name -Name 'Virtual Machine' | Set-ClusterParameter -Name MigrationNetworkOrder -Value $ch.Value }
                'LmExclude'   { Get-ClusterResourceType -Cluster $cl.Name -Name 'Virtual Machine' | Set-ClusterParameter -Name MigrationExcludeNetworks -Value $ch.Value }
                'ClusterProp' { (Get-Cluster -Name $cl.Name).($ch.Name) = $ch.Value }
            }
            Write-Host "  OK   $($ch.Desc)" -ForegroundColor Green
        } catch { Write-Host "  FAIL $($ch.Desc) - $($_.Exception.Message)" -ForegroundColor Red }
    }
    Save-PhaseComplete 'ClusterBaseline'
}

# ---------------------------------------------------------------------------
# Phase: Next - attended automation. Works out where this host is from
# state.json, runs phases back to back, stops at the human gates, asks before
# every reboot, and resumes at the engineer's next logon (no auto-logon, no
# stored password).
# ---------------------------------------------------------------------------

$NextTaskName = 'ArcHyperVClusterNext'

# Is this process in the physical/iLO console session? $env:SESSIONNAME isn't
# reliable when launched from a scheduled task, so compare session IDs.
function Test-ArcConsoleSession {
    if ($env:SESSIONNAME -like 'RDP-*') { return $false }
    $mine = (Get-Process -Id $PID).SessionId
    $ErrorActionPreference = 'Continue'
    $q = qwinsta 2>&1 | ForEach-Object { "$_" } | Out-String
    if ($q -match '(?m)^\s*>?console\s+(?:\S+\s+)?(\d+)\s') { return ([int]$Matches[1] -eq $mine) }
    return ($env:SESSIONNAME -eq 'Console')
}

function Request-ArcReboot {
    param([string]$Reason = 'The last phase needs a reboot.')
    Write-Host "`n$Reason" -ForegroundColor Yellow
    $scriptPath = $PSCommandPath
    if ($scriptPath -and (Test-Path $scriptPath)) {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$scriptPath`" -Phase Next"
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
        Register-ScheduledTask -TaskName $NextTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "  After the reboot, log on as $user - the next phase starts by itself (one-shot task '$NextTaskName')." -ForegroundColor Cyan
    } else {
        Write-Host '  (No script file on disk - after the reboot, run -Phase Next yourself.)' -ForegroundColor Yellow
    }
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

function Invoke-Next {
    Unregister-ScheduledTask -TaskName $NextTaskName -Confirm:$false -ErrorAction SilentlyContinue

    # A reboot was asked for and declined last time - don't carry on as if it happened.
    $state = Get-State
    if ($state.RebootPending -and $state.PSObject.Properties['RebootRequestedAt'] -and $state.RebootRequestedAt) {
        if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -lt [datetime]$state.RebootRequestedAt) {
            Request-ArcReboot "A reboot requested at $($state.RebootRequestedAt) hasn't happened yet."
            return
        }
    }

    # Existing cluster node (not one this script joined): Baseline -> reboot -> Resume.
    $state = Get-State
    $joinedHere = [bool]$state.Phases.PSObject.Properties['Join']
    if ((Test-ArcClusterMember) -and -not $joinedHere) {
        Write-Step "$env:COMPUTERNAME is an existing cluster node - baseline workflow"
        if ($state.PSObject.Properties['Drained'] -and $state.Drained -eq $true) {
            Invoke-Resume
            Write-Host "`nThis node is done. Next: -Phase Next on the next node; -Phase ClusterBaseline once, after all nodes." -ForegroundColor Green
        } else {
            Invoke-Baseline
            $s = Get-State
            if ($s.PSObject.Properties['Drained'] -and $s.Drained -eq $true -and $s.RebootPending) { Request-ArcReboot 'Baseline applied; the node is drained and needs a reboot. Resume runs after it.' }
        }
        return
    }

    # New node: the onboarding sequence. Keys are phase records in state.json.
    if (-not $PeerParams) { throw "PeerNode must be set in the settings for the new-node workflow." }
    $steps = 'PreFlight', 'Hpe', 'PreFlightPostHpe', 'Base', 'Network', 'StorageVerified', 'AgentsVerified', 'Baseline', 'Join', 'HyperV', 'Report'
    while ($true) {
        $state = Get-State
        $step = $steps | Where-Object { -not $state.Phases.PSObject.Properties[$_] } | Select-Object -First 1
        if (-not $step) { Write-Host "`nOnboarding complete for $env:COMPUTERNAME - all phases recorded." -ForegroundColor Green; return }
        Write-Host "`n################ Next: $step ################" -ForegroundColor Magenta
        $script:Results.Clear()

        switch ($step) {
            'PreFlight' {
                Invoke-PreFlight
                if (-not $NodeConfig) { Stop-Next "Add $env:COMPUTERNAME to Nodes in the settings file: AdapterMacs (from the NIC list above) and an IP per role."; return }
                if (@($script:Results | Where-Object Status -eq 'FAIL').Count) { Stop-Next 'Fix the FAIL items above.'; return }
                Save-PhaseComplete 'PreFlight'
            }
            'Hpe' { Invoke-Hpe }
            'PreFlightPostHpe' {
                Invoke-PreFlight
                if (@($script:Results | Where-Object Status -eq 'FAIL').Count) { Stop-Next 'Fix the FAIL items above (post-SPP check).'; return }
                Write-Host "`n  Review any firmware/driver WARNs above - continuing in 10 seconds (Ctrl+C to stop)." -ForegroundColor Yellow
                Start-Sleep -Seconds 10
                Save-PhaseComplete 'PreFlightPostHpe'
            }
            'Base' { Invoke-Base }
            'Network' {
                if (-not $NodeConfig) { Stop-Next "Add $env:COMPUTERNAME to Nodes in the settings file."; return }
                if (-not (Test-ArcConsoleSession) -and -not $AllowRemoteSession) { Stop-Next 'Log on at the iLO remote console (not RDP) - building the vSwitch drops remote sessions.'; return }
                Invoke-Network
            }
            'StorageVerified' {
                Invoke-Storage
                if ((Get-State).RebootPending) { break }
                if ($script:StorageMissing -gt 0) { Stop-Next "Zone the WWPNs above and present the cluster LUNs to this host on the 3PAR/Primera (persona 15) - $($script:StorageMissing) LUN(s) not visible yet."; return }
                Save-PhaseComplete 'StorageVerified'
            }
            'AgentsVerified' {
                Invoke-Agents
                if ((Get-State).RebootPending) { break }
                $wantRemoved = $Config.Agents.Sentinel.RemoveDefender -ne $false
                if ($wantRemoved -and (Get-WindowsFeature Windows-Defender).Installed) { Stop-Next 'Defender is still installed - confirm the host shows as connected in the SentinelOne console and answer yes to the removal.'; return }
                Save-PhaseComplete 'AgentsVerified'
            }
            'Baseline' { Invoke-Baseline }
            'Join'     { Invoke-Join }
            'HyperV'   { Invoke-HyperV }
            'Report'   { Invoke-Report; Save-PhaseComplete 'Report' }
        }

        if ((Get-State).RebootPending) { Request-ArcReboot; return }
    }
}

# ---------------------------------------------------------------------------
# Phase: Report
# ---------------------------------------------------------------------------

function Invoke-Report {
    Write-Step "Final comparison against $($Config.PeerNode)"
    $peer  = Get-PeerFingerprint
    $local = Get-LocalFingerprint
    Export-Diff (Compare-Fingerprint -Peer $peer -Local $local) 'report'

    Write-Step 'Cluster membership'
    try {
        $n = Get-ClusterNode -Cluster $Config.ClusterName -Name $env:COMPUTERNAME
        if ($n.State -eq 'Up') { Add-Result PASS 'Cluster node Up' $Config.ClusterName } else { Add-Result FAIL 'Cluster node Up' "$($n.State)" }
    } catch { Add-Result FAIL 'Cluster membership' $_.Exception.Message }

    if ($local.Compare['Feature.Windows-Defender'] -eq 'Installed' -and $local.Compare['Service.SentinelAgent'] -eq 'Present') { Add-Result WARN 'Defender + Sentinel both installed' 'Remove Defender (-Phase Agents)' }
    if ($local.Compare['Service.SentinelAgent'] -ne 'Present') { Add-Result FAIL 'SentinelOne' 'Not installed' } else { Add-Result PASS 'SentinelOne' 'Installed' }
    if ($local.Compare['Service.DattoCagService'] -ne 'Present') { Add-Result WARN 'Datto RMM agent' 'Not installed' } else { Add-Result PASS 'Datto RMM agent' 'Installed' }

    $state = Get-State
    $script:PeerFp = $peer
    $left = @(Get-BaselinePlan -Fp $local)
    if ($left) { Add-Result WARN 'Baseline' "$($left.Count) item(s) differ from the config - run -Phase Baseline"; Show-Plan $left }
    else { Add-Result PASS 'Baseline' 'Security, optimisation, BIOS, MPIO and Hyper-V settings match the config' }

    foreach ($p in 'PreFlight', 'Hpe', 'Base', 'Network', 'Storage', 'Agents', 'Baseline', 'Join', 'HyperV') {
        $e = $state.Phases.PSObject.Properties[$p]
        if ($e) { Add-Result INFO "Phase $p" "completed $($e.Value.Completed) (v$($e.Value.Version))" } else { Add-Result WARN "Phase $p" 'not recorded' }
    }
    Write-Host "`n  Suggested final test: live-migrate a non-critical VM onto and off this node." -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Import-ArcConfig
    switch ($Phase) {
        'Next'            { Invoke-Next }
        'Capture'         { Invoke-Capture }
        'Baseline'        { Invoke-Baseline }
        'Resume'          { Invoke-Resume }
        'ClusterBaseline' { Invoke-ClusterBaseline }
        'PreFlight' { Invoke-PreFlight; Save-PhaseComplete 'PreFlight' }
        'Hpe'       { Invoke-Hpe }
        'Base'      { Invoke-Base }
        'Network'   { Invoke-Network }
        'Storage'   { Invoke-Storage }
        'Agents'    { Invoke-Agents }
        'Join'      { Invoke-Join }
        'HyperV'    { Invoke-HyperV }
        'Report'    { Invoke-Report }
    }
    if ($script:Results.Count) {
        $fails = @($script:Results | Where-Object Status -eq 'FAIL').Count
        $warns = @($script:Results | Where-Object Status -eq 'WARN').Count
        Write-Host "`nSummary: $fails FAIL, $warns WARN." -ForegroundColor $(if ($fails) { 'Red' } elseif ($warns) { 'Yellow' } else { 'Green' })
        $script:Results | Export-Csv -Path (Join-Path $LogRoot "$Phase-checks-$Stamp.csv") -NoTypeInformation
        if ($Phase -eq 'PreFlight' -and $fails) { Write-Host 'Fix the FAIL items before -Phase Base.' -ForegroundColor Red }
    }
} catch {
    Write-Host "`nPHASE $Phase STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
