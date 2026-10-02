# SCVMM baseline for the Arc hosting platform.

> **What this guide covers**
>
> The standard way Arc builds and runs System Center Virtual Machine Manager (SCVMM) for its hosting platform: one SCVMM managing a Hyper-V cluster at each of two sites. Every customer workload runs at the primary site in the customer's own SCVMM cloud. The secondary site holds cold replicas only: powered off, kept up to date, and ready to start if the primary site is lost.
>
> → SCVMM owns host networking, cluster membership, VM placement, live migration host settings and every customer workload.
>
> → `ArcHyperVCluster.ps1` prepares each host to "VMM-ready" and then checks what SCVMM builds against that cluster's `cluster.json`. See the Hyper-V cluster standard guide.
>
> → Every value in this guide that also appears in `cluster.json` must match it. Where the two disagree, the script's final report fails the node.

> **Status:** draft baseline. The structure and settings follow Microsoft's published guidance and the Arc cluster design, but have not yet been proven on the Arc platform. Validate each section in a lab or during the first build, and confirm version-specific details against Microsoft's documentation for the SCVMM release you deploy.

## The platform

```
                              SCVMM (Arc infrastructure domain)
                                           |
                 +-------------------------+-------------------------+
                 |                                                   |
        Primary site cluster                               Secondary (DR) site cluster
     every workload runs here                     cold replicas only: powered off, kept in sync
                 |                                                   |
   +-------------+-------------+                       +-------------+-------------+
   |             |             |    replication -->    |             |             |
 Cloud:        Cloud:        Cloud:                  DR cloud:     DR cloud:     DR cloud:
 Customer A    Customer B    Customer C              Customer A    Customer B    Customer C
 running VMs   running VMs   running VMs             replicas      replicas      replicas
```

Nothing runs at the secondary site in normal operation. A replica is only started in a failover, a failover test, or a planned move.
## Principles

| Principle | What it means in practice |
|---|---|
| One SCVMM for the whole platform | A single SCVMM in Arc's infrastructure domain manages every site's cluster. It is a critical platform service and is built and protected accordingly |
| One cluster per site | Each site has one Hyper-V cluster, with its own `cluster.json` on its own deployment share |
| Live at primary, cold at secondary | Every workload runs at the primary site. The secondary site holds powered-off replicas only, and must always have the capacity, networks and runbook to start them |
| Hosts belong to Arc, not to customers | Hosts, clusters and SCVMM are members of the Arc infrastructure domain. Customer VMs never join that domain |
| One cloud per customer per site | Each customer has a working cloud at the primary site and a DR cloud at the secondary site that holds their replicas |
| Customers are separated by network and by role | Each customer has its own VLANs and VM networks, and SCVMM user roles limit each engineer or customer to the right clouds |
| SCVMM is the source of truth | VMs, VM networks and host networking are created and changed in SCVMM, not in Hyper-V Manager or Failover Cluster Manager |
| Names are part of the design | Object names follow the convention below, and host adapter names match HostNetworks in `cluster.json` exactly |
| Changes to live hosts are drained first | Any change that touches a host's networking or needs a restart is done one node at a time, with the node in maintenance mode |

## SCVMM architecture

### Components

| Component | Arc baseline |
|---|---|
| VMM management server | Highly available: two VMM servers in a failover cluster. One SCVMM runs the whole platform, so losing it would stop provisioning and management for every customer |
| Database | SQL Server, highly available (an Always On availability group or a SQL failover cluster), dedicated to SCVMM and other platform management databases |
| Library server | A dedicated library server or file share for templates, ISOs and scripts, separate from the VMM servers |
| VMM console | Installed only on Arc's management jump hosts, never on the hypervisors or on engineer laptops |
| SCVMM agent | Installed on every Hyper-V host by SCVMM when the cluster or host is added |

### Where SCVMM runs

→ The VMM servers, the SQL Server and the library are platform management VMs. They run at the primary site, spread across nodes, with automatic start.

→ They are replicated to the secondary site like customer VMs, and the SCVMM database is also backed up to the secondary site, so SCVMM can be brought up there first in a disaster.

→ If the primary site is lost, SCVMM is started at the secondary site (from its replicas, or rebuilt and restored from the database backup) before any customer replica, because it is needed to manage the failover.

→ Exclude the management VMs from dynamic optimisation, so they stay where engineers expect them during maintenance.

→ Give every management VM a static IP on the management network. They are never placed in a customer cloud.

### Sizing starting point

| Item | Starting point per server |
|---|---|
| VMM server | 4 vCPU, 16 GB RAM, separate OS and data volumes |
| SQL Server | 4 vCPU, 16 GB RAM, separate data, log and backup volumes |
| Library | Sized for templates, ISOs and scripts; 500 GB is a typical starting point for a multi-customer platform |

Size up as the platform grows. Check the current Microsoft system requirements for the SCVMM release before building.

## Prerequisites

### Accounts

Create these in the Arc infrastructure domain before installing. Store every password in the Arc password vault, never in documents or scripts.

| Account | Purpose | Notes |
|---|---|---|
| VMM service account | Runs the SCVMM service | Domain account, or a group managed service account where the SCVMM release supports it. Local administrator on the VMM servers. Not a domain administrator |
| SQL Server service accounts | Run the SQL Server services | Separate from the VMM service account |
| Host management Run As account | SCVMM uses it to add and manage the hosts and clusters | Domain account, local administrator on every Hyper-V host. Stored in SCVMM as a Run As account |
| VMM administrators group | Arc engineers who administer the whole platform | Domain security group, added to the SCVMM Administrator role |
| Per-customer engineer groups | Arc engineers who manage a given customer's workloads | Domain security groups, one per customer or per team, used in tenant roles |

### Active Directory

→ Create an Active Directory container for distributed key management (DKM) before installing, and use it during setup. DKM stores SCVMM's encryption keys in AD instead of on the server. It is required for a highly available SCVMM.

→ Put the hosts, clusters, VMM servers and SQL Servers in dedicated OUs, with group policy that does not configure WinRM in ways SCVMM does not support. Microsoft documents which WinRM policy settings SCVMM tolerates; anything else can stop the SCVMM agent installing.

### Network and DNS

→ Forward and reverse DNS records for the VMM servers, the SQL Servers, the library and every host.

→ The VMM servers can reach every host's management address at both sites, over the platform management network only. Confirm SCVMM's current port list in Microsoft's documentation and allow it between the VMM servers and the hosts.

→ Customer VLANs never carry management traffic, and the management network is never offered to a customer cloud.

→ Time synchronised across the VMM servers, SQL Servers, domain controllers and hosts.

## Installation baseline

| Setting | Arc baseline |
|---|---|
| Install order | SQL Server (highly available), then the first VMM server, then the second VMM server added to the VMM cluster, then the console on the jump hosts |
| Database | New database on the SCVMM SQL instance |
| Service account | The VMM service account above, not Local System |
| Distributed key management | Enabled, using the container created above |
| Ports | Microsoft defaults, unless Arc's firewall policy needs otherwise; record any change |
| Library | Added after installation as a highly available file share or dedicated library server |
| Updates | Apply the latest update rollup immediately after installation, and keep the agents on the hosts at the same level |

## Host groups and clusters

Host groups hold the hosts and clusters, and placement, reserves and permissions are set on them, so the structure matters.

```
All Hosts
    Platform
        <SITE_A>
            <SITE_A_CLUSTER>
        <SITE_B>
            <SITE_B_CLUSTER>
```

→ Set placement rules, host reserves and dynamic optimisation on the Platform host group, so both sites inherit them, and override per site only where the sites genuinely differ.

→ Scope network sites to the site host groups, so each site can use its own VLANs and subnets.

→ Set the cluster reserve on the primary cluster to 1 node. SCVMM then treats the cluster as overcommitted if it could not run every VM after losing one node, and stops placing new VMs on it.

→ Set the secondary site host group so it is not available for normal placement. New VMs are only ever created at the primary site; the secondary cluster only receives replicas.

## Fabric: networking

This part must match `cluster.json` exactly for the host networks. Build it once per site, in this order, before adding the cluster.

### Naming convention

| Object | Convention | Example |
|---|---|---|
| Logical network (host roles) | `LN-<Role>` | LN-Management, LN-LiveMigration, LN-Cluster |
| Logical network (customer traffic) | `LN-Tenants` | LN-Tenants |
| Network site | `NS-<Role>-<Site>` | NS-Management-SiteA, NS-Tenants-SiteA |
| IP pool (host roles) | `IP-<Role>-<Site>` | IP-LiveMigration-SiteA |
| VM network (host roles) | `VMN-<Role>` | VMN-Cluster |
| VM network (customer) | `VMN-<CUSTOMER>-<Purpose>-<VLAN>` | VMN-CUSTA-Servers-210 |
| Port classification | `PC-<Role>` | PC-Management, PC-VM |
| Uplink port profile | `UPP-SET-<Site>` | UPP-SET-SiteA |
| Logical switch | `LS-SET` | LS-SET |
| Cloud | `CL-<CUSTOMER>-<Site>` | CL-CUSTA-SiteA |
| Host adapter | The Role name from HostNetworks, exactly | Management, LiveMigration, Cluster |

Use Arc's short customer code, not the customer's full name, in object names.

### Step 1: logical networks and network sites

| Logical network | Network sites | Contents |
|---|---|---|
| LN-Management | One per site, scoped to that site's host group | The Management VLAN and subnet from that site's HostNetworks |
| LN-LiveMigration | One per site | The LiveMigration VLAN and subnet |
| LN-Cluster | One per site | The Cluster VLAN and subnet |
| LN-Tenants | One per site | Every customer VLAN in use at that site, VLAN-based |

### Step 2: IP pools for the host networks

SCVMM assigns host adapter addresses from these pools.

| Pool | Range | Gateway | DNS | Notes |
|---|---|---|---|---|
| IP-Management-Site | Host management addresses | Yes | Yes, with DNS registration | Reserve the cluster IP and the management VMs' addresses outside the pool |
| IP-LiveMigration-Site | One address per host, plus spare | No | No | Local subnet, cluster nodes only |
| IP-Cluster-Site | One address per host, plus spare | No | No | Local subnet, cluster nodes only |

Customer VM addressing is the customer's (DHCP or static inside their VLANs). SCVMM IP pools for customer networks are optional and decided per customer.

### Step 3: VM networks

→ One VM network per host role logical network (VMN-Management, VMN-LiveMigration, VMN-Cluster), with no isolation. Only host adapters use these; they are never added to a customer cloud.

→ One VLAN-based VM network per customer VLAN on LN-Tenants, named with the customer code. Each customer's VM networks are offered only to that customer's clouds.

→ A customer never shares a VLAN with another customer.

→ The customer VLANs are extended to the secondary site over layer-2 links, so every customer VLAN exists at both sites with the same subnets. Each customer VLAN has a VM network at the secondary site as well, so a replica connects to the same network, with the same addresses, when it starts. No re-addressing is needed at failover.

### Step 4: port classifications and virtual port profiles

The host weights come from HostNetworks in `cluster.json`; the example values are shown.

| Port classification | Settings |
|---|---|
| PC-Management | Minimum bandwidth weight 10 |
| PC-LiveMigration | Minimum bandwidth weight 30 |
| PC-Cluster | Minimum bandwidth weight 10 |
| PC-VM | Minimum bandwidth weight 50, VMQ enabled. The only classification offered to customer clouds |

Weights across all classifications on the switch total 100 or less. A per-customer classification with its own weight or limit is possible later if a customer needs guaranteed bandwidth.

### Step 5: uplink port profile

One per site, so each site's profile includes only that site's network sites.

| Setting | Value |
|---|---|
| Teaming mode | Switch independent |
| Load balancing | Hyper-V Port |
| Network sites | That site's host role sites and its LN-Tenants site |

### Step 6: logical switch

| Setting | Value |
|---|---|
| Uplink mode | Embedded Team (SET) |
| Minimum bandwidth mode | Weight. This cannot be changed after the logical switch is created |
| Uplink port profiles | UPP-SET-SiteA and UPP-SET-SiteB |
| Port classifications | PC-Management, PC-LiveMigration, PC-Cluster, PC-VM |

When a new customer VLAN is added, add it to the LN-Tenants network site for that site and to the physical switch trunks together.

## Adding the clusters

### An existing cluster

1. Bring the cluster up to the Arc standard first with the script: Capture, then Baseline on every node.
2. In SCVMM, add the cluster to its site host group using the host management Run As account. SCVMM installs its agent on every node.
3. For each node in turn, with the node in maintenance mode:
   1. Bring its existing switch under the logical switch, or rebuild the switch from the logical switch if it cannot be converted.
   2. Confirm the host adapters are named exactly as in HostNetworks, with the right VLANs and addresses.
   3. Take the node out of maintenance mode.
4. Run the script's Report on each node to confirm the networking matches `cluster.json`.
5. Run ClusterBaseline once from any node.

Test the conversion on one node and confirm the outcome before doing the rest.

### A new node

The script prepares the node and stops at the SCVMM handoff. In SCVMM:

1. Add the host to its site host group.
2. Apply the logical switch:
   1. Select all the 10GbE ports as uplinks.
   2. Add the Management, LiveMigration and Cluster host adapters with those exact names, each on its VM network with its port classification and an address from its pool.
   3. Mark Management as the host management adapter and let it inherit the physical adapter's settings. The connection may drop briefly while the management address moves.
3. Add the host to the cluster.
4. Hand back to the engineer running the script, who runs `-Phase Next` to finish.

### Cluster validation from SCVMM

Microsoft notes that on Windows Server 2025 nodes, cluster validation run from SCVMM needs the cluster's CLIUSR account to be added before it works. Check Microsoft's current guidance for the exact step, and record it in the build notes once proven. The script's own checks do not depend on this.

## Host settings baseline

Set these on the Platform or site host groups where SCVMM allows, so every host inherits them.

| Setting | Arc baseline |
|---|---|
| VM placement paths | Not set by hand on clustered hosts. SCVMM manages the available paths from the cluster shared volumes |
| Live migration | Enabled; compression; two simultaneous live migrations and two simultaneous storage migrations per host |
| Live migration networks | Left to the cluster. ClusterBaseline sets the order (LiveMigration, then Cluster) and excludes Management |
| Host reserves | CPU and memory reserved for the host, so placement never fills a host. A starting point is 10% CPU and 8 GB memory per host |
| Cluster reserve | Primary cluster: 1 node. Secondary cluster: sized against the failover capacity plan in DR and replicas |
| Dynamic optimisation | Primary site: enabled at a moderate aggressiveness, so VMs rebalance across nodes, with management VMs excluded. Secondary site: off in normal operation, because nothing is running; enable it after a failover |
| Power optimisation | Off. Hosts are never powered down automatically |
| Maintenance mode | Live migrate all running VMs off the host when it enters maintenance mode |

## Fabric: storage

→ Fibre Channel zoning and LUN presentation stay with the storage team and the array. Every node sees the same LUNs before it joins the cluster; the script checks this.

→ Cluster shared volumes are created and managed through Failover Clustering. SCVMM shows them and uses them for placement.

→ Create storage classifications (for example Gold for flash tiers and Silver for others) and assign them to the CSVs. Each customer cloud is given only the classifications it is entitled to.

→ Decide whether a customer's VMs can share CSVs with other customers. The baseline is shared CSVs, separated by cloud quotas; dedicated CSVs per customer are an option for customers who need them.

→ Managing the 3PAR or Primera from SCVMM through an SMI-S provider is optional and not part of the baseline.

## Customer clouds

Each customer gets two clouds:

→ A working cloud at the primary site, where their VMs run.

→ A DR cloud at the secondary site, which holds their replicas. In normal operation it is used only by Arc; no VMs are created in it. Its quotas are set to cover the customer's replicas, so the capacity to start them is reserved.

### What a cloud contains

| Cloud setting | Arc baseline |
|---|---|
| Name | `CL-<CUSTOMER>-<Site>`, for example CL-CUSTA-Primary and CL-CUSTA-DR |
| Host group | The site's host group (or the cluster) |
| Logical networks | LN-Tenants only, so customers can only reach their own VM networks through their user role |
| Port classifications | PC-VM only |
| Storage classifications | Those the customer is entitled to |
| Library | Read-only access to the Arc template library; an optional per-customer library share for their own ISOs |
| Capacity | Quotas for virtual CPUs, memory, storage and number of VMs, from the customer's contract |
| Capability profile | Hyper-V, Generation 2 |

### Customer VM networks

→ Created on LN-Tenants, VLAN-based, one per customer VLAN, named with the customer code.

→ Offered to the customer's cloud through the customer's user role, so no other customer can see or use them.

### Onboarding a customer

1. Agree the customer's VLANs with the network team and add them to the physical switch trunks at each site.
2. Add the VLANs to the LN-Tenants network site at each site.
3. Create the customer's VM networks.
4. Create the customer's working cloud at the primary site and DR cloud at the secondary site, with quotas.
5. Create the customer's user role, scoped to their clouds and VM networks.
6. Deploy a test VM in the working cloud, check it reaches only the customer's networks, and remove it.
7. Set up replication for the customer's VMs to the secondary site and confirm the replicas appear in the DR cloud, powered off.

### Offboarding a customer

Stop replication and remove their replicas, then their VMs (after the agreed data retention), then the user role, both clouds, the VM networks and the VLANs from the network site and the physical trunks, in that order. Record each step in the change log.

## DR and replicas

### What "cold replica, ready to spin up" requires

| Requirement | What it means |
|---|---|
| Every production VM is replicated | New VMs are added to replication as part of deployment, not afterwards. A VM that is not replicated is not protected |
| Replicas stay powered off | Nothing starts at the secondary site except in a failover, a failover test or a planned move |
| Replication is healthy | Replication state and lag are monitored, and a replica that falls behind its target raises a ticket |
| Capacity is there when needed | The secondary cluster can run the workloads it is expected to run in a failover (see capacity below), even though it is idle day to day |
| Networks are there when needed | Every customer VLAN is extended to the secondary site over layer 2, has a VM network there, and is carried on the secondary site's trunks |
| The order is written down | A failover runbook says what starts first and how it is checked |
| It is tested | Failover tests run on a schedule, into an isolated network, without touching production |

### Replication with Veeam

Replication uses Veeam Backup and Replication, as on the current platform.

| Item | Arc baseline |
|---|---|
| Jobs | One replication job per customer (or per customer and recovery tier), so each customer's schedule, retention and failover plan stand alone |
| Target | The secondary cluster. Replicas are registered as highly available VMs on the cluster and appear in SCVMM |
| Replica naming | A consistent suffix (for example `_replica`) so replicas are never confused with originals in SCVMM or Veeam |
| DR cloud | After Veeam creates a replica, assign it to the customer's DR cloud in SCVMM, so quotas and access cover it. Script this as part of the job's post-job activity or the daily checks |
| Network mapping | The same VLANs exist at both sites, so each replica maps to the matching customer VM network at the secondary site. No re-IP rules |
| Restore points | Enough replica restore points to step back past a problem (for example ransomware) that has already replicated; agree the number per customer |
| Failover plans | One Veeam failover plan per customer, starting the customer's VMs in tiers with delays (see Failover order) |
| Testing | Veeam SureReplica in a virtual lab at the secondary site, which is isolated from production by design |
| Failback | Veeam's failback to the primary site, planned as a change |

Where Veeam itself runs matters. A failover must not depend on anything at the lost site:

→ The Veeam backup server, or a fully ready standby of it with its configuration backup, runs at the secondary site, so failover plans can be started when the primary site is down.

→ Veeam failover does not depend on SCVMM. SCVMM is brought up first to manage the platform afterwards, not to perform the failover.

→ Replicas are never edited or started by hand outside a failover plan, because that breaks replication.

How the replicas are kept up to date, and what recovery point that achieves, is covered in Recovery point performance below.
### Capacity

The platform is designed for full failover: the secondary cluster must be able to run every replica at once. It is idle day to day, so it is easy to let it fall behind the primary without noticing.

→ Keep the secondary cluster's usable CPU and memory at least equal to the primary cluster's running workload, after host reserves.

→ Check it every month as part of the capacity review, and before onboarding any large customer. The DR cloud quotas make the commitment visible per customer.

→ The secondary hosts currently have 2 network ports where the primary hosts have 4. With full failover they carry the whole production network load after a failover, so either confirm 2 x 10GbE per host is enough at peak, or bring the secondary hosts up to 4 ports.

### Layer-2 extension: what it requires

The customer VLANs are stretched between the sites, so a replica keeps its address when it starts. That makes failover simpler, and it brings three rules.

| Rule | Why |
|---|---|
| Never two live copies | A replica started while its original is still running would conflict on the same subnet. Replicas stay powered off, and only the runbook starts them |
| Failover tests never use the stretched VLANs | Tests run in an isolated network at the secondary site, so a test copy can never meet production |
| Gateways fail over with the customer | Each customer's default gateway is a virtual firewall inside their cloud, replicated like their other VMs. It is the first VM in the customer's failover plan, so routing is back before anything else starts. Its outside (internet or transit) interfaces need their networks and upstream routing available at the secondary site too; the network team confirms how the edge and public addressing move in a failover |

The network team owns the layer-2 extension's design, including loop protection and storm control between the sites.
### Failover order

1. Confirm the primary site is genuinely unavailable, and that the decision to fail over has been made by the agreed approver.
2. Bring up Arc's platform services at the secondary site: domain controllers and DNS, then the SCVMM SQL Server, then SCVMM.
3. Enable dynamic optimisation on the secondary site host group.
4. Confirm the edge and upstream routing are live at the secondary site.
5. Run customers' Veeam failover plans in recovery time order: the shortest contracted recovery time objectives (2 hours) first, the longest (48 hours) last.
6. Within each customer's plan, start the tiers in order: the customer's virtual firewall, then domain controllers and DNS, then databases, then application servers, checking each tier before the next. Replicas keep their addresses, so no re-addressing is needed.
7. Confirm each customer's services and tell the customer.

Failback to the primary site uses Veeam failback, planned as a change once the primary site is healthy.

### Recovery point performance

The current platform achieves its recovery point by replicating from storage snapshots, which keeps the work off the hosts. On Hyper-V, Veeam replicates by taking a checkpoint of each VM on every run and copying the changed blocks (tracked by Hyper-V's resilient change tracking). Each run therefore costs host CPU, CSV I/O and a brief checkpoint on every VM, and the cost grows with how often jobs run and how many VMs they cover.

The platform target is a recovery point of 1 hour, the same as today. Veeam replication runs hourly with on-host processing to start with, and the load is measured from the pilot onwards.

→ Stagger customer jobs across the hour so they do not all take checkpoints at the same moment.

→ Keep job duration well inside the interval. A job that takes longer than its interval cannot meet its recovery point.

→ Watch CSV latency and host CPU on the primary cluster during replication windows.

Move to off-host processing if the measurements cross these starting thresholds, which should be confirmed in the pilot:

| Measure | Threshold that triggers off-host processing |
|---|---|
| Job duration | Regularly more than 30 minutes for an hourly job |
| CSV latency during replication windows | Sustained above 20 ms |
| Host CPU during replication windows | Sustained above 80% |
| Customer impact | Any customer-reported slowdown that lines up with replication windows |

Off-host processing uses dedicated Veeam proxy servers with Fibre Channel access to the LUNs, reading from 3PAR or Primera snapshots taken through the HPE VSS hardware provider. That moves the processing off the hosts, much as the current storage snapshot approach does. Confirm with Veeam that off-host processing covers replication jobs for the Veeam version in use before relying on it.

### Local rollback

The current 3PAR and Primera storage snapshots stay as a local rollback capability on the primary site. On Hyper-V, a storage snapshot covers a whole cluster shared volume, so rolling one back restores every VM on that volume at once; it is a platform-level tool, not a per-customer one. Per-VM rollback comes from Veeam: backup restore points, and the replica's own restore points at the secondary site.

### Failover testing

→ Test failover at least twice a year per customer, and after any major change to the platform or the customer's environment.

→ Run tests with Veeam SureReplica in a virtual lab at the secondary site, so test copies never meet production on the network.

→ Record the time taken against the customer's recovery time objective, and fix anything that slowed the test.

## VM baseline

### Templates and profiles

| Item | Arc baseline |
|---|---|
| VM template source | The Arc gold-image Windows Server VHDX, generalised, in the library |
| Generation | Generation 2, Secure Boot on with the Microsoft Windows template |
| Virtual TPM | On where the guest OS needs it |
| Memory | Static memory for SQL Server and other memory-sensitive workloads; dynamic memory allowed for general servers, with a sensible minimum |
| Processors | Start small (2 vCPU) and grow on evidence |
| Network | One adapter on one of the customer's VM networks, port classification PC-VM |
| Guest OS profile | Customer domain join, time zone and local administrator handled at deployment, not typed per VM |
| Checkpoints | Production checkpoints only, and not used as backups. Remove them once a change is verified |
| Availability | Every VM created as highly available on the primary cluster, and added to replication to the secondary site |

### Placement

→ Place VMs through SCVMM into the customer's cloud, so quotas, placement rules and host reserves apply.

→ Use availability sets for VMs that provide the same service, such as a customer's two domain controllers, so SCVMM keeps them on different nodes.

## Access control

| SCVMM user role | Who | Scope |
|---|---|---|
| Administrator | Arc platform engineers (the VMM administrators group) | Everything |
| Fabric administrator | Arc engineers who manage hosts, clusters and networking | The Platform host group |
| Read-only administrator | Arc service desk and monitoring | Everything, read-only |
| Tenant administrator, one per customer | Arc engineers responsible for that customer, and customer staff only where agreed | That customer's clouds and VM networks, within its quotas |

→ Use domain groups for every role, never individual accounts.

→ Review role membership whenever an engineer joins or leaves, and whenever a customer's contacts change.

## Security

SCVMM can create, change and delete every VM on the platform, so it is protected as a critical platform system.

→ Administer SCVMM only from Arc's management jump hosts, with multi-factor authentication on the jump host sign-in.

→ Keep the VMM servers, SQL Servers, library and hosts on the platform management network, with no internet browsing from them.

→ Grant the Administrator role to the smallest possible group; day-to-day customer work uses tenant roles.

→ Keep the host management Run As account's password in the vault and rotate it on the platform's credential schedule.

→ Apply the same security baseline to the VMM, SQL and library servers as to other Arc infrastructure servers (the gold-image server baseline).

## Operations

| Task | Arc baseline |
|---|---|
| Database backup | Daily backup of the SCVMM database to the secondary site. Test a restore at least once a year |
| Replication | Replication state and lag monitored for every replicated VM; a replica outside its target raises a ticket. Every new VM checked for replication within a day of deployment |
| Failover tests | At least twice a year per customer, into an isolated network, with the results recorded against the recovery time objective |
| SCVMM updates | Apply update rollups within a month of release, after a lab test. Update the agents on the hosts afterwards. Plan updates as platform maintenance, because they affect every customer's management |
| Host patching | Not done through SCVMM. Patch hosts through the agreed patching route, one node at a time, draining each node |
| Host changes | Any networking or restart-needed change is made with the node in maintenance mode, one node at a time, then checked with the script's Report |
| Capacity | Review primary cluster capacity, cluster reserve state, cloud quota use and the secondary cluster's failover capacity monthly |
| Monitoring | SCVMM jobs and host health monitored through Datto; failed jobs raise a ticket |
| Change record | Record every fabric change (new VLAN, new VM network, cloud or quota change) in the platform change log, and update `cluster.json` where it holds the same value |

## Validation checklist

Use this when the platform's SCVMM is first built, after any major fabric change, and when onboarding a customer.

→ SCVMM installed highly available, with DKM, the correct service account and the latest update rollup.

→ Host groups built as above, with placement rules, host reserves, cluster reserve and dynamic optimisation set.

→ Logical networks, network sites, IP pools, VM networks, port classifications, uplink port profiles and the logical switch named and configured as above.

→ Port classification weights match HostNetworks in `cluster.json` at each site.

→ Every host shows the logical switch as compliant, and the script's Report passes host networking on every node.

→ Each customer's working cloud and DR cloud offer only that customer's VM networks, PC-VM and the right storage classifications, with quotas set.

→ A test VM in each customer cloud reaches only that customer's networks, live-migrates to every node and back, and is removed.

→ Database backup running to the secondary site and a restore tested.

→ Every production VM replicated, with its replica powered off in the customer's DR cloud.

→ A failover test completed into the isolated test network, within the recovery time objective.

→ User roles assigned to domain groups.

## Decisions made

| Decision | Outcome |
|---|---|
| Secondary site role | Cold replicas only. No live workloads at the secondary site |
| DR network addressing | Customer VLANs extended to the secondary site over layer 2; replicas keep the same addresses |
| DR capacity | Full failover: the secondary cluster can run every replica at once |
| Recovery objectives | Recovery point objective 1 hour, as today. Recovery time objectives 2 to 48 hours by contract |
| Replication product | Veeam Backup and Replication, hourly, on-host processing to start; off-host proxies if the load thresholds are crossed |
| Array replication | HPE Remote Copy is not used for DR, because failing over replicated volumes is too manual in a disaster. Storage snapshots stay for local rollback only |
| Customer gateways | Virtual firewalls inside each customer's cloud, replicated with the customer and first in their failover plan |

## Open decisions

| Decision | Options | Arc default |
|---|---|---|
| Customer separation on the network | VLAN-based VM networks, or software-defined networking with network virtualisation | VLAN-based. Software-defined networking needs a Network Controller and is a separate design |
| Customer self-service | Customers manage their own VMs through tenant roles, or Arc operates everything | Arc operates everything unless agreed with the customer |
| Shared or dedicated CSVs per customer | Shared with quotas, or dedicated per customer | Shared, dedicated on request |
| SCVMM IP pools for customer networks | SCVMM assigns customer VM addresses, or the customer's own DHCP and static addressing | The customer's own addressing |
| Service account type | Domain account, or a group managed service account | Group managed service account where supported |
| Array management from SCVMM | SMI-S provider for 3PAR or Primera, or not | Not used |
| Shorter recovery points for individual customers | Hyper-V Replica or a dedicated replication job for that customer's VMs, rather than shortening the interval for the whole platform | Only if a contract needs better than 1 hour |
| Secondary host network ports | Keep 2 x 10GbE per host, or match the primary's 4 x 10GbE for full failover | To be confirmed against peak load |
| Where management VMs run | Primary site with replicas at the secondary site, or split across both sites | Primary site, replicated and backed up to the secondary site |
| Bare-metal host deployment | SCVMM deploys hosts over PXE, or hosts are built and prepared by the script | Built and prepared by the script |

> **Page owner:** OWNER NAME · **Applies to:** the Arc Hyper-V hosting platform (primary site live, secondary site cold replicas), SCVMM 2025 · **Last reviewed:** 02/10/2026
