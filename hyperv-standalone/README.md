# Standalone Hyper-V host build

Two scripts build a **standalone HPE ProLiant Hyper-V host** for a customer site, and bring an existing customer host up to the same standard:

| Script | Where | What |
|---|---|---|
| `ArcHyperVHost-Workshop.ps1` | At Arc, before the host ships | HPE firmware and iLO, host name, Hyper-V, VM volume, Datto RMM, Windows Update, **SET switch on the workshop DHCP**, **security baseline**, then ships |
| `ArcHyperVHost-Site.ps1` | On site, and on existing customer hosts | Customer static address (or the full network, if there's no switch), domain or workgroup, EDR question (removes Defender if one is planned), new local admin, security baseline, VM start/stop, HTML as-built report |
| `ArcHyperVHost-Lite.ps1` | On a live host that is already built | **Security and Hyper-V optimisation standard only**: a read-only Check, then an Apply that asks separately before anything that could interrupt service. Always asks about **Defender and EDR**. No network, identity or account changes, and **never reboots** |

All three are run by an engineer, interactively. They are not Datto components. There is **no config file**: everything is prompted. Answers that are not secret (host name, Datto site, IPs, VM volume) are kept in `C:\ArcLogs\HyperVHost\state.json` on the host, so a re-run and the Site script don't ask again. Passwords are never stored or logged.

Unlike `hyperv-cluster/`, there's no SCVMM and no peer node. The scripts build the host networking themselves. **The workshop network is DHCP:** the host builds its SET switch there, keeps internet access on a DHCP address, and ships that way. The Site script then sets the customer static address. **Hosts ship with the standard in place:** the Workshop script applies the baseline before shipping, and the Site script re-checks it on site (a domain GPO can change things after the join).

## Running them

Each script header has the one-liner. In short, from an elevated PowerShell prompt:

```powershell
$p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Workshop.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Workshop.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Next
```

```powershell
$p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Site.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Site.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Next
```

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Lite.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Lite.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Check
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
| `Edr` | Asks one question: **will a third-party EDR (SentinelOne, Sophos) be installed?** Yes **removes Microsoft Defender** (feature uninstall, reboot). No keeps Defender as the antivirus, with the Hyper-V exclusions. It never installs the EDR. If an EDR turns up later while Defender is still installed, it asks again. |
| `Admin` | Creates a **new local admin** (name and password prompted, password typed twice), checks the password works, then **disables the built-in Administrator** (RID 500). If you're logged on as the built-in account, it stops and resumes when you log on as the new one. |
| `Baseline` | Re-checks the standard on site (the same code as the workshop) and applies anything that differs, after showing the plan. On an existing host, this is where the standard is first applied. |
| `HostSettings` | On every VM: the **Shutdown integration service** on (Shut Down depends on it), automatic stop = **Shut Down**, automatic start = start if it was running, with **one start delay** (prompted, default 120 s). Hyper-V has no host-wide default for these, so re-run it after creating VMs. |
| `Report` | Runs the checks, then writes `C:\ArcLogs\HyperVHost\AsBuilt-<host>-<time>.html` for the engineer to **attach to the host's Configuration in ITGlue**. |

**On an existing customer host,** run the Site script only. It shows each plan and asks before changing anything. It never rebuilds a switch or moves an IP, and it warns before any reboot that running VMs will be stopped. If the host only needs the security and Hyper-V standard, with no network, identity or account work and no reboots, use the [Lite script](#lite-archypervhost-liteps1) instead.

### Defender on Windows Server

Defender **doesn't go passive by itself** on Windows Server when SentinelOne or Sophos is installed. Passive mode is only for hosts onboarded to Defender for Endpoint, and two real-time scanners on VM disks hurt performance. So when an EDR is planned, the Edr phase **removes the Defender feature** (`Uninstall-WindowsFeature Windows-Defender`, then a reboot).

- **Removal leaves no antivirus until the EDR is installed.** The phase warns when no agent is there yet. Deploy the EDR straight after, through Datto policy or the customer. The Report FAILs a host with neither.
- If the Sophos installer has already removed Defender, the phase sees that and moves on.
- **If the EDR is ever uninstalled** (at contract end, say), put Defender back first: `Install-WindowsFeature Windows-Defender`, then reboot. The as-built report says so, so this is on record in ITGlue.
- The Report still flags the older "Turn off Microsoft Defender Antivirus" policy (`DisableAntiSpyware`) if it finds it on an existing host. To undo that policy, delete its values and run `Start-Service WinDefend`; a reboot alone doesn't bring Defender back (checked on WS2025).

### Workgroup hosts and remote UAC

With the built-in Administrator disabled, the remaining local admin account gets a filtered token over the network. That blocks Veeam's admin-share and WMI access, and remote Hyper-V Manager, with a local account. **On workgroup hosts the Identity phase sets `LocalAccountTokenFilterPolicy = 1` (Arc standard).** Domain hosts don't need it, so it isn't set there.

The trade-off: anyone holding this host's local admin password, or its hash, can administer it remotely. That is why **every host's local admin password must be unique**: generated per host, recorded in ITGlue, and never reused across hosts or customers. The script prints this reminder, and the report records the setting.
### Baseline

The Baseline is the cluster standard without the cluster, FC/MPIO and NUMA items:

- **Security:** NTLMv2 only, WDigest off, LLMNR off, AutoRun off, UAC, a 900 s inactivity lock, RDP with NLA/TLS/high encryption, SSL 3.0/TLS 1.0/1.1 off, SMBv1 off, SMB signing required, firewall on, lockout after 10 attempts, Guest disabled, Print Spooler disabled.
  - The firewall rules for Hyper-V, WinRM, file sharing, WMI and RDP are enabled. They're checked as their own item, because a fresh install already has the firewall on.
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
| VMs | Automatic stop is Shut Down, automatic start isn't Nothing, and clean shutdown: the Shutdown integration service is enabled on each VM and, on running VMs, the guest answers it |

The HTML is self-contained, so it opens offline. It's **deliberately unbranded**: this repo is public, so no logo or brand assets live in it.

## Lite: `ArcHyperVHost-Lite.ps1`

For a host that is **already built and in service** (Hyper-V role in, SPP done, network and VMs running) that only needs the security and Hyper-V optimisation standard. It applies the same standard as `Baseline`, from the same shared code, and adds an endpoint protection step, Defender's Hyper-V exclusions and the VM start/stop settings. It never touches the network, domain membership or accounts, never installs an EDR, and **it never reboots**. It stops when Failover Clustering is installed (use `hyperv-cluster/`, whose Baseline drains the node first) and on a host without the Hyper-V role.

**Tested on WS2025 only.** Existing customer hosts may run 2016-2022; those are untested, and the script warns. Its one-liner forces TLS 1.2 so the download works on older builds. Run `Check` first there and read the plan.

| Phase | What it does |
|---|---|
| `Check` (default) | Read-only. Shows what Apply would change, runs the live-host checks and writes `Lite-Check-<host>-<time>.html` to attach to the change request. |
| `Apply` | Shows the same plan and asks **every question before changing anything**: once for the live-safe items (**Now**), once for the items that take effect at the next reboot (**At reboot**), then **separately for each change that could interrupt service**, with the risk stated. Then the VM start/stop changes. It applies VMQ last, lists anything declined or still different (a domain GPO wins), writes `Lite-Apply-<host>-<time>.html`, and says if a reboot is needed. |

The changes that are asked for separately:

| Change | Risk on a live host |
|---|---|
| Firewall profile on | Inbound traffic outside the Hyper-V, WinRM, file sharing, WMI and RDP rules is blocked: Hyper-V Replica listeners (their own rule groups), Veeam data movers, UPS agent, SNMP, monitoring |
| UAC turned back on | From the reboot, remote UAC filtering applies again. On a workgroup host without `LocalAccountTokenFilterPolicy = 1`, Veeam and remote Hyper-V Manager with a local admin get access denied |
| NTLMv2 only | Devices that authenticate with LM or NTLMv1 are refused |
| SSL 3.0, TLS 1.0 and 1.1 off | Software that only speaks the old protocols stops connecting (from the next reboot) |
| SMB signing required | SMB connections that can't sign are refused, in both directions; check older NAS backup repositories |
| SMBv1 and PowerShell 2.0 removed | Anything still using them stops working (finishes at the reboot) |
| BIOS workload profile | Power and processor settings change at the next reboot (only checked when ilorest is installed) |
| VMQ on | The switch NICs restart: VMs and RDP lose network for a few seconds. Applied last; use the iLO remote console. Say no if VMQ was turned off deliberately (some Broadcom 1GbE NICs) |

**Endpoint protection (Defender and EDR):** Check shows the state, and Apply always asks the engineer the question that fits it:

| State | What Apply asks |
|---|---|
| Defender only, no EDR | **Will a third-party EDR (SentinelOne, Sophos) be installed?** The answer is recorded. Yes keeps Defender until the agent is running: deploy the EDR, then run Apply again. No keeps Defender, with the Hyper-V exclusions. Asked on every Apply, so it gets thought about each time. |
| EDR running and Defender still active | **Remove Microsoft Defender?** (feature uninstall, finishes at the next reboot) |
| EDR installed but not all services running | Nothing is removed. Check the EDR in its console |
| EDR running, Defender removed or off | Nothing to ask |
| Neither | **No active antivirus.** Offers to put Defender back: reinstall the feature (reboot), or remove the old off-policy and start the service |

Unlike the Site script's Edr phase, **Lite removes Defender only once an EDR agent is installed and running.** A host already in service is never left without antivirus while it waits for the EDR. The report also WARNs when no decision is recorded, when an EDR was planned but isn't installed, when Defender's real-time protection is off, and when its signatures are more than 7 days old.

**VM start and stop on a live host:** only VMs that differ are changed. An automatic start action of `Nothing` becomes `StartIfRunning`. A start delay the customer already set (a staggered DC-first order, for example) is kept; only VMs with no delay get the default (prompted, 120 s). A running VM's stop action can't be changed, so it's reported to set at its next shutdown.

**Checks** are the Site Report's, minus the build-only ones (local admin "created by these scripts", workshop DHCP). Datto is a WARN rather than a FAIL. They add the following for live hosts:
- Clean shutdown and restart on every VM, as in the Site Report (Apply enables a disabled Shutdown integration service; it's safe while the VM runs).
- Checkpoints older than 7 days.
- VMs running on differencing disks (`.avhdx`) with no checkpoint, which usually means a backup merge failed.
- VM files on the system drive.
- An LBFO team or a single NIC under the switch.
- A Hyper-V Replica server whose listener firewall rules are off.
- Remote UAC still on for local accounts on a workgroup host (WARN).
- Windows updates more than 45 days old.
- A reboot these scripts asked for that hasn't happened yet.

## Maintenance

- **Shared helpers are duplicated on purpose.** The block between `start of shared helpers` and `end of shared helpers` is identical in all three scripts, so each file stays self-contained for `irm` and USB use. It includes the network build and the whole baseline. Change it in all three.
- **Report helpers too.** The block between `start of report helpers` and `end of report helpers` (EDR/Defender detection, the VSS writer list, the HTML builder) is identical in `ArcHyperVHost-Site.ps1` and `ArcHyperVHost-Lite.ps1`. Change it in both.
- **Versioning:** all three scripts share one version (`$ScriptVersion`) and one [CHANGELOG](CHANGELOG.md). They follow the repo's `develop` / `main` workflow: the one-liners point at `/develop/` and the version carries `-dev` until release.
- **Logs:** a transcript per run, the check CSVs and the as-built HTML go to `C:\ArcLogs\HyperVHost\`.
- **Engineer guide:** [docs/ArcHyperVHost-Confluence-Guide.md](docs/ArcHyperVHost-Confluence-Guide.md) is the source of the Confluence page "Standalone Hyper-V host build" in the Data Center space. Keep the two in step.
