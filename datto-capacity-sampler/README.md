# Datto capacity sampler

Estate-wide RAM and CPU right-sizing for monitored Windows servers, delivered as Datto RMM
components — both directions: reclaim when over-allocated, growth when under-provisioned, from
one shared target so the two can never disagree. Guest-side demand only — Committed Bytes rather
than `FreePhysicalMemory`, highest single-core utilisation rather than just total — drives the
sizing, with role-aware floors/exclusions and pressure guardrails so a bad reading **suppresses**
a reclaim/reduce recommendation rather than degrading it, and **escalates** a growth
recommendation instead when the bad reading is active memory pressure.

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

Both directions — reclaim (over-allocated) and growth (under-provisioned) — come from one shared
target, so they can never disagree about what "right-sized" means:

```
RAM   RoleFloor   = flat per-role minimum, except DomainController: raised to
                    ceil( DIT size × 1.15 + 2GB ) where the DIT path can be read
                    from the registry — ESE dynamically caches the DIT against
                    available memory on any currently supported Windows Server
                    version, no manual tuning needed, but a large-DIT DC
                    genuinely needs more RAM to benefit from that. Never lowers
                    the floor. If the DIT path can't be resolved, suppresses the
                    RAM/growth verdict entirely (flags DIT-UNKNOWN) rather than
                    silently computing against the flat floor this exists
                    because it's wrong. If the DIT-raised floor alone would
                    trigger growth but the SAME target using the flat floor
                    doesn't, downgrades to REVIEW (flags DIT-REVIEW) instead of
                    asserting a number — a DIT can be large from tombstone/
                    whitespace bloat with no live-memory equivalent. Active
                    memory pressure is independent, stronger evidence and still
                    fires URGENT regardless of this check
      Target      = max( RoleFloor , p95 Committed × 1.25 )
      Reclaim     = Allocated − Target when positive, floored to a 2GB increment,
                    suppressed below 4GB (not worth a change window)
      Growth      = Target − Allocated when positive, ceilinged to a 2GB increment.
                    Escalates independently whenever MEM-PRESSURE is active, using
                    max Committed rather than p95 (active thrashing is a peak
                    problem, not a typical-case one) with the same multiplier the
                    current mode already selected. If pressure is active but even
                    that escalation shows no shortfall, flags REVIEW rather than
                    forcing a number the math doesn't support

CPU   EffCores    = (p95 Total% ÷ 100) × vCPU
      Reduce      = current vCPU − ceil( EffCores ÷ 0.65 ) [rounded even], when lower
      Growth      = ceil( EffCores ÷ 0.65 ) [rounded even] − current vCPU, when higher.
                    Queue-driven CPU pressure the total%-based model doesn't catch
                    (e.g. many short-lived threads) is flagged `REVIEW` for manual
                    attention rather than forcing a fabricated core count
```

**Growth is not the mirror image of reclaim in risk profile — it's deliberately more willing to
flag.** A missed reclaim candidate costs nothing but idle capacity; a missed growth candidate
costs someone a bad afternoon on a struggling server. That's why the MEM-PRESSURE escalation
exists at all: a host can be thrashing on short spikes that a 14-day p95 smooths flat, so active
pressure symptoms (available memory near zero, real hard faults) get to override what the
percentile math alone would conclude.

Role floors (RAM GB / vCPU): DC 4/2 (RAM floor raised per DIT size where resolvable — see above)
· RDSH 8/4 · File server 8/2 · SQL 8/4 · Exchange 16/4 · Veeam 8/4 · Generic 4/2.

**The 1.15× / 2GB DIT margin is a reasoned estimate, not a vendor-published constant** — same
status as this tool's other multipliers (1.25, 1.4, 65%). It only ever raises the DC floor above
the flat 4GB, never below it, and there's no companion registry tuning required on any currently
supported Windows Server version for the extra RAM to actually get used: NTDS's database cache
sizes itself dynamically against available memory by default. The one thing this doesn't check
for is a legacy manual cache-size cap (`Database cache size (max)` / `EDB max buffers` under
`HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters`) — if an admin has previously capped
NTDS's cache for some other reason, added RAM won't help until that cap is also raised, and this
tool won't tell you that's why.

### Guardrails — these suppress a recommendation rather than degrade it

- Sample coverage under 60% of the expected window
- Minimum Available memory under 1GB, or p95 hard faults above 10/sec — suppresses reclaim, but
  **escalates** growth instead (see Sizing logic above)
- p95 max-core above 85% while total sits below the single-thread ceiling for that vCPU count —
  suppresses reduce *and* growth, since more vCPU doesn't help a workload that can't spread past
  one core
- Role exclusions from RAM sizing, both directions: **SQL Server, Exchange, Veeam infrastructure**

Veeam is excluded because proxy and repository demand peaks inside the job window, and a p95
across 14 days will flatten it. SQL and Exchange are excluded because guest committed bytes
reports the configured memory cap, not the requirement, in either direction — their buffer pool
figure and minimum PLE are reported instead (UDF 66), enough to triage which instances justify a
`max server memory` review.

## UDF map

UDFs already exist on every Datto device — this process **labels** existing fields, it does not
create new ones. Labels are account-wide (Setup → Global Settings → User-Defined
Fields); values are per device. Datto caps UDF labels at 22 characters. These scripts accept any
index from 1–300 (registry values `Custom1`–`Custom300`); the ranges actually used are **60–69**
(Analyse), **70–73** (Screen) and **79** (enrollment marker).

> Check the existing UDF map in Global Settings before first run. `usrUdfBase` /
> `usrScreenUdfBase` overwrite without warning, and an out-of-range value now fails the job
> rather than silently falling back to the default — a typo can't quietly clobber a range that's
> already in use elsewhere in the account. `usrEnrollUdf` (Component 1, default `79` — see
> **Self-maintaining device filter** below) is the same overwrite-without-warning risk, but an
> out-of-range value there only downgrades to a `WARNING` and skips the marker for that run rather
> than failing the job — the actual sampler deploy must never fail over an auxiliary field.

### `Arc — Capacity Sampler Deploy` (default field 79, 1 field, valid 1–300)

| UDF | Suggested label | Content | Example |
|---|---|---|---|
| Custom79 | `Cap: Enrolled` | Enrollment marker — see **Self-maintaining device filter** | `ENROLLED \| 18/08/2026 22:15` |

### `Arc — Capacity Analyse` (default base 60, 10 consecutive fields, valid 1–291)

| UDF | Suggested label | Content | Example |
|---|---|---|---|
| Custom60 | `Cap: Window` | Sample window and coverage | `14d \| 1312/1344 samples \| 98% coverage` |
| Custom61 | `Cap: RAM Detail` | Memory detail | `Alloc 32GB \| Commit p50 8.9 p95 9.9 max 11.2GB \| MinAvail 18.4GB \| Faults p95 0.4/s` |
| Custom62 | `Cap: Reclaim GB` | **Reclaimable GB — zero-padded** | `020` |
| Custom63 | `Cap: CPU Detail` | CPU detail | `8 vCPU \| Total p50 12% p95 19% max 44% \| MaxCore p95 43% \| Queue p95 1 max 4` |
| Custom64 | `Cap: Rec vCPU` | **Recommended vCPU — zero-padded** | `04` |
| Custom65 | `Cap: Role/Flags` | Role and flags | `Generic \| SINGLE-THREAD` |
| Custom66 | `Cap: Verdict` | Reclaim/reduce verdict summary and timestamp | `RAM: RECLAIM 20GB -> 12GB … \|\| 14/08/2026 22:15` |
| Custom67 | `Cap: Growth GB` | **RAM growth recommendation — zero-padded** | `004` |
| Custom68 | `Cap: Growth vCPU` | **vCPU growth recommendation — zero-padded** | `02` |
| Custom69 | `Cap: Growth Verdict` | Growth verdict summary and timestamp | `RAM: URGENT +4GB -> 20GB … \|\| 14/08/2026 22:15` |

On a domain controller, `Cap: RAM Detail` gets an extra suffix — either
`| DIT 12.4GB -> floor 16GB` when the DIT size resolved, or `| DIT size unknown -> flat floor`
when it didn't — so the floor a DC's reclaim/growth figures are measured against is never a
silent number.

`Cap: Reclaim GB`/`Cap: Rec vCPU` and `Cap: Growth GB`/`Cap: Growth vCPU` are deliberately kept as
**separate fields rather than one signed number** — a device is never both a reclaim and a growth
candidate at once (they come from the same target calculation, on opposite sides of it), but
keeping them apart preserves the existing `Cap: Reclaim GB` **not equal to `000`** worklist filter
exactly as it already works, rather than changing what that field means.

### `Arc — Capacity Screen` (default base 70, 4 consecutive fields, valid 1–297)

| UDF | Suggested label | Content |
|---|---|---|
| Custom70 | `Scr: RAM` | `Alloc 32GB \| Commit 8.1GB \| PeakWS sum 11.4GB \| Avail 19.2GB \| Up 34d` |
| Custom71 | `Scr: Reclaim GB` | Zero-padded, e.g. `014` |
| Custom72 | `Scr: CPU` | `8 vCPU \| Avg since boot 6.4% over 34d = 0.51 cores of 8 \| REVIEW` |
| Custom73 | `Scr: Verdict` | Verdict, flags, timestamp |

There is no `Scr: Rec vCPU` — the screen deliberately produces no vCPU number (see Operation
below); don't leave a gap for one when building grid views. Keeping the screen's UDFs clear of
60–69 lets the screen and the long-term monitor be read side by side.

**Custom62/64/67/68 and Custom71 hold nothing but a zero-padded integer.** Datto stores and sorts
every UDF as a string, so an unpadded `8` sorts above `20` and your worst offenders end up buried
mid-list. Padding to a fixed width makes the lexical sort behave like a numeric one. Export the
grid with those columns for your dataset; strip the padding in Excel with `=VALUE(A2)` if you need
to sum it. Build a reclaim worklist by filtering `Cap: Reclaim GB` **not equal to `000`**; build a
RAM growth worklist the same way on `Cap: Growth GB`.

**A CPU growth worklist needs the flag, not just the number.** Queue-driven CPU pressure that the
sizing model can't turn into a safe core count still sets `CPU-GROWTH` in `Cap: Role/Flags`, but
leaves `Cap: Growth vCPU` at `00` since there's nothing to show there — filtering only on `Cap:
Growth vCPU not equal to 00` silently misses those hosts. Filter on the `CPU-GROWTH` flag (or check
`Cap: Growth Verdict` for `REVIEW`) to catch both the numeric and the queue-driven cases.

The `Cap:` and `Scr:` prefixes group the two sets in the column picker and filter builder, which
matters once a dozen UDFs are in use — worth preserving since Screen values are provisional and
Analyse values are not.

### Flags

| Flag | Meaning |
|---|---|
| `MEM-PRESSURE` | Available memory or fault rate breached the guardrail; no reclaim offered, growth escalated instead |
| `MEM-REVIEW` | Memory pressure is active but even the escalated (max-based) target shows no allocation shortfall — likely a leaking process or transient spike, not under-provisioning; no growth number is forced |
| `GROWTH` | RAM growth recommended — see `Cap: Growth GB` / `Cap: Growth Verdict` |
| `CPU-GROWTH` | vCPU growth recommended, or queue-driven pressure flagged `REVIEW` with no safe number to give — check `Cap: Growth Verdict`, since `Cap: Growth vCPU` stays `00` for the REVIEW case |
| `SINGLE-THREAD` | One core near saturation on a low total; vCPU held in both directions |
| `CPU-PRESSURE` | Sustained high utilisation or queue depth; no reduction offered, and growth flagged `REVIEW` if queue-driven |
| `SQL` / `EXCH` / `VEEAM` | Excluded from RAM sizing by role, in both directions |
| `DIT-UNKNOWN` | DC only — the DIT path couldn't be resolved from the registry, so both `Cap: Verdict` and `Cap: Growth Verdict` are suppressed to `REVIEW` rather than computed against the flat floor |
| `DIT-REVIEW` | DC only — the DIT-raised floor alone would trigger growth, but the same target using the flat floor doesn't; measured demand doesn't corroborate it, so no growth number is forced |
| `LOW-UPTIME` | Screen only — under `usrMinUptimeHrs`, peak working sets not yet representative |
| `CANDIDATE` | Screen only — cleared the gross over-allocation test |

## Deployment

### Target filter

Create a device filter rather than using the built-in "All Windows Servers" filter — scope it to
your target servers. Filter on `Operating System contains Server` plus whatever site/tag/group
boundary matches that scope; including anything outside it makes the aggregate reclaim figure
meaningless. Fall back to a device-level exclusion for any edge cases a filter can't cleanly
separate.

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
  | `usrEnrollUdf` | Integer | 79 | UDF index to mark this device as enrolled — see **Self-maintaining device filter** below. Set to `0` to disable |

  Registers `\Arc\Arc Capacity Sampler`, running as SYSTEM with a boot trigger so reboots don't
  create gaps. **Overhead per sample:** one CIM query per performance class plus a 2-second
  settle for the processor class — under a second of CPU, a few KB written. Buffer at 14 days /
  15 minutes is 1,344 rows, roughly 150KB. The daily git-fetch check itself is a single small file
  download — negligible next to the sampling overhead.

  #### Self-maintaining device filter

  Component 1 writes `ENROLLED | <date/time>` to `Custom79` (`usrEnrollUdf`, suggested label
  `Cap: Enrolled` — outside the 60–73 range the other two components use) on every successful
  run — cleared back to blank on
  `usrUninstall=true`. Build a Datto Device Filter on `Custom79 is not blank` and target **all
  three components'** recurring schedules at that filter instead of a hand-maintained Device Group:
  a device gains membership the moment Component 1 first deploys to it, and loses it the moment
  it's uninstalled, with no one having to remember to update group membership either way. Set
  `usrEnrollUdf=0` to disable if this UDF slot is already in use for something else, or a
  manually-scoped filter or group already does the job — this doesn't replace the **Target filter**
  guidance below, it's an alternative for keeping that filter's membership accurate on its own. A
  stale-looking timestamp on an otherwise-enrolled device is a useful heartbeat too — it means
  Component 1 hasn't completed a run recently, independent of whatever `SamplerStatus` last
  reported.

* `Arc — Capacity Analyse` (Component 2) — same category/type. Paste in
  `Invoke-ArcCapacityAnalyse.ps1` (the bootstrap stub — see Branching & releases); no file
  attachment. Scheduled **weekly**, first run no earlier than 14 days after the sampler was
  deployed.

  | Variable | Type | Default | Notes |
  |---|---|---|---|
  | `usrBranch` | String | `main` | Branch to fetch `Read-ArcCapacityBuffer.ps1` from |
  | `usrUdfBase` | Integer | 60 | First UDF index — consumes 10 consecutive fields, valid 1–291 |
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

**The Screen component does not detect under-provisioning.** Growth-sizing (Custom67–69) is only
computed by `Arc — Capacity Analyse`, deliberately — a same-day, no-history screen is the wrong
basis for a recommendation that's meant to catch active memory pressure using a max-based demand
figure; Screen has no percentile history to compute that from. If a host looks like it's
struggling and you can't wait for Analyse's window, that's a same-day judgement call, not
something this component automates.

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

**This gross-only dampening applies to reclaim/reduce only, not growth.** Growth uses the same
conservative basis (max × 1.4 for RAM, max-utilisation for CPU) but keeps its normal 2GB /
even-vCPU rounding threshold rather than requiring gross clearance — a false-negative on reclaim
just defers a tidy-up, but a false-negative on growth is a server left short. Conservative-mode
growth is still labelled `PROVISIONAL` for the same reason reclaim is: a p95 over a handful of
days isn't a settled figure.

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

# Total RAM growth needed across the estate (under-provisioned hosts)
($rows | Measure-Object -Property GrowthGB -Sum).Sum

# vCPU growth needed
($rows | Measure-Object -Property VcpuGrowth -Sum).Sum

# Top candidates by reclaim
$rows | Sort-Object { [int]$_.ReclaimGB } -Descending |
        Select-Object Hostname,Role,AllocatedGB,CommitP95GB,ReclaimGB,vCPU,RecommendedVcpu -First 25

# Under-provisioned hosts, most urgent first (memory-pressure escalation sorts to the top
# since it uses the max-based basis and rarely gets suppressed to 0 the way p95-only does)
$rows | Where-Object { [int]$_.GrowthGB -gt 0 -or [int]$_.VcpuGrowth -gt 0 } |
        Sort-Object { [int]$_.GrowthGB } -Descending |
        Select-Object Hostname,Role,AllocatedGB,CommitMaxGB,GrowthGB,GrowthVerdict,vCPU,VcpuGrowth -First 25

# DCs where DIT size couldn't be confirmed or a DIT-driven growth trigger wasn't
# corroborated by measured demand - worth a manual look either way
$rows | Where-Object { $_.Role -eq 'DomainController' -and $_.GrowthVerdict -match 'REVIEW' } |
        Select-Object Hostname,DitSizeGB,RamFloorGB,AllocatedGB,CommitP95GB,GrowthVerdict
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

**To confirm which revisions a device is running**, read Component 1's job output. Its first line
is the pasted deploy script's own version (`Deploy-ArcCapacitySampler.ps1 v1.6`), and it reports the
installed payload separately (`Arc-CapacitySampler.ps1 on device is v1.5`); both also appear in the
result block as `SamplerDeployVersion=` / `SamplerPayloadVersion=`. These answer two genuinely
different questions — the deploy version tells you what's **pasted into the Datto console** and only
changes when someone re-pastes it, while the payload version tells you what git delivered to the
device and changes on its own. A stale deploy version with a current payload is the normal signature
of a component that needs re-pasting.

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
| `Cap: Enrolled` blank on some devices but populated on others | Check the job output's first line for the deploy script version. Below v1.5 the component predates the marker entirely — re-paste Component 1. On v1.6+ the log states the resolved index and source (`Enrollment marker target: Custom79 (script default)`) or says the marker is disabled — note that **jobs carry their own variable overrides**, so one job passing `usrEnrollUdf=0` disables it for that job's devices only. On v1.5 exactly the marker is written silently or skipped silently, so those two cases are indistinguishable from the log — upgrade to v1.6+ before diagnosing further. Also check the job didn't fail before the write (`SamplerStatus=FAILED`) |
| Component 1 shows `FAILED` / "has now failed N days in a row" | Git fetch has failed on 7+ **consecutive** daily runs — no longer treated as a one-off blip. Check the device's outbound HTTPS and the component's `usrBranch` value for a typo; the counter resets to 0 automatically on the next successful fetch |
| Analyse/Screen output shows "running the last successfully-fetched copy (cached ...)" | The fetch failed but a previously-cached copy exists at `C:\ProgramData\Arc\CapacitySampler\cache\` and ran instead — the job still completes normally; check connectivity if this persists across multiple runs, since the cached copy will grow stale |
| `Arc-CapacitySampler.ps1 not found` | Fetch failed **and** there's no file attachment **and** nothing is installed yet — this only happens on a device's very first deploy. Either fix connectivity or attach `Arc-CapacitySampler.ps1` as a one-time fallback |
| `samples.csv` far larger than the ~175KB steady state | Sampler versions before v1.6 never trimmed the ring buffer (the trim test's row count was always 0), so `usrRetention` went unenforced and the buffer grew unbounded — ~24KB/day. Harmless to recommendations, since analysis windows by timestamp rather than buffer length. Resolves itself: once the device picks up sampler v1.6+ via Component 1, the next sample trims it back to `usrRetention` |
| `No buffer at …` | `Arc — Capacity Sampler Deploy` hasn't run on that device |
| `BAD_UDF_BASE` | `usrUdfBase` outside 1–291 (Analyse), or `usrScreenUdfBase` outside 1–297 (Screen) |
| Coverage well under 100% | Device powered off for part of the window, or task disabled by GPO |
| CPU columns blank | Processor performance counters corrupt — `lodctr /R`, then re-run |
| Everything reads `EXCLUDED` | Expected on SQL, Exchange and Veeam hosts |
| `INSUFFICIENT DATA` | Coverage under 60%; wait, or reduce `usrWindowDays` |
| Reclaim `000` on an apparently idle server | Check `Cap: RAM Detail` for `MEM-PRESSURE` — a leaking process can hold committed bytes high |
| UDFs populated but stale | `Arc — Capacity Analyse` hasn't run recently; check the timestamp in `Cap: Verdict` |
| `Cap: Growth GB` non-zero *and* `Cap: Reclaim GB` shows `000` at the same time | Expected — a device is only ever a candidate on one side of the target, never both |
| `Cap: Growth Verdict` says `URGENT` and the figure looks larger than `Cap: RAM Detail`'s p95 numbers suggest | Working as intended — the memory-pressure escalation path uses max Committed, not p95, specifically because active thrashing is a peak problem a percentile can understate |
| `Cap: Growth vCPU` stays `00` despite `CPU-PRESSURE` being flagged | Check `Cap: Growth Verdict` for `REVIEW` — that means the pressure is queue-driven rather than total%-driven, and the sizing model doesn't fabricate a core count from queue depth alone; needs a manual look |

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

**~~The domain controller RAM floor is a flat 4GB, and this is wrong~~ — addressed.** ESE sizes
the AD database cache dynamically against available memory, so a DC's committed bytes partly
reflects what it was given; a flat floor risked a reclaim recommendation into a large DIT's
legitimate demand. The floor is now `max(4GB, ceil(DIT size × 1.15 + 2GB))` where the DIT path
can be resolved from the registry (see Sizing logic above). Unlike the tool's other floors,
resolution failure here doesn't fall back to computing anyway — it **suppresses the RAM/growth
verdict to `REVIEW`/`DIT-UNKNOWN`**, matching the "suppress rather than degrade" guardrail
philosophy used everywhere else in this tool, since silently reverting to the flat floor is
exactly the known-wrong value this feature exists to avoid.

**A large DIT alone doesn't force a growth recommendation.** DIT size can reflect tombstone or
whitespace bloat from years without an offline defrag, with no live-memory equivalent — so a
DIT-raised floor that would trigger growth is cross-checked against the *same* target using the
flat floor first. If the flat-floor evidence doesn't independently support growth, the verdict
downgrades to `REVIEW`/`DIT-REVIEW` rather than asserting a number the measured demand doesn't
back up. Active memory pressure is unaffected by this check — it's independent, stronger
evidence and still produces a firm `URGENT` verdict regardless.

This doesn't remove the need for judgement entirely — the DIT size only bounds the
*memory-caching* demand; **still check `lsass` working set before acting on a DC
recommendation**, since other DC-hosted workloads (co-located DNS, a chatty LDAP consumer) aren't
reflected in DIT size at all. Nor does it check for a legacy manual NTDS cache-size cap that
would make added RAM ineffective — see Sizing logic above.

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
