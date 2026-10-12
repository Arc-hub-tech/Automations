# Changelog

All notable changes to `ArcHyperVHost-Workshop.ps1` and `ArcHyperVHost-Site.ps1`. The two scripts share one version, independent of the gold-image and cluster scripts.

## [Unreleased]

_Work in progress on the `develop` branch. `$ScriptVersion` is `0.1.1-dev`; the download one-liners point at `/develop/`._

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
    - The Defender off-policy alongside SentinelOne and alongside Sophos.
    - The domain join path.
    - The any-administrator logon task (GroupId principal, AtLogOn trigger) opening its interactive window after a reboot and after the switch to the new admin account.
    - **Each ProLiant generation.** The iLO steps and the workload profile name were written against iLO 5 (Gen10). Gen11 (iLO 6) and especially Gen12 (iLO 7, which changes how in-band ilorest authenticates) need their own first build.
