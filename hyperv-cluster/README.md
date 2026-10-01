# Hyper-V cluster standard and node onboarding

`ArcHyperVCluster.ps1` defines a best-practice standard for **HPE ProLiant Gen10 / Windows Server 2025 Datacenter** Hyper-V failover clusters on **3PAR/Primera FC** storage with **plain 10GbE** (no RDMA). It brings existing nodes up to that standard and onboards new nodes to it. The same script handles production clusters (4-port SET) and the DR cluster (2-port SET): only the config file differs.

An engineer runs it interactively. It is not a Datto component.

## Design

- **The config file is the standard.** `Capture` writes it from a live node and cluster. You edit it towards best practice. `Baseline` (per node) and `ClusterBaseline` (once) apply it.
- **Peer fallback.** Where a config value is `null`, the script uses the `PeerNode`'s value; with no peer, it leaves that setting alone. For a new node, the peer is also the drift check (`PreFlight` / `Report`).
- **Live nodes are drained first.** `Baseline` shows the full change plan and asks before doing anything. On a cluster member it health-checks the cluster and **drains the node** before changing anything, then stops. You reboot if it says so and run `Resume`. It never touches the vSwitch, vNICs or IPs of an existing node.
- **Phases, run one at a time.** Each phase is safe to re-run. Progress is recorded in `C:\ArcLogs\HyperVClusterOnboard\state.json`, with a transcript per run in the same folder.
- **Anything that changes the live cluster needs the engineer.** This covers the drain (plus typing `DRAIN` if the health check finds problems), cluster changes, and the join (`Test-Cluster` without storage tests, then typing `JOIN`).
- **Installers come from an internal SMB share**, except the Datto agent, which is downloaded from the Datto platform. Every MSI and EXE must pass an Authenticode signature check.

## Workflows

**Existing cluster: set the standard and bring every node up to it**

1. `Capture -SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>` on any node. It writes `cluster.json` to the share (and a local copy), lists captured values that differ from best practice, and shows drift between nodes.
2. Edit `cluster.json` on the share: the Datto site ID and platform, installer file names, and anything Capture flagged (e.g. VM paths not on a CSV).
3. `Baseline` on each node **one at a time**. It shows the plan, then health check, drain, apply, and stop.
4. Reboot if Baseline says so, then `Resume` (you choose whether VMs move back).
5. `ClusterBaseline` once, from any node.

**New node:** `PreFlight` → `Hpe` → `PreFlight` → `Base` → `Network` (console) → `Storage` → `Agents` → **`Baseline`** → `Join` → `HyperV` → `Report`

### Attended automation: `-Phase Next`

Once `cluster.json` is set up, an engineer only needs to run **`-Phase Next`**. It reads `state.json` to see where the host is, then:

- **Runs phases back to back.** Re-checks are automatic: PreFlight runs again after the SPP, Storage repeats until every LUN is visible, Agents repeats until Defender is gone, and Base repeats if VT-x was off.
- **Stops at the human gates** with an `ACTION NEEDED` line. You do the step, then run `-Phase Next` again.
- **Asks before every reboot** (`Reboot now? [y/N]`). It registers a one-shot logon task, so the next phase **starts by itself when you log back on**. There's no auto-logon and no stored password. If you say no, the next `-Phase Next` asks again rather than carrying on un-rebooted.

| Stop | What you do |
|---|---|
| After the first PreFlight | Add this host's `AdapterMacs` (from the NIC list) and IPs to `Nodes` in `cluster.json`; fix any FAIL items |
| Before Network | Log on at the **iLO remote console**. The task launched at your logon then runs Network. |
| Storage | FC zoning, plus the 3PAR/Primera host object (persona 15) with the printed WWPNs |
| Agents | Confirm the host shows as connected in the SentinelOne console, and answer yes to removing Defender |
| Join | Review the validation report and type `JOIN` |

A new node typically takes about **six starts**:
1. PreFlight → stop: add MACs and IPs.
2. Hpe → reboot → PreFlight → Base → reboot → stop: iLO console.
3. Network → Storage → stop: zoning.
4. Storage → Agents → stop: Sentinel.
5. Defender removal → reboot → Baseline (→ reboot) → Join (`JOIN`).
6. HyperV → Report → done.

**On an existing cluster node**, `-Phase Next` runs `Baseline` (health check, drain, apply), asks to reboot, then runs `Resume` after you log back on. Then move to the next node. Run `ClusterBaseline` once by hand after all the nodes are done.

## Phases

| Phase | What it does | Reboot |
|---|---|---|
| `Capture` | Reads this node and every Up node in the cluster over WinRM. Writes the config: host networks from the real vNIC names (VLAN, prefix, weight, gateway, DNS, jumbo), each node's SET member MACs and IPs, switch settings, MPIO claim/policy/timers, Hyper-V settings, BIOS profile target, and live migration network order. Security and optimisation are set to the recommended defaults. Agents and share paths are left as placeholders. Writes `<SettingsShare>\cluster.json` (`-OutPath` to write elsewhere) and a local copy. | - |
| `Baseline` | Applies [security defaults](#security-defaults) and [Hyper-V host optimisations](#hyper-v-host-optimisations), plus the BIOS workload profile, MPIO claim/policy/timers and Hyper-V host settings. Only changes what differs. On a cluster member: health check, drain, apply, stop. | If an item needs it |
| `Resume` | After a Baseline reboot: checks the reboot happened, resumes the node (VMs moved back or not, your choice), and lists anything still different. | - |
| `ClusterBaseline` | Cluster networks named and roled by subnet (Management = ClusterAndClient, others = Cluster; **never None**, which would stop heartbeats). Live migration network order and exclusions. DrainOnShutdown on. Optional: CSV block cache, intra-cluster SecurityLevel. **Report only:** quorum witness (warns if there's none, critical on 2 nodes), CAU role, node states. | - |
| `PreFlight` | Read-only. OS, domain, VT/Secure Boot/TPM, DNS, time source, pending reboot, HPE ilorest/AMS. Lists the physical NICs (MAC, PCI slot, speed) and FC WWPNs. Diffs against the peer: OS build, hotfixes, CPU, system ROM, NIC/HBA drivers, HPE BIOS, MPIO, Hyper-V, and the host-network subnet/VLAN per role. | - |
| `Hpe` | Mounts the SPP ISO from the share and runs **SUM unattended** (`smartupdate /silent`). This applies every component newer than what is installed, with no downgrades. It then checks the iLO Channel Interface driver (CHIF) and AMS, installs `ilorest` from its MSI if missing, and reports the boot volume via `ssacli`. | If SUM says so |
| `Base` | Hyper-V, Failover Clustering, MPIO. High Performance power plan. HPE BIOS workload profile via `ilorest`, set *before* the Hyper-V role (which won't install while VT-x is off). iLO settings are reported only. | Yes |
| `Network` | SET vSwitch on the NICs listed by MAC (weight mode, HyperVPort), NIC power management off, host vNICs per role (VLAN, static IP, bandwidth weight, DNS registration), optional jumbo frames, and a ping to the peer on each network. **Console only.** | - |
| `Storage` | Prints WWPNs for zoning and the array host object (persona 15). Adds the MSDSM claim for `3PARdata`/`VV`, sets the load-balance policy and MPIO timers (peer values), and checks every peer cluster LUN is visible here (matched on `UniqueId`). | If changed |
| `Agents` | Datto RMM agent, then the SentinelOne MSI (site token prompted, hidden). Once Sentinel is running **and** you confirm it is connected in the console, Windows Defender is removed. | Yes |
| `Join` | `Test-Cluster -Ignore Storage`, engineer review, `Add-ClusterNode -NoStorage`. Warns if a new cluster network appears, which means a subnet mismatch. Shows node, network and CSV state. | - |
| `HyperV` | `Set-VMHost`: VM/VHD paths, migration limits, Compression, NUMA spanning (peer value; VMMS restarted if it changed). Runs after `Join` because the CSV paths only exist on a member node. | - |
| `Report` | Final peer diff exported to CSV, plus cluster, agent and phase-completion checks. | - |

After `Hpe`, re-run `PreFlight`. Its firmware and driver comparison against the peer shows what SUM changed.

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
| NIC power management off, VMQ on (SET members) | Stops the OS powering NICs down, and spreads VM traffic across cores |
| Server Manager not opened at logon | Housekeeping |
| MPIO | `3PARdataVV` claim with Microsoft's MSDSM, as the HPE Primera Windows implementation guide specifies. That guide gives no custom timer values, so timers and policy come from the capture or config. |
| Hyper-V | VM/VHD paths on CSV, live migration Compression (best without RDMA), 2 simultaneous live/storage migrations, NUMA spanning as captured |
| Cluster (`ClusterBaseline`) | Live migration on the LM network first and never on Management. DrainOnShutdown on, so a shutdown live-migrates VMs rather than failing them over. |

## Inputs

### 1. `cluster.json`: one per cluster, on the deployment share

Each cluster has its own deployment share. One `cluster.json` sits there next to the SPP ISO and MSIs (see [the share layout](#3-deployment-share)), so every node in that cluster uses the same settings and the same Datto site. For an existing cluster, `Capture` writes it. The layout is in [`cluster.example.json`](cluster.example.json).

- **Give `-SettingsShare <folder>` once per host.** That host's `state.json` remembers it, so later phases need only `-Phase <Name>`.
- **A local copy is kept on every run.** It is written to `C:\ArcLogs\HyperVClusterOnboard\settings-last.json`, plus `settings-used-<phase>-<time>.json` as the record of exactly what each run applied. If the share can't be reached, for example just after the Network phase rebuilds the NICs, the script offers to carry on from the last local copy.
- **Installer paths are relative to the file's folder** (`SPP\<version>.iso`). The same file works wherever the share is mounted. Full paths still work.
- `-ConfigPath <file>` points at one specific file instead, for testing or one-offs.
- **Keep it off GitHub, and keep share access to engineers.** It holds hostnames, IPs, VLANs and the Datto site ID, which count as customer and infrastructure data. `hyperv-cluster/*.json` other than the example is gitignored as a backstop.

| Section | Values |
|---|---|
| Top level | `ClusterName`; `PeerNode`: FQDN of a healthy existing node (Capture sets it to the node it ran on) |
| `Switch` | vSwitch name, load-balancing algorithm (default HyperVPort), default-flow (VM) bandwidth weight, jumbo size or `null` |
| `HostNetworks[]` | Per role (Management / LiveMigration / Cluster): VLAN, prefix length, bandwidth weight, DNS registration, jumbo on/off, `ClusterRole` (`ClusterAndClient` or `Cluster`). Management only: gateway and DNS servers. |
| `Nodes.<hostname>` | One per node (Capture fills in the existing ones): `AdapterMacs` (4 for prod, 2 for DR; `PreFlight` lists them) and a static IP per role |
| `Hpe` | `SppIsoPath`, `IloRestMsiPath`, `WorkloadProfile` |
| `Storage` | MSDSM vendor/product IDs (`3PARdata`/`VV`); load-balance policy and `MpioSettings` (`null` = copy the peer) |
| `HyperV` | VM/VHD paths, migration limits, migration performance, NUMA spanning (`null` = copy the peer, or leave alone with no peer) |
| `Security` | `Apply`, `DisableLegacyTls`, `RequireSmbSigning`, `DisablePrintSpooler`, `InactivityTimeoutSecs`, `LockoutThreshold`, `CredentialGuard` (opt-in), `Hvci` (opt-in). See [Security defaults](#security-defaults). |
| `Optimisation` | `Apply`. See [Hyper-V host optimisations](#hyper-v-host-optimisations). |
| `Cluster` | `LiveMigrationNetworks` (roles in preference order; everything else is excluded from live migration), `DrainOnShutdown`, `BlockCacheSizeMB` and `SecurityLevel` (`null` = leave alone) |
| `Agents` | Datto `Platform` (`pinotage` or `merlot`; prompted if left as the placeholder) and `SiteID`; Sentinel `MsiPath`, `SiteToken` (optional, see below) and `RemoveDefender` |

### 2. Entered at runtime (never stored)

- **Datto platform**: Pinotage or Merlot, prompted in `Agents` only if the config doesn't set it.
- **SentinelOne site token**: only if `Agents.Sentinel.SiteToken` isn't set in `cluster.json`, or this run is using the local copy (which never holds it). Prompted hidden. Take it from the customer's site in the S1 console.
- **iLO credentials**: only if in-band iLO access is refused ("Require Host Authentication" is on).
- **Confirmations**:
  - running SUM
  - creating the SET switch
  - confirming Sentinel shows as connected before Defender is removed
  - applying a Baseline plan, and typing `DRAIN` if the cluster health check found problems
  - resuming, and whether VMs move back
  - applying ClusterBaseline changes
  - typing `JOIN` after reviewing the validation report

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

- The engineer account is local admin on every cluster node (Capture and the drain capacity check read the other nodes remotely), and has rights to change the cluster and add nodes.
- iLO remote console access, for the `Network` phase.
- Outbound HTTPS from the host to `<platform>.rmm.datto.com`, for the Datto agent download.

### 5. Done outside the script

| When | Task |
|---|---|
| Before `PreFlight` | Install WS2025 Datacenter, patch to the peer's level, set the hostname, join the domain. Create DNS A/PTR records for the management IP. |
| Before `Network` | Switch ports trunked with the Management, LM and Cluster VLANs; MTU set end to end if using jumbo frames. |
| During `Storage` | FC zoning of the WWPNs the script prints. On the 3PAR/Primera, a host object with those WWPNs (persona 15 / WindowsServer) in the cluster's host set. |
| Before `Agents` | A SentinelOne group or policy for Hyper-V hosts with the cluster exclusions (VM config/VHDX paths, `C:\ClusterStorage`, `vmms.exe`, `vmwp.exe`, `vmcompute.exe`, `%SystemRoot%\Cluster`). |
| After `Join` | Add the host to backups, and check the Datto site and monitoring policy. |

## Running it

Download-then-run, elevated:

```powershell
$p="$env:SystemDrive\ArcLogs\HyperVClusterOnboard\ArcHyperVCluster.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-cluster/ArcHyperVCluster.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Capture -SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>
```

Then run `& $p -Phase Next` (see [attended automation](#attended-automation--phase-next)), or `& $p -Phase <Name>` for any single step of the [workflow](#workflows). On a host's first run, add `-SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>`; after that the host remembers it. Run `Network` **from the iLO remote console**, and reboot whenever a phase asks you to.

## Config notes

- **`HostNetworks[].Role`** becomes the host vNIC name (`vEthernet (<Role>)`). It must match the vNIC names on the peer, otherwise pre-flight can't compare subnets. Each role's subnet must exactly match the peer's; otherwise the join creates a new cluster network.
- **Bandwidth weights:** `DefaultFlowWeight` plus every `Weight` must not exceed 100. The example gives 50 VM / 10 Mgmt / 30 LM / 10 Cluster.
- **`Switch.JumboPacket`:** leave `null` unless the physical switches are configured end to end. If set (e.g. `9014`), it applies to the physical NICs and to vNICs with `"Jumbo": true`, and the Network phase tests it with a don't-fragment ping.
- **`Storage.MpioSettings`:** Capture fills this with the current node's values; `null` means copy the peer. The keys are `PathVerificationState`, `PathVerificationPeriod`, `PDORemovePeriod`, `RetryCount`, `RetryInterval`, `DiskTimeoutValue`, `UseCustomPathRecoveryTime` and `CustomPathRecoveryTime`. The [HPE Primera Windows Server implementation guide](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00001330en_us) specifies Microsoft MPIO with the `3PARdataVV` claim and host persona 15, and gives no custom timer values. So this repo ships none.
- **`Hpe.WorkloadProfile`:** `Virtualization-MaxPerformance` sets and locks the dependent BIOS settings (power regulator, C-states, VT-x/VT-d). Pre-flight and Report compare the result with the peer.

## Security notes

- The **Sentinel site token** can be stored in `cluster.json` on the deployment share (`Agents.Sentinel.SiteToken`), which saves entering it on every node. It is **never copied to node disks**: the `settings-last` / `settings-used` / `settings-captured` local copies hold a redaction marker instead, so a run from the local copy prompts for it. It is never printed to the console or transcript. If it isn't stored, it's prompted as a SecureString. Either way, it's visible on `msiexec`'s command line while the install runs (process auditing, EDR telemetry), because the MSI only accepts it as a property; that can't be avoided. No verbose MSI log is written, because `/lv*` would record it on disk. The token only lets an agent enrol into that S1 site (no console or API access). If it leaks, regenerate it in the S1 console and update `cluster.json`.
- If in-band `ilorest` login is refused, the script can prompt for iLO credentials. `ilorest` only accepts the password as an argument, so it is briefly visible on that process's command line.

## Not automated (deliberately)

- **FC zoning and array configuration:** the script prints what to enter.
- **iLO network, hostname and directory settings:** changing them resets the iLO mid-session.
- **AD constrained delegation:** only needed for shared-nothing migration.
- **SentinelOne exclusions:** set in the S1 console policy.
- **vSwitch, vNICs and IPs on existing nodes:** SET bandwidth mode can only be chosen when the switch is created. Mismatches show in the drift reports and are fixed in a rebuild window.
- **Quorum witness and CAU:** reported by `ClusterBaseline`, not changed.
- **Automatic reboot of a live node:** Baseline drains and stops; an engineer reboots and runs `Resume`.

## Status

Pilot. The script parses clean, and the fingerprint and Baseline plan builder have been exercised on a Windows 11 machine. It **has not yet been run on a cluster or on HPE hardware.** Start with `Capture` (read-only), then run `Baseline` on one node of a cluster you can afford to drain. Check these on the pilot:
- The drain, apply and `Resume` sequence, and that the firewall rule groups keep the cluster healthy when the firewall is switched on.
- `ClusterBaseline` network renames and roles, and the live migration order and exclusions (`MigrationNetworkOrder` / `MigrationExcludeNetworks`).
- SUM's exit code comes back through `cmd /c` (0 / 1 / 3 success, negative = failure).
- `ilorest` accepts the BIOS attribute names.
- `Set-MPIOSetting` behaves as expected.
