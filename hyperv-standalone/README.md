# Standalone Hyper-V host build

Two scripts build a **standalone HPE ProLiant Hyper-V host** for a customer site, and bring an existing customer host up to the same standard:

| Script | Where | What |
|---|---|---|
| `ArcHyperVHost-Workshop.ps1` | At Arc, before the host ships | HPE firmware and iLO, host name, Hyper-V, VM volume, Datto RMM, Windows Update, **SET switch on the workshop DHCP**, **security baseline**, then ships |
| `ArcHyperVHost-Site.ps1` | On site, and on existing customer hosts | Customer static address (or the full network, if there's no switch), domain or workgroup, EDR check and Defender, new local admin, security baseline, VM start/stop, HTML as-built report |

Both are run by an engineer, interactively. They are not Datto components. There is **no config file**: everything is prompted. Answers that are not secret (host name, Datto site, IPs, VM volume) are kept in `C:\ArcLogs\HyperVHost\state.json` on the host, so a re-run and the Site script don't ask again. Passwords are never stored or logged.

Unlike `hyperv-cluster/`, there's no SCVMM and no peer node. The scripts build the host networking themselves. **The workshop network is DHCP:** the host builds its SET switch there, keeps internet access on a DHCP address, and ships that way. The Site script then sets the customer static address. **Hosts ship with the standard in place:** the Workshop script applies the baseline before shipping, and the Site script re-checks it on site (a domain GPO can change things after the join).

## Running them

Each script header has the one-liner. In short, from an elevated PowerShell prompt:

```powershell
$p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Workshop.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Workshop.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Next
```

```powershell
$p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Site.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Site.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Next
```

**The pen drive (recommended):** one stick carries both scripts and the HPE media for every ProLiant generation. Format it **NTFS or exFAT**, because SPP ISOs are bigger than FAT32's 4 GB limit.

```
E:\ArcHyperVHost\
  ArcHyperVHost-Workshop.ps1
  ArcHyperVHost-Site.ps1
  SPP\Gen10\<SPP>.iso
  SPP\Gen10Plus\<SPP>.iso      (optional - Gen10 Plus falls back to SPP\Gen10)
  SPP\Gen11\<SPP>.iso
  SPP\Gen12\<SPP>.iso
  HPE\ilorest-<version>.msi
```

The Workshop script reads the generation from the server model (`ProLiant DL380 Gen11` gives `Gen11`) and offers the newest ISO in that generation's folder.
- A Gen10 Plus looks in `SPP\Gen10Plus`, then `SPP\Gen10`.
- A top-level `SPP\*.iso` is the last resort, with a warning to check that it covers the server.
- If the file name names a different generation, it warns.
- PreFlight reports whether the stick holds an SPP for the server.

The SPP ISO is **mounted from Windows and run with SUM in online mode**, so firmware and the Windows drivers go on in one pass. Booting the server from the SPP (offline mode) updates firmware only. Keep that as the fallback for when old firmware stops Windows installing, for example when setup can't see the RAID disks.

The Workshop script looks for the media under `-MediaPath`, then next to the script, then asks. Each script copies itself to `C:\ArcLogs\HyperVHost\`, so the resume-after-reboot task still works once the stick is removed. The Datto agent and Windows Update still need internet access in the workshop.

### `-Phase Next`

Run `-Phase Next` and the script works out where the host is from `state.json`:

- **It runs the phases back to back.**
- **It stops at the human gates** with an `ACTION NEEDED` line.
- **It asks before every reboot** (`Reboot now? [y/N]`). It registers a one-shot logon task for any member of local Administrators, so the next phase starts when an admin logs back on. That still works after a domain join, or with the new local admin account. There's no auto-logon and no stored password.

Every phase can also be run on its own (`-Phase Storage`, `-Phase Report` ...) and is safe to re-run.

## Workshop: `ArcHyperVHost-Workshop.ps1`

Run it on the iLO remote console or a local console, with internet access.

| Phase | What it does |
|---|---|
| `PreFlight` | Read-only. Checks the hardware is HPE, the OS is WS2025 Standard or Datacenter with Desktop Experience, and checks VT-x, Secure Boot, TPM, internet access, the NIC groups and the disks. |
| `Hpe` | Runs the SPP through SUM unattended. Checks CHIF/AMS and installs ilorest (MSI signature checked). Reports the boot RAID. Sets the **iLO Administrator password** (prompted) and turns **IPMI over LAN and SSDP** off. |
| `Base` | Sets the **host name** (prompted) and the High Performance power plan. Sets the BIOS workload profile `Virtualization-MaxPerformance`, then installs the Hyper-V role. If VT-x is off, it defers Hyper-V until after the reboot. |
| `Storage` | Lists candidate disks (never the boot or system disk, a USB stick, a mounted ISO, or the media disk) and asks which one to use. A **RAW** disk is formatted NTFS 64K and labelled `VMs` only after you **type the disk number again**. A disk that has data is never formatted; you can pick an existing volume by letter instead. Sets the default VM and VHD paths to `<letter>:\Hyper-V`. |
| `Agents` | Installs the **Datto RMM** agent: the platform and site ID are prompted, and the installer's signature is checked. **Defender stays on** at this point: it keeps its server-role auto-exclusions, and the VM folder is excluded. |
| `Updates` | Windows Update through the Windows Update API, **software only, no optional or preview updates** (and no drivers over the SPP). Repeats with reboots until nothing is left. |
| `Network` | Builds the **SET switch** (Hyper-V port load balancing, weight mode) over the NIC group you choose, plus a `Management` host vNIC on the **workshop DHCP, untagged**, so Datto and Windows Update keep working. Needs the console or the iLO remote console, because the DHCP address changes (the vNIC has a new MAC). |
| `Baseline` | The security and optimisation standard (below), including the switch NIC settings, so the host **ships with the standard in place**. Shows the plan and asks first. |
| `Ship` | Pre-ship checks. Optionally sets the **customer static address** now (only if it's known; it normally happens on site), and optionally the **iLO IP, DNS and host name** (this resets the iLO). Then offers to shut down. |

`Ship` comes last because a customer IP/VLAN set in the workshop cuts the host off from the workshop network, and an iLO network change drops an iLO remote console session. The Agents and Updates phases warn if a customer address has already been set.

## Site: `ArcHyperVHost-Site.ps1`

| Phase | What it does |
|---|---|
| `Network` | **Workshop-built host:** sets the customer **VLAN and static IP** (DHCP is offered too) on the `Management` vNIC that the workshop left on DHCP. **No switch yet:** builds the SET switch, then asks for the address. Needs the console (or the iLO remote console); over RDP you must type `REMOTE`. **An existing switch is never rebuilt, and an address the workshop didn't leave on DHCP is never moved**, so existing customer hosts are only verified. |
| `Identity` | **Domain:** checks the DC SRV records, then joins (with an optional OU, and a credential prompt). **Workgroup:** asks before changing the workgroup name (the default is the current one), the NTP servers, the Private network profile on the management vNIC and WinRM. It also turns remote UAC off for local accounts (see below). |
| `Edr` | **Detects** SentinelOne or Sophos; it never installs them. If neither is there, you choose to wait, or record Defender as the antivirus. Once the services run and you confirm the host is connected in the console, in the policy with the Hyper-V exclusions, it **turns Defender off by policy** and reboots. After the reboot it **checks Defender really is off**. |
| `Admin` | Creates a **new local admin** (name and password prompted, password typed twice), checks the password works, then **disables the built-in Administrator** (RID 500). If you're logged on as the built-in account, it stops and resumes when you log on as the new one. |
| `Baseline` | Re-checks the standard on site (the same code as the workshop) and applies anything that differs, after showing the plan. On an existing host, this is where the standard is first applied. |
| `HostSettings` | On every VM: automatic stop = **Shut Down**, automatic start = start if it was running, with **one start delay** (prompted, default 120 s). Hyper-V has no host-wide default for these, so re-run it after creating VMs. |
| `Report` | Runs the checks, then writes `C:\ArcLogs\HyperVHost\AsBuilt-<host>-<time>.html` for the engineer to **attach to the host's Configuration in ITGlue**. |

**On an existing customer host,** run the Site script only. It shows each plan and asks before changing anything. It never rebuilds a switch or moves an IP, and it warns before any reboot that running VMs will be stopped.

### Defender on Windows Server

Defender **doesn't go passive by itself** on Windows Server when SentinelOne or Sophos is installed. Passive mode is only for hosts onboarded to Defender for Endpoint. The Edr phase therefore:

1. Leaves Defender on until the EDR is confirmed connected, so the host is never unprotected, including while it's being shipped.
2. Sets the "Turn off Microsoft Defender Antivirus" policy (`DisableAntiSpyware`, plus real-time monitoring off), then reboots.
3. After the reboot, reads `Get-MpComputerStatus`. If Defender is still active (tamper protection, a domain GPO, or the EDR re-enabling it), it says so and the Report flags it. It doesn't remove the feature by itself.

If the Sophos installer has already removed the Defender feature, the phase sees that and moves on.

**The off-policy outlives the EDR.** If the customer later removes SentinelOne or Sophos (at contract end, say), Defender stays off and the host has **no antivirus**. To turn Defender back on, delete both values and reboot:

- `DisableAntiSpyware` under `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender`
- `DisableRealtimeMonitoring` under `...\Windows Defender\Real-Time Protection`

The as-built report names both values, so this is on record in ITGlue.

### Workgroup hosts and remote UAC

With the built-in Administrator disabled, the remaining local admin account gets a filtered token over the network. That blocks Veeam's admin-share and WMI access, and remote Hyper-V Manager, with a local account. **On workgroup hosts the Identity phase sets `LocalAccountTokenFilterPolicy = 1` (Arc standard).** Domain hosts don't need it, so it isn't set there.

The trade-off: anyone holding this host's local admin password, or its hash, can administer it remotely. That is why **every host's local admin password must be unique**: generated per host, recorded in ITGlue, and never reused across hosts or customers. The script prints this reminder, and the report records the setting.
### Baseline

The Baseline is the cluster standard without the cluster, FC/MPIO and NUMA items:

- **Security:** NTLMv2 only, WDigest off, LLMNR off, AutoRun off, UAC, a 900 s inactivity lock, RDP with NLA/TLS/high encryption, SSL 3.0/TLS 1.0/1.1 off, SMBv1 off, SMB signing required, firewall on, lockout after 10 attempts, Guest disabled, Print Spooler disabled.
  - The firewall rules enabled first are Hyper-V, WinRM, file sharing, WMI and RDP.
  - A stricter existing lock or lockout value is kept.
- **Optimisation:** High Performance power plan, hibernation off, last-access updates off, 8.3 names off, telemetry tasks off (defrag/retrim left on), NIC power management off and VMQ on for the switch members.
- **HPE:** BIOS workload profile `Virtualization-MaxPerformance`.

### Report checks

| Area | What it checks |
|---|---|
| Hardware | HPE hardware, workload profile, Secure Boot, TPM |
| Windows | Activation, install type, **licensing** (Standard with more than 2 VMs is a WARN), time source, pending reboot |
| Network | SET switch, member links, still on the workshop DHCP address |
| Storage | VM path off the system drive, disk health, free space |
| Protection | EDR running, Defender state, Datto agent, built-in Administrator disabled, the local admin account, baseline differences, remote UAC off on workgroup hosts |
| Backup and power | Hyper-V VSS writer and other writers, firewall groups Veeam needs, Veeam components (INFO only), **UPS shutdown agent** (PowerChute, Eaton IPP etc.) |
| VMs | Automatic stop action on each VM |

The HTML is self-contained, so it opens offline. It's **deliberately unbranded**: this repo is public, so no logo or brand assets live in it.

## Maintenance

- **Shared helpers are duplicated on purpose.** The block between `start of shared helpers` and `end of shared helpers` is identical in both scripts, so each file stays self-contained for `irm` and USB use. It includes the network build and the whole baseline. Change it in both.
- **Versioning:** both scripts share one version (`$ScriptVersion`) and one [CHANGELOG](CHANGELOG.md). They follow the repo's `develop` / `main` workflow: the one-liners point at `/develop/` and the version carries `-dev` until release.
- **Logs:** a transcript per run, the check CSVs and the as-built HTML go to `C:\ArcLogs\HyperVHost\`.
