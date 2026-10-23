<#
.SYNOPSIS
  After migration: removes VMware Tools from a Windows VM now running on Hyper-V,
  and checks the VM against its pre-migration capture.
  Arc Systems - VMware to Hyper-V migrations. Version 2.0

.DESCRIPTION
  Refuses to run unless the VM is on Hyper-V.

  Why v2.0: the VMware Tools uninstaller runs a hardware check (VM_CheckRequirements)
  that fails on any non-VMware hypervisor, so a normal uninstall rolls back with
  error 1603 (Broadcom KB 414772). This version:
    1. finds the cached VMware Tools installer Windows uses for the uninstall
       (C:\Windows\Installer\*.msi) and backs it up to C:\ProgramData\Arc\Migration
    2. disables only the VMware-only steps in it, by setting their condition to 0:
       VM_CheckRequirements, VM_LogStart, VM_UninstGHIRestGuestHandle
    3. runs the normal silent uninstall with a full log
    4. if the uninstall fails, puts the original cached installer back
  Then reports, without changing anything: VMware entries and services remaining,
  Hyper-V integration services, network adapters compared with the pre-migration
  capture, offline disks, missing drive letters and old VMware network devices.
  Does not restart the VM unless -Restart is given.

  -Inspect   Read-only. Shows the cached installer and the VMware steps that would
             be disabled, then stops. Changes nothing.

.EXAMPLE
  One-liner: paste as a single line into an elevated Windows PowerShell. It saves the script to
  C:\ProgramData\Arc\Migration and runs it. Do not use irm | iex: exit would close the window and
  switches can't be passed. Drop -Inspect (or use -Restart) for the real run. Needs internet on
  the VM; if the move lost its network, copy the script to the VM and run it as below instead.

  [Net.ServicePointManager]::SecurityProtocol='Tls12'; $p="$env:ProgramData\Arc\Migration\Remove-VMwareTools.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/vmware-migration/Remove-VMwareTools.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Inspect

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\Remove-VMwareTools.ps1 -Inspect
  powershell.exe -ExecutionPolicy Bypass -File .\Remove-VMwareTools.ps1
  powershell.exe -ExecutionPolicy Bypass -File .\Remove-VMwareTools.ps1 -Restart
#>
[CmdletBinding()]
param([switch]$Restart, [switch]$Inspect)

$ErrorActionPreference = 'Stop'
$outDir = 'C:\ProgramData\Arc\Migration'
$preFile = Join-Path $outDir 'pre-migration.json'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$warnings = @()

# Must be elevated
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'STOP - run this in Windows PowerShell as administrator. Nothing changed.' -ForegroundColor Red
    exit 1
}

# Must be on Hyper-V
$cs = Get-CimInstance Win32_ComputerSystem
if (-not ($cs.Manufacturer -eq 'Microsoft Corporation' -and $cs.Model -eq 'Virtual Machine')) {
    Write-Host "STOP - this script is for use after migration, on Hyper-V. This VM reports: $($cs.Manufacturer) / $($cs.Model). Nothing changed." -ForegroundColor Red
    exit 1
}
"Computer : $env:COMPUTERNAME"
"Platform : Hyper-V"

$pre = $null
if (Test-Path $preFile) {
    $pre = Get-Content $preFile -Raw | ConvertFrom-Json
    "Pre-migration capture found, taken $($pre.CapturedAt)"
} else {
    $warnings += "No pre-migration capture at $preFile - network and drive checks below cannot be compared."
}
""

# ---------------- Windows Installer helpers (COM) ----------------
function Invoke-Com($obj, [string]$member, [string]$kind, [object[]]$args2) {
    $flags = [System.Reflection.BindingFlags]::$kind
    return $obj.GetType().InvokeMember($member, $flags, $null, $obj, $args2)
}
function Get-MsiRows($db, [string]$sql, [int]$cols) {
    $view = Invoke-Com $db 'OpenView' 'InvokeMethod' @($sql)
    [void](Invoke-Com $view 'Execute' 'InvokeMethod' $null)
    $rows = @()
    while ($true) {
        $rec = Invoke-Com $view 'Fetch' 'InvokeMethod' $null
        if ($null -eq $rec) { break }
        $vals = @(); for ($c = 1; $c -le $cols; $c++) { $vals += (Invoke-Com $rec 'StringData' 'GetProperty' @($c)) }
        $rows += ,$vals
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
    }
    [void](Invoke-Com $view 'Close' 'InvokeMethod' $null)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
    return ,$rows
}
function Invoke-MsiSql($db, [string]$sql) {
    $view = Invoke-Com $db 'OpenView' 'InvokeMethod' @($sql)
    [void](Invoke-Com $view 'Execute' 'InvokeMethod' $null)
    [void](Invoke-Com $view 'Close' 'InvokeMethod' $null)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
}
$vmActions = 'VM_CheckRequirements', 'VM_LogStart', 'VM_UninstGHIRestGuestHandle'
$seqTables = 'InstallExecuteSequence', 'InstallUISequence', 'AdminExecuteSequence', 'AdminUISequence', 'AdvtExecuteSequence'

# Returns the sequence rows for the VMware-only actions: Table, Action, Condition, Sequence
function Get-VMwareSequenceRows($db) {
    $tables = @((Get-MsiRows $db "SELECT ``Name`` FROM ``_Tables``" 1) | ForEach-Object { $_[0] })
    $found = @()
    foreach ($t in $seqTables) {
        if ($tables -notcontains $t) { continue }
        foreach ($r in (Get-MsiRows $db "SELECT ``Action``, ``Condition``, ``Sequence`` FROM ``$t``" 3)) {
            if ($vmActions -contains $r[0]) {
                $found += [pscustomobject]@{ Table = $t; Action = $r[0]; Condition = $r[1]; Sequence = $r[2] }
            }
        }
    }
    return ,$found
}

# ---------------- Uninstall VMware Tools ----------------
$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$entries = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'VMware Tools' })

$rc = $null
if ($entries.Count -eq 0) {
    'VMware Tools is not installed - nothing to uninstall.'
}
elseif ($entries.Count -gt 1) {
    Write-Host 'STOP - more than one VMware Tools entry found. Nothing changed. Entries:' -ForegroundColor Red
    $entries | Format-List DisplayName, DisplayVersion, PSChildName, InstallLocation
    exit 1
}
else {
    $code = $entries[0].PSChildName
    if ($code -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        Write-Host "STOP - '$code' is not an MSI product code. Nothing changed." -ForegroundColor Red
        exit 1
    }
    "Found VMware Tools $($entries[0].DisplayVersion), product code $code"

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $cached = Invoke-Com $installer 'ProductInfo' 'GetProperty' @($code, 'LocalPackage')
    if (-not $cached -or -not (Test-Path $cached)) {
        Write-Host "STOP - the cached VMware Tools installer could not be found ('$cached'). Nothing changed." -ForegroundColor Red
        exit 1
    }
    "Cached installer: $cached ($([math]::Round((Get-Item $cached).Length / 1MB, 1)) MB)"

    # Read-only look at the VMware-only steps
    $dbRO = Invoke-Com $installer 'OpenDatabase' 'InvokeMethod' @($cached, 0)
    $rows = Get-VMwareSequenceRows $dbRO
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($dbRO); $dbRO = $null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    ""
    "=== VMware-only steps in the cached installer ==="
    if ($rows.Count) { $rows | Format-Table -AutoSize } else { 'None found' }
    $toDisable = @($rows | Where-Object { $_.Condition -ne '0' })

    if ($Inspect) {
        ""
        if ($toDisable.Count) { "Inspect only: $($toDisable.Count) step(s) above would be disabled (condition set to 0). Nothing changed." }
        else { "Inspect only: no VMware-only steps need disabling. Nothing changed." }
        exit 0
    }

    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    $backup = Join-Path $outDir ("{0}-{1}.original" -f (Split-Path $cached -Leaf), $stamp)
    Copy-Item -Path $cached -Destination $backup
    if ((Get-FileHash $cached).Hash -ne (Get-FileHash $backup).Hash) {
        Write-Host "STOP - backup of the cached installer does not match the original. Nothing changed. Backup: $backup" -ForegroundColor Red
        exit 1
    }
    "Backed up cached installer to $backup"

    if ($toDisable.Count) {
        $item = Get-Item $cached
        $wasReadOnly = $item.IsReadOnly
        if ($wasReadOnly) { $item.IsReadOnly = $false }
        $db = Invoke-Com $installer 'OpenDatabase' 'InvokeMethod' @($cached, 1)
        foreach ($r in $toDisable) {
            Invoke-MsiSql $db ("UPDATE ``{0}`` SET ``Condition`` = '0' WHERE ``Action`` = '{1}'" -f $r.Table, $r.Action)
            "Disabled $($r.Action) in $($r.Table) (condition was '$($r.Condition)')"
        }
        [void](Invoke-Com $db 'Commit' 'InvokeMethod' $null)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db); $db = $null
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        if ($wasReadOnly) { (Get-Item $cached).IsReadOnly = $true }
    }
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer); $installer = $null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()

    $log = Join-Path $outDir "VMwareTools-uninstall-$stamp.log"
    "Uninstalling silently. Log: $log"
    $p  = Start-Process -FilePath msiexec.exe -ArgumentList "/x $code /qn /norestart REBOOT=ReallySuppress /l*v `"$log`"" -Wait -PassThru
    $rc = $p.ExitCode
    switch ($rc) {
        0       { Write-Host 'Result   : uninstalled (exit code 0)' -ForegroundColor Green }
        3010    { Write-Host 'Result   : uninstalled - restart required to finish (exit code 3010)' -ForegroundColor Green }
        1605    { Write-Host 'Result   : msiexec reports the product is not installed (exit code 1605)' -ForegroundColor Yellow }
        default { Write-Host "Result   : FAILED (exit code $rc). Keep the log for review: $log" -ForegroundColor Red
                  $warnings += "VMware Tools uninstall failed with exit code $rc - see $log" }
    }

    # If the uninstall failed and the product is still installed, put the original cached installer back
    if ($rc -ne 0 -and $rc -ne 3010 -and (Test-Path $cached)) {
        $item = Get-Item $cached
        $wasReadOnly = $item.IsReadOnly
        if ($wasReadOnly) { $item.IsReadOnly = $false }
        Copy-Item -Path $backup -Destination $cached -Force
        if ($wasReadOnly) { (Get-Item $cached).IsReadOnly = $true }
        if ((Get-FileHash $cached).Hash -eq (Get-FileHash $backup).Hash) { "Original cached installer restored to $cached" }
        else { $warnings += "Could not restore the original cached installer. Backup is at $backup" }
    }
}

# ---------------- Checks (report only) ----------------
""
"=== VMware entries still registered (expected: none) ==="
$left = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*VMware*' })
if ($left) { $left | Format-Table DisplayName, DisplayVersion, PSChildName -AutoSize } else { 'None' }

"=== VMware services still present (expected: none after the restart) ==="
$svc = @(Get-Service | Where-Object DisplayName -like '*VMware*')
if ($svc) { $svc | Format-Table Name, DisplayName, Status, StartType -AutoSize } else { 'None' }

"=== Hyper-V integration services (expected: Running) ==="
$vmic = @(Get-Service vmic* -ErrorAction SilentlyContinue)
$vmic | Format-Table Name, DisplayName, Status, StartType -AutoSize
foreach ($s in 'vmicheartbeat', 'vmicshutdown', 'vmictimesync', 'vmickvpexchange') {
    $x = $vmic | Where-Object Name -eq $s
    if (-not $x -or $x.Status -ne 'Running') { $warnings += "Integration service $s is not running." }
}

"=== Network adapters now ==="
$nowIPs = @()
Get-NetAdapter | ForEach-Object {
    $a    = $_
    $ip   = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $cfg  = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
    $dns  = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    $dhcp = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
    $nowIPs += $ip | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }
    [pscustomobject]@{
        Name        = $a.Name
        Description = $a.InterfaceDescription
        Status      = "$($a.Status)"
        MacAddress  = $a.MacAddress
        DHCP        = "$dhcp"
        IPv4        = (($ip | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', ')
        Gateway     = (@($cfg.IPv4DefaultGateway.NextHop | Where-Object { $_ }) -join ', ')
        DNS         = ($dns -join ', ')
    }
} | Format-List

if ($pre) {
    "=== Network adapters before migration ==="
    $pre.Network | Select-Object Name, Description, MacAddress, DHCP,
        @{n='IPv4';e={$_.IPv4 -join ', '}}, @{n='Gateway';e={$_.Gateway -join ', '}}, @{n='DNS';e={$_.DNS -join ', '}} | Format-List
    foreach ($n in $pre.Network) {
        if ($n.DHCP -eq 'Disabled') {
            foreach ($i in @($n.IPv4)) {
                if ($i -and ($i -notlike '169.254.*') -and ($nowIPs -notcontains $i)) {
                    $warnings += "Static address $i (was on '$($n.Name)', gateway $($n.Gateway -join ', '), DNS $($n.DNS -join ', ')) is not configured on any adapter now."
                }
            }
        }
    }
    if ($pre.Routes) {
        "=== Persistent static routes before migration (check these still exist) ==="
        $pre.Routes | Format-Table -AutoSize
    }
}

"=== Disks now ==="
$diskNow = @(Get-Disk)
$diskNow | Format-Table Number, @{n='SizeGB';e={[math]::Round($_.Size / 1GB, 1)}}, PartitionStyle, IsOffline, IsReadOnly -AutoSize
foreach ($d in $diskNow) {
    if ($d.IsOffline)  { $warnings += "Disk $($d.Number) ($([math]::Round($d.Size / 1GB, 1)) GB) is offline." }
    if ($d.IsReadOnly) { $warnings += "Disk $($d.Number) ($([math]::Round($d.Size / 1GB, 1)) GB) is read-only." }
}

"=== Volumes now ==="
$volNow = @(Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter)
$volNow | Format-Table DriveLetter, DriveType, FileSystemLabel, FileSystem, @{n='SizeGB';e={[math]::Round($_.Size / 1GB, 1)}} -AutoSize
if ($pre) {
    $lettersNow = @($volNow | ForEach-Object { "$($_.DriveLetter)" })
    # v1.1: skip CD/DVD drives (0 GB in the capture) - VMware's CD drive letter is not carried over to Hyper-V
    foreach ($v in @($pre.Volumes | Where-Object { $_.SizeGB -gt 0 -and $_.DriveType -ne 'CD-ROM' })) {
        if ($lettersNow -notcontains $v.DriveLetter) {
            $warnings += "Drive $($v.DriveLetter): ('$($v.Label)', $($v.SizeGB) GB) existed before migration but is missing now."
        }
    }
}

"=== Old VMware network devices (report only) ==="
if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
    $old = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like '*vmxnet*' })
    if ($old) { $old | Format-Table FriendlyName, Status, InstanceId -AutoSize } else { 'None' }
} else { 'Not checked - Get-PnpDevice is not available on this OS version.' }

# ---------------- Summary ----------------
""
"=================== SUMMARY ==================="
if ($warnings.Count -eq 0) {
    Write-Host 'No warnings.' -ForegroundColor Green
} else {
    foreach ($w in $warnings) { Write-Host "WARNING - $w" -ForegroundColor Yellow }
}

if ($rc -eq 0 -or $rc -eq 3010) {
    if ($Restart) {
        ""
        Write-Host 'Restarting in 15 seconds to finish the removal. Press Ctrl+C to cancel.' -ForegroundColor Yellow
        Start-Sleep 15
        Restart-Computer -Force
    } else {
        Write-Host 'Restart the VM when convenient to finish the removal.' -ForegroundColor Yellow
    }
}