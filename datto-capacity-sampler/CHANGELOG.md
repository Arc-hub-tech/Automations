# Changelog

All notable changes to the Datto capacity sampler tooling (`Deploy-ArcCapacitySampler.ps1`,
`Arc-CapacitySampler.ps1`, `Read-ArcCapacityBuffer.ps1`, `Get-ArcCapacityScreen.ps1`). Each
script versions independently — see its own header comment for its current version.

## [Unreleased]

_Work in progress on the `develop` branch._

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
