# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

This repository is a placeholder. It currently contains only a `LICENSE` file (GPLv3) — no source code, build configuration, or documentation has been added yet.

## Purpose

Intended home for Arc Systems internal automation tooling. Scope, language/stack, and structure have not been decided yet.

## Secrets & safety

This repository is public. Never commit credentials, API keys, connection strings, tenant IDs, client names, or customer data.

- Secrets must come from environment variables or a vault — never hardcode them in source, config, or scripts.
- Before committing, check the diff for accidental secrets; if any are found, stop and remove them rather than committing.
- Use placeholder values (e.g. `<API_KEY>`, `<TENANT_ID>`) in examples and documentation.

## Notes for future work

- Once code is added, update this file with actual build/lint/test commands and a description of the architecture — do not rely on this placeholder section.
- Licensed under GPLv3 (see `LICENSE`); keep this in mind when adding dependencies or third-party code.
