# Changelog

All notable changes to the Datto capacity sampler tooling (`Deploy-ArcCapacitySampler.ps1`,
`Arc-CapacitySampler.ps1`, `Read-ArcCapacityBuffer.ps1`, `Get-ArcCapacityScreen.ps1`). Each
script versions independently — see its own header comment for its current version.

## [Unreleased]

_Work in progress on the `develop` branch._

### Fixed
- **Multi-instance SQL hosts couldn't raise `SQL-CAP`** (`Read-ArcCapacityBuffer.ps1` v1.12).
  Found on the first real two-instance pilot host: two Standard instances on 12GB, 0.72GB free,
  179 hard faults/s. It read only as "target fell to 6.4GB from 9.6GB - OS pressure or a lowered
  cap". The counters cover one instance, so caps that are each reasonable but together exceed the
  host were invisible, and the squeeze finding named the wrong suspects.
  - **New `SQL-CAP` trigger:** on hosts running more than one instance, the combined live footprint
    of every `sqlservr` process is compared with the allocation, using the same half-reserve bar as
    the single-instance check. That gives `2 instances hold 10.8GB of 12GB - combined caps too
    high, total at 8GB`.
  - **The squeeze finding** names "another SQL instance" first on those hosts.
  - **The live footprint** is now the larger of private bytes and working set per process. Working
    set alone understates a host that's paging.
  - **The CSV export** gains `SqlRunning` and `SqlLiveGB`.

  Replayed against synthetic buffers: the two-instance host now leads with the combined finding,
  two instances with room spare raise nothing, and a single-instance squeeze keeps its original
  wording.
- **Every Hyper-V host read `HV-PARTIAL`** (`Get-ArcCapacityScreen.ps1` v1.12). Found on the
  first real cluster-node pilot, a Windows Server 2025 node with 2 running VMs. The explicit
  Recovery checkpoint query raises an *error* for a VM that has no Recovery checkpoints, rather
  than returning nothing. The check treated any error as "can't list them", so it skipped the
  orphaned-`.avhdx` test on effectively every host. The stand-ins had returned an empty list, so
  testing hadn't caught it. Now:
  - `-SnapshotType` support is checked once, up front, instead of being inferred from an error.
  - Errors are collected without stopping. ObjectNotFound, or Hyper-V's own "unable to find"
    wording, means the VM has none.
  - Anything else still skips the orphan test, and reports its exact text and category in the job
    output. The match is deliberately narrow: a loose "not found" would read a genuine failure as
    "no checkpoints" and let a VM mid-backup through as a failed merge.

### Added
- **Hyper-V pilot diagnostics** (`Get-ArcCapacityScreen.ps1` v1.12). The first real run on a
  cluster node, via Datto as SYSTEM, worked with no `HV error` lines. That run confirmed the
  module loads, `Get-VMHost` returns hypervisor-level figures (767.7GB, 72 LP), and cluster
  detection works. But the output couldn't show whether that node owned the core cluster group, so
  "no cluster findings" could mean either "checked and healthy" or "skipped here". The `Cluster :`
  line now says which, and a new `HV checks :` line says whether the checks ran in-process or via
  the 64-bit relaunch.
- **Hyper-V host health checks in the Screen** (`Get-ArcCapacityScreen.ps1` v1.11). Hypervisors
  used to get only `NO SCREEN`. Now they get point-in-time checks for what takes hosts down, read as
  SYSTEM from the Hyper-V and FailoverClusters modules (no history, no login, nothing changed):
  - `HV-CRITICAL`: a VM in a critical state.
  - `HV-MEM`: host free memory under 5% of capacity (minimum 2GB).
  - `HV-STORAGE`: a VM volume or CSV under 12% free.
  - `HV-CHECKPOINT`: a standard checkpoint over 3 days old, a Recovery checkpoint over 1 day old
    (a stuck backup), or a VM running on an `.avhdx` with no checkpoint (a failed merge).
  - `HV-REPLICA`: replication Critical or Warning.
  - `HV-GUEST`: a lost heartbeat.
  - `HV-CPU-RATIO`: running vCPU above 4:1 logical processors.
  - `HV-CLUSTER`: a node not Up, or a CSV in redirected I/O.

  Noise controls, given UPSIZE's history:
  - Replica VMs are excluded from the checkpoint checks.
  - Thin provisioning alone doesn't flag; it's only mentioned on a volume that's already low.
  - NoContact heartbeats count only after an hour of uptime with the heartbeat service enabled.
  - Cluster-wide findings come from the core cluster group owner only.
  - CSV redirection by design (ReFS/S2D, tiering, Storage Replica) is ignored.
  - `HV-MEM`'s 5% is capped between 2GB and 8GB, so large packed hosts don't flag.
  - On a hypervisor, `UPSIZE` is raised only on the absolute under-1GB trigger, never the
    root-partition commit ratio.
  - If Recovery checkpoints can't be listed, the orphaned-`.avhdx` test is skipped rather than
    guessed.

  Each check runs in its own try/catch. A failed check is listed and flags `HV-PARTIAL`, and checks
  that couldn't run at all flag `HV-NO-DATA`, so "no findings" never stands in for "couldn't look".
  The checks re-run in 64-bit PowerShell when Datto's process is 32-bit, since the Hyper-V module
  only loads in 64-bit. No new UDFs or `ScreenStatus` values: the four Screen UDFs carry host
  content on hypervisors, and `ScreenHvFindings` is a new result field the stub ignores. The CSV
  export gains `Hv*` columns, including `HvCluster` for an estate-level N+1 rollup.

  Tested with stub cmdlets across twelve scenarios plus a real 32-bit → 64-bit relaunch: a healthy
  thin-provisioned host, PausedCritical, stale and orphaned checkpoints, replica VMs (must not flag),
  memory/replication/heartbeat/ratio, a throwing cmdlet, cluster owner vs non-owner, module missing,
  a worst case kept within 255 characters, ReFS by-design redirection, and an unsupported Recovery
  query. **Not yet run on a real Hyper-V host.** In
  particular, whether `Get-VMSnapshot` lists Recovery checkpoints by default varies, so it's queried
  explicitly.

### Fixed
- **Component 2's role detection had fallen behind the Screen's fixes** (`Read-ArcCapacityBuffer.ps1`
  v1.11, `Get-ArcCapacityScreen.ps1` v1.10). The Screen's header claims its roles are "kept identical
  to Component 2", but its v1.4–v1.8 fixes were never carried across, so the 14-day analysis still
  made the same mistakes:
  - **SQL was excluded on mere presence.** That caught RD gateways, VPN hosts and file servers
    carrying a bundled Express or Veeam instance, and discarded their reclaim. SQL now has to be
    material (at least 2GB and at least 25% of allocation), otherwise the host is flagged
    `SQL-MINOR` and sized normally. The footprint is the larger of the sampled p95 Total Server
    Memory and the live `sqlservr` working set: the sampler reads one instance, the live figure
    covers them all. The SQL attention checks still run on `SQL-MINOR` hosts, so an Express
    database near its limit appears as `| SQL: ...` in `Cap: Growth Verdict`.
  - **Any `Veeam*` service meant backup infrastructure**, including the installer and agent on
    every protected server. Now only data-mover and control services; others get `VEEAM-MINOR`.
  - **No Hyper-V guard.** Cluster nodes were sized from guest-side figures and flagged
    `CPU-PRESSURE`. Hosts running `vmms` now get `NO SIZING` for RAM and vCPU and no CPU flags,
    overriding every other role. The Screen also stops raising CPU flags on them.
  - **Exchange and Veeam infrastructure hid memory pressure behind `EXCLUDED`.** They now read
    `URGENT` (unsized, `GROWTH` flag), as SQL, MySQL and Hyper-V hosts do.

  Tested with injected service lists across eight scenarios: a bundled-Express RD gateway, a
  material SQL host, a Veeam-agent file server, a Veeam proxy under pressure, a Hyper-V node with
  Veeam services at 80% CPU, a Hyper-V node under pressure, and Exchange with and without pressure.

### Added
- **SQL Server attention signals** (`Read-ArcCapacityBuffer.ps1` v1.10). SQL hosts were excluded
  from RAM sizing with nothing else to say. `SqlTargetGB` was sampled but never read, and PLE was
  reported as a raw minimum against no threshold. The new checks use only counters already in
  the buffer plus the registry: no sampler change, so no buffer reset, and no database login.
  Three flags, each with a short reason in `Cap: Growth Verdict`:
  - `SQL-CAP`: the peak Target leaves the OS under half of Kehayias's recommended reserve, so
    `max server memory` is unset or set too high. The verdict gives the cap to set.
  - `SQL-MEM`: either PLE p05 is under 300s per 4GB of buffer pool while the pool sits at Target,
    or Target p05 is under 80% of its peak (SQL squeezed by memory pressure from outside it).
  - `SQL-EXPRESS-CAP`: an Express database is at 8GB or more of its 10GB limit, or a host with
    only Express instances is memory-bound at the ~1.4GB pool cap, where RAM won't help.

  A SQL host under `MEM-PRESSURE` now reads `URGENT` with the likeliest cause first, rather than
  `EXCLUDED`. That was the same pressure-hiding gap MySQL had; Exchange and Veeam still have it.
  The CSV export gains `SqlFindings` and `SqlEditions`. Instances are read through the 64-bit
  registry view so a 32-bit host process can't miss them. Tested against six synthetic buffers
  (cap unset under pressure, healthy capped, Express at cap with a DB near the limit, squeezed
  Target, no counters sampled, a worst case with two instances) and a fake registry tree.
- **The verdict UDFs now trim the RAM text instead of the end** (`Read-ArcCapacityBuffer.ps1`
  v1.10). `Cap: Verdict` and `Cap: Growth Verdict` are `RAM || CPU || timestamp`. The plain
  255-character cut took the timestamp and CPU verdict first, and the timestamp is how a stale
  UDF gets spotted.
- **MySQL / MariaDB role** (`Read-ArcCapacityBuffer.ps1` v1.9, `Get-ArcCapacityScreen.ps1` v1.9).
  A 24GB, 4 vCPU MySQL host was read as `Generic`. It got `URGENT +32GB -> 56GB` and a vCPU cut
  to 2. The +32GB is just commit max 44.4GB × 1.25. On Windows, InnoDB commits its whole buffer
  pool at startup, so commit on a MySQL host restates the configured `innodb_buffer_pool_size`
  rather than the demand. A pool sized beyond what the allocation can hold also produces exactly
  this pattern, and then the fix is lowering the pool, not adding 32GB.
  - **Detection** is by service binary (`mysqld` / `mariadbd`), since service names vary. A host
    counts as MySQL only when mysqld's private bytes reach at least 2GB and at least 25% of
    allocation, the same bar the Screen applies to SQL Server. Otherwise it's flagged
    `MYSQL-MINOR` and sized normally.
  - **Floors** are 8GB / 4 vCPU, matching SQL Server.
  - **RAM** is excluded from commit-based sizing in both directions.
  - **Under `MEM-PRESSURE`**, Component 2 still reports `URGENT` and flags `GROWTH`, with
    `Cap: Growth GB` left at `000` (the same convention as the `CPU-GROWTH` queue REVIEW case).
    Instead of a GB figure it cites the configured buffer pool: over 75% of allocation reads
    "lower it to N GB or grow RAM to M GB", and under 75% reads "isn't the cause". The pool is
    read credential-free from the option files mysqld reads: `--defaults-file`, the Windows
    search order, and a `SET PERSIST` in `mysqld-auto.cnf`. A pool sized by
    `innodb_dedicated_server` is reported as unresolved, never guessed.
  - `Cap: RAM Detail` and both CSV exports gain mysqld's footprint and the configured pool.
  - **`Arc-CapacitySampler.ps1` is deliberately unchanged.** A new buffer column would change the
    header, which archives `samples.csv` and resets every device's 14-day window. All MySQL facts
    are read at analysis time.

### Fixed
- **vCPU reduction was offered while the host was under memory pressure** (`Read-ArcCapacityBuffer.ps1`
  v1.9). The same 24GB host was paging hard (0.1GB min available, 66 faults/s) and was recommended
  4 → 2 vCPU on p95 17%, with a 67% peak that 2 vCPU couldn't carry. Waiting on paging I/O isn't CPU
  time, so utilisation measured under pressure understates demand once memory is fixed. Reduction
  is now held under `MEM-PRESSURE` (`NO REDUCTION - memory pressure ... resolve memory first`).
  Growth is unaffected.
- **The vCPU role floor was applied after deciding a reduction existed** (`Read-ArcCapacityBuffer.ps1`
  v1.9). A host at or below its floor could read `REDUCE to 4 vCPU` on 4 vCPU, or a "reduction"
  upwards on a 2 vCPU host with a floor of 4. The floor is now applied first, and such hosts read
  `NO CHANGE - demand sizes to N but <role> floor is M vCPU`.
- **The commit ratio still triggered `UPSIZE` on its own, and still produced false positives**
  (`Get-ArcCapacityScreen.ps1` v1.8). Raising the ratio from 90% to 100% in v1.6 fixed the reported
  case but not the class: on a 155-device run the same 96GB host reappeared at 108% commit while
  holding **28.36GB (30%) available**, joined by three 32GB session hosts at 23–30% available and
  five more at 21–29%. Commit charge routinely exceeds RAM on RDSH, because committed bytes counts
  reservations the pagefile can back and much of it is never touched. Available memory is now the
  primary evidence and the ratio never triggers alone: `UPSIZE` requires **available under 1GB**
  (unchanged, matching Component 2's `MEM-PRESSURE`), or **commit exceeding allocation while
  available is under 20% of allocation**. Verified against the export — 34 → 25 flagged, the nine
  healthy hosts dropped, **nothing newly flagged** (the rule only tightens), no sub-1GB host missed.
- **The Veeam exclusion matched any `Veeam*` service, treating every backed-up machine as backup
  infrastructure** (`Get-ArcCapacityScreen.ps1` v1.7) — the same over-broad mistake the SQL predicate
  made, found in the same estate export. Veeam installs its Installer/Deployment service on every
  managed server and its agent on protected endpoints, so a 12GB file server with 8.58GB committed
  was classed `BackupInfra` and had its reclaim discarded. The exclusion's rationale — proxy and
  repository demand peaking inside the job window — describes something that moves or stores backup
  data, not a backup source. Now matches only data-mover and control services (`VeeamBackup*`,
  `VeeamTransport*`, `VeeamNFS*`, `VeeamCatalog*`, `VeeamBroker*`, `VeeamMount*`,
  `VeeamHvIntegration*`, by prefix so version suffixes survive); agent- or installer-only hosts are
  flagged `VEEAM-MINOR` and screened normally. Fail-open by design: an unrecognised future service
  name lands in `VEEAM-MINOR`, and the gross-over-allocation gate still has to clear before anything
  is recommended.
- **Hyper-V hosts were being screened as though they were guests.** Three 127GB, 20 vCPU cluster
  nodes appeared in the estate reporting guest-side figures and `CPU-PRESSURE` at 77–79% — but a
  hypervisor's memory is consumed by its VMs and sustained high CPU is normal for a busy host, so
  neither figure supports a right-sizing decision. Added a `vmms`-based guard returning a distinct
  `NO SCREEN` verdict, applied **unconditionally and last** so it overrides every other role rather
  than depending on the `-eq 'Generic'` guards elsewhere staying in place: a hypervisor running a
  Veeam data mover, or with RDSH bolted on, is still a hypervisor. Placed after `UPSIZE` in the
  verdict chain so a hypervisor that is itself out of memory still surfaces. Verified across 13 role
  scenarios including Hyper-V combined with Veeam infra, Veeam agent, RDSH, file server and material
  SQL.
- **`UPSIZE` fired on the commit ratio alone, which produced false positives on its first real run**
  (`Get-ArcCapacityScreen.ps1` v1.6). Committed bytes counts reservations the pagefile can back, so
  a high ratio is not by itself evidence of memory pressure: `SFP-RDS-1` was flagged at 93% of
  allocation while holding **33.46GB (35%) available**, and `SC-AM-RDS05` at 93% with 19% available.
  Neither host was short of memory. The ratio also missed hosts that genuinely were, below 100% —
  `S2D-DC02` (a DC on 3GB, already under its own 4GB role floor, with 0.4GB available),
  `LASERMECH-DC1` (0.91GB), `SC-NOA-DC02` (0.86GB) and `SC-PUR-GW01` (0.8GB) all read `NO HEADROOM`.
  Now two independent triggers: **committed bytes exceeding allocation**, or **available memory
  under 1GB** — the latter deliberately the same metric and threshold Component 2 uses for
  `MEM-PRESSURE` (`availMin < 1.0`), so the two components cannot disagree about what "under memory
  pressure" means. The verdict names which trigger fired, since one means "the pagefile is carrying
  commit" and the other means "the OS is out of memory now"; reporting only a percentage made the
  second case look like the first, or on a sub-100% host look like a mistake. Verified against the
  87-device export: 22 hosts flagged, the two false positives dropped, the four missed hosts caught.

### Changed
- **The Screen's sizing basis moved off peak-working-set sum onto committed bytes**
  (`Get-ArcCapacityScreen.ps1` v1.5). It was `max(committed, peakSum)`, which in practice meant the
  peak sum won on most hosts. Summing per-process peaks double-counts shared pages and adds peaks
  that never co-occurred, and the result isn't bounded by physical memory — on a 73-device estate it
  **exceeded allocated RAM on 20 of them**, emitting verdicts like `basis 13.89GB against 8GB
  allocated`. As an intentional over-count it was defensible in principle, but a basis that exceeds
  the allocation it's compared against can't support a verdict either way, and the ×1.4 multiplier
  compounded it. Committed bytes is also what Component 2 sizes from, so the two components now
  agree on what "demand" means. Peak working set sum is still collected and reported as context.

  **The gross-over-allocation gate (40% of allocation and 8GB) and the 24h uptime floor were both
  retained deliberately.** Measurement showed the gate, not the basis, was the binding constraint:
  the basis change alone moves the estate from 90GB/5 devices to 104GB/6 devices, whereas relaxing
  the gate would reach 248GB/22 devices. Keeping it preserves the Screen's no-false-positives
  property, which matters more now the basis is a single instantaneous reading — an RDSH host at one
  day's uptime fills up across the working week. For a fuller early picture, `Arc — Capacity Analyse`
  with `usrConservative=true` reads real samples and self-labels `PROVISIONAL`.

  A proposed 7-day uptime gate was measured and **rejected as counter-productive**: it would defer 32
  of 73 devices, suppress 4 of the 5 then-current candidates, and suppress all four 96GB RDSH hosts
  (1–3 days' uptime) that carry the largest single opportunity — cutting the screen to 26GB/2
  devices. The gate's wording is corrected instead: it was justified as a peak-working-set warm-up
  period, which no longer applies to an instantaneous metric, so it now reads as the settling floor
  it actually is.

  A proposed business-hours p95 CPU basis fed from a new aggregator UDF was **deferred** — Component
  2 already sizes vCPU from a real 14-day window with per-core spread, and it would make the Screen
  depend on sampling history it's designed not to need. `CPU-PRESSURE` below covers the urgent gap.

### Fixed
_Three defects in `Get-ArcCapacityScreen.ps1`, all found by reviewing a real 73-device estate
export rather than by testing._
- **The SQL exclusion fired on mere presence of a SQL instance, excluding 21 of 73 devices** —
  among them RD gateways, a VPN host and plain file servers. None were mis-matched: the predicate
  (`MSSQLSERVER` or `MSSQL$*`) cannot match `SQLWriter`, `SQLBrowser` or Native Client, which was
  verified directly. Those hosts genuinely carry a bundled instance — `MSSQL$SQLEXPRESS` from an
  RDS Connection Broker deployment, `MSSQL$VEEAMSQL*` from Veeam, or an LOB app's Express instance.
  The predicate worked as designed; the design was too broad. The exclusion exists because commit
  reports the configured `max server memory` rather than the requirement, which only holds while
  SQL dominates memory — a capped Express instance idling at a few hundred MB on a 12GB gateway
  doesn't distort anything, and excluding it discarded real reclaim (ARC-RDGW01 was sitting at 36%
  of its allocation). Now requires `sqlservr` to hold **at least 2GB and at least 25% of allocated
  RAM**; below that the host is flagged `SQL-MINOR` and screened normally. Both conditions
  deliberately — the ratio alone over-fires on small hosts (Express caps its buffer pool near
  1.4GB), the absolute alone under-fires on large ones. The exclusion verdict now cites the
  footprint that justified it, so it's auditable from the UDF rather than an unexplained
  suppression. Validated against 11 bounding scenarios.
- **Hosts at or over their allocation were silently buried in `NO HEADROOM` or `EXCLUDED`** — 12 on
  the estate export, including one at **237% of allocation** (9.46GB committed on 4GB) that the SQL
  exclusion had silenced entirely. New `UPSIZE` verdict and flag where committed bytes exceed 90% of
  allocation, deliberately **outranking both the uptime gate and the role exclusions**: neither
  applies, because over-commitment is an observable fact rather than a sizing claim, and a host
  over-committed 8 hours after boot is genuinely over-committed. Those guards exist to stop commit
  being used to size a host *down*; they were never meant to conceal a host that's out of memory.
  Reported, never sized — Component 2's growth-sizing still produces the number. Replaying the real
  export surfaces 13 hosts, 7 of which were previously hidden behind `EXCLUDED`.
- **There was no high-CPU path at all** — `CPU-REVIEW` only fired on `avgCpuPct < 5 -and vCPU >= 8`,
  so the screen could only ever spot *idle* hosts. A real host averaging 95.1% since boot over 104
  days (7.61 of 8 cores) produced no signal whatsoever. Added `CPU-PRESSURE` at 70% or above, at any
  vCPU count, matching Component 2's flag name so one filter catches both. Because averaging
  flattens spikes, a sustained average that high is a floor rather than a peak.

  **`ScreenStatus` values are deliberately unchanged** (`CANDIDATE`/`LOW_UPTIME`/`NO_ACTION`).
  `Invoke-ArcCapacityScreen.ps1` fails closed on any status it doesn't whitelist, and that stub is
  *pasted* into Datto — so introducing `ScreenStatus=UPSIZE` would have reported a job failure on
  every over-committed host until every device had been re-pasted. The new signals travel as
  separate `ScreenUpsize=` / `ScreenCpuPressure=` result fields, which the stub ignores, keeping
  this a git-only change that works against any already-pasted stub version. CSV export gains
  `OverCommitted` and `SqlWsGB`.

### Fixed
- **The on-device ring buffer never trimmed, so `usrRetention` was silently unenforced**
  (`Arc-CapacitySampler.ps1` v1.6). The row count driving the trim test used
  `Get-Content -ReadCount 0`, which emits the whole file as a *single* array object — so
  `@(...).Count` returned `1` for a buffer of any size, and subtracting the header pinned the count
  at `0`. The guard `if ($lineCount -gt ($ringSize + 24))` was therefore always false and the
  buffer grew without bound on every deployed device. **Recommendations were never affected** —
  `Read-ArcCapacityBuffer.ps1` windows by timestamp cutoff, not by buffer length — so this cost
  disk (~24KB/day, roughly 9MB/year) rather than correctness. Devices whose buffers have already
  overgrown will trim back to `usrRetention` on their next sample after this reaches them.
- **The seed sample always reported `0 sample(s)`** (`Deploy-ArcCapacitySampler.ps1` v1.7). Same
  `-ReadCount 0` defect as above, in the deploy's post-seed count — which is what produced the
  self-contradictory `Seed sample taken - buffer now holds 0 sample(s)` observed on a real fresh
  install. Two further weaknesses in the same block were fixed alongside it: the success branch
  tested only `Test-Path`, so a header-only buffer reported success; and the fixed 12-second sleep
  was a race on a slow VM regardless. It now polls every 2s for up to 60s for the first actual data
  row, returning as soon as one lands — so the normal case is *faster* than the old unconditional
  12s block — and distinguishes "no buffer file" from "buffer exists but no rows yet". A slow seed
  never escalates past `WARNING`, since the 15-minute schedule populates the buffer regardless.
  Verified against 5 scenarios including the exact production case (header present, row arriving
  later).

### Added
- **Component 1 now stamps its own version into the job output** (`Deploy-ArcCapacitySampler.ps1`
  v1.6), as the first line (`Deploy-ArcCapacitySampler.ps1 v1.6`) and as
  `SamplerDeployVersion=` in the `<-Start Result->` block on all three exit paths, including the
  failure path. This script is *pasted* into Datto's console rather than fetched, so nothing in the
  output previously revealed which revision ran — during a multi-site rollout that made "an older
  paste" indistinguishable from "a per-job variable override" from the log alone. Emitted before
  anything that can fail, so even a crashed run identifies itself.
- **The installed sampler payload's version is now reported too** —
  `Arc-CapacitySampler.ps1 on device is v1.5`, plus `SamplerPayloadVersion=`. Read from the
  installed file on disk (not the fetch) on all three copy paths — installed, already current, and
  left as-is — so the log always states which sampler revision the device is actually running.
  Since the payload is fetched from git and changes with no re-paste, the SHA256 already logged
  identified it uniquely but told a human nothing. Falls back to `unknown` rather than failing a
  deploy over a cosmetic field.

### Changed
- **Corrected the README's "All 30 UDFs" claim**, which contradicted the scripts' own `1–300`
  validation range and briefly misdirected diagnosis of a live enrollment-marker issue toward a
  non-existent platform ceiling. Now states the accepted range (`Custom1`–`Custom300`) and the
  ranges actually used: 60–69 (Analyse), 70–73 (Screen), 79 (enrollment marker).

### Fixed
- **The enrollment marker's disabled path was completely silent, making a live rollout
  undiagnosable** (`Deploy-ArcCapacitySampler.ps1` v1.6). With `usrEnrollUdf=0` the script wrote
  nothing and logged nothing, so a job log from a device with the marker deliberately switched off
  was byte-identical to one from a device still running a pre-1.5 component — two different
  problems needing opposite fixes, with no way to tell them apart from the output. Surfaced when
  `Custom79` didn't appear after a multi-site rollout despite working on a test site. Every other
  suppression in this toolset announces itself (`DIT-UNKNOWN` sets a flag, an out-of-range
  `usrEnrollUdf` emits a WARNING); this one didn't. Now always logs the resolved index **and where
  it came from** — `Enrollment marker target: Custom79 (script default)` vs
  `(usrEnrollUdf=79)` — and on the disabled path says so explicitly. Absence of *any* enrollment
  line in a job log is now itself the signal that a pre-1.5 component is still pasted into the
  console. Verified against 8 input cases (undeclared, blank, explicit `0`, explicit index, a
  different index, out-of-range, non-numeric, and reserved UDF 1).

### Added
- **Self-maintaining device filter via a new enrollment marker**
  (`Deploy-ArcCapacitySampler.ps1` v1.5). New `usrEnrollUdf` variable, default `79` — Component 1
  writes `ENROLLED | <date/time>` to that field on every successful run and clears it on
  `usrUninstall=true`. Lets a Datto Device Filter key off `Custom79 is not blank` so the device
  group used to target all three components' recurring schedules stays correct on its own as
  devices are enrolled or removed, instead of a hand-maintained group. Written regardless of
  `SamplerStatus` as long as the scheduled task is actually registered — it tracks fleet
  membership, not today's fetch health, which is already reported separately. Set `usrEnrollUdf=0`
  to disable if that UDF is already in use for something else; an out-of-range index downgrades to
  `WARNING` and skips the marker for that run rather than failing the deploy — an auxiliary field
  must never take down the core job.

### Added
- **Domain controller RAM floor is now a function of actual DIT size** (`Read-ArcCapacityBuffer.ps1`
  v1.8) — closes the open item from Known limitations. Previously every DC used the same flat
  4GB floor regardless of how large its `ntds.dit` actually was; since ESE dynamically caches the
  DIT against available memory (no manual tuning needed on any currently supported Windows
  Server version), a large-DIT DC genuinely benefits from more RAM and a flat floor risked
  recommending a reclaim into that legitimate demand. New `Get-DcDitSizeGB` helper reads the
  actual configured DIT path from the registry (not assuming the default location, since it's
  commonly relocated) and computes the floor as `max(4GB, ceil(DIT size × 1.15 + 2GB))` — a
  reasoned estimate, not a vendor-published constant, same status as this tool's other
  multipliers. Only ever raises the floor, never lowers it. Feeds into the *same* shared
  `Get-SizingTarget` reclaim and growth already use, so both directions automatically respect the
  new floor with no separate logic path. `Cap: RAM Detail` gains a DC-specific suffix showing the
  resolved DIT size and computed floor (or that it couldn't be resolved) so the number driving
  the recommendation is never silent. Does not check for a legacy manual NTDS cache-size cap
  (`Database cache size (max)` / `EDB max buffers`) that would prevent added RAM from actually
  being used — deliberately out of scope for now. CSV export gains `DitSizeGB`/`RamFloorGB`
  columns.

### Fixed
_Found by a pre-commit code review of the DIT-floor addition above; see each item for what was
wrong and why. Both caught before this ever ran on a real device._
- **An unresolvable DIT size silently fell back to the flat 4GB floor and computed a live verdict
  anyway** — the exact known-wrong value this whole feature exists to move away from. Every other
  guardrail in this file suppresses the recommendation rather than degrade it (`EXCLUDED` roles,
  `MEM-PRESSURE`, `CPU-PRESSURE`); the DIT floor didn't follow that pattern. Fixed: `DIT-UNKNOWN`
  now suppresses both the RAM and growth verdict to `REVIEW` entirely, matching the rest of the
  file, rather than silently computing against a floor the tool's own docs call wrong.
- **A large-but-uncompacted DIT could manufacture an evidence-free growth recommendation with no
  correlation to actual measured demand.** A DIT can grow from tombstone/whitespace bloat after
  years without an offline defrag, with no live-memory equivalent — the DIT-raised floor alone
  was enough to trigger a firm `GROWTH` verdict even when p95 committed memory showed the host
  comfortably within its current allocation (worked example: 32GB DIT, 16GB allocated, 5GB p95
  commit — no memory pressure — produced a firm `GROWTH +56GB` before this fix). Fixed: the
  DIT-raised target is now cross-checked against the *same* target computed with the flat,
  non-DIT floor. If the flat-floor evidence doesn't independently support growth, the verdict
  downgrades to `REVIEW`/`DIT-REVIEW` instead of asserting a number the measured demand doesn't
  back up. Active memory pressure is unaffected by this check — it's independent, stronger
  evidence and still produces a firm `URGENT` verdict regardless. The DIT floor's original,
  intended protection (preventing an inappropriate *reclaim* recommendation on a large-DIT DC)
  is unaffected by this fix — only the *growth* side needed the extra corroboration.
- Two lower-severity items also addressed: the DC-specific `Cap: RAM Detail` suffix logic was
  duplicated (same role/null checks re-derived ~230 lines apart) — consolidated into one
  suffix computed once, alongside the floor, and reused at the write-back site; and the DIT
  formula's deliberate non-use of the existing `Get-SizingTarget` helper (additive, not a
  max-of-floor-and-basis) is now called out in a comment, since the surface similarity invites a
  future "helpful" consolidation that would silently change the arithmetic.
- Validated against 6 scenarios before committing: the exact flagged bug case (bloated DIT, no
  corroborating demand → now `REVIEW` not a fabricated number), a genuinely under-provisioned
  large-DIT DC (evidence corroborates → firm `GROWTH` still fires), a large DIT correctly
  preventing an over-reclaim (the feature's original purpose, unaffected), a small DIT deferring
  to the flat floor, the `DIT-UNKNOWN` full-suppression path, and active memory pressure
  correctly overriding the new evidence check to still produce `URGENT`.

### Fixed
- **Confirmed production bug: a genuinely successful `Arc — Capacity Screen` run on a real
  device was reported as a failure** (`Invoke-ArcCapacityAnalyse.ps1` v1.4,
  `Invoke-ArcCapacityScreen.ps1` v1.4). The fail-closed exit-code check added in the previous
  fix pass assumed `$LASTEXITCODE` reliably propagates across the `& $Local` invocation of the
  fetched script — it doesn't, in Datto's actual execution environment, even though two separate
  local reproductions of the same invocation pattern worked fine. The device's console output
  showed the fetched script reaching its normal `exit 0` and printing a complete `<-Start
  Result->` block (`ScreenStatus=NO_ACTION`), immediately followed by the stub reporting "returned
  without an exit code - treating as a failure." Since the previous fix made exit-code propagation
  load-bearing, every run of both stubs was affected, not just this one case. Replaced entirely:
  both stubs now determine success/failure from the fetched script's own `<-Start Result->`
  block — which the production output proves reliably arrives — with the status value whitelisted
  against known-OK values (`OK`/`LOW_COVERAGE`/`NO_DATA` for Analyse,
  `CANDIDATE`/`LOW_UPTIME`/`NO_ACTION` for Screen) rather than blocklisted against known-bad ones,
  so an unrecognised or `BAD_UDF_BASE`/`FAILED` status still fails closed by default. Verified
  against the exact production case plus four other scenarios (crash before any result block,
  explicit `FAILED` status, `BAD_UDF_BASE`, and each whitelisted status) before committing.

### Changed
- **Removed the "Platform & Infrastructure" internal team byline from every script header**
  (all six `.ps1` files bumped a patch version). Same reasoning as the earlier company-name
  removal — this repo is public, and the header doesn't need to name an internal team any more
  than it needs to name the company. The line now reads just "Datto capacity sampling toolset".

### Added
- **Under-provisioning detection with a growth-sizing recommendation (`Read-ArcCapacityBuffer.ps1`
  v1.5).** Previously the guardrails (`MEM-PRESSURE`, `CPU-PRESSURE`) only ever suppressed a
  reclaim/reduce recommendation on a struggling host — there was no equivalent "this host needs
  more" output, just a flag and a verdict sentence. Growth-sizing now shares the same target
  computation as reclaim/reduce, via a new shared `Get-SizingTarget` helper (`Target =
  max(RoleFloor, basis × multiplier)`), and reads the other side of it: when demand plus headroom
  already exceeds allocation, that's a growth candidate. RAM growth additionally escalates
  independently whenever `MEM-PRESSURE` is active, using max Committed rather than p95 (a host can
  be thrashing on short spikes a 14-day p95 smooths flat) and the same mode-appropriate multiplier
  as the primary target; when pressure is active but even that escalation shows no allocation
  shortfall, it flags `REVIEW` rather than forcing a number the math doesn't support. vCPU growth
  mirrors the existing reduce calculation, and flags `REVIEW` (without fabricating a core count,
  but still setting the `CPU-GROWTH` flag so a flag-based worklist catches it) when `CPU-PRESSURE`
  is queue-driven rather than total%-driven. A structural guard before UDF write-back now enforces
  — rather than assumes — that a device is never shown as both a reclaim and a growth candidate for
  the same metric. New UDFs `Custom67` (`Cap: Growth GB`), `Custom68` (`Cap: Growth vCPU`),
  `Custom69` (`Cap: Growth Verdict`) — `usrUdfBase` now needs **10** consecutive fields instead of
  7 (valid range 1–291, was 1–294). New flags `GROWTH` and `CPU-GROWTH`. Per-device CSV export
  gains `GrowthGB`, `GrowthVerdict`, `VcpuGrowth`, `CpuGrowthVerdict` columns. Deliberately scoped
  to `Arc — Capacity Analyse` only — `Arc — Capacity Screen`'s same-day, no-history basis is the
  wrong foundation for a recommendation meant to catch active pressure via a max-based figure it
  has no percentile history to compute.

### Fixed
_Found by a pre-commit code review of the growth-sizing addition above; see each item for what was
wrong and why. All caught before this ever ran on a real device._
- **A memory-pressure event, however transient, forced a fabricated `URGENT +2GB` growth
  recommendation regardless of actual need.** The "floor to a minimum 2GB" guard on the
  pressure-escalation path was based on a wrong assumption about the rounding helper it fed from —
  that helper already never returns a value below 2 for any positive input, so the floor only ever
  fired when the escalation had legitimately computed zero shortfall, silently overriding it to 2.
  A device with enormous real headroom that merely had one transient available-memory dip (a
  backup job, an AV scan) would have shown a false urgent-growth flag. Replaced with a `REVIEW`
  verdict when pressure is active but no shortfall is actually confirmed, matching the pattern
  already used for CPU's queue-driven case.
- **The same pressure-escalation path hardcoded a 1.25× multiplier instead of the mode-appropriate
  one**, so conservative mode's escalation was narrower than conservative mode's own standard
  margin — backwards for a mode that exists to add safety margin under noisier data. Fixed by
  extracting a shared `Get-SizingTarget` helper both the primary target and the escalation target
  now call, so the two can no longer drift onto different multipliers.
- **Queue-driven CPU growth set a `REVIEW` verdict but never added the `CPU-GROWTH` flag**, so a
  worklist filtered on that flag (or on `Cap: Growth vCPU not equal to 00`, which stays `00` for
  this case since there's no number to show) would silently miss these hosts entirely — exactly
  the failure mode this tool's own design philosophy says is worse than a missed reclaim. Now sets
  the flag alongside the text.
- **The "never both a reclaim and a growth candidate" invariant was incidental, not enforced** — it
  held only because of how the guardrail branches happened to be ordered, not because anything
  structurally guaranteed it. A future guardrail refinement (e.g. partial reclaim under mild
  pressure) could have silently broken it. Added an explicit check before UDF write-back that
  resolves any such conflict in favour of growth.
- **A new `Get-Ceil2` helper duplicated the existing `Get-CeilEven` exactly** (confirmed by direct
  testing — both round up to the nearest even number for any positive input). Removed; RAM growth
  now uses `Get-CeilEven` like CPU growth already did.
- **Neither pressure-suppressed verdict pointed to a waiting growth recommendation.** "NO RECLAIM -
  memory pressure" and "NO REDUCTION - CPU pressure" gave no indication when the same host also had
  a growth recommendation sitting in the adjacent UDF, risking an operator reading only one verdict
  field and concluding no action was needed. Both now append "- see growth verdict" when that's
  the case.

### Changed
- **Removed the company-name credit from every script header and from the scheduled task's
  `<Author>` field** (all six `.ps1` files bumped a patch version). These scripts live in a
  public repo; the literal entity name doesn't need to be in the file headers or baked into
  metadata a device's Task Scheduler exposes. Functional "Arc"-branded identifiers — the install
  path, scheduled task name, script names, and Datto component naming — are unchanged, since
  already-deployed devices depend on them and renaming those is a separate, bigger exercise.

### Fixed
_Found by a pre-commit code review of the changes below; see each item for what was wrong and why._
- **Missing TLS 1.2 enforcement (`Deploy-ArcCapacitySampler.ps1` v1.2, `Invoke-ArcCapacityAnalyse.ps1`
  / `Invoke-ArcCapacityScreen.ps1` v1.1).** None of the three GitHub-fetching scripts forced TLS
  1.2 before calling `Invoke-WebRequest` against `raw.githubusercontent.com`, even though
  `gpo/Apply-Baseline.ps1` and `gpo/Register-DriftTask.ps1` already carry this exact fix in this
  same repo. Windows Server 2012R2/early 2016 — explicitly a supported OS per these scripts' own
  headers — doesn't default to TLS 1.2, and GitHub's raw-content CDN requires it, so every fetch
  would have failed outright on that OS tier with no obvious diagnostic. Fixed by setting
  `[Net.ServicePointManager]::SecurityProtocol = Tls12` at the top of all three scripts.
- **A permanently broken fetch looked identical to a one-off blip, forever (`Deploy-ArcCapacitySampler.ps1`
  v1.2).** A bad `usrBranch` or a proxy permanently blocking GitHub produced the same WARNING as a
  transient failure, indefinitely, with no escalation. Now tracks consecutive fetch failures in
  `deploy-fetch-state.json` beside the payload and escalates to a genuine `FAILED` status (and
  non-zero exit) after 7 consecutive daily failures, resetting to 0 on the next success.
- **`usrSeedNow` still defaulted to forcing a sample on every run (`Deploy-ArcCapacitySampler.ps1`
  v1.2).** Recommending a daily schedule (this same changeset, below) without revisiting this
  meant every device would force an extra off-cycle sample plus a 12-second blocking wait once a
  day instead of roughly 12x/year. Now auto-detects a genuinely fresh install and only seeds then,
  regardless of the `usrSeedNow` value — no operator action needed.
- **SQL counter cache locked in a total resolution failure for 30 days (`Arc-CapacitySampler.ps1`
  v1.3).** If SQL's Memory Manager/Buffer Manager counter sets failed to resolve even once (e.g.
  moments after a SQL install/reboot, before perf counters register), that null result was cached
  for the full 30-day `$CacheDays` window with no retry path. Now only caches a resolution that
  found at least one counter set; a total failure retries on the next 15-minute sample instead.
  Pre-existing logic carried over from the original bundle, not introduced by the disk-guard work
  below, but surfaced by the same review pass.
- **Buffer directory creation could throw unhandled ahead of the new disk guard (`Arc-CapacitySampler.ps1`
  v1.3).** `New-Item` for the buffer directory ran outside the main try/catch and before the disk
  guard (which needs the directory to already exist to log to it) — if the directory was ever
  missing while the drive was already critically low, this would crash with a raw error instead of
  the guard's intended clean skip. Now wrapped so it fails the same clean way.
- **Disk guard relied on catching an exception for non-local `-BufferPath` values (`Arc-CapacitySampler.ps1`
  v1.3).** `System.IO.DriveInfo` throws for a UNC path; the guard caught this and silently disabled
  itself, correctly in outcome (the guard is cosmetic, not a disk-space safeguard - see below) but
  via exception-driven control flow. Now checks the path shape first and treats a non-drive-letter
  `-BufferPath` as an intentional "guard not applicable" case with the same fail-open result.
- **Fetch/retry logic duplicated 3x with no "keep in sync" signal.** `Deploy-ArcCapacitySampler.ps1`,
  `Invoke-ArcCapacityAnalyse.ps1` and `Invoke-ArcCapacityScreen.ps1` each independently implement
  the same retry block (unavoidable — they're pasted separately into Datto's console with no
  shared file available at runtime), but nothing marked them as needing to move together. Each now
  carries a `KEEP THIS RETRY LOOP IN SYNC` comment naming the other two files.
- **No fallback if the weekly/ad-hoc stub's fetch failed (`Invoke-ArcCapacityAnalyse.ps1` /
  `Invoke-ArcCapacityScreen.ps1` v1.1).** Unlike Component 1's git → attachment → keep-existing
  chain, a fetch failure here skipped the entire run outright. Both stubs now cache the last
  successfully-fetched copy of their target script under
  `C:\ProgramData\Arc\CapacitySampler\cache\` and run that on a fetch failure instead of skipping
  — only reporting `FETCH_FAILED` if no cached copy exists yet (a component's first-ever run).
- **`exit $LASTEXITCODE` after `& $Local` depended on an unenforced contract (`Invoke-ArcCapacityAnalyse.ps1`
  / `Invoke-ArcCapacityScreen.ps1` v1.1).** Not a live bug — every current branch of
  `Read-ArcCapacityBuffer.ps1`/`Get-ArcCapacityScreen.ps1` calls an explicit `exit` — but a future
  edit adding a bare `return` would leave `$LASTEXITCODE` stale/null, and `exit $null` reports
  success (0) regardless of what happened. Now resets `$LASTEXITCODE` to `$null` before invoking
  the fetched script and fails closed (`exit 1`) if it's still `$null` afterwards.
- One candidate from the same review — a theory that an empty `samples.csv` could cause
  `Export-Csv -Append` to silently write headerless rows — was investigated and refuted by direct
  testing; no change made.

### Added
- **Low disk space guard in `Arc-CapacitySampler.ps1` (v1.2).** Skips a sample cleanly (logged,
  exit 0) if its buffer's drive has under 500MB free (`$MinFreeMB`, hardcoded default — not
  wired through Datto variables). Not intended to relieve disk pressure — the buffer/log
  footprint is a few hundred KB regardless — the point is failing clean rather than repeating a
  write error every 15 minutes on an already-critical drive. Datto's own low-disk-space
  monitor/alert is assumed present and covers the actual incident; this only avoids noisy
  failures and leaves a visible coverage gap in `Cap: Window` for the affected period.

- **Git as the source of truth for deployed monitors, so a revision needs a git merge, not a
  Datto re-paste.** Three scripts are now pasted into their Datto components once and fetch the
  real payload/logic fresh from this repo's raw content (branch selectable per-component via a
  new `usrBranch` variable, default `main`) on every run:
  - `Deploy-ArcCapacitySampler.ps1` (v1.1) — now fetches `Arc-CapacitySampler.ps1` from git first
    (3 attempts with backoff), hash-compares it against the on-device copy, and only redeploys if
    it changed. The file attachment is now an **optional fallback** for a device's first deploy
    if the fetch is briefly unreachable — no longer required. A fetch failure on a device that
    already has the sampler installed just logs a warning and leaves the existing payload
    running untouched, rather than failing the job. Recommended schedule changed from monthly to
    **daily**, since the daily run is what turns a git merge into a same-day fleet update.
  - `Invoke-ArcCapacityAnalyse.ps1` (v1.0, new) — bootstrap stub pasted into `Arc — Capacity
    Analyse`. Fetches and runs `Read-ArcCapacityBuffer.ps1` from git on every (weekly) run; that
    existing weekly cadence is itself the check-back, no separate timer needed. Fails the job
    with `CapacityStatus=FETCH_FAILED` after 3 retries, since a weekly job failing is easy to
    notice and re-run.
  - `Invoke-ArcCapacityScreen.ps1` (v1.0, new) — same pattern for `Arc — Capacity Screen`,
    fetching and running `Get-ArcCapacityScreen.ps1`; fails with `ScreenStatus=FETCH_FAILED`.
  - `Read-ArcCapacityBuffer.ps1` (v1.3) and `Get-ArcCapacityScreen.ps1` (v1.1) — header comments
    only, updated to state that these are now fetched by their respective bootstrap stub rather
    than pasted into Datto directly. No logic change.
  - `README.md` restructured accordingly: component table now distinguishes what's actually
    pasted into Datto from what's fetched, `Branching & releases` describes the fetch-and-hash
    delivery model and the daily/weekly cadence split, Deployment/Troubleshooting/Rollback
    sections updated for `usrBranch` and the new `FETCH_FAILED` / fallback states.

- **Brought into the repo.** Initial import of the Datto RMM capacity-sampling toolset:
  - `Deploy-ArcCapacitySampler.ps1` (v1.0) — Component 1, installs the on-device sampler and its
    scheduled task (SYSTEM, boot trigger, idempotent/hash-checked payload copy).
  - `Arc-CapacitySampler.ps1` (v1.1) — on-device 15-minute sampler, file attachment on Component
    1. Committed Bytes / Available MBytes / hard fault rate, total + max-core CPU + processor
    queue length, RDSH session count, SQL Total/Target Server Memory + PLE with a cached counter
    set resolution. CSV ring buffer with schema-change detection (archives the old buffer rather
    than throwing on an `Export-Csv -Append` schema mismatch).
  - `Read-ArcCapacityBuffer.ps1` (v1.2) — Component 2, weekly aggregation of the buffer into
    percentile RAM/CPU demand, role detection (DC/SQL/Exchange/RDSH/File server/Veeam/Generic)
    with role-based floors and RAM-sizing exclusions, pressure guardrails (mem pressure,
    single-thread bound, CPU pressure), UDF 60–66 write-back, optional per-device CSV export, and
    a conservative short-window mode (max×1.4, gross-only, forced below a 7-day window).
  - `Get-ArcCapacityScreen.ps1` (v1.0) — Component 3, same-day over-allocation screen with no
    buffer history required (peak working-set sum as a conservative upper bound, average CPU
    since boot from idle time, no vCPU recommendation), UDF 70–73 write-back, uptime gate.
  - Status: Pilot — built and pilot-tested per the rollout plan in `README.md`; full estate
    rollout in progress as of 14/08/2026.
  - No functional changes made during import — scripts carried over as authored; only the
    accompanying documentation was restructured into this repo's `README.md`/`CHANGELOG.md`
    convention, and site-identifying examples (real hostnames/site names) were replaced with
    placeholders.
