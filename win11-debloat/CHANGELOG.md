# Changelog

All notable changes to `Debloat-Win11.ps1`.

## [Unreleased]

### Added
- Initial version: removes Microsoft consumer/promo appx bloat and preinstalled 3rd-party promo apps (Spotify, Netflix, TikTok, Candy Crush, etc.), best-effort removal of common OEM trialware (McAfee, Norton, WildTangent, Dell/HP promo utilities) via each product's own uninstaller, and disables Start menu/lock screen ads and other consumer content-delivery features. Safe to run on any live Windows 11 machine any number of times - no account, domain-join, BitLocker, or hardening changes (see `gold-image/` for that).
