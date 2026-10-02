# Hyper-V cluster standard and VMM-ready host preparation.

> **What this guide covers**
>
> `ArcHyperVCluster.ps1` brings every node in an HPE ProLiant Gen10 Hyper-V cluster up to one Arc standard: security defaults, Hyper-V host optimisations, BIOS profile and multipath. It also prepares a new node from a clean Windows Server 2025 Datacenter install to the point where SCVMM can onboard it. SCVMM then builds the host networking, joins the node to the cluster and owns all workloads.
>
> → The settings for each cluster live in one file, `cluster.json`, on that deployment's share next to the installers.
>
> → An engineer runs one command, `-Phase Next`, repeatedly. The script works out what comes next, stops whenever a person is needed and asks before every reboot.
>
> → Live nodes are health-checked and drained before anything changes.

> **Status:** pilot, version 0.4.0-dev on the develop branch. The script has been tested in a lab with mocked cluster data but has not yet been run on a production cluster or HPE hardware. Run the first Baseline on a node you can afford to drain, and report anything unexpected to the script owner.

## Scope

| Item | Supported |
|---|---|
| Servers | HPE ProLiant Gen10 (iLO 5) |
| Operating system | Windows Server 2025 Datacenter |
| Storage | HPE 3PAR or Primera over Fibre Channel, Microsoft multipath (MPIO) |
| Networking | Plain 10GbE, no RDMA. Production: 4 ports per host. DR: 2 ports per host |
| Clusters | One cluster at the primary site (all running workloads) and one at the secondary site (cold replicas only), each with its own share and `cluster.json` |
| Management | SCVMM owns host networking, cluster membership and all workloads; this script prepares and checks the hosts |
| Run by | An engineer, interactively. This is not a Datto component |

## Where the script ends and SCVMM starts

| Area | Owner |
|---|---|
| HPE firmware (SPP), BIOS workload profile, HPE management tools, boot volume check | Script |
| Windows roles: Hyper-V, Failover Clustering, Multipath I/O | Script |
| Fibre Channel multipath and disk visibility | Script |
| Datto, SentinelOne and Defender removal | Script |
| Security baseline, host optimisations and NUMA spanning | Script |
| Drift checks against an existing node; drain, apply and resume for host changes | Script |
| Cluster network names and roles, live migration network order | Script (ClusterBaseline) |
| Host networking: SET switch and host adapters, through the logical switch and IP pools | SCVMM |
| Adding the host to SCVMM and to the cluster | SCVMM |
| VM placement paths and live migration host settings | SCVMM |
| VM networks, templates, placement and all workloads | SCVMM |

The script still checks what SCVMM builds. The final report fails a node whose host adapters do not match the agreed design in `cluster.json`, so a logical switch that drifts from the design is caught.

One SCVMM manages the whole Arc platform: one cluster per site, with each customer's workloads in their own SCVMM cloud. Every workload runs at the primary site; the secondary site holds powered-off replicas only, ready to start in a disaster. Both clusters are built and checked with this script in the same way. How SCVMM itself is built and configured (management servers, host groups, networking fabric, customer clouds, host settings, VM templates, access and operations) is in the separate SCVMM baseline guide.

## Before you start

### Access

→ A domain account that is a local administrator on every cluster node and can manage the cluster and add nodes.

→ Read access to the deployment share, plus write access for the Capture step.

→ SCVMM rights to add hosts, apply logical switches and add hosts to clusters.

→ Outbound HTTPS from hosts to the Datto platform (Pinotage or Merlot) for the Datto agent download.

### Prepared in advance

| Where | What |
|---|---|
| SentinelOne console | A Hyper-V host group or policy with the cluster exclusions: VM configuration and VHDX paths, the ClusterStorage folder, vmms.exe, vmwp.exe, vmcompute.exe and the Windows Cluster folder |
| Network switches | Host ports trunked with the Management, Live Migration and Cluster VLANs and every VM VLAN, with no LACP. MTU set end to end only if jumbo frames are used |
| SCVMM | A logical switch whose host adapters match HostNetworks in `cluster.json`: the same names, VLANs, subnets and bandwidth weights |
| HPE support portal | The SPP release that the existing nodes run, and that lists Windows Server 2025 for your Gen10 models |
| Deployment share | Created and populated as below |

## The deployment share

Each cluster has its own deployment share. Everything a build needs sits in one folder:

```
\\<SERVER>\<SHARE>\<DEPLOYMENT>\
    cluster.json                                  settings for this cluster
    SPP\<SPP_VERSION>.iso                         Service Pack for ProLiant
    HPE\ilorest-<VERSION>.msi                     HPE RESTful Interface Tool
    SentinelOne\SentinelInstaller-<VERSION>.msi   SentinelOne agent (MSI)
```

→ Put the version in every file name; the logs then record exactly what was installed.

→ Restrict the share to engineers. `cluster.json` holds IP addresses, VLANs, the Datto site ID and the SentinelOne site token.

→ Never copy `cluster.json` into the GitHub repository; the repository is public.

## The settings file: cluster.json

`cluster.json` is the standard for the cluster. The Capture step writes it from the live cluster; an engineer then edits it. Every node reads the same file, so every node in a deployment gets the same settings and the same Datto site.

| Section | Contents | Who fills it in |
|---|---|---|
| ClusterName, PeerNode | Cluster name and a healthy existing node to compare new nodes against | Capture |
| Switch, HostNetworks | The agreed host networking that the SCVMM logical switch must produce: each host network with its VLAN, subnet, bandwidth weight, gateway, DNS and cluster role. The script checks every node against it | Capture |
| Nodes | Optional record of each existing node's adapter MACs and IPs. New nodes need no entry; SCVMM assigns their host adapter IPs | Capture |
| Hpe | SPP and ilorest file names (relative to the share), BIOS workload profile | Engineer: file names |
| Storage | Multipath claim (3PARdata / VV), load-balance policy and timers | Capture |
| HyperV | NUMA spanning. VM paths and live migration host settings are set in SCVMM | Capture |
| Security, Optimisation | Switches for each group of settings; Credential Guard and HVCI are opt-in | Defaults; engineer for opt-ins |
| Cluster | Live migration network order, drain on shutdown, optional CSV cache and cluster security level | Capture |
| Agents | Datto platform (pinotage or merlot) and site ID; SentinelOne MSI name and site token | Engineer |

> **About the SentinelOne site token**
>
> The token is stored in `cluster.json` on the share so engineers do not have to enter it on every node. It is never copied to a node's disk: local copies of the settings show a redaction marker instead, and the token is never printed. If the token is missing, or the share cannot be reached, the script asks for it with hidden input. The token only allows an agent to enrol into that SentinelOne site. If it is ever exposed, regenerate it in the SentinelOne console and update `cluster.json`.

## How the networking works

Each host uses a converged design: all of its Ethernet ports join one virtual switch, and both host traffic and VM traffic run over it, kept apart by VLANs and protected by bandwidth weights. Storage does not use Ethernet at all; it runs over Fibre Channel.

SCVMM builds and owns this networking through a logical switch. The script does not create switches or adapters; it checks that what SCVMM built matches the agreed design in HostNetworks in `cluster.json`.

### The layout on a production host

```
            Physical switch A                   Physical switch B
           (trunk: all VLANs)                  (trunk: all VLANs)
             |           |                       |           |
          NIC 1       NIC 2                   NIC 3       NIC 4        4 x 10GbE, no LACP
             \___________\_______________________/___________/
                                     |
          SET vSwitch, built by the SCVMM logical switch
          (embedded team, Hyper-V Port load balancing, weight mode)
                                     |
     +---------------+---------------+---------------+-----------------------+
     |               |               |               |                       |
 vEthernet       vEthernet       vEthernet        VM network adapters     more VMs
 (Management)    (LiveMigration) (Cluster)        on SCVMM VM networks
 VLAN a          VLAN b          VLAN c           VLAN x, y, z
 weight 10       weight 30       weight 10        share weight 50
 gateway + DNS   no gateway      no gateway
     |               |               |
 host traffic    live migration  heartbeat and CSV traffic

 Storage: FC HBAs -> FC switches -> 3PAR / Primera   (separate from all of the above)
```

DR hosts are identical with 2 ports instead of 4. The weights shown are the example values; a real cluster uses the values Capture reads from its existing nodes.

### Physical ports and the vSwitch

→ All of a host's ports join one SET team and one vSwitch. There are no separate switches per traffic type.

→ SET is switch-independent: the physical switch ports are plain trunks, with no LACP and no port-channel. In SCVMM this is the uplink port profile's teaming mode.

### Host traffic: several vEthernet adapters on one vSwitch

A vSwitch can carry many host network adapters. Each one is a separate virtual NIC that Windows shows as `vEthernet (name)`, with its own IP address, VLAN, DNS settings and bandwidth weight. SCVMM creates three when it applies the logical switch:

| Host adapter | Carries | IP settings | Cluster role |
|---|---|---|---|
| Management | RDP, domain, DNS, backups, Datto, SentinelOne, WinRM, the SCVMM agent. The cluster name and IP live here | IP, default gateway, DNS, registers in DNS | Cluster and client |
| LiveMigration | Live migration, compressed | IP only: no gateway, not registered in DNS | Cluster only |
| Cluster | Heartbeats between nodes, and CSV traffic if a node has to reach storage through another node | IP only: no gateway, not registered in DNS | Cluster only |

→ The adapter names must match the Role names in HostNetworks exactly. The script's checks, and the cluster network names ClusterBaseline sets, match on these names.

→ Only Management has a default gateway. A gateway on more than one adapter makes routing unpredictable.

→ LiveMigration and Cluster are local subnets used only by the cluster nodes.

→ To see them on a host, run `Get-VMNetworkAdapter -ManagementOS`; `Get-NetAdapter` lists them alongside the physical NICs.

### VM traffic

VMs connect to the same vSwitch through SCVMM VM networks. Each VM network maps to a VLAN, so engineers pick a VM network by name when creating or moving a VM instead of typing a VLAN ID. VMs cannot see the host's Management, LiveMigration or Cluster VLANs unless a VM is deliberately placed on one of those VM networks.

### How the design maps to SCVMM

| Part of the design | SCVMM object | Settings |
|---|---|---|
| Each host network (Management, LiveMigration, Cluster) | A logical network with a network site per location, scoped to the cluster's host group | The VLAN and subnet from HostNetworks |
| Host adapter IP addresses | A static IP pool on each host network site | Management pool includes the gateway and DNS servers. LiveMigration and Cluster pools have no gateway and no DNS |
| VM VLANs | A logical network and network sites for VM traffic, with a VM network per VLAN | VLAN-based VM networks |
| Teaming | Uplink port profile | Switch independent, Hyper-V Port load balancing, every host and VM network site included |
| Bandwidth weights | A port classification and virtual port profile per host role, plus one for VM traffic | Minimum bandwidth weight from HostNetworks (example: 10, 30, 10) and 50 for VMs. VMQ enabled |
| The vSwitch | Logical switch | Uplink mode Embedded Team (SET). Minimum bandwidth mode Weight, which is fixed when the logical switch is created |
| The host adapters | Virtual network adapters defined when the logical switch is applied to a host | Names exactly as the HostNetworks roles, each on its VM network and VLAN, with its port classification and an IP from its pool. Management is marked for host management and inherits the physical adapter's settings |

The physical NICs, VLANs, IP pools and port classifications need setting up once per cluster in SCVMM. After that, every node gets identical networking by applying the same logical switch.

### Applying the logical switch to a host

→ Select all the host's 10GbE ports as the logical switch uplinks. PreFlight lists them with their MAC addresses and slots.

→ Add the three host adapters with the exact role names. Mark Management as the host management adapter so it takes over the host's existing management IP; the connection may drop briefly while it moves.

→ Once it completes, the script's final report checks the result: the switch is SET in weight mode, every role's adapter exists with the right VLAN and an IP on the same subnet as the other nodes, and there are no unexpected extra adapters.

→ On an existing node, bringing its current switch under the logical switch, or rebuilding it, changes live networking. Drain the node first and do one node at a time.

### How bandwidth is shared

Bandwidth weights are minimum guarantees, not limits. When the links are quiet, any traffic can use everything available to it. When a link is busy, each type is guaranteed at least its share: VMs 50%, live migration 30%, Management 10% and Cluster 10% in the example. A large live migration therefore cannot starve VM traffic or the cluster heartbeat; a starved heartbeat is what causes false failovers.

Weights only work when the vSwitch is built in weight mode, and in SCVMM that is chosen when the logical switch is created. Create the logical switch in weight mode from the start; changing it later means a new logical switch and a planned rebuild of every host's switch. The script's checks warn about any host whose switch is not in weight mode.

### How traffic spreads across the ports

→ Each adapter, host or VM, uses one physical port at a time. The vSwitch spreads adapters across all the ports.

→ A single VM or a single live migration therefore peaks at 10Gb, while many VMs together can use all 40Gb (20Gb on DR hosts).

→ If a port, cable or physical switch fails, its adapters move to the surviving ports within about a second. The host stays up and RDP sessions survive.

### Live migration

→ Uses the LiveMigration network first, then Cluster. Management is excluded, so migrations never compete with RDP, backups or the cluster name. ClusterBaseline sets this order on the cluster.

→ Uses compression rather than SMB Direct, because the design has no RDMA. It spends some CPU to send less data, which suits 10GbE. This and the number of simultaneous migrations (two per host) are set in each host's SCVMM migration settings.

### Storage traffic

VM disks reach the 3PAR or Primera over Fibre Channel, completely separate from Ethernet. The only storage-related Ethernet traffic is CSV redirected I/O: if a node temporarily loses its own Fibre Channel paths, it reaches the disks through another node over the Cluster network. This is normally zero, and it is the reason the Cluster network has a protected share.

### What the network team needs to provide

| Item | Requirement |
|---|---|
| Port mode | Trunk on every host port, carrying the Management, LiveMigration and Cluster VLANs plus every VM VLAN that SCVMM's VM networks use |
| Teaming | No LACP and no port-channel; SET does the teaming on the host. Configure the ports as edge (portfast) ports |
| Resilience | Split each host's ports across two physical switches, for example NIC 1 and 2 to switch A and NIC 3 and 4 to switch B |
| Consistency | The same VLANs on every host's ports, and the LiveMigration and Cluster subnets identical on every node. A mismatched subnet makes the cluster create an extra network; the script's final report catches it |
| MTU | Standard 1500 unless jumbo frames are agreed. Jumbo frames must be set end to end on every switch in the path, and on the host adapters through SCVMM |
| New VLANs | Agree them with the SCVMM team, so the trunk and the SCVMM network site are updated together |

### Who builds the networking

| Situation | What happens |
|---|---|
| New node | Before SCVMM the host needs only its management IP on one physical adapter. SCVMM applies the logical switch, which builds the SET vSwitch and the host adapters; its management adapter takes over the management IP. The script's final report then checks the result against HostNetworks |
| Existing node | The script never changes the vSwitch, host adapters or IP addresses. Capture records them, and differences are fixed in SCVMM |
| Whole cluster | ClusterBaseline names the cluster networks after their roles, sets which networks carry client traffic, and sets the live migration order |
| Adding a host network | Add it to SCVMM (logical network, IP pool, port classification, logical switch) and to HostNetworks in `cluster.json`, so the checks expect it |
## Getting the script

On the host, open an elevated PowerShell prompt and paste this as a single line. Replace the share path with the deployment's share. Use `-Phase Capture` on an existing node or `-Phase Next` on a new one.

```powershell
$p="$env:SystemDrive\ArcLogs\HyperVClusterOnboard\ArcHyperVCluster.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/hyperv-cluster/ArcHyperVCluster.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Phase Capture -SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>
```

The share is only needed on a host's first run. The host remembers it, so every later command is simply:

```powershell
& $p -Phase Next
```

## Process 1: capture and remediate an existing cluster

Use this to define the standard for a cluster that is already built and running, then bring each node up to it.

### Step 0: get the cluster to capture readiness

Capture copies what it finds. The node it runs on becomes the template for every setting that Baseline does not own, and the networking layout it reads becomes the layout every new node is built to. A cluster therefore has to reach a minimum level before Capture is worth running. The requirements fall into three levels.

#### Level 1: must be in place before Capture

If any of these is missing, Capture either fails or writes a config that cannot be used to build or check nodes.

| Requirement | Why it matters | Fix if it is not met |
|---|---|---|
| Every node Up, every CSV online, no failed cluster resources | Capture reads every node over WinRM, and nodes that are down are left out of the config | Resolve the cluster health issue first |
| WinRM works from the capture node to every node, and the engineer account is a local administrator on all of them | Capture reads each node remotely | Enable WinRM, or fix group membership |
| Each node has one SET vSwitch for host and VM traffic | Capture reads the team members' MACs and the switch settings from it. An LBFO team or a non-teamed switch gives no usable network layout | Rebuild that node's networking with the SCVMM logical switch, one drained node at a time |
| Host traffic runs on host vEthernet adapters, one per role, with an IPv4 address | The roles in the config come from these adapter names | Add the missing host adapters through the SCVMM logical switch, with the node drained |
| The same host adapter names on every node, for example Management, LiveMigration, Cluster | New nodes and the subnet checks match on name | Align the names in the SCVMM logical switch, or rename on the drained node: `Rename-VMNetworkAdapter -ManagementOS -Name old -NewName new` |
| Exactly one host adapter with a default gateway (Management) | Capture uses the gateway to identify the management network and its cluster role | Remove the extra gateways |
| Each role on the same subnet and VLAN on every node | A mismatch creates extra cluster networks and breaks the live migration order | Correct the IP pool or VLAN in SCVMM for the odd node, with the node drained |
| Hyper-V, Failover Clustering and Multipath I/O installed, with the 3PARdata VV device claimed | Capture records the multipath and Hyper-V settings | Install and claim. A claim needs a reboot, so drain the node first |

#### Level 2: review, because these values become the standard

Capture works without these, but whatever the capture node has is written into the config and then applied to every node. Get them right on the capture node, or correct them in `cluster.json` after Capture.

| Item | What to check |
|---|---|
| Choice of capture node | Use the node you trust most. Its multipath, Hyper-V and live migration values become the standard |
| vSwitch bandwidth mode | Weight mode on every node. Weights cannot be applied to a switch built in another mode, and the mode cannot be changed without rebuilding the switch. Note any node that differs and plan a rebuild |
| Bandwidth weights | VM traffic plus all host adapter weights total 100 or less. The adapters carrying the cluster heartbeat get a real share |
| Multipath load-balance policy and timers | The same on every node, and the values you intend. HPE gives no custom timer values for Primera, so these are the cluster's own settings |
| Default VM and VHD paths | On a cluster shared volume, not the C: drive. Set in SCVMM; Capture prints the current values as a note |
| Live migration host settings | Compression, and a sensible number of simultaneous migrations (two is the usual choice at 10GbE). Set in SCVMM; Capture prints the current values as a note |
| NUMA spanning | The same on every node, and a deliberate choice |
| Jumbo frames | Either off everywhere, or on everywhere and set end to end on the physical switches |
| Patch level and SPP | The same on every node. Capture reports hotfix and driver drift per node, but it is better to close obvious gaps first |
| HPE tools on the capture node | ilorest and the iLO Channel Interface driver installed, so Capture can read the BIOS profile. Without them the BIOS comparison is empty |
| Test or temporary host adapters | Removed before Capture, otherwise they become a role that every new node is built with |

#### Level 3: leave for Baseline to fix

These do not need to be right before Capture. The config sets the standard for them, and Baseline brings every node into line one node at a time:

→ Security settings: SMB, TLS, NTLM, firewall, Remote Desktop, UAC, lockout, Print Spooler.

→ Optimisation settings: power plan, hibernation, NTFS, scheduled tasks, NIC power saving, VMQ.

→ BIOS workload profile.

→ Multipath and Hyper-V values, once they are correct in `cluster.json`.

→ Cluster network names, roles and live migration order, which ClusterBaseline sets.

#### Quick readiness check

Run this on the node you plan to capture from. It only reads, and it shows the Level 1 items for every node side by side.

```powershell
Get-ClusterNode | Format-Table Name, State
Get-ClusterSharedVolume | Format-Table Name, State
Get-ClusterResource | Where-Object State -eq 'Failed' | Format-Table Name, OwnerGroup
Invoke-Command -ComputerName (Get-ClusterNode).Name -ScriptBlock {
    $sw = @(Get-VMSwitch -SwitchType External)
    [pscustomobject]@{
        Node      = $env:COMPUTERNAME
        Switches  = ($sw | ForEach-Object { "$($_.Name) SET=$($_.EmbeddedTeamingEnabled) Mode=$($_.BandwidthReservationMode)" }) -join '; '
        HostNICs  = ((Get-VMNetworkAdapter -ManagementOS).Name | Sort-Object) -join ', '
        Gateways  = ((Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).InterfaceAlias | Sort-Object -Unique) -join ', '
        MpioClaim = ((Get-MSDSMSupportedHW -ErrorAction SilentlyContinue | Where-Object VendorId -like '3PAR*' | ForEach-Object { "$($_.VendorId.Trim())/$($_.ProductId.Trim())" }) -join ', ')
        Build     = "$((Get-CimInstance Win32_OperatingSystem).BuildNumber).$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"
        ilorest   = [bool](Get-Command ilorest.exe -ErrorAction SilentlyContinue) -or (Test-Path "$env:ProgramFiles\Hewlett Packard Enterprise\RESTful Interface Tool\ilorest.exe")
    }
} | Format-Table Node, Switches, HostNICs, Gateways, MpioClaim, Build, ilorest -AutoSize -Wrap
```

A cluster is ready to capture when every node shows the following:

→ State Up, with every CSV online and no failed resources.

→ One switch with SET=True. Mode=Weight is wanted; any other mode is a Level 2 item to plan for.

→ The same host adapter names on every node, and only the management adapter under Gateways.

→ 3PARdata/VV under MpioClaim, and the same Build on every node.

→ ilorest True on the capture node at least.

Changes to networking or multipath on a live node, such as a rename, a new adapter or a device claim, follow the same rule as Baseline: drain the node first and do one node at a time.

### Step 1: capture the cluster

Run on any node. This step only reads; nothing on the cluster changes.

```powershell
& $p -Phase Capture -SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>
```

The script reads this node and every running node, writes `cluster.json` to the share, then reports:

→ Captured values that differ from best practice, for example a BIOS profile other than Virtualization Max Performance, or VM paths that are not on a cluster shared volume.

→ Drift between nodes: how many settings and hotfixes differ on each node compared with this one. A CSV per node is saved in the ArcLogs folder.

If `cluster.json` already exists, the script asks before overwriting it and keeps the Agents section and installer file names.

### Step 2: edit cluster.json

Open `cluster.json` on the share and complete:

→ Agents: Datto platform and site ID, SentinelOne MSI file name and site token.

→ Hpe: the SPP and ilorest file names.

→ Anything Capture flagged. Notes about VM paths and live migration host settings are for SCVMM, not `cluster.json`.

→ Opt-in security choices, such as Credential Guard.

### Step 3: baseline each node, one at a time

On the first node:

```powershell
& $p -Phase Next
```

| What the script does | What you do |
|---|---|
| Shows the change plan: each setting with its current value, the target value and whether it needs a restart. Settings that already comply, or are stricter than the standard, are left alone | Read the plan and confirm |
| Checks cluster health. It stops outright if this is a single-node cluster or another node is down. It asks you to type DRAIN to continue if CSVs are offline, resources have failed, the witness is offline (or missing on a two-node cluster), or the other nodes may lack the memory for this node's VMs | Type DRAIN only if you are satisfied the warning is safe |
| Drains the node: all VMs live-migrate to other nodes and the node is paused | Nothing |
| Applies each change and reports OK or FAIL, then re-checks and lists anything still different. A setting that will not stick is usually being overridden by a domain group policy | Fix any group policy conflicts in the GPO |
| Asks to reboot. A one-shot task is set so the next step starts when you log back on | Confirm the reboot, then log back on |
| After logon: checks the reboot happened and that every cluster network on the node is up, then resumes the node | Choose whether the drained VMs move back |

Repeat on each remaining node. Do one node at a time and let each node finish before starting the next.

### Step 4: apply the cluster-wide settings

Run once, from any node, after all nodes are done:

```powershell
& $p -Phase ClusterBaseline
```

The script shows the planned changes and asks before applying them. None of them restarts a node.

→ Names each cluster network after its role and sets its role: Management carries cluster and client traffic; Live Migration and Cluster carry cluster traffic only.

→ Sets the live migration network order (Live Migration first, then Cluster) and excludes Management from live migration.

→ Turns on drain on shutdown, so shutting down a node live-migrates its VMs instead of failing them over.

→ Reports the quorum witness, Cluster-Aware Updating and node states. It warns if a two-node cluster has no witness.

Two safety checks apply. The script will not make the network carrying the cluster name cluster-only, and it will not change live migration settings if none of the configured networks can be matched.

## Process 2: add a new node to the cluster

A new node is prepared by the script, onboarded by SCVMM, then checked by the script.

### Starting point

→ Windows Server 2025 Datacenter installed and patched to the same level as the existing nodes.

→ Hostname set and joined to the domain, with the management IP on one physical network adapter and DNS forward and reverse records for it.

→ Switch ports trunked, the SCVMM logical switch ready, and `cluster.json` already on the share (from Process 1). The new node needs no entry in `cluster.json`.

### The build

Every start is the same command. On the first run, add the share:

```powershell
& $p -Phase Next -SettingsShare \\<SERVER>\<SHARE>\<DEPLOYMENT>
```

The script runs as many phases as it can, stops whenever a person is needed, and asks before every reboot. After a reboot, log back on and it carries on by itself.

| Start | What the script does | Where it stops and what you do |
|---|---|---|
| 1 | Pre-flight checks against an existing node, listing the network adapters and Fibre Channel WWPNs. Installs the SPP unattended from the share and reboots. Re-checks firmware and drivers, sets the BIOS workload profile, installs Hyper-V, Failover Clustering and MPIO, and reboots. Sets up multipath | Confirm each reboot and log back on. It stops for zoning: zone the WWPNs on the Fibre Channel switches and add the host to the 3PAR or Primera (host persona 15) in the cluster's host set |
| 2 | Confirms every cluster disk is visible. Installs the Datto agent and the SentinelOne agent, using the stored site token | Check the host shows as connected in the SentinelOne console, move it into the Hyper-V group, then confirm Defender removal and the reboot |
| 3 | Applies the Baseline (security and optimisation) and reboots if needed. Reports that the host is VMM-ready | Hand over to SCVMM (below) |
| 4 | Confirms the node is a cluster member, re-runs the Baseline now the vSwitch exists, resumes the node if it was drained, and produces the final report, including the check that the host networking matches `cluster.json` | Nothing. The node is complete |

### The SCVMM handoff

When the script reports the host as VMM-ready, in SCVMM:

→ Add the host to its host group. SCVMM installs its agent.

→ Apply the logical switch. SCVMM builds the SET vSwitch and the Management, LiveMigration and Cluster host adapters, assigns their IP addresses, and moves the management IP from the physical adapter to the management host adapter. The connection may drop briefly.

→ Set the host's live migration settings (compression, two simultaneous migrations). Do not set VM placement paths by hand on a clustered host; SCVMM manages them from the cluster shared volumes.

→ Add the host to the cluster. SCVMM runs cluster validation as part of this.

Then log on to the host and run `-Phase Next` again for start 4.

### After the script

→ Add the host to backups.

→ Check the Datto site and monitoring policy.

→ Live-migrate a non-critical VM onto the new node and back off it.
## What Baseline changes

### Security defaults

These match the Arc gold-image security baseline, with one addition for Hyper-V hosts.

| Setting | Standard |
|---|---|
| SMB version 1 | Off and removed |
| SMB signing | Required, server and client |
| Windows Firewall | On for all profiles. The cluster, Hyper-V, WinRM, file sharing, WMI and Remote Desktop rules are enabled first so cluster traffic is not interrupted |
| SSL 3.0, TLS 1.0, TLS 1.1 | Off, server and client. Restart needed |
| NTLM | NTLMv2 only; WDigest plaintext credentials off |
| LLMNR, AutoRun, AutoPlay | Off |
| User Account Control | On, prompting on the secure desktop |
| Inactivity lock | 15 minutes. A shorter existing lock is kept |
| Remote Desktop | Allowed, with Network Level Authentication, TLS and high encryption |
| Local account lockout | 10 attempts, 15 minutes. A stricter existing setting is kept |
| Guest account | Disabled |
| Print Spooler | Disabled; a Hyper-V host has no need to print |
| Credential Guard, memory integrity (HVCI) | Opt-in only, off by default. Check HPE driver compatibility before turning on HVCI |

### Hyper-V host optimisations

| Setting | Reason |
|---|---|
| High Performance power plan and BIOS profile Virtualization Max Performance | Removes power-saving latency for VMs |
| Hibernation off | A cluster node never hibernates and the file wastes disk space |
| NTFS last-access updates and 8.3 short names off | Removes metadata writes that add nothing |
| Telemetry, Maps and error-reporting scheduled tasks off | Removes background work on the host |
| Scheduled defrag left on | On 3PAR and Primera thin volumes it also returns freed space to the array |
| Network adapter power saving off, VMQ on | Stops adapters powering down and spreads VM network load across processor cores |
| Multipath | 3PARdata VV claim with Microsoft MPIO, as HPE's Primera Windows implementation guide specifies. Timers come from the captured cluster |
| NUMA spanning | The same on every node, as captured. VM placement and live migration host settings are set in SCVMM |

## Safety controls

→ Nothing changes without a confirmation, and every plan is shown before it runs.

→ Live nodes are always health-checked and drained before changes, and only one node is worked on at a time.

→ Reboots are always confirmed by the engineer. There is no automatic logon and no stored password.

→ Installers must pass a digital signature check before they run.

→ The script checks the host networking SCVMM builds against the agreed design, and fails a node that does not match.

The script never does the following; it reports them and leaves them to an engineer:

| Not automated | Why |
|---|---|
| Fibre Channel zoning and array configuration | Done on the switches and the array |
| Host networking, cluster join, VM placement and live migration host settings | Owned by SCVMM. The script checks the networking result |
| Quorum witness and Cluster-Aware Updating changes | Reported only; changes need planning |
| iLO network and directory settings | Changing them resets the iLO mid-session |
| SentinelOne exclusions | Set in the SentinelOne console policy |

## Logs and records

Every host keeps a full record in its ArcLogs folder:

```
C:\ArcLogs\HyperVClusterOnboard\
    <Phase>-<time>.log                    full transcript of every run
    settings-used-<phase>-<time>.json     the exact settings each run used (token redacted)
    settings-last.json                    fallback copy if the share cannot be reached
    *-diff-*.csv, *-checks-*.csv          comparisons with the existing node and check results
    state.json                            phases completed, pending reboots, drain state
```

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| Cannot read the settings from the share | The script offers the last local copy. Accept it to carry on; it will ask for the SentinelOne token if it needs it. Fix share access before the next node |
| Health check asks you to type DRAIN | Read each warning. Only continue if you are confident the remaining nodes can carry the load |
| Drain did not complete | The node stays paused. Move the listed VMs by hand, or run `-Phase Resume` to undo |
| A setting still differs after Baseline | Usually a domain group policy is setting it. Change the GPO, not the host |
| LUNs not visible | Check zoning and that the host is in the cluster's host set on the array, then run `-Phase Next` again |
| SUM failed | Check the SUM logs in the cpqsystem folder on the host, fix the component, then run `-Phase Next` again |
| In-band iLO login refused | iLO "Require Host Authentication" is on. The script offers to use iLO credentials instead |
| Report fails on host networking | The SCVMM logical switch did not produce what HostNetworks describes: a host adapter is missing, named differently, on the wrong VLAN, or on a different subnet from the other nodes. Fix it in SCVMM, or update HostNetworks if the design changed |
| Report warns about an extra host adapter | A test or extra adapter that is not in HostNetworks. Remove it, or add the role to `cluster.json` |

## Reference

### Running a single phase

`-Phase Next` is the normal way to run the script. Any phase can also be run on its own:

| Phase | Purpose |
|---|---|
| Capture | Write `cluster.json` from the live cluster |
| Baseline | Apply the security and optimisation standard to this node |
| Resume | Bring a drained node back into the cluster |
| ClusterBaseline | Apply the cluster-wide settings |
| PreFlight | Read-only checks and comparison with the existing node |
| Hpe | SPP, HPE tools and boot volume check |
| Base | BIOS profile and Windows roles |
| Storage | Multipath and disk visibility |
| Agents | Datto, SentinelOne and Defender removal |
| Report | Final comparison and checks, including host networking against HostNetworks |

### Source

The script, README and change log are in the Arc Automations repository on GitHub, in the hyperv-cluster folder. Only placeholder examples are kept there; real settings files stay on the deployment shares.

> **Page owner:** OWNER NAME · **Script version:** 0.4.0-dev · **Last reviewed:** 02/10/2026
