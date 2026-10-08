# Changelog

All notable changes to `ArcHyperVHost-Workshop.ps1` and `ArcHyperVHost-Site.ps1`. The two scripts share one version, independent of the gold-image and cluster scripts.

## [Unreleased]

_Work in progress on the `develop` branch. `$ScriptVersion` is `0.1.0-dev`; the download one-liners point at `/develop/`._

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
  - **Not yet run on hardware.** Both files parse. The following were exercised with mocked data: the baseline plan builder, NIC grouping (the iLO virtual NIC and USB NICs are excluded, and the 10/25GbE group is suggested first), the HTML report, and the check that the shared block matches.
  - **To confirm on the first real build:**
    - The iLOrest calls: `iloaccounts changepass`, `ethernet --network_ipv4/--nameservers`, and `rawpatch` for the host name and protocols.
    - The Defender off-policy on WS2025, with SentinelOne and with Sophos.
    - The Windows Update loop, including `BrowseOnly=0`.
    - The any-administrator logon task (GroupId principal, AtLogOn trigger) opening its interactive window after a reboot and after the switch to the new admin account.
    - **Each ProLiant generation.** The iLO steps and the workload profile name were written against iLO 5 (Gen10). Gen11 (iLO 6) and especially Gen12 (iLO 7, which changes how in-band ilorest authenticates) need their own first build.
