# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Active. The repository holds Arc Systems internal automation tooling, currently PowerShell:

- `gold-image/` — Windows gold-image prep scripts (W11 VDI, WS2025 RDSH, WS2025 general Server) that turn a fresh VM into a sysprep-ready template. See `gold-image/README.md` and `gold-image/CHANGELOG.md`.
- `windows-debloat/` — a standalone Windows debloat script.

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
