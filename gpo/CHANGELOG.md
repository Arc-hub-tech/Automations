# Changelog

All notable changes to the GPO baseline tooling (`Apply-Baseline.ps1`, `Register-DriftTask.ps1`) and the baselines under `baselines/`. This tool versions **independently** of the gold-image scripts.

## [Unreleased]

_Work in progress on the `develop` branch. `$ScriptVersion` is `0.1.0-dev` here; the fetch one-liners and the `-Branch` defaults point at `/develop/`. On the first release cut these revert to `main` and `$ScriptVersion` drops to `0.1` (or `1.0` once validated)._

### Added
- **Initial scaffold — local-policy baseline as code, delivered via Git.** New `gpo/` area that manages Windows policy baselines as diffable LGPO text files in Git and delivers them by having each machine re-fetch and re-apply on a schedule. Mirrors Microsoft's Security Baseline model (author once → export → apply with `LGPO.exe`) but keeps only the **local-policy** path — no domain, no domain controller, no `Import-GPO`.
  - `Apply-Baseline.ps1` — applies a baseline to local policy via `LGPO.exe /t` (text file) or `/g` (GPO backup folder), then `gpupdate /force`. Bootstraps `LGPO.exe` from Microsoft if not staged; fetches the baseline from the repo branch (or a local `-Path`); idempotent, so re-runs re-assert the baseline and drift self-heals; stamps `HKLM\SOFTWARE\Arc Systems\GpoBaseline`; transcript-logs to `C:\ArcLogs\GpoBaseline\`.
  - `Register-DriftTask.ps1` — registers a SYSTEM scheduled task (at startup + every `-IntervalHours`, default 4) whose action re-fetches `Apply-Baseline.ps1` from the branch and runs it, so any edit merged to the branch reaches the fleet automatically. VM-friendly task settings mirror the gold-image resume task.
  - `baselines/arc-workstation-v1/arc-workstation-v1.lgpo.txt` — starter workstation baseline (LLMNR off, AutoRun/AutoPlay off, SmartScreen block, UAC hardening, no last-user display, 15-min inactivity lock, no elevated MSI installs, PowerShell script-block logging, WDigest cleartext off, secure screensaver). A safe, well-known starting point to edit down to Arc's actual CE+/ISO 27001 standard — **not** a finished policy.
  - `tools/LGPO/README.md` — how `LGPO.exe` is obtained (auto-bootstrap or manual staging); the binary is deliberately not committed.
  - `README.md` — model, layout, delivery flow, quick-start one-liners, editing/authoring guidance, and the shared `develop`/`main` release workflow.
  - **Not yet validated on a real build** — scripts parse clean; end-to-end apply + drift-reapply on a test VM is pending.
