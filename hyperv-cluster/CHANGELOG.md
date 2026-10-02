# Changelog

All notable changes to `ArcHyperVCluster.ps1` (originally `Add-ArcHyperVClusterNode.ps1`). This script versions independently of the gold-image scripts.

## [Unreleased]

_Work in progress on the `develop` branch. `$ScriptVersion` is `0.4.0-dev`; the download one-liner points at `/develop/`._

### Changed
- **SCVMM owns host networking, cluster join and workloads (0.4.0-dev).** The script now stops at "VMM-ready" for a new node and checks what SCVMM builds.
  - **Removed phases:** `Network` (SET switch and host vNICs, now built by the VMM logical switch), `Join` (SCVMM adds the host to the cluster) and `HyperV` (VM placement paths and live migration host settings are set in SCVMM). The `-AllowRemoteSession` parameter and the console-session check went with Network.
  - **New-node flow in `-Phase Next`:**
    1. PreFlight → Hpe → PreFlight → Base → Storage → Agents → Baseline.
    2. A **VMM handoff gate**: add the host, apply the logical switch, add it to the cluster.
    3. Post-VMM Baseline (NIC power and VMQ apply once the SET switch exists) → Resume if drained → Report.

    A `NewNode` marker in `state.json` keeps an onboarded host on this flow after SCVMM makes it a cluster member.
  - **Host networking checks:** a new `Test-ArcHostNetworks` check compares the host vNICs with `HostNetworks`: SET switch in weight mode, each role's vNIC present with the right VLAN, a subnet matching the peer, and stray vNICs flagged. It is INFO in PreFlight (before VMM) and enforced in Report (after VMM).
  - **Nodes entries are optional:** a new node needs no MACs or IPs in `cluster.json`, because SCVMM assigns host vNIC IPs. PreFlight lists the NICs for the VMM uplinks and checks the 10GbE ports are up.
  - **Baseline no longer sets VM/VHD paths or live migration host settings**; NUMA spanning stays with the script. Capture records only `HyperV.NumaSpanningEnabled` and prints the VM path and live migration values as notes for the VMM host settings.
  - The host-network check, the Baseline plan without VMHost items, and the `Next` sequencing through the VMM handoff were exercised with mocked data.

### Added
- **`-Phase Next`: attended automation (0.3.0-dev).** This works out where the host is from `state.json`.
  - **New node:** runs the onboarding phases back to back, with automatic re-checks: PreFlight after the SPP, Storage until every LUN is visible, Agents until Defender is removed, Base if VT-x was off.
  - **It stops at the human gates** with an `ACTION NEEDED` line: add MACs/IPs, iLO console for Network, FC zoning/array, Sentinel connected, `JOIN`.
  - **It asks before every reboot** and registers a one-shot logon task (`ArcHyperVClusterNext`), so the next phase starts when the engineer logs back on. There's no auto-logon and no stored password. A declined reboot is asked for again rather than skipped.
  - **Existing cluster node:** Baseline (drain, apply), the reboot prompt, then Resume after logon.
  - **Console detection** now compares the process's session ID with the console session from `qwinsta`. `$env:SESSIONNAME` isn't reliable when launched from a scheduled task. The Network phase uses the same check.
  - The sequencing (step order, gates, re-runs, reboots) was exercised with mocked phases. Console detection was tested on a real console session and against RDP-style `qwinsta` output.
- **Settings on the deployment share (0.3.0-dev).** Each cluster's settings now live in one `cluster.json` on that deployment's share, next to the SPP ISO and MSIs, so every node in the cluster uses the same settings and Datto site.
  - **`-SettingsShare <folder>`:** give it once per host. `state.json` remembers it, so later phases need only `-Phase <Name>`, and `-ConfigPath` is no longer needed on each run.
  - **`Capture`** writes `<SettingsShare>\cluster.json`, after a confirmation that warns an overwrite replaces any edits. `-OutPath` still overrides the location.
  - **Local copy on every run:** `settings-last.json`, plus `settings-used-<phase>-<time>.json` as the record of what each run applied. If the share can't be read (e.g. just after the Network phase rebuilds the NICs), the script offers to continue from the last local copy and says so in the log.
  - **Relative installer paths:** `Hpe.SppIsoPath`, `Hpe.IloRestMsiPath` and `Agents.Sentinel.MsiPath` may be relative to the file's folder (`SPP\<version>.iso`). Capture and the example now write them that way.
  - **Sentinel site token on the share:** `Agents.Sentinel.SiteToken` in `cluster.json` is used when set. Otherwise (not set, still a placeholder, or the run is using the local copy) the hidden prompt is used as before.
    - The token is **never copied to node disks**: `settings-last`, `settings-used` and `settings-captured` hold a redaction marker instead. It is never printed.
  - **Re-running `Capture` keeps the hand-entered sections** (`Agents`, including the Datto Site ID and Sentinel token, and the Hpe installer paths) from the existing `cluster.json`, rather than resetting them to placeholders.
  - The loading, remembering, relative-path resolution, local-copy fallback and token redaction were exercised locally against a simulated share. A dummy token appeared in none of the local files.
- **Existing-cluster standard (0.2.0-dev).** The script now defines and applies a best-practice standard to a built cluster, as well as onboarding new nodes. It was renamed to `ArcHyperVCluster.ps1` to match. **The config file is now the authority.** The peer node only fills `null` values and serves as the drift check for new nodes.
  - **`Capture`** reads the node it runs on and every Up node over WinRM, then writes the config (outside the repo, `C:\ArcLogs\HyperVClusterOnboard\<cluster>.json` by default). It includes:
    - host networks from the real vNIC names (VLAN, prefix, weight, gateway, DNS, jumbo, cluster role)
    - each node's SET member MACs and IPs, and the switch settings
    - MPIO claim, policy and timers; Hyper-V settings; live migration order
    - security and optimisation set to the recommended defaults
    - placeholders for agents and share paths

    It then prints the captured values that differ from best practice and a drift summary per node (CSV per node).
  - **`Baseline`** applies security defaults, Hyper-V host optimisations, the BIOS workload profile, MPIO, and Hyper-V host settings from the config.
    - It shows the change plan and asks first, and only changes what differs.
    - On a cluster member it health-checks the cluster and **drains the node** before changing anything, then stops. Hard blocks: single node, other nodes not Up. Engineer must type `DRAIN` for: CSVs offline, failed resources, witness offline or none on two nodes, not enough free memory on the other nodes.
    - It never touches the vSwitch, vNICs or IPs.
    - Afterwards it lists anything that still differs, which is usually a domain GPO winning.
    - A single settings list drives both the fingerprint (reading, locally and on the peer) and Baseline (applying).
  - **`Resume`**: after a Baseline reboot, checks the reboot happened, resumes the node (VMs moved back or not, the engineer's choice), and lists remaining differences.
  - **`ClusterBaseline`** (run once):
    - names and sets roles on cluster networks by subnet (never `None`)
    - sets the live migration network order and exclusions on the Virtual Machine resource type
    - turns DrainOnShutdown on
    - optional CSV block cache and intra-cluster SecurityLevel
    - reports the quorum witness, the CAU role and node states
    - guards:
      - refuses to make a network cluster-only if it carries a cluster IP Address resource (that would take the cluster name offline)
      - leaves live migration settings unchanged if none of `LiveMigrationNetworks` matches a cluster network (an empty order would have excluded every network and broken all drains)
    - these guards and the change planning were tested against mocked cluster cmdlets in three scenarios
  - **Resume** checks that every cluster network interface on the node is Up before resuming, which catches a firewall change that broke cluster traffic. Straight after Baseline, registry items are re-read so a failed write is flagged, not just reported as OK.
  - **Security defaults** mirror the gold-image CE+/ISO 27001 block:
    - SMBv1 and PowerShell v2 removed; SMB signing required
    - firewall on, with the cluster/Hyper-V/WinRM/SMB/WMI/RDP rule groups enabled first
    - SSL 3.0 and TLS 1.0/1.1 off
    - NTLMv2 only, WDigest off, LLMNR off, AutoRun off
    - UAC; inactivity lock and lockout threshold (a stricter existing value is kept)
    - RDP with NLA/TLS/high encryption; Guest disabled

    Hyper-V host additions: Print Spooler disabled, and Credential Guard/HVCI as opt-in only.
  - **Optimisations:**
    - High Performance power; hibernation, NTFS last-access and 8.3 names off
    - telemetry/CEIP/Maps/WER tasks off (the scheduled defrag is **left on** for 3PAR/Primera retrim)
    - NIC power management off and VMQ on for SET members
    - Server Manager not opened at logon
  - New config sections: `Security`, `Optimisation`, `Cluster`, `HyperV.NumaSpanningEnabled` and `HostNetworks[].ClusterRole`. `PeerNode` is optional outside the new-node diff phases.
  - The new-node flow now runs `Baseline` before `Join`, so a node is hardened before it takes workload.
- **Initial phased onboarding script (0.1.0-dev)** for joining an HPE ProLiant Gen10 / Windows Server 2025 Datacenter host to an existing Hyper-V failover cluster on 3PAR/Primera FC storage with plain 10GbE.
  - **Phases:** `PreFlight`, `Hpe`, `Base`, `Network` (console-only guard), `Storage`, `Agents`, `Join` (`Test-Cluster -Ignore Storage`, engineer `JOIN` gate, `Add-ClusterNode -NoStorage`), `HyperV` and `Report`.
  - **`Hpe` phase:** SPP from the SMB share via SUM unattended (`smartupdate /silent`, the local-host form from the SUM 12.0 CLI guide). SUM's documented Windows return codes are mapped. Checks CHIF and AMS, installs `ilorest` from a signed MSI, and reports the boot volume via `ssacli`.
  - **Datto and SentinelOne installers:** logic adapted from the vendor/partner scripts in use, rewritten rather than copied.
    - Both check the Authenticode signature, throw rather than `exit`, and check exit codes and services.
    - The Sentinel site token is prompted as a SecureString and is never echoed or MSI-logged.
    - The Datto platform is validated to `pinotage` or `merlot`.
  - **PreFlight respects the phase order:** HPE tooling and SPP-dependent drift is INFO before `Hpe` runs and WARN after.
  - **Base phase order:** the BIOS workload profile is set before the Hyper-V role, and Hyper-V is deferred to a re-run if VT-x is currently off.
- **Status:** parse-clean. The fingerprint and the Baseline plan builder have been exercised on a Windows 11 machine. Not yet exercised on a cluster or on HPE hardware.
