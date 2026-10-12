# Changelog

All notable changes to `ArcHyperVHost-Workshop.ps1`, `ArcHyperVHost-Site.ps1` and `ArcHyperVHost-Lite.ps1`. The three scripts share one version, independent of the gold-image and cluster scripts.

## [Unreleased]

_Work in progress on the `develop` branch. `$ScriptVersion` is `0.2.0-dev`; the download one-liners point at `/develop/`._

### Added (0.2.0-dev)
- **`ArcHyperVHost-Lite.ps1`: lite standardisation for a live host that is already built.** It applies only the security and Hyper-V optimisation standard, from the same shared baseline code. It never touches the network, domain membership, EDR or accounts, and it **never reboots**. It stops on a failover cluster node (pointing to `hyperv-cluster/`) and on a host without the Hyper-V role.
  - **`-Phase Check`** (the default) is read-only. It shows what Apply would change, runs the live-host checks, and writes `Lite-Check-<host>-<time>.html` for the change request.
  - **`-Phase Apply`** asks every question first, then applies:
    - once for the live-safe items;
    - once for items that take effect at the next reboot;
    - separately, with the risk stated, for each change that could interrupt service: firewall profile on, NTLMv2 only, SSL/TLS 1.0/1.1 off, SMB signing, SMBv1/PowerShell 2.0 removal, the BIOS workload profile and VMQ. VMQ is applied last.
    - Afterwards it lists anything declined or still different, and writes `Lite-Apply-<host>-<time>.html`.
  - Also plans Defender's Hyper-V exclusions (when Defender is the antivirus).
  - **VM start/stop changes only VMs that differ.** A customer's existing non-zero start delays are kept. A running VM's stop action is reported to set at its next shutdown.
  - **Extra checks for live hosts:** checkpoints older than 7 days, VMs on `.avhdx` disks with no checkpoint (a failed backup merge), VM files on the system drive, an LBFO team or single NIC under the switch, updates more than 45 days old, and a reboot that was asked for but hasn't happened.
  - Tested on the WS2025 lab VM:
    - Check on a built host (nothing to change).
    - Check and Apply after deliberate drift: safe, at-reboot and risk items, yes and no answers, a missing Defender exclusion, and a running VM with non-standard start/stop settings.
    - The checkpoint check.
    - The Site Report re-run after the refactor below.

### Changed (0.2.0-dev)
- The Site script's report helpers (EDR/Defender detection, the built-in admin lookup, the VSS writer list, the time source and the HTML builder) now sit together in a second marked block, `start of report helpers` / `end of report helpers`. That block is identical in the Site and Lite scripts. The HTML footer names the script that wrote it, and the title takes a report kind.
- The shared helper block is now identical in all three scripts. All three share `$ScriptVersion`.

### Changed (0.1.2-dev)
- **The Edr phase is now one question:** will a third-party EDR (SentinelOne, Sophos) be installed? **Yes removes the Microsoft Defender feature** (reboot needed). **No keeps Defender** as the antivirus, with the Hyper-V exclusions.
  - This replaces the old flow: wait for the agent, confirm it in the console, turn Defender off by policy, then check after the reboot. That flow left a policy that outlived the EDR.
  - The phase asks again if an EDR turns up later while Defender is still installed. It warns that the host has no antivirus between the removal and the EDR install.
  - The Report FAILs a host with neither Defender nor an EDR. It also says how to put Defender back (`Install-WindowsFeature Windows-Defender`, then reboot) if the EDR is ever uninstalled, and still flags the old off-policy on existing hosts.
  - Tested in the lab VM: No, then a rerun without a prompt; a dummy SentinelAgent service triggering the question again; Yes removing Defender across the reboot; and the Report with and without an agent.

### Fixed (0.1.1-dev, from a lab run on a Windows Server 2025 VM)
Both scripts were run phase by phase on a nested Hyper-V VM: every Workshop phase except Hpe and Agents, and every Site phase on the workgroup path with Defender as the antivirus.
- **Choosing a NIC group by number never worked.** `Where-Object Number -eq [int]$pick` is in argument mode, so it compared against the text `[int]1`. The SET switch could only be built by typing NIC names.
- **The NIC list could miss NICs whose driver reports the physical medium as "unspecified".** It now takes 802.3 adapters reporting medium 14 or 0, which includes Hyper-V's synthetic NIC. Wi-Fi, USB, RNDIS and the iLO virtual NIC are still excluded.
- **PreFlight reported "No internet" on every host.** The probe used `https://www.msftconnecttest.com`, which serves a CDN certificate with a different name. It now uses plain HTTP (as Windows' own probe does) and checks the reply.
- **Windows Update could loop forever in `-Phase Next`.** KB5007651 (Windows Security platform) reports Succeeded but is offered again every time. Next hit its four-round cap, stopped, and did the same on every re-run. Each update revision that installs successfully is now recorded in the state file and skipped with a warning if it's offered again.
- **RDP, file sharing and WMI stayed blocked by the firewall.** The baseline only opened the management rule groups when it turned a firewall profile on, and a fresh install already has the firewall on. That left Remote Desktop refused, and the Veeam readiness checks failing. The rule groups are now a baseline item of their own (`Sec.FirewallRules`).
- **VMQ on a NIC that doesn't support it was planned as drift and reported as fixed.** It's now treated as "Not supported", and enabling VMQ errors properly instead of failing silently.
- **The report's advice for bringing Defender back was wrong.** Deleting the two policy values and rebooting leaves WinDefend stopped (startup Manual). The advice now says to run `Start-Service WinDefend` after deleting them, which restores it (checked on WS2025).
- PreFlight names a remote PowerShell session as such, instead of calling it RDP.

### Added
- **Standalone Hyper-V host build for customer sites (0.1.0-dev).** Two prompt-only scripts that share a state file (`C:\ArcLogs\HyperVHost\state.json`, no secrets) and a duplicated helper block.
  - **`ArcHyperVHost-Workshop.ps1`** runs PreFlight → Hpe → Base → Storage → Agents → Updates → Network → Baseline → Ship:
    - SPP through SUM in online mode, mounted from the pen drive. The ISO is chosen by ProLiant generation from `SPP\Gen10`, `SPP\Gen10Plus` (which falls back to `Gen10`), `SPP\Gen11` or `SPP\Gen12`, with a warning if the file name names another generation. PreFlight reports whether the stick has an SPP for the server.
    - ilorest, plus the iLO Administrator password and IPMI/SSDP off.
    - Host name, workload profile and Hyper-V.
    - A VM disk the engineer picks. A RAW disk is formatted only after the disk number is typed again.
    - The Datto RMM agent, with Defender kept on and the VM folder excluded.
    - Windows Update, software only, no optional or preview updates.
    - The **security baseline**, so the host ships with the standard in place. It re-runs for the switch NICs if Ship builds the switch.
    - **Network:** the SET switch and a Management vNIC on the workshop DHCP (untagged), so internet keeps working and the baseline covers the switch NICs.
    - **Ship:** an optional customer static address (normally set on site) and an optional iLO IP/DNS/host name, as the last step before shutdown.
  - **`ArcHyperVHost-Site.ps1`** runs Network → Identity → Edr → Admin → Baseline → HostSettings → Report, for new builds and existing customer hosts:
    - **Network:** sets the customer VLAN and static IP on the Management vNIC the workshop left on DHCP, or builds the switch if there is none. It never rebuilds a switch or moves any other address; the Report warns if the host is still on the workshop DHCP address.
    - **Identity:** domain join, or workgroup with NTP and WinRM (each asked first), plus remote UAC off for local accounts (`LocalAccountTokenFilterPolicy = 1`, Arc standard for workgroup hosts; local admin passwords must be unique per host).
    - **EDR:** detects SentinelOne or Sophos, then turns Defender off by policy once the engineer confirms the EDR is connected, and checks after the reboot that it's off.
    - **Admin:** creates a new local admin and disables the built-in Administrator.
    - **Baseline:** re-checks the standard on site; the first apply on an existing host. It's the cluster baseline minus the cluster, MPIO and NUMA items, and lives in the shared block, so both scripts run the same code.
    - **HostSettings:** VM automatic stop = Shut Down, with one start delay.
    - **Report:** a self-contained, deliberately unbranded HTML as-built for ITGlue (public repo, so no logo or brand assets).
  - **`-Phase Next`** in both scripts. It asks before each reboot and resumes through a one-shot logon task for any local administrator, so it survives the domain join and the switch to the new admin account.
  - **Not yet run on hardware.** The following were exercised with mocked data: the baseline plan builder, NIC grouping (the iLO virtual NIC and USB NICs are excluded, and the 10/25GbE group is suggested first), the HTML report, and the check that the shared block matches. Since 0.1.1-dev, both scripts have also run on a WS2025 lab VM (see Fixed).
  - **Confirmed in the lab VM:**
    - Storage on an offline RAW disk.
    - The SET switch with Management on DHCP, then the customer static address on site.
    - The baseline converging to "nothing to change" after one apply and a reboot.
    - The Windows Update loop.
    - Workgroup identity with NTP and LocalAccountTokenFilterPolicy.
    - Defender as the antivirus, with exclusions.
    - The new local admin, with the built-in Administrator disabled from the new account.
    - VM start/stop settings and the as-built report.
    - The Defender off-policy turning Defender off on WS2025 after a reboot.
  - **To confirm on the first real build:**
    - The SPP, the Datto agent install, and the iLOrest calls: `iloaccounts changepass`, `ethernet --network_ipv4/--nameservers`, and `rawpatch` for the host name and protocols.
    - Removing Defender alongside SentinelOne and alongside Sophos (removal itself is lab-tested).
    - The domain join path.
    - The any-administrator logon task (GroupId principal, AtLogOn trigger) opening its interactive window after a reboot and after the switch to the new admin account.
    - **Each ProLiant generation.** The iLO steps and the workload profile name were written against iLO 5 (Gen10). Gen11 (iLO 6) and especially Gen12 (iLO 7, which changes how in-band ilorest authenticates) need their own first build.
