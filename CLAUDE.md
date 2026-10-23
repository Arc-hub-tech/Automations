# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Active. The repository holds Arc Systems internal automation tooling, currently PowerShell:

- `gold-image/` — Windows gold-image prep scripts (W11 VDI, WS2025 RDSH, WS2025 general Server) that turn a fresh VM into a sysprep-ready template. See `gold-image/README.md` and `gold-image/CHANGELOG.md`.
- `datto-capacity-sampler/` — Datto RMM components that sample guest RAM/CPU demand across the server estate (15-min on-device buffer, weekly percentile aggregation, plus a same-day screen) and write right-sizing recommendations to UDFs. Delivered by pasting/attaching scripts into Datto Automation components, not a runtime `irm` fetch. Each script versions independently. See `datto-capacity-sampler/README.md` and `datto-capacity-sampler/CHANGELOG.md`.
- `hyperv-standalone/` — `ArcHyperVHost-Workshop.ps1` (at Arc: HPE SPP/iLO, host name, Hyper-V, VM disk, Datto, Windows Update, SET switch on the workshop DHCP, security baseline so hosts ship with the standard; SPP chosen per ProLiant generation from the pen drive) and `ArcHyperVHost-Site.ps1` (on site, also for existing customer hosts: customer static IP on the workshop-built switch, domain/workgroup, EDR question (removes Defender if SentinelOne/Sophos is planned), new local admin + disable built-in, baseline re-check, VM start/stop, unbranded HTML as-built for ITGlue - no logo/brand assets in this public repo), plus `ArcHyperVHost-Lite.ps1` (live host already built: read-only `Check`, then `Apply` of the security + Hyper-V optimisation standard only, risk items asked one by one, always asks about Defender/EDR but removes Defender only once an EDR agent is running, never reboots, refuses cluster nodes). Standalone HPE customer hosts, no SCVMM. Prompt-only (no config file); non-secret answers kept in `C:\ArcLogs\HyperVHost\state.json`. The helper block between the "shared helpers" markers (including the network build and the whole baseline) is duplicated in all three files and must stay identical; the "report helpers" block is duplicated in Site and Lite. All three share one version. See `hyperv-standalone/README.md` and `hyperv-standalone/CHANGELOG.md`.
- `windows-debloat/` — a standalone Windows debloat script.
- `vmware-migration/` — VMware to Hyper-V guest migration: `Save-PreMigrationConfig.ps1` (on VMware, before the move: records network, routes, disks, volumes and VMware Tools to `C:\ProgramData\Arc\Migration\pre-migration.json`/`.txt`, changes nothing) and `Remove-VMwareTools.ps1` (on Hyper-V, after the move: disables the VMware-only hardware-check actions in the cached Tools MSI so the uninstall doesn't roll back with 1603, backs up/restores that MSI, then reports against the pre-migration capture; `-Inspect` read-only, `-Restart` optional). Run on the VM with a download-then-run one-liner from `/main/` (saves to `C:\ProgramData\Arc\Migration\`, never `irm | iex` because the scripts `exit`), or copied over by hand when the VM has no internet. Each script versions independently. See `vmware-migration/README.md` and `vmware-migration/CHANGELOG.md`.

## Purpose

Home for Arc Systems internal automation tooling.

## Branching & release workflow

The gold-image scripts are fetched at runtime via an `irm` one-liner, so whatever is on the branch that one-liner points at is **live** on any template building from it. Two branches:

- **`main` = production/live**, and **branch-protected** — changes land via pull request, not direct push. The one-liners in the script headers and `gold-image/README.md` point at `/main/`. Keep it stable; never push work-in-progress here.
- **`develop` = work in progress.** Its one-liners point at `/develop/` and `$ScriptVersion` carries a `-dev` suffix so dev builds are visually distinct. Commit WIP here (or feature branches off it).

**Release cut:** merge `develop` → `main` (via PR); revert the one-liner URLs to `/main/`; drop the `-dev` suffix from `$ScriptVersion` (e.g. `1.7.0-dev` → `1.7`); move `CHANGELOG` `[Unreleased]` → `[vX.Y]`; tag `vX.Y`. All three gold-image scripts share one version — bump in lockstep.

## Secrets & safety

This repository is public. Never commit credentials, API keys, connection strings, tenant IDs, client names, or customer data.

- Secrets must come from environment variables or a vault — never hardcode them in source, config, or scripts.
- Before committing, check the diff for accidental secrets; if any are found, stop and remove them rather than committing.
- Use placeholder values (e.g. `<API_KEY>`, `<TENANT_ID>`) in examples and documentation.

## Notes for future work

- Once code is added, update this file with actual build/lint/test commands and a description of the architecture — do not rely on this placeholder section.
- Licensed under GPLv3 (see `LICENSE`); keep this in mind when adding dependencies or third-party code.
