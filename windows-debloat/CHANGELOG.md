# Changelog

All notable changes to `Debloat-Windows.ps1`.

## [Unreleased]

### Added
- Initial version: removes Microsoft consumer/promo appx bloat and preinstalled 3rd-party promo apps (Spotify, Netflix, TikTok, Candy Crush, etc.), best-effort removal of common OEM trialware (McAfee, Norton, WildTangent, Dell/HP promo utilities) via each product's own uninstaller, and disables Start menu/lock screen ads and other consumer content-delivery features. Safe to run on any live Windows 10 or 11 machine any number of times - no account, domain-join, BitLocker, or hardening changes (see `gold-image/` for that).

### Changed
- Renamed from `Debloat-Win11.ps1` (in a `win11-debloat/` folder) to `Debloat-Windows.ps1` (in `windows-debloat/`) - nothing in the script is actually Windows 11-specific; the appx/registry mechanisms and target apps/keys are equally applicable to Windows 10, so the naming now reflects that instead of implying Win11-only support.
- `Invoke-WithTimeout` now also prints a heartbeat every 30s while waiting, matching the lesson learned in the gold-image scripts - a long-running command going silent (e.g. DISM component cleanup) was otherwise indistinguishable from a genuine hang.

### Added
- Disk cleanup step: temp files, Windows Update download cache, Recycle Bin, Delivery Optimization cache, a leftover `C:\Windows.old` from a feature upgrade (best-effort - flags remaining permission-locked files rather than forcing removal), and a `DISM /StartComponentCleanup` pass on the WinSxS component store (bounded by a 20-minute timeout via `Invoke-WithTimeout`, since component cleanup can genuinely take a while).
