# Hyper-V cluster standard and VMM-ready host preparation

`ArcHyperVCluster.ps1` defines a best-practice standard for **HPE ProLiant Gen10 / Windows Server 2025 Datacenter** Hyper-V failover clusters on **3PAR/Primera FC** storage with **plain 10GbE** (no RDMA), managed by **SCVMM**. It brings existing nodes up to that standard, and it prepares new nodes to the point where SCVMM can onboard them. The same script handles production clusters (4-port SET) and the DR cluster (2-port SET): only the config file differs.

An engineer runs it interactively. It is not a Datto component.

## Where the script ends and SCVMM starts

| Area | Owner |
|---|---|
| HPE: SPP, BIOS workload profile, CHIF/AMS, ilorest, boot RAID check | Script |
| Windows roles: Hyper-V, Failover Clustering, MPIO | Script |
| FC and multipath: 3PARdata claim, policy, timers, LUN visibility | Script |
| Agents: Datto, SentinelOne, Defender removal | Script |
| Security baseline, host optimisations, NUMA spanning (`Baseline`) | Script |
| Drift checks against a peer; drain, apply and resume for host changes | Script |
| Cluster network names and roles, live migration network order (`ClusterBaseline`) | Script |
| **Host networking: SET switch and host vNICs (logical switch, IP pools)** | **SCVMM** |
| **Adding the host to VMM and to the cluster** | **SCVMM** |
| **VM placement paths and live migration host settings** | **SCVMM** |
| **VM networks, templates, placement and all workloads** | **SCVMM** |

The script still **checks** what SCVMM builds. `Report` fails a node whose host vNICs don't match `HostNetworks` (names, VLANs, subnets), so a logical switch that drifts from the agreed design is caught.

## Design

- **The config file is the standard.** `Capture` writes it from a live node and cluster. You edit it towards best practice. `Baseline` (per node) and `ClusterBaseline` (once) apply it.
- **Peer fallback.** Where a config value is `null`, the script uses the `PeerNode`'s value; with no peer, it leaves that setting alone. For a new node, the peer is also the drift check (`PreFlight` / `Report`).
- **Live nodes are drained first.** `Baseline` shows the full change plan and asks before doing anything. On a cluster member it health-checks the cluster and **drains the node** before changing anything, then stops. You reboot if it says so and run `Resume`. It never touches the vSwitch, vNICs or IPs.
- **Phases are safe to re-run.** Progress is recorded in `C:\ArcLogs\HyperVClusterOnboard\state.json`, with a transcript per run in the same folder.
- **Anything that changes the live cluster needs the engineer.** This covers the drain (plus typing `DRAIN` if the health check finds problems) and cluster changes.
- **Installers come from the deployment share**, except the Datto agent, which is downloaded from the Datto platform. Every MSI and EXE must pass an Authenticode signature check.

## Workflows

**Existing cluster: set the standard and bring every node up to it**

1. `Capture -SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>` on any node, once the cluster meets the [capture readiness](docs/ArcHyperVCluster-Confluence-Guide.md) levels. It writes `cluster.json` to the share (and a local copy), lists captured values that differ from best practice, and shows drift between nodes.
2. Edit `cluster.json` on the share: the Datto site ID and platform, the Sentinel token, the installer file names, and anything Capture flagged.
3. `-Phase Next` on each node **one at a time**: Baseline (plan, health check, drain, apply), reboot, then Resume.
4. `ClusterBaseline` once, from any node.

**New node: get it VMM-ready, hand over to SCVMM, then verify**

`PreFlight` → `Hpe` → `PreFlight` → `Base` → `Storage` → `Agents` → `Baseline` → **SCVMM**: add the host, apply the logical switch, add it to the cluster → `Baseline` (post-VMM) → `Report`

The host needs only its management IP on one physical NIC before SCVMM; the logical switch's management adapter takes that IP over.

### Attended automation: `-Phase Next`

Once `cluster.json` is set up, an engineer only needs to run **`-Phase Next`**. It reads `state.json` to see where the host is, then:

- **Runs phases back to back.** Re-checks are automatic: PreFlight runs again after the SPP, Storage repeats until every LUN is visible, Agents repeats until Defender is gone, and Base repeats if VT-x was off.
- **Stops at the human gates** with an `ACTION NEEDED` line. You do the step, then run `-Phase Next` again.
- **Asks before every reboot** (`Reboot now? [y/N]`). It registers a one-shot logon task, so the next phase **starts by itself when you log back on**. There's no auto-logon and no stored password. If you say no, the next `-Phase Next` asks again rather than carrying on un-rebooted.

| Stop | What you do |
|---|---|
| PreFlight FAIL items | Fix them (OS edition, domain, DNS, peer reachable, CPU vendor) |
| Storage | FC zoning, plus the 3PAR/Primera host object (persona 15) with the printed WWPNs |
| Agents | Confirm the host shows as connected in the SentinelOne console, and answer yes to removing Defender |
| VMM handoff | In SCVMM: add the host to its host group, apply the logical switch, add the host to the cluster |

After the handoff, `-Phase Next` re-runs `Baseline` (the NIC power and VMQ items only apply once the SET switch exists), resumes the node if it was drained, and runs `Report`.

A new node typically takes about **four starts**:
1. PreFlight → Hpe → reboot → PreFlight → Base → reboot → Storage → stop: zoning.
2. Storage → Agents → stop: Sentinel.
3. Defender removal → reboot → Baseline (→ reboot) → stop: VMM handoff.
4. Post-VMM Baseline → Resume → Report → done.

**On an existing cluster node**, `-Phase Next` runs `Baseline` (health check, drain, apply), asks to reboot, then runs `Resume` after you log back on. Then move to the next node. Run `ClusterBaseline` once by hand after all the nodes are done.

## Phases

| Phase | What it does | Reboot |
|---|---|---|
| `Next` | Attended automation: runs the right next phase(s), stops at the gates, confirms reboots, resumes at logon | As needed |
| `Capture` | Reads this node and every Up node in the cluster over WinRM. Writes the config: host networks from the real vNIC names (VLAN, prefix, weight, gateway, DNS, jumbo), each node's SET member MACs and IPs (for reference), switch settings, MPIO claim/policy/timers, NUMA spanning, BIOS profile target, and live migration network order. Security and optimisation are set to the recommended defaults. Writes `<SettingsShare>\cluster.json` (`-OutPath` to write elsewhere) and a local copy. Reports VM path and live migration values as notes for the VMM host settings. | - |
| `Baseline` | Applies [security defaults](#security-defaults) and [Hyper-V host optimisations](#hyper-v-host-optimisations), plus the BIOS workload profile, MPIO claim/policy/timers and NUMA spanning. Only changes what differs. On a cluster member: health check, drain, apply, stop. | If an item needs it |
| `Resume` | After a Baseline reboot: checks the reboot happened and every cluster network interface is Up, resumes the node (VMs moved back or not, your choice), and lists anything still different. | - |
| `ClusterBaseline` | Cluster networks named and roled by subnet (Management = ClusterAndClient, others = Cluster; **never None**). Live migration network order and exclusions. DrainOnShutdown on. Optional: CSV block cache, intra-cluster SecurityLevel. **Report only:** quorum witness, CAU role, node states. | - |
| `PreFlight` | Read-only. OS, domain, VT/Secure Boot/TPM, DNS, time source, pending reboot, HPE ilorest/AMS, 10GbE ports up. Lists the physical NICs (for the VMM uplinks) and FC WWPNs. Diffs against the peer: OS build, hotfixes, CPU, system ROM, NIC/HBA drivers, HPE BIOS and MPIO. | - |
| `Hpe` | Mounts the SPP ISO from the share and runs **SUM unattended** (`smartupdate /silent`): every component newer than what is installed, no downgrades. Then checks the iLO Channel Interface driver (CHIF) and AMS, installs `ilorest` from its MSI if missing, and reports the boot volume via `ssacli`. | If SUM says so |
| `Base` | High Performance power plan and the HPE BIOS workload profile via `ilorest`, then Hyper-V, Failover Clustering and MPIO (Hyper-V waits for a re-run if VT-x is still off). iLO settings are reported only. | Yes |
| `Storage` | Prints WWPNs for zoning and the array host object (persona 15). Adds the MSDSM claim for `3PARdata`/`VV`, sets the load-balance policy and MPIO timers, and checks every peer cluster LUN is visible here (matched on `UniqueId`). | If changed |
| `Agents` | Datto RMM agent, then the SentinelOne MSI (stored token, or a hidden prompt). Once Sentinel is running **and** you confirm it is connected in the console, Windows Defender is removed. | Yes |
| `Report` | Final peer diff exported to CSV, cluster membership, **host networking vs `HostNetworks`** (vSwitch is SET in weight mode; every role's vNIC present with the right VLAN and a subnet matching the peer; stray vNICs flagged), baseline compliance, agents and phase history. | - |

## Security defaults

These mirror the gold-image CE+/ISO 27001 block item for item. The image-only items (BitLocker, appx, sysprep, WU cache) are dropped, and one Hyper-V host item is added. Switched with `Security.*` in the config.

| Setting | Value | Restart |
|---|---|---|
| SMBv1 | Protocol off, `FS-SMB1` removed (and PowerShell v2, if present) | feature removal |
| SMB signing | Required, server and client (`RequireSmbSigning`) | - |
| Firewall | On for all profiles. The Failover Clusters, Hyper-V, WinRM, File and Printer Sharing, WMI and Remote Desktop rule groups are enabled **first**, so the node can't lose cluster traffic. | - |
| SSL 3.0 / TLS 1.0 / TLS 1.1 | Off, server and client (`DisableLegacyTls`) | yes |
| NTLM | NTLMv2 only (`LmCompatibilityLevel` 5). WDigest plaintext credentials off. | - |
| LLMNR, AutoRun/AutoPlay | Off | - |
| UAC | On, admin prompt on the secure desktop | if it was off |
| Inactivity lock | 900 s (`InactivityTimeoutSecs`). A stricter (shorter) existing value is kept. | yes |
| RDP | Allowed, with NLA, TLS security layer and high encryption | - |
| Local lockout | Threshold 10, 15 min duration/window (`LockoutThreshold`). A stricter existing value is kept. | - |
| Guest | Disabled | - |
| **Print Spooler** | **Disabled.** Not needed on a Hyper-V host (PrintNightmare class of attacks). (`DisablePrintSpooler`) | - |
| Credential Guard / HVCI | **Opt-in, off by default** (`CredentialGuard`, `Hvci`). Credential Guard is set without a UEFI lock, so it's reversible. Check HPE driver compatibility before HVCI. The script never turns either off. | yes |

A domain GPO overrides the policy-backed keys. After applying, Baseline lists anything that still differs, and that's where a GPO is winning. Fix those in the GPO.

## Hyper-V host optimisations

Switched with `Optimisation.Apply`.

| Setting | Why |
|---|---|
| High Performance power plan, plus BIOS `Virtualization-MaxPerformance` | No C-state/P-state latency for VMs. The BIOS profile locks power regulator, C-states and VT-x/VT-d. |
| Hibernation off | A cluster node never hibernates, and `hiberfil.sys` wastes disk |
| NTFS last-access updates off, 8.3 names off | Metadata writes with no benefit |
| Telemetry, CEIP, Maps and WER scheduled tasks off | Background overhead on the host |
| **Scheduled defrag left on** | On thin-provisioned 3PAR/Primera it also does the retrim (UNMAP) that returns freed space to the array |
| NIC power management off, VMQ on (SET members) | Stops the OS powering NICs down, and spreads VM traffic across cores. VMM uplink port profiles don't set NIC power management, so the script keeps this. Check the port profile's VMQ setting agrees. |
| Server Manager not opened at logon | Housekeeping |
| MPIO | `3PARdataVV` claim with Microsoft's MSDSM, as the HPE Primera Windows implementation guide specifies. That guide gives no custom timer values, so timers and policy come from the capture or config. |
| NUMA spanning | As captured, the same on every node |
| Cluster (`ClusterBaseline`) | Live migration on the LM network first and never on Management. DrainOnShutdown on, so a shutdown live-migrates VMs rather than failing them over. |

VM placement paths and the per-host live migration settings (performance option, simultaneous migrations) are set in SCVMM. Capture prints the current values as notes for the VMM host settings.

## Inputs

### 1. `cluster.json`: one per cluster, on the deployment share

Each cluster has its own deployment share. One `cluster.json` sits there next to the SPP ISO and MSIs (see [the share layout](#3-deployment-share)), so every node in that cluster uses the same settings and the same Datto site. For an existing cluster, `Capture` writes it. The layout is in [`cluster.example.json`](cluster.example.json).

- **Give `-SettingsShare <folder>` once per host.** That host's `state.json` remembers it, so later phases need only `-Phase <Name>`.
- **A local copy is kept on every run.** It is written to `C:\ArcLogs\HyperVClusterOnboard\settings-last.json`, plus `settings-used-<phase>-<time>.json` as the record of exactly what each run applied. If the share can't be reached, the script offers to carry on from the last local copy.
- **Installer paths are relative to the file's folder** (`SPP\<version>.iso`). Full paths still work.
- `-ConfigPath <file>` points at one specific file instead, for testing or one-offs.
- **Keep it off GitHub, and keep share access to engineers.** It holds hostnames, IPs, VLANs, the Datto site ID and the Sentinel token. `hyperv-cluster/*.json` other than the example is gitignored as a backstop.

| Section | Values |
|---|---|
| Top level | `ClusterName`; `PeerNode`: FQDN of a healthy existing node (Capture sets it to the node it ran on) |
| `Switch` | The vSwitch the VMM logical switch should produce: name, load balancing, default-flow (VM) weight, jumbo size. Recorded by Capture and used as the reference; the script doesn't build it |
| `HostNetworks[]` | The agreed host networks, per role (Management / LiveMigration / Cluster): VLAN, prefix length, bandwidth weight, DNS registration, jumbo, `ClusterRole`. **Role names must match the host vNIC names the logical switch creates.** Report checks every node against this |
| `Nodes.<hostname>` | Optional. Capture records existing nodes' SET member MACs and IPs for reference. New nodes don't need an entry; SCVMM assigns their host vNIC IPs |
| `Hpe` | `SppIsoPath`, `IloRestMsiPath`, `WorkloadProfile` |
| `Storage` | MSDSM vendor/product IDs (`3PARdata`/`VV`); load-balance policy and `MpioSettings` (`null` = copy the peer) |
| `HyperV` | `NumaSpanningEnabled` (`null` = copy the peer, or leave alone with no peer) |
| `Security` | `Apply`, `DisableLegacyTls`, `RequireSmbSigning`, `DisablePrintSpooler`, `InactivityTimeoutSecs`, `LockoutThreshold`, `CredentialGuard` (opt-in), `Hvci` (opt-in) |
| `Optimisation` | `Apply` |
| `Cluster` | `LiveMigrationNetworks` (roles in preference order; everything else is excluded from live migration), `DrainOnShutdown`, `BlockCacheSizeMB` and `SecurityLevel` (`null` = leave alone) |
| `Agents` | Datto `Platform` (`pinotage` or `merlot`) and `SiteID`; Sentinel `MsiPath`, `SiteToken` (optional) and `RemoveDefender` |

### 2. Entered at runtime (never stored)

- **Datto platform**: Pinotage or Merlot, prompted only if the config doesn't set it.
- **SentinelOne site token**: only if `Agents.Sentinel.SiteToken` isn't set, or this run is using the local copy (which never holds it). Prompted hidden.
- **iLO credentials**: only if in-band iLO access is refused ("Require Host Authentication" is on).
- **Confirmations**: running SUM; confirming Sentinel is connected before Defender is removed; applying a Baseline plan, and typing `DRAIN` if the cluster health check found problems; resuming, and whether VMs move back; applying ClusterBaseline changes; every reboot.

### 3. Deployment share

One per cluster:

```
\\<SERVER>\<SHARE>\<DEPLOYMENT>\
    cluster.json
    SPP\<SPP_VERSION>.iso
    HPE\ilorest-<VERSION>.msi
    SentinelOne\SentinelInstaller-<VERSION>.msi
```

- The engineer's account needs read access, plus **write** access for `Capture` to write `cluster.json`. The phases run as that account, not as SYSTEM.
- The SPP ISO is mounted straight from the share. If mounting in place fails, it is copied locally first (about 10 GB).
- **Use the SPP release the existing nodes run,** or plan to bring the whole cluster up to it. SUM installs everything newer, so a newer SPP leaves the new node ahead of its peers. Also check the SPP lists Windows Server 2025 support for your Gen10 models.
- Put the version in each filename, so the transcripts record what was installed.

### 4. Access

- The engineer account is local admin on every cluster node (Capture and the drain capacity check read the other nodes remotely), and has rights to change the cluster.
- Outbound HTTPS from the host to `<platform>.rmm.datto.com`, for the Datto agent download.
- SCVMM access to add hosts, apply logical switches and add hosts to clusters.

### 5. Done outside the script

| When | Task |
|---|---|
| Before `PreFlight` | Install WS2025 Datacenter, patch to the peer's level, set the hostname, join the domain, put the management IP on one physical NIC. Create DNS A/PTR records for the management IP. |
| Before the VMM handoff | Switch ports trunked with the host and VM VLANs, no LACP; MTU end to end if using jumbo frames. In SCVMM: a logical switch whose host vNICs match `HostNetworks`. |
| During `Storage` | FC zoning of the WWPNs the script prints. On the 3PAR/Primera, a host object with those WWPNs (persona 15 / WindowsServer) in the cluster's host set. |
| Before `Agents` | A SentinelOne group or policy for Hyper-V hosts with the cluster exclusions (VM config/VHDX paths, `C:\ClusterStorage`, `vmms.exe`, `vmwp.exe`, `vmcompute.exe`, `%SystemRoot%\Cluster`). |
| VMM handoff | Add the host to its host group, apply the logical switch, add the host to the cluster; set the live migration settings in the host's VMM properties (SCVMM manages VM placement paths on a cluster from its CSVs). |
| After `Report` | Add the host to backups, and check the Datto site and monitoring policy. |

## Running it

Download-then-run, elevated:

```powershell
$p="$env:SystemDrive\ArcLogs\HyperVClusterOnboard\ArcHyperVCluster.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-cluster/ArcHyperVCluster.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Capture -SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>
```

Then run `& $p -Phase Next` (see [attended automation](#attended-automation--phase-next)), or `& $p -Phase <Name>` for any single step. On a host's first run, add `-SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>`; after that the host remembers it.

## Config notes

- **`HostNetworks[].Role`** is the host vNIC name (`vEthernet (<Role>)`). The VMM logical switch must create host vNICs with exactly these names, VLANs and subnets; `Report` checks it. A role whose subnet differs from the peer's makes the cluster create a new cluster network.
- **Bandwidth weights:** `DefaultFlowWeight` plus every `Weight` must not exceed 100. The example gives 50 VM / 10 Mgmt / 30 LM / 10 Cluster. Set the same weights in the VMM port classifications.
- **`Storage.MpioSettings`:** Capture fills this with the current node's values; `null` means copy the peer. The [HPE Primera Windows Server implementation guide](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00001330en_us) specifies Microsoft MPIO with the `3PARdataVV` claim and host persona 15, and gives no custom timer values. So this repo ships none.
- **`Hpe.WorkloadProfile`:** `Virtualization-MaxPerformance` sets and locks the dependent BIOS settings (power regulator, C-states, VT-x/VT-d). Pre-flight and Report compare the result with the peer.

## Security notes

- The **Sentinel site token** can be stored in `cluster.json` on the deployment share (`Agents.Sentinel.SiteToken`). It is **never copied to node disks**: the local copies hold a redaction marker instead, so a run from the local copy prompts for it. It is never printed. If it isn't stored, it's prompted as a SecureString. Either way, it's visible on `msiexec`'s command line while the install runs (process auditing, EDR telemetry), because the MSI only accepts it as a property; that can't be avoided. No verbose MSI log is written. The token only lets an agent enrol into that S1 site. If it leaks, regenerate it in the S1 console and update `cluster.json`.
- If in-band `ilorest` login is refused, the script can prompt for iLO credentials. `ilorest` only accepts the password as an argument, so it is briefly visible on that process's command line.

## Not automated (deliberately)

- **Host networking, cluster join, VM placement and live migration host settings:** owned by SCVMM. The script verifies the result.
- **FC zoning and array configuration:** the script prints what to enter.
- **iLO network, hostname and directory settings:** changing them resets the iLO mid-session.
- **SentinelOne exclusions:** set in the S1 console policy.
- **Quorum witness and CAU:** reported by `ClusterBaseline`, not changed.
- **Automatic reboot of a live node:** Baseline drains and stops; an engineer confirms the reboot and Resume runs after logon.

## Status

Pilot. The script parses clean; the fingerprint, Baseline plan builder, host-network check and the `-Phase Next` sequencing (including the VMM handoff) have been exercised with mocked data. It **has not yet been run on a cluster, with SCVMM, or on HPE hardware.** Start with `Capture` (read-only), then run `Baseline` on one node of a cluster you can afford to drain. Check these on the pilot:
- The drain, apply and `Resume` sequence, and that the firewall rule groups keep the cluster healthy when the firewall is switched on.
- `ClusterBaseline` network renames and roles, and the live migration order and exclusions, alongside SCVMM.
- That the VMM logical switch produces host vNICs matching `HostNetworks`, and Report agrees.
- SUM's exit code comes back through `cmd /c` (0 / 1 / 3 success, negative = failure).
- `ilorest` accepts the BIOS attribute names, and `Set-MPIOSetting` behaves as expected.
