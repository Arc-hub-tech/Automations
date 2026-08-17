# Datto capacity sampler

Estate-wide RAM and CPU white-space measurement for Arc-managed Windows servers, delivered as
Datto RMM components. Guest-side demand only — Committed Bytes rather than `FreePhysicalMemory`,
highest single-core utilisation rather than just total — drives right-sizing recommendations,
with role-aware floors/exclusions and pressure guardrails so a bad reading **suppresses** a
recommendation rather than degrading it.

**Status:** Pilot — components built, UDFs configured, estate rollout in progress.

Git is the source of truth for revision delivery — see **Branching & releases** below. Only
`Deploy-ArcCapacitySampler.ps1`, `Invoke-ArcCapacityAnalyse.ps1` and
`Invoke-ArcCapacityScreen.ps1` are ever pasted into the Datto console; everything else is fetched
fresh from the branch each time those run, so a revision merged to `main` reaches the fleet
without touching Datto again.

| Script | Datto component | Pasted into Datto? | Runs | Purpose |
| --- | --- | --- | --- | --- |
| `Deploy-ArcCapacitySampler.ps1` | Component 1 — `Arc — Capacity Sampler Deploy` | **Yes** | Daily (recommended) | Fetches the sampler payload from git, redeploys it + its scheduled task if changed |
| `Arc-CapacitySampler.ps1` | Fetched by Component 1 | No — fetched (fallback: file attachment) | Every 15 min, on-device | Writes one sample to the rolling buffer |
| `Invoke-ArcCapacityAnalyse.ps1` | Component 2 — `Arc — Capacity Analyse` | **Yes** | Weekly | Bootstrap stub — fetches and runs `Read-ArcCapacityBuffer.ps1` |
| `Read-ArcCapacityBuffer.ps1` | Fetched by Component 2's stub | No — fetched | Weekly | Aggregates the buffer, sizes, writes UDF 60–66 |
| `Invoke-ArcCapacityScreen.ps1` | Component 3 — `Arc — Capacity Screen` | **Yes** | Ad hoc | Bootstrap stub — fetches and runs `Get-ArcCapacityScreen.ps1` |
| `Get-ArcCapacityScreen.ps1` | Fetched by Component 3's stub | No — fetched | Ad hoc | Same-day over-allocation screen, writes UDF 70–73 |

`Arc-CapacitySampler.ps1` can still travel with Component 1 as a file attachment — that's now a
**fallback only**, used for a device's first deploy if the git fetch is briefly unreachable (see
Branching & releases). It's no longer required for normal operation.

See `CHANGELOG.md` for version history. Each script versions independently — check its own
header comment for its current version rather than assuming one tool-wide number.

## Branching & releases

Same two-branch model as the rest of this repo (see root `CLAUDE.md`): `develop` = work in
progress, `main` = production and branch-protected.

**Git is the source of truth for what's actually deployed**, the same way `gold-image/` and
`gpo/` work, just adapted to how Datto RMM components run rather than an interactive `irm`
one-liner. Three thin scripts are pasted into the Datto console once —
`Deploy-ArcCapacitySampler.ps1`, `Invoke-ArcCapacityAnalyse.ps1`, `Invoke-ArcCapacityScreen.ps1`
— and each fetches the real payload/logic fresh from `https://raw.githubusercontent.com/
Arc-hub-tech/Automations/<branch>/datto-capacity-sampler/...` every time it runs, controlled by
the component's own `usrBranch` variable (default `main`). Revision delivery then just needs a
git merge:

- **Component 1** (`Arc — Capacity Sampler Deploy`) should be scheduled **daily** as a recurring
  Datto job. Each run fetches `Arc-CapacitySampler.ps1` from the branch, hash-compares it against
  what's installed, and only redeploys + restarts the on-device scheduled task if it changed. A
  one-off fetch failure doesn't fail the job or touch the device — it just logs a WARNING and
  leaves the already-installed payload running, retrying on the next scheduled run. A fetch that
  keeps failing on every daily run for **7 consecutive days** — a permanently broken `usrBranch`,
  a proxy that started blocking GitHub — escalates to a genuine `FAILED` status instead of
  repeating an easy-to-ignore WARNING indefinitely (state tracked in
  `C:\ProgramData\Arc\CapacitySampler\deploy-fetch-state.json`, reset to 0 on the next successful
  fetch). Devices on Datto are never air-gapped, but treat the fetch as best-effort anyway (see
  Troubleshooting).
- **Components 2 and 3** (`Arc — Capacity Analyse`, `Arc — Capacity Screen`) already run
  infrequently enough (weekly / ad hoc) that their own existing cadence *is* the check-back — no
  separate timer needed. Each run fetches the current `Read-ArcCapacityBuffer.ps1` /
  `Get-ArcCapacityScreen.ps1` and caches a copy at
  `C:\ProgramData\Arc\CapacitySampler\cache\`. If the fetch fails, the stub runs that last
  successfully-fetched copy instead of skipping the run outright — it only reports `FETCH_FAILED`
  if there's no cached copy yet (a component's first-ever run with no connectivity).
- **The fetch/retry block is duplicated, not shared, across all three pasted scripts** — Datto's
  console is a single opaque paste field per component, so there's no local file a shared helper
  could live in without itself needing a fetch. Each copy carries a `KEEP THIS RETRY LOOP IN SYNC`
  comment naming the other two; a fix to the fetch mechanism (retry count, TLS, timeout) needs
  applying to all three by hand.
- **The on-device 15-minute sampler never touches the network.** Only the once-a-day Component 1
  check does — the sampler itself stays a fully local, self-contained scheduled task between
  redeploys, so a git-fetch hiccup can never disrupt the actual sampling.

To ship a revision: commit and validate on `develop` (point a pilot device's `usrBranch` at
`develop` to test it live before merging), merge `develop` → `main` via PR, bump the version in
the changed script's own header comment, and move `CHANGELOG` `[Unreleased]` → `[vX.Y]`. The
three pasted stubs themselves should rarely need touching — only if the fetch mechanism changes
(e.g. the repo moves) — everything else about a revision is a git-only change.

## Why the metrics are what they are

**Memory is measured as Committed Bytes, not free memory.** Windows parks spare memory on the
standby list as file cache, so a server with 32GB allocated and 9GB of real demand reports
roughly 2GB free and looks fully committed. Sizing from `FreePhysicalMemory` — what most scripts
use — understates reclaim across the estate by 60–70%. Committed Bytes is private memory demand
and is unaffected by cache behaviour. `Available MBytes` and hard fault rate are captured
alongside as pressure witnesses.

**CPU captures per-core spread, not just the total.** The same trap runs in the opposite
direction: a single-threaded workload on 8 vCPU reports 12% total utilisation while one core sits
pegged at 100%. Cutting vCPU on the total alone breaks exactly the workloads that cannot tolerate
it. Highest single-core utilisation and processor queue length are sampled to catch this.

**Sampling is continuous, not point-in-time.** A one-shot reading catches servers mid-backup or
mid-batch and discards perfectly good reclaim candidates. Samples are taken every 15 minutes into
a 14-day rolling buffer on the device; the analysis component reads percentiles from that buffer.

**SQL Server** gets Total/Target Server Memory and Page Life Expectancy where an instance is
present, because Committed Bytes on a SQL host reports the configured `max server memory`, not
the requirement. Counter set names are resolved once and cached to `sqlcounters.json` beside the
buffer, refreshed monthly, and invalidated immediately if a cached path stops resolving.

## Sizing logic

```
RAM   Target      = max( RoleFloor , p95 Committed × 1.25 )
      Reclaim     = Allocated − Target, floored to a 2GB increment,
                    suppressed below 4GB (not worth a change window)

CPU   EffCores    = (p95 Total% ÷ 100) × vCPU
      Recommended = ceil( EffCores ÷ 0.65 ), rounded up to an even count
```

Role floors (RAM GB / vCPU): DC 4/2 · RDSH 8/4 · File server 8/2 · SQL 8/4 · Exchange 16/4 ·
Veeam 8/4 · Generic 4/2.

### Guardrails — these suppress a recommendation rather than degrade it

- Sample coverage under 60% of the expected window
- Minimum Available memory under 1GB, or p95 hard faults above 10/sec
- p95 max-core above 85% while total sits below the single-thread ceiling for that vCPU count
- Role exclusions from RAM sizing: **SQL Server, Exchange, Veeam infrastructure**

Veeam is excluded because proxy and repository demand peaks inside the job window, and a p95
across 14 days will flatten it. SQL and Exchange are excluded because guest committed bytes
reports the configured memory cap, not the requirement — their buffer pool figure and minimum
PLE are reported instead (UDF 66), enough to triage which instances justify a `max server memory`
review.

## UDF map

All 30 UDFs already exist on every Datto device — this process **labels** existing fields, it
does not create new ones. Labels are account-wide (Setup → Global Settings → User-Defined
Fields); values are per device. Datto caps UDF labels at 22 characters.

> Check the existing UDF map in Global Settings before first run. `usrUdfBase` /
> `usrScreenUdfBase` overwrite without warning, and an out-of-range value now fails the job
> rather than silently falling back to the default — a typo can't quietly clobber a range that's
> already in use elsewhere in the account.

### `Arc — Capacity Analyse` (default base 60, 7 consecutive fields, valid 1–294)

| UDF | Suggested label | Content | Example |
|---|---|---|---|
| Custom60 | `Cap: Window` | Sample window and coverage | `14d \| 1312/1344 samples \| 98% coverage` |
| Custom61 | `Cap: RAM Detail` | Memory detail | `Alloc 32GB \| Commit p50 8.9 p95 9.9 max 11.2GB \| MinAvail 18.4GB \| Faults p95 0.4/s` |
| Custom62 | `Cap: Reclaim GB` | **Reclaimable GB — zero-padded** | `020` |
| Custom63 | `Cap: CPU Detail` | CPU detail | `8 vCPU \| Total p50 12% p95 19% max 44% \| MaxCore p95 43% \| Queue p95 1 max 4` |
| Custom64 | `Cap: Rec vCPU` | **Recommended vCPU — zero-padded** | `04` |
| Custom65 | `Cap: Role/Flags` | Role and flags | `Generic \| SINGLE-THREAD` |
| Custom66 | `Cap: Verdict` | Verdict summary and timestamp | `RAM: RECLAIM 20GB -> 12GB … \|\| 14/08/2026 22:15` |

### `Arc — Capacity Screen` (default base 70, 4 consecutive fields, valid 1–297)

| UDF | Suggested label | Content |
|---|---|---|
| Custom70 | `Scr: RAM` | `Alloc 32GB \| Commit 8.1GB \| PeakWS sum 11.4GB \| Avail 19.2GB \| Up 34d` |
| Custom71 | `Scr: Reclaim GB` | Zero-padded, e.g. `014` |
| Custom72 | `Scr: CPU` | `8 vCPU \| Avg since boot 6.4% over 34d = 0.51 cores of 8 \| REVIEW` |
| Custom73 | `Scr: Verdict` | Verdict, flags, timestamp |

There is no `Scr: Rec vCPU` — the screen deliberately produces no vCPU number (see Operation
below); don't leave a gap for one when building grid views. Keeping the screen's UDFs clear of
60–66 lets the screen and the long-term monitor be read side by side.

**Custom62/64 and Custom71 hold nothing but a zero-padded integer.** Datto stores and sorts every
UDF as a string, so an unpadded `8` sorts above `20` and your worst offenders end up buried
mid-list. Padding to a fixed width makes the lexical sort behave like a numeric one. Export the
grid with those columns for your dataset; strip the padding in Excel with `=VALUE(A2)` if you
need to sum it. Build a reclaim worklist by filtering `Cap: Reclaim GB` **not equal to `000`**.

The `Cap:` and `Scr:` prefixes group the two sets in the column picker and filter builder, which
matters once a dozen UDFs are in use — worth preserving since Screen values are provisional and
Analyse values are not.

### Flags

| Flag | Meaning |
|---|---|
| `MEM-PRESSURE` | Available memory or fault rate breached the guardrail; no reclaim offered |
| `SINGLE-THREAD` | One core near saturation on a low total; vCPU held |
| `CPU-PRESSURE` | Sustained high utilisation or queue depth; no reduction offered |
| `SQL` / `EXCH` / `VEEAM` | Excluded from RAM sizing by role |
| `LOW-UPTIME` | Screen only — under `usrMinUptimeHrs`, peak working sets not yet representative |
| `CANDIDATE` | Screen only — cleared the gross over-allocation test |

## Deployment

### Target filter

Create a device filter rather than using the built-in "All Windows Servers" filter — scope it to
only the servers you actually control the sizing decision for. Filter on `Operating System
contains Server` plus whatever site/tag/group boundary matches that scope in your Datto account;
including anything outside it makes the aggregate reclaim figure meaningless. Fall back to a
device-level exclusion for any edge cases a filter can't cleanly separate.

### Pilot

Run against 5–10 devices before the estate. The pilot set **must** include a domain controller, a
SQL Server host and an RDSH host — those branches carry the role exclusion logic, and they're
where an incorrect recommendation would do real damage.

Automation → Jobs → New Job → add `Arc — Capacity Sampler Deploy`, target the pilot set, run
once. Then run `Arc — Capacity Screen` against the same set for an immediate same-day read.

### Rollout

* `Arc — Capacity Sampler Deploy` (Component 1) — Category: Scripts · Type: Script (PowerShell) ·
  Platform: Windows · Level: Devices. Paste in `Deploy-ArcCapacitySampler.ps1`. File attachment
  `Arc-CapacitySampler.ps1` is now **optional** — a fallback for a first deploy if the git fetch
  is briefly unreachable, not a requirement. Run once against the full filter, then scheduled
  **daily** (not monthly — the daily run is what makes git the effective source of truth; see
  Branching & releases). Idempotent and hashes the fetched payload, so daily runs cost nothing,
  self-heal devices where the scheduled task was removed, and pick up any revision merged to the
  branch within a day.

  | Variable | Type | Default | Notes |
  |---|---|---|---|
  | `usrBranch` | String | `main` | Branch to fetch `Arc-CapacitySampler.ps1` from |
  | `usrInterval` | Integer | 15 | Sample interval in minutes |
  | `usrRetention` | Integer | 14 | Ring buffer depth in days |
  | `usrSeedNow` | Boolean | true | Take one sample immediately on a genuinely fresh install — automatically skipped on an already-deployed device, so the daily recurring run never forces a redundant off-cycle sample regardless of this setting |
  | `usrUninstall` | Boolean | false | Remove task, payload and collected samples |

  Registers `\Arc\Arc Capacity Sampler`, running as SYSTEM with a boot trigger so reboots don't
  create gaps. **Overhead per sample:** one CIM query per performance class plus a 2-second
  settle for the processor class — under a second of CPU, a few KB written. Buffer at 14 days /
  15 minutes is 1,344 rows, roughly 150KB. The daily git-fetch check itself is a single small file
  download — negligible next to the sampling overhead.

* `Arc — Capacity Analyse` (Component 2) — same category/type. Paste in
  `Invoke-ArcCapacityAnalyse.ps1` (the bootstrap stub — see Branching & releases); no file
  attachment. Scheduled **weekly**, first run no earlier than 14 days after the sampler was
  deployed.

  | Variable | Type | Default | Notes |
  |---|---|---|---|
  | `usrBranch` | String | `main` | Branch to fetch `Read-ArcCapacityBuffer.ps1` from |
  | `usrUdfBase` | Integer | 60 | First UDF index — consumes 7 consecutive fields, valid 1–294 |
  | `usrWindowDays` | Integer | 14 | Analysis window |
  | `usrInterval` | Integer | 15 | Must match Component 1 |
  | `usrExportPath` | String | *(blank)* | Optional UNC for a per-device CSV row |
  | `usrConservative` | Boolean | false | Short-window mode: max×1.4, gross-only. Forced on when `usrWindowDays` < 7 |

  Coverage below 60% returns `INSUFFICIENT DATA` rather than a bad number.

* `Arc — Capacity Screen` (Component 3) — same category/type. Paste in
  `Invoke-ArcCapacityScreen.ps1` (the bootstrap stub); no file attachment. Run once for an
  immediate candidate list; needs no buffer history.

  | Variable | Type | Default | Notes |
  |---|---|---|---|
  | `usrBranch` | String | `main` | Branch to fetch `Get-ArcCapacityScreen.ps1` from |
  | `usrScreenUdfBase` | Integer | 70 | First UDF index — consumes 4 consecutive fields, valid 1–297 |
  | `usrMinUptimeHrs` | Integer | 24 | Below this, no recommendation is made |
  | `usrExportPath` | String | *(blank)* | Writes `<hostname>-screen.csv`, so it can't collide with Component 2's export |

Input variables can be left blank for all three — the defaults above are correct for a standard
rollout on `main`. Set `usrBranch=develop` only on pilot devices while testing a revision.

## Operation

### Same-day screen (`Arc — Capacity Screen`)

Needs no history. Peak working set per process is retained by Windows since process start, so
summing it gives a high-water mark with no observation window — it overcounts on purpose (shared
pages double-counted, per-process peaks not simultaneous), making it a conservative upper bound.
It will miss marginal candidates and won't produce false positives, the correct bias for a list
meant to be acted on quickly.

CPU is average utilisation since boot, derived from System Idle Process kernel time rather than
by summing per-process CPU (which would undercount anything that's since exited). **No vCPU
recommendation is produced** — an average cannot size CPU; a host averaging 6% with a nightly 90%
batch window still needs its cores. Hosts under 5% average on 8+ vCPU are flagged `CPU-REVIEW`
for manual attention only; vCPU sizing comes from Component 2 on a real window.

Below `usrMinUptimeHrs` (default 24h) the peak working sets haven't had time to become
representative and the screen declines to recommend, flagging `LOW-UPTIME`.

Where Screen and Analyse disagree, **Analyse wins** — it measures demand over time rather than
inferring it from a high-water mark.

### Provisional analysis before 14 days (conservative mode)

For running the full aggregator before the buffer has filled, set `usrConservative=true` on
`Arc — Capacity Analyse`, or just set `usrWindowDays` below 7 and it switches on by itself — a
p95 over a handful of days is the maximum with extra steps, and presenting it as a percentile
invites someone acting on it as though it were one.

| | Standard | Conservative |
|---|---|---|
| RAM basis | p95 × 1.25 | **max × 1.4** |
| RAM threshold | ≥ 4GB | **≥ 8GB and ≥ 40% of allocation** |
| CPU basis | p95, 65% target | **max, 50% target** |
| CPU threshold | any reduction | **must at least halve** |
| Output label | — | **`PROVISIONAL`** |

The 40% threshold was tuned rather than guessed. At 50%, a 32GB VM peaking at 12GB — the most
obvious candidate on any estate — fell just outside and got deferred for no good reason. At 40%
it's caught, while a 32GB VM peaking at 16GB is still correctly deferred:

| Scenario | Standard | Conservative |
|---|---|---|
| 32GB, max 12.1GB | 20GB | 14GB |
| 32GB, max 16.0GB | 16GB | defer |
| 64GB, max 9.8GB | 56GB | 50GB |
| 16GB, max 11.0GB | 4GB | defer |
| 96GB, max 40GB | 50GB | 40GB |

Conservative mode gives up roughly 20–30% of the available reclaim in exchange for defensibility.
Re-run in standard mode at 14 days to recover the rest.

### Month-end batch hosts

Anything running finance, billing or reporting batch will show a clean 14-day p95 and then need
the memory back on the 31st. For those hosts, set `usrRetention=35` on
`Arc — Capacity Sampler Deploy` and `usrWindowDays=30` on `Arc — Capacity Analyse`. Buffer grows
from ~175KB to ~390KB. **RDSH hosts running close to their memory limit** should be moved to a
30-minute `usrInterval` instead — the CPU cost is negligible, but a 60MB sampler working-set spike
every 15 minutes on a host at 85% memory with 40 sessions will trim the standby list each time.
672 samples over 14 days is still ample for a p95.

### Estate rollup / reporting

Set `usrExportPath` on both `Arc — Capacity Analyse` and `Arc — Capacity Screen` to a UNC share.
Each device drops a single-row CSV (`<hostname>.csv` and `<hostname>-screen.csv` respectively),
sidestepping the Devices grid entirely:

```powershell
$rows = Get-ChildItem '\\<fileserver>\CapacityReports' -Filter '*.csv' |
        Where-Object { $_.Name -notlike '*-screen.csv' } |
        ForEach-Object { Import-Csv $_.FullName }

# Total reclaimable RAM across the estate
($rows | Measure-Object -Property ReclaimGB -Sum).Sum

# vCPU reduction available
($rows | Measure-Object -Property vCPU -Sum).Sum -
($rows | Measure-Object -Property RecommendedVcpu -Sum).Sum

# Top candidates by reclaim
$rows | Sort-Object { [int]$_.ReclaimGB } -Descending |
        Select-Object Hostname,Role,AllocatedGB,CommitP95GB,ReclaimGB,vCPU,RecommendedVcpu -First 25
```

The components run as SYSTEM under the machine account, so the share needs write for `Domain
Computers` on both share and NTFS permissions. If permissions are wrong the components still
report success and skip the export, with a line in the activity log. `EffectiveCores` and
`CommitP95GB` in the export feed platform capacity planning directly, so the same dataset answers
the overcommit ratio question without a second pass.

## Verification

On a device, after the sampler has been deployed:

```powershell
# Task registered and the trigger is live
Get-ScheduledTaskInfo -TaskPath '\Arc\' -TaskName 'Arc Capacity Sampler' |
  Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns

# Samples landing
Get-Content 'C:\ProgramData\Arc\CapacitySampler\samples.csv'
```

Expect `LastTaskResult` of `0`, `NumberOfMissedRuns` of `0`, and a populated `NextRunTime`.

**Two rows fifteen minutes apart is the actual proof.** The first row is written by the seed run
that the deploy component triggers directly, which demonstrates the script works but not that the
scheduled trigger fires — those are separate failure modes. Sample times land on `:02`, `:17`,
`:32`, `:47` rather than the quarter hours, since the trigger `StartBoundary` is midnight plus two
minutes — expected.

To check which UDFs a device has written locally:

```powershell
Get-Item 'HKLM:\SOFTWARE\CentraStage' |
  Select-Object -ExpandProperty Property |
  Where-Object { $_ -like 'Custom*' } | Sort-Object
```

> This registry key is a **write channel, not a mirror of platform state**. It shows only UDFs
> written locally by a script on that device. Values set in the portal, via the API, or by an
> integration won't appear. An empty result doesn't prove a UDF range is unused account-wide —
> check Global Settings for that.

After `Arc — Capacity Screen` runs, UDF 70–73 should populate on the device summary within
seconds — Datto's agent watches the registry key and pushes on change rather than waiting for an
audit. If the registry holds values but the portal doesn't, that's an agent communications issue
rather than a script fault.

**Monitors referencing a `Custom` UDF only read the value when the monitoring policy is pushed to
the device**, refreshed at least daily — a monitor on reclaim thresholds therefore lags the UDF
write by up to a day. Acceptable for capacity work; don't treat it as live. And UDF values are a
**snapshot from the last `Arc — Capacity Analyse` run, not live** — UDF 66 carries a timestamp for
exactly this reason, so a fresh reading can be told apart from one taken three weeks ago on a
server that's since been resized.

## Overhead

Estimates, not measurements from a live estate.

| | Non-SQL | SQL |
|---|---|---|
| CPU per sample | 0.6–1.2s | 0.6–1.2s (counter names cached) |
| Duty cycle | ~0.1% of one core | ~0.1% of one core |
| Disk per day | ~24KB | ~24KB |
| Buffer steady state | ~175KB | ~175KB |

Scheduled task priority is 7 (below normal). `Arc — Capacity Analyse` runs 8–15s per device,
weekly. The sampler perturbs its own measurement: a 45–60MB PowerShell process exists at the
moment committed bytes is read, inflating every reading by that amount — 0.2% on a 32GB server,
closer to 1.5% on a 4GB server. The bias is upward, so reclaim figures are slightly conservative.

The sampler skips a sample cleanly (logged, exit 0) if its buffer's drive has under 500MB free
(`$MinFreeMB` in `Arc-CapacitySampler.ps1`). This isn't about relieving disk pressure — the
buffer/log footprint above is trivial either way — it's so a genuinely critical drive fails clean
instead of repeating a write error every 15 minutes. Datto's own low-disk-space monitor is the
actual alert for that condition; a coverage gap in `Cap: Window` is the visible side effect here.

## Troubleshooting

| Symptom | Cause / action |
|---|---|
| Sampler log shows "Sample skipped - ... below the 500MB guard threshold" | The buffer's drive is critically low on space — the sampler deliberately skips the write rather than repeat a failing one every 15 minutes. Not a fix for the underlying low-disk condition — Datto's own low-disk-space monitor/alert covers that; this just means the buffer will show a coverage gap for the affected period once space recovers |
| `FETCH_FAILED` (Analyse/Screen) | The component's bootstrap stub couldn't reach GitHub after 3 attempts — check the device's outbound HTTPS (proxy/firewall must allow `raw.githubusercontent.com`), then re-run the job. Devices on Datto have a network path by definition, so a *persistent* failure here points at a proxy/allowlist gap, not a design limitation |
| Component 1 shows `WARNING` / "keeping the currently installed payload unchanged" | Git fetch failed on a device that already has the sampler installed and no file attachment was provided — harmless and self-heals on the next scheduled run; the on-device sampler keeps running on its last-good payload throughout |
| Component 1 shows `FAILED` / "has now failed N days in a row" | Git fetch has failed on 7+ **consecutive** daily runs — no longer treated as a one-off blip. Check the device's outbound HTTPS and the component's `usrBranch` value for a typo; the counter resets to 0 automatically on the next successful fetch |
| Analyse/Screen output shows "running the last successfully-fetched copy (cached ...)" | The fetch failed but a previously-cached copy exists at `C:\ProgramData\Arc\CapacitySampler\cache\` and ran instead — the job still completes normally; check connectivity if this persists across multiple runs, since the cached copy will grow stale |
| `Arc-CapacitySampler.ps1 not found` | Fetch failed **and** there's no file attachment **and** nothing is installed yet — this only happens on a device's very first deploy. Either fix connectivity or attach `Arc-CapacitySampler.ps1` as a one-time fallback |
| `No buffer at …` | `Arc — Capacity Sampler Deploy` hasn't run on that device |
| `BAD_UDF_BASE` | `usrUdfBase` outside 1–294 (Analyse), or `usrScreenUdfBase` outside 1–297 (Screen) |
| Coverage well under 100% | Device powered off for part of the window, or task disabled by GPO |
| CPU columns blank | Processor performance counters corrupt — `lodctr /R`, then re-run |
| Everything reads `EXCLUDED` | Expected on SQL, Exchange and Veeam hosts |
| `INSUFFICIENT DATA` | Coverage under 60%; wait, or reduce `usrWindowDays` |
| Reclaim `000` on an apparently idle server | Check `Cap: RAM Detail` for `MEM-PRESSURE` — a leaking process can hold committed bytes high |
| UDFs populated but stale | `Arc — Capacity Analyse` hasn't run recently; check the timestamp in `Cap: Verdict` |

Device-side log: `C:\ProgramData\Arc\CapacitySampler\sampler.log` (self-trims at 200KB).

## Rollback

`Arc — Capacity Sampler Deploy` with `usrUninstall=true` removes the scheduled task, the payload
and all collected samples from the device — this also removes
`C:\ProgramData\Arc\CapacitySampler\cache\`, the Analyse/Screen stubs' last-known-good cache, so
their next run after an uninstall needs a working git fetch (no fallback available until a fetch
succeeds at least once more). **It does not clear the UDFs** — those must be blanked separately.
The pasted bootstrap stubs (`Invoke-ArcCapacityAnalyse.ps1`, `Invoke-ArcCapacityScreen.ps1`) don't
need removing from Datto to roll back a *logic* revision — just merge the previous version back to
`main` and their next run picks it straight up.

## Known limitations

**Datto only ever sees the guest.** No ballooning, no swap-in rate, no CPU ready time. Guest-side
demand is the correct input for right-sizing allocations, which is where most of the white space
sits — but hypervisor-side allocated-vs-active needs your hypervisor's own reporting (e.g. Nutanix
Prism Central, VMware RVTools, or the equivalent for your platform). Use both: the hypervisor view
for allocated-vs-active, this tool for the in-guest truth.

**The domain controller RAM floor is a flat 4GB, and this is wrong.** ESE sizes the AD database
cache dynamically against available memory, so a DC's committed bytes partly reflects what it was
given. The cache is bounded by the DIT size, so this is self-limiting and far milder than the SQL
case — but a DC with a large DIT could receive a reclaim recommendation that shouldn't be acted
on. **Do not action DC reclaim recommendations without checking `ntds.dit` size and `lsass`
working set first.** Open item: make the DC floor a function of DIT size.

**SQL is a separate exercise.** Given how much of a typical estate is SQL, expect a meaningful
share to come back `EXCLUDED`.

**14 days is arguably short.** Commercial right-sizing tools commonly default to 30. The
one-week alternative is worse than it looks: at a 15-minute interval, the p95 tail over 7 days is
only 8.5 hours, so a single overnight batch run fills it entirely and "95th percentile" becomes
"the worst day that week".

## UDF allocation note

> If this process is ever extended into additional UDF fields, check Global Settings first rather
> than assuming a range is free — other automation in the account may already own fields outside
> 60–73.
