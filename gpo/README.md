# GPO baselines

Manage Windows policy baselines **as code in Git**, and deliver them to machines by having each machine re-pull and re-apply on a schedule. This mirrors how Microsoft ships its own Security Baselines — the policy is authored once, exported to a portable format, and applied with **LGPO.exe** — but trimmed to the **local-policy** path only (no domain, no domain controller, no `Import-GPO`).

> **Status:** new tool, `0.1.0-dev`. The scripts parse clean but have **not** yet been validated on a real build. Review the starter baseline and test on a throwaway VM before any rollout.

## Why this shape

A domain GPO can't be committed to Git directly — it lives half in AD and half in SYSVOL. The portable unit is an *export*. Microsoft's baseline packages carry GPO **backups** plus two appliers: `Import-GPO` (domain) and `LGPO.exe` (local). We keep only the local path, and use LGPO's **text format** as the stored format because it's a single, human-diffable file — real line-by-line diffs in a PR instead of an opaque binary `registry.pol`.

So: **the baseline is the source of truth in this repo**, and **Git is also the delivery channel** — a scheduled task on each machine re-fetches the applier and the baseline on every tick, so anything merged to the branch reaches the fleet automatically and any local drift self-heals.

## Layout

| Path | What |
| --- | --- |
| `baselines/<name>/<name>.lgpo.txt` | The baseline, in LGPO text format. Edit this; it's the source of truth. |
| `Apply-Baseline.ps1` | Applies a baseline to **local** policy (`LGPO.exe /t`), then `gpupdate /force`. Idempotent. |
| `Register-DriftTask.ps1` | Installs the scheduled task that re-fetches + re-applies on an interval (drift self-heal). |
| `tools/LGPO/` | Where `LGPO.exe` lives at runtime (not committed — see its README). |
| `CHANGELOG.md` | Version history for this tool. |

## Delivery model (drift re-apply)

```
Scheduled task (SYSTEM, at startup + every N hours)
  -> irm  .../<branch>/gpo/Apply-Baseline.ps1   (re-fetch the applier)
  -> Apply-Baseline.ps1
       -> ensure LGPO.exe (bootstrap from Microsoft if missing)
       -> irm  .../<branch>/gpo/baselines/<name>/<name>.lgpo.txt   (re-fetch the baseline)
       -> LGPO.exe /t <baseline>      (re-assert local policy)
       -> gpupdate /force
       -> stamp HKLM\SOFTWARE\Arc Systems\GpoBaseline
```

Every run re-asserts the baseline, so a machine converges back to standard on each tick — this is essentially Microsoft's `Baseline-LocalInstall.ps1` on a timer.

## Quick start

Run both elevated on the target machine (or bake into a gold image). On `develop` these fetch from `/develop/`; production should pass `-Branch main`.

```powershell
# 1. Apply once now (fetches LGPO.exe + the baseline, applies, refreshes policy):
$p="$env:ProgramData\Arc Systems\GpoBaseline\Apply-Baseline.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/gpo/Apply-Baseline.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -BaselineName arc-workstation-v1 -Branch develop

# 2. Install the drift re-apply task (every 4h + at startup):
$r="$env:ProgramData\Arc Systems\GpoBaseline\Register-DriftTask.ps1"; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/develop/gpo/Register-DriftTask.ps1 -OutFile $r; & $r -BaselineName arc-workstation-v1 -Branch develop -IntervalHours 4
```

Verify what applied: `Get-ItemProperty 'HKLM:\SOFTWARE\Arc Systems\GpoBaseline'` and the transcripts under `C:\ArcLogs\GpoBaseline\`.

## Editing a baseline

Edit `baselines/<name>/<name>.lgpo.txt` — the format (one 4-line stanza per setting) is documented in the file header. To **remove** a setting a previous version set, change its last line to `DELETE` rather than deleting the stanza, so the re-apply actively clears it (removing the stanza just stops re-asserting it — it won't un-set what's already there). Commit on `develop`, PR to `main` when validated.

### Authoring from a GUI instead of by hand
Prefer to click it together? Configure it in `gpedit.msc` on a clean staging VM, export with `LGPO.exe /b <out>` (a GPO backup folder) or `LGPO.exe /parse /m registry.pol` (to text), and commit the result. For a **full** baseline (user-rights, audit, services — not just registry keys) keep the GPO **backup folder** and apply it with `Apply-Baseline.ps1 -Path <folder>` (uses `LGPO.exe /g`); the remote-fetch path handles the single-file text format.

## Branching & releases

Same model as `gold-image/` (see the repo root `CLAUDE.md`): `develop` = WIP (one-liners and the task point at `/develop/`, `$ScriptVersion` carries `-dev`); `main` = production and branch-protected. **Release cut:** merge `develop` → `main` via PR, switch the fetch URLs / `-Branch` defaults to `main`, drop the `-dev` suffix from `$ScriptVersion`, move `CHANGELOG` `[Unreleased]` → `[vX.Y]`, and tag. This tool versions **independently** of the gold-image scripts.

## Scope / limits

- **Local policy only.** Domain-linked GPOs (`Backup-GPO`/`Import-GPO` on a DC) are deliberately out of scope. The stored text format is portable to that path later if needed.
- **Registry/policy-backed settings** are the sweet spot for the text format. Security settings that aren't registry-based (fine-grained audit, user-rights assignment) need the GPO-backup-folder route (`-Path`).
- LGPO applies as **Local** GPO; a real domain GPO linked to the machine still wins by normal LGPO/precedence rules.
