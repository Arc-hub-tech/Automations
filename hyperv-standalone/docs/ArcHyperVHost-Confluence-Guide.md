# Standalone Hyper-V host build.

> **What this guide covers**
>
> Two scripts build a standalone HPE ProLiant Hyper-V host for a customer site, and bring an existing customer host up to the same Arc standard.
>
> → **Workshop script** (`ArcHyperVHost-Workshop.ps1`): runs at Arc before the host ships. It covers firmware, iLO, Hyper-V, the VM disk, Datto, Windows Update, the network switch and the security baseline.
>
> → **Site script** (`ArcHyperVHost-Site.ps1`): runs on site. It covers the customer IP address, domain or workgroup, endpoint protection, the local admin account and VM start/stop, then produces the as-built report for ITGlue.
>
> → **One command, every time:** an engineer runs `-Phase Next` repeatedly. The script works out what comes next, stops whenever a person is needed, and asks before every reboot.
>
> → **Ships with the standard in place:** the security baseline is applied in the workshop and checked again on site.

> **Status:** pilot, version 0.1.0-dev on the develop branch. Both scripts have been tested with mocked data but have not yet run on HPE hardware. These need confirming on the first real builds:
>
> → the iLO steps (password, IP, DNS, host name, protocols);
>
> → turning Defender off alongside SentinelOne and Sophos;
>
> → the Windows Update loop;
>
> → the automatic restart of the script after a reboot;
>
> → each ProLiant generation, particularly Gen11 (iLO 6) and Gen12 (iLO 7).
>
> Report anything unexpected to the script owner.

## Scope

| Item | Supported |
|---|---|
| Servers | HPE ProLiant Gen10, Gen10 Plus, Gen11 and Gen12, standalone (not clustered) |
| Operating system | Windows Server 2025 Standard or Datacenter, Desktop Experience |
| Identity | Domain-joined or workgroup |
| Endpoint protection | SentinelOne or Sophos, deployed by Datto policy or the customer. The scripts detect it and never install it. Defender is kept if the customer has neither. |
| Networking | One SET switch over a matching group of NICs, with a Management host adapter |
| Storage | Local RAID: a boot array plus a data volume for VMs |
| Management | No SCVMM. Datto RMM is installed on every host |
| Run by | An engineer, interactively. These are not Datto components |

For hosts in the Arc platform clusters, use the Hyper-V cluster standard guide instead.

## How the build is split

| Stage | Where | Script | What happens |
|---|---|---|---|
| Workshop | At Arc, on the workshop network (DHCP, with internet) | `ArcHyperVHost-Workshop.ps1` | Firmware (SPP), iLO password, host name, Hyper-V, VM disk, Datto, Windows Update, SET switch on DHCP, security baseline, then shut down |
| Site | At the customer, on their network | `ArcHyperVHost-Site.ps1` | Customer IP address, domain or workgroup, endpoint protection, local admin account, baseline re-check, VM start/stop, as-built report |
| Existing host | At the customer | `ArcHyperVHost-Site.ps1` only | Brings a running customer host up to the standard, showing each change and asking first |

The two scripts share a state file on the host (`C:\ArcLogs\HyperVHost\state.json`). Answers given in the workshop, such as the host name and Datto site, are not asked again on site. Passwords are never stored.

## Before you start

### Access

→ The local Administrator account on the new host, plus the iLO factory password from the server's pull-out tag.

→ The iLO remote console, or a keyboard and screen. The network steps move the host's address and drop any RDP session.

→ The workshop network: DHCP with internet access, for the Datto download and Windows Update.

→ On site, for a domain join: an account allowed to join computers to the customer's domain.

### Customer details to collect first

| Detail | Used by | Notes |
|---|---|---|
| Host name | Workshop, Base phase | Up to 15 characters |
| Datto platform and site ID | Workshop, Agents phase | Pinotage or Merlot. The site ID is in the Datto site settings |
| Management VLAN, static IP, prefix, gateway, DNS | Site, Network phase | The workshop uses DHCP; the static address is set on site |
| Domain name and OU, or workgroup name and NTP servers | Site, Identity phase | |
| iLO IP, mask, gateway, DNS, host name | Workshop (Ship) or site | Optional. Can also be set in the iLO web UI |
| Endpoint protection product | Site, Edr phase | SentinelOne or Sophos, in the policy with the Hyper-V exclusions |
| Name for the new local admin account | Site, Admin phase | Its password must be unique to this host; record it in ITGlue |
| VM start delay | Site, HostSettings phase | One delay for every VM, in seconds. The default is 120 |

## The pen drive

One pen drive carries both scripts and the HPE media for every ProLiant generation. **Format it NTFS or exFAT, not FAT32**, because SPP ISOs are bigger than FAT32's 4 GB file limit.

```
E:\ArcHyperVHost\
  ArcHyperVHost-Workshop.ps1
  ArcHyperVHost-Site.ps1
  SPP\Gen10\<SPP>.iso
  SPP\Gen10Plus\<SPP>.iso      (optional: Gen10 Plus falls back to SPP\Gen10)
  SPP\Gen11\<SPP>.iso
  SPP\Gen12\<SPP>.iso
  HPE\ilorest-<version>.msi
```

→ The Workshop script reads the generation from the server model, so `ProLiant DL380 Gen11` gives `Gen11`. It offers the newest ISO in that generation's folder and asks you to confirm it.

→ It warns if the ISO's file name names a different generation, or if it only finds an ISO loose in the top `SPP` folder.

→ PreFlight reports whether the stick holds an SPP for the server, before anything changes.

→ The SPP is mounted from Windows and run with HPE's Smart Update Manager, so firmware and the Windows drivers go on in one pass. Booting the server from the SPP updates firmware only. Keep that as a fallback for when old firmware stops Windows installing, for example when setup can't see the RAID disks.

Get the SPP for each generation, and the iLOrest MSI, from HPE's support site. Refresh the stick when a new SPP is released.

## Getting the scripts

Run from an elevated PowerShell prompt. **From the pen drive:**

```
Set-ExecutionPolicy Bypass -Scope Process -Force; & E:\ArcHyperVHost\ArcHyperVHost-Workshop.ps1 -Phase Next
```

**Or download the current develop version:**

```
$p="$env:SystemDrive\ArcLogs\HyperVHost\ArcHyperVHost-Workshop.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-standalone/ArcHyperVHost-Workshop.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Next
```

For the Site script, use the same commands with `ArcHyperVHost-Site.ps1`.

→ Each script copies itself to `C:\ArcLogs\HyperVHost\`, so it carries on after a reboot even once the pen drive is removed.

→ After each reboot, log on with an administrator account. The next phase starts by itself. This still works after a domain join, or once you are using the new local admin account. There's no automatic logon and no stored password.

## Process 1: workshop build

### Starting point

→ Windows Server 2025 Standard or Datacenter, Desktop Experience, installed on the boot array.

→ The data array for VMs created in the RAID controller.

→ The server cabled to the workshop network on at least one port of the NIC group that will form the switch.

→ The pen drive plugged in.

### The build

Run `-Phase Next` and answer the prompts. It runs these phases in order:

| Phase | What it does | You are asked for |
|---|---|---|
| PreFlight | Read-only checks: HPE hardware, OS edition, VT-x, Secure Boot, TPM, internet, NIC groups, disks, SPP on the stick | Nothing. Fix any FAIL items first |
| Hpe | Runs the SPP (30 to 60 minutes). Installs iLOrest. Reports the boot RAID. Sets the iLO Administrator password and turns IPMI over LAN and SSDP off | Confirm the SPP ISO; the new iLO password |
| Base | Host name, High Performance power plan, BIOS workload profile `Virtualization-MaxPerformance`, Hyper-V role | Host name |
| Storage | Lists candidate disks and sets the default VM and VHD paths to `<drive>:\Hyper-V` | Which disk or volume; the disk number again before an empty disk is formatted; the drive letter |
| Agents | Installs the Datto RMM agent. Defender stays on, with the VM folder excluded | Datto platform and site ID |
| Updates | Windows Update until nothing is left: software only, no optional or preview updates, no drivers | Nothing (reboots are confirmed) |
| Network | Builds the SET switch and a Management host adapter on the workshop DHCP. Internet keeps working | Which NIC group; switch name |
| Baseline | Applies the security and optimisation standard, including the switch NIC settings. Shows the plan first | Confirm the plan |
| Ship | Pre-ship checks. Optionally sets the customer static address and the iLO network now. Then shuts down | Whether to set those now |

**Expect several reboots,** after the SPP, the host name and Hyper-V, Windows Update and the baseline. Each one is confirmed first.

### Disks and formatting

The Storage phase never offers the boot or system disk, a USB disk, a mounted ISO, or the disk the media is on. An empty (RAW) disk is formatted NTFS with 64K clusters and labelled `VMs` only after you type its disk number a second time. A disk that already has data is never formatted; choose its existing volume by drive letter instead.

### Network in the workshop

The Network phase builds the switch over the NIC group you choose. Matching 10/25GbE ports are suggested first, and the iLO's virtual NIC and USB adapters are excluded. The Management adapter takes a DHCP address from the workshop network. That address differs from the one the host had before, because the adapter is new, so run this phase on the iLO remote console.

### Ship

Ship is the last step before switching off. The host normally ships on its workshop DHCP address, and the customer address is set on site.

→ Set the customer static address in Ship only if it is known and nothing else needs the workshop network.

→ Setting the iLO network in Ship resets the iLO, which drops an iLO remote console session for a minute or two.

## Process 2: on-site completion

Connect the host to the customer network. Log on at the console or the iLO remote console, plug in the pen drive, and run the Site script with `-Phase Next`.

| Phase | What it does | You are asked for |
|---|---|---|
| Network | Sets the customer VLAN and static IP on the Management adapter the workshop left on DHCP. Builds the switch if there is none | VLAN, IP, prefix, gateway, DNS |
| Identity | Domain: checks DNS can find the domain controllers, then joins. Workgroup: workgroup name, NTP servers, private network profile, WinRM, and remote UAC off for local accounts | Domain, OU and join account; or workgroup and NTP servers |
| Edr | Detects SentinelOne or Sophos, then turns Defender off once you confirm the agent is connected. Checks after the reboot that Defender is really off | Confirm the agent is connected and in the right policy |
| Admin | Creates a new local admin, checks its password works, then disables the built-in Administrator | Account name and password |
| Baseline | Re-checks the standard and applies anything that differs, such as settings changed by a domain policy after the join | Confirm the plan, if anything differs |
| HostSettings | On every VM: automatic stop is Shut Down, automatic start is "start if it was running" after the delay | The start delay |
| Report | Runs the checks and writes the as-built report | Nothing |

**Gates.** The script stops with an `ACTION NEEDED` line when a person is needed. Do the step, then run `-Phase Next` again. The gates are:

→ the endpoint protection agent isn't installed or connected yet;

→ you are logged on as the built-in Administrator, which can't be disabled from its own session. Log off and log on as the new account, and the script carries on.

**After the VMs are created,** run `-Phase HostSettings` again. Hyper-V has no host-wide default for VM start and stop actions, so they're set per VM. Then run `-Phase Report` for a fresh as-built.

## Process 3: existing customer hosts

Run only the Site script, with `-Phase Next`, in a maintenance window.

→ **Network:** an existing switch is checked, never rebuilt. An existing address is never moved.

→ **Baseline:** this is where the standard is first applied. The script shows every change and asks before applying.

→ **Reboots:** before any reboot it warns which VMs are running, because a reboot stops them using each VM's automatic stop action.

→ **VMQ:** turning VMQ on restarts the switch NICs, so VMs lose network for a few seconds.

→ **Local admin:** if a suitable local admin account already exists, you can choose to use it. Its password is not changed.

## Endpoint protection and Defender

On Windows Server, Defender **does not switch itself to passive mode** when SentinelOne or Sophos is installed. That only happens on hosts onboarded to Defender for Endpoint. Two antivirus products scanning VM disks at once hurts performance, so the Edr phase:

1. Leaves Defender on, with the Hyper-V exclusions, until the agent is confirmed connected, so the host is never unprotected, including in transit.
2. Sets the "Turn off Microsoft Defender Antivirus" policy and reboots.
3. After the reboot, checks Defender's state. If Defender is still active, the phase and the report say so. Likely causes are tamper protection, a domain policy, or the agent switching it back on.

If the Sophos installer has already removed Defender, the phase sees that and moves on. If the customer has no SentinelOne or Sophos, choose "Defender stays as the antivirus" and Defender keeps running with its exclusions.

**The off-policy outlives the agent.** If the customer later removes SentinelOne or Sophos, Defender stays off. The as-built report names the two registry values to delete, so this is on record in ITGlue. Keeping protection in place after that is part of the customer's own checks.

→ `DisableAntiSpyware` under `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender`

→ `DisableRealtimeMonitoring` under `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection`

Before confirming the agent, make sure the host is in the SentinelOne or Sophos policy that carries the Hyper-V exclusions:

→ the VM folders;

→ the files `*.vhdx`, `*.avhdx`, `*.vmcx`, `*.vmrs` and `*.vmgs`;

→ the processes `vmms.exe`, `vmwp.exe` and `vmcompute.exe`.

## Local admin and remote UAC

Every host gets a new local admin account, and the built-in Administrator is disabled.

**On workgroup hosts,** the Identity phase turns remote UAC off for local accounts (`LocalAccountTokenFilterPolicy = 1`). This is the Arc standard. Without it, Windows refuses admin rights over the network to any local account other than the built-in Administrator. That would block Veeam's access to the host and remote Hyper-V Manager. Domain hosts don't need it, so it isn't set there.

The trade-off is that anyone holding the host's local admin password, or its hash, can administer it remotely. So:

→ **every host's local admin password must be unique;**

→ record it in ITGlue against the host;

→ never reuse it across hosts or customers.

## What Baseline changes

### Security defaults

→ NTLMv2 only; WDigest plain-text credentials off; LLMNR off; AutoRun and AutoPlay off.

→ UAC on, prompting admins on the secure desktop. The machine locks after 900 seconds of inactivity.

→ Remote Desktop allowed, with Network Level Authentication, TLS and high encryption.

→ SSL 3.0, TLS 1.0 and TLS 1.1 off. SMBv1 off and its feature removed. SMB signing required. PowerShell 2.0 removed.

→ Windows Firewall on for every profile. The Hyper-V, WinRM, file sharing, WMI and Remote Desktop rules are enabled first.

→ Local accounts lock after 10 failed attempts, for 15 minutes. Guest account disabled. Print Spooler disabled.

A stricter value already on the host, such as a shorter lock time or a lower lockout threshold, is kept.

### Hyper-V host optimisations

→ High Performance power plan; hibernation off.

→ NTFS last-access updates and 8.3 short names off.

→ Telemetry, customer-experience, Maps and error-reporting scheduled tasks off. Defrag and retrim are left on.

→ Power management off and VMQ on for the switch NICs.

→ HPE BIOS workload profile `Virtualization-MaxPerformance`.

If a domain policy sets something differently, the domain policy wins. The script lists those items so they can be fixed in the policy.

## The as-built report

The Report phase writes `C:\ArcLogs\HyperVHost\AsBuilt-<host>-<date>.html`. **Attach it to the host's Configuration in ITGlue.** It opens offline in any browser and is deliberately unbranded, because the script lives in a public repository.

It contains:

→ a summary, then every check with failures and warnings first;

→ hardware and firmware: model, serial number, ROM, BIOS profile and iLO;

→ operating system, activation and identity;

→ network: switch, members, management address;

→ storage: VM paths, volumes and disk health;

→ security and protection;

→ backup readiness;

→ every VM with its start and stop settings;

→ the build record of each phase, with its date and script version.

| Area | Checks |
|---|---|
| Hardware | HPE hardware, BIOS workload profile, Secure Boot, TPM |
| Windows | Activation, Desktop Experience, licensing (Standard edition with more than 2 VMs is a warning), time source, pending reboot |
| Network | SET switch, member links up, still on the workshop DHCP address |
| Storage | VM path off the system drive, disk health, free space below 15% |
| Protection | Endpoint protection running, Defender state and the off-policy note, Datto agent, built-in Administrator disabled, local admin account, baseline differences, remote UAC on workgroup hosts |
| Backup and power | Hyper-V VSS writer stable, other VSS writers, firewall rules Veeam needs, Veeam components present, UPS shutdown agent (PowerChute, Eaton IPP and similar) |
| VMs | Automatic stop action is Shut Down on every VM |

## Safety controls

→ Every change shows a plan and asks first.

→ Every reboot is confirmed, with a warning if VMs are running.

→ An empty disk is formatted only after its number is typed a second time. A disk with data is never formatted.

→ An existing switch is never rebuilt. The only address ever moved is one the workshop left on DHCP.

→ Network changes need the console or the iLO remote console. Over RDP you must type `REMOTE`.

→ The HPE and Datto installers must pass a digital signature check before they run.

→ Passwords are typed at hidden prompts and never written to disk or the logs. One exception: the iLO password is passed to iLOrest on its command line for the moment it runs, because that is the only way iLOrest accepts it.

→ Defender stays on until the endpoint protection agent is confirmed connected.

## Logs and records

| File | What it is |
|---|---|
| `C:\ArcLogs\HyperVHost\state.json` | Phases completed, with dates and script versions, and the non-secret answers |
| `Workshop-<phase>-<time>.log`, `Site-<phase>-<time>.log` | A full transcript of each run |
| `*-checks-<time>.csv` | The check results from PreFlight and Report |
| `AsBuilt-<host>-<time>.html` | The as-built report for ITGlue |

Every phase is safe to re-run. To repeat a single step, run that phase by name, for example `-Phase Storage` or `-Phase Report`.

## Troubleshooting

| Symptom | What to do |
|---|---|
| PreFlight: "SPP on the media" warning | Put the SPP for that generation in `SPP\<generation>` on the pen drive |
| Hpe: SUM exit code -3 | A component failed. Check `C:\cpqsystem\sum\log`, fix it, and run `-Phase Hpe` again |
| Hpe: in-band iLO login refused | iLO "Require Host Authentication" is on, or the iLO is not in Production security state. Answer yes to log in with iLO credentials, or set the password and protocols in the iLO web UI |
| Base: Hyper-V deferred | VT-x was off. Reboot after the BIOS profile is set; Base installs Hyper-V on its next run |
| Storage: "disk is not empty" | Pick the existing volume by drive letter, or clear the disk by hand if it should be reused |
| Updates keeps stopping | An update fails every time. Check the warnings and the Windows Update log; hide or install that update by hand |
| Network: lost connection | Expected over RDP. Use the iLO remote console. The new address is printed once DHCP or the static address is set |
| Edr: Defender still active after the reboot | Check tamper protection and any domain policy, then run `-Phase Edr` again. Remove the Defender feature by hand only once the agent is confirmed protecting the host |
| Admin: stops at the built-in Administrator | Log off, log on as the new account; the script carries on |
| Report: still on workshop DHCP | Run `-Phase Network` on site |
| Report: remote UAC warning on a workgroup host | Run `-Phase Identity` |

## Reference

→ Scripts, README and change log: https://github.com/Arc-hub-tech/Automations/tree/develop/hyperv-standalone

→ This page's source in the repo: `hyperv-standalone/docs/ArcHyperVHost-Confluence-Guide.md`. Keep the two in step.

→ For hosts in the Arc platform clusters, see the Hyper-V cluster standard guide.
