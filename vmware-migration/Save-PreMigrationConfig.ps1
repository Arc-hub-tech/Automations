<#
.SYNOPSIS
  Before migration: records a Windows VM's configuration while it is still on VMware.
  Arc Systems - VMware to Hyper-V migrations. Version 1.0

.DESCRIPTION
  Read-only apart from writing its report files. It does not change any setting.
  Saves to C:\ProgramData\Arc\Migration\
    pre-migration.json  - read by Remove-VMwareTools.ps1 after migration
    pre-migration.txt   - readable copy for the migration ticket
  Records: computer, domain and OS; VMware Tools version and product code;
  every network adapter (IP addresses, mask, gateway, DNS, DHCP, MAC, DNS registration);
  persistent static routes; disks (online state) and volumes (drive letters).
  If an earlier capture exists, it is renamed with a timestamp, never overwritten.

.EXAMPLE
  One-liner: paste as a single line into an elevated Windows PowerShell. It saves the script to
  C:\ProgramData\Arc\Migration and runs it. Do not use irm | iex: exit would close the window.

  [Net.ServicePointManager]::SecurityProtocol='Tls12'; $p="$env:ProgramData\Arc\Migration\Save-PreMigrationConfig.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/vmware-migration/Save-PreMigrationConfig.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\Save-PreMigrationConfig.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$outDir = 'C:\ProgramData\Arc\Migration'
$json   = Join-Path $outDir 'pre-migration.json'
$txt    = Join-Path $outDir 'pre-migration.txt'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'

# Must be elevated
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'STOP - run this in Windows PowerShell as administrator. Nothing saved.' -ForegroundColor Red
    exit 1
}

# Must still be on VMware
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.Manufacturer -notlike 'VMware*') {
    Write-Host "STOP - this script is for use before migration, on VMware. This VM reports: $($cs.Manufacturer) / $($cs.Model). Nothing saved." -ForegroundColor Red
    exit 1
}

$os = Get-CimInstance Win32_OperatingSystem

$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$tools = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'VMware Tools' } |
    ForEach-Object { [pscustomobject]@{ Version = $_.DisplayVersion; ProductCode = $_.PSChildName; InstallLocation = $_.InstallLocation } })

$network = @(Get-NetAdapter | ForEach-Object {
    $a    = $_
    $ip   = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $cfg  = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
    $dns  = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    $dhcp = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
    [pscustomobject]@{
        Name          = $a.Name
        Description   = $a.InterfaceDescription
        Status        = "$($a.Status)"
        MacAddress    = $a.MacAddress
        DHCP          = "$dhcp"
        IPv4          = @($ip | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        Gateway       = @($cfg.IPv4DefaultGateway.NextHop | Where-Object { $_ })
        DNS           = $dns
        RegisterInDNS = (Get-DnsClient -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue).RegisterThisConnectionsAddress
    }
})

$routes = @(Get-NetRoute -PolicyStore PersistentStore -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -ne '0.0.0.0/0' } |
    ForEach-Object { [pscustomobject]@{ Destination = $_.DestinationPrefix; NextHop = $_.NextHop; Metric = $_.RouteMetric } })

$disks = @(Get-Disk | ForEach-Object {
    [pscustomobject]@{ Number = $_.Number; SizeGB = [math]::Round($_.Size / 1GB, 1); PartitionStyle = "$($_.PartitionStyle)"; IsOffline = $_.IsOffline; IsReadOnly = $_.IsReadOnly }
})

$volumes = @(Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter | ForEach-Object {
    [pscustomobject]@{ DriveLetter = "$($_.DriveLetter)"; Label = $_.FileSystemLabel; FileSystem = $_.FileSystem; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.SizeRemaining / 1GB, 1) }
})

$report = [pscustomobject]@{
    CapturedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Computer    = $env:COMPUTERNAME
    Domain      = $cs.Domain
    OS          = "$($os.Caption) ($($os.Version))"
    Platform    = "$($cs.Manufacturer) / $($cs.Model)"
    VMwareTools = $tools
    Network     = $network
    Routes      = $routes
    Disks       = $disks
    Volumes     = $volumes
}

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
foreach ($f in $json, $txt) {
    if (Test-Path $f) {
        $kept = $f -replace '\.(json|txt)$', "-$stamp.`$1"
        Rename-Item -Path $f -NewName (Split-Path $kept -Leaf)
        "Earlier capture kept as $kept"
    }
}

$report | ConvertTo-Json -Depth 5 | Set-Content -Path $json -Encoding UTF8

$lines = @()
$lines += "Pre-migration capture - $($report.Computer) - $($report.CapturedAt)"
$lines += "Domain   : $($report.Domain)"
$lines += "OS       : $($report.OS)"
$lines += "Platform : $($report.Platform)"
$lines += ""
$lines += "--- VMware Tools ---"
$lines += ($tools | Format-List | Out-String).Trim()
$lines += ""
$lines += "--- Network adapters ---"
$lines += ($network | Select-Object Name, Description, Status, MacAddress, DHCP,
    @{n='IPv4';e={$_.IPv4 -join ', '}}, @{n='Gateway';e={$_.Gateway -join ', '}}, @{n='DNS';e={$_.DNS -join ', '}}, RegisterInDNS |
    Format-List | Out-String).Trim()
$lines += ""
$lines += "--- Persistent static routes ---"
$lines += if ($routes) { ($routes | Format-Table -AutoSize | Out-String).Trim() } else { 'None' }
$lines += ""
$lines += "--- Disks ---"
$lines += ($disks | Format-Table -AutoSize | Out-String).Trim()
$lines += ""
$lines += "--- Volumes ---"
$lines += ($volumes | Format-Table -AutoSize | Out-String).Trim()
$lines | Set-Content -Path $txt -Encoding UTF8

Get-Content $txt
""
Write-Host "Saved: $json" -ForegroundColor Green
Write-Host "Saved: $txt" -ForegroundColor Green
"No settings were changed. Copy pre-migration.txt into the migration ticket."