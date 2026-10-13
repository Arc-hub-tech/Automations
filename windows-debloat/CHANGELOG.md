# Changelog

All notable changes to `Debloat-Windows.ps1`.

## [Unreleased]

### Added
- Initial version: removes Microsoft consumer/promo appx bloat and preinstalled 3rd-party promo apps (Spotify, Netflix, TikTok, Candy Crush, etc.), best-effort removal of common OEM trialware (McAfee, Norton, WildTangent, Dell/HP promo utilities) via each product's own uninstaller, and disables Start menu/lock screen ads and other consumer content-delivery features. Safe to run on any live Windows 10 or 11 machine any number of times - no account, domain-join, BitLocker, or hardening changes (see `gold-image/` for that).
- Disk cleanup step: temp files, Windows Update download cache, Recycle Bin, Delivery Optimization cache, a leftover `C:\Windows.old` from a feature upgrade (best-effort - flags remaining permission-locked files rather than forcing removal), and a `DISM /StartComponentCleanup` pass on the WinSxS component store (bounded by a 20-minute timeout via `Invoke-WithTimeout`, since component cleanup can genuinely take a while).
- `-NewOutlook Remove|Block|Keep` choice for the new Outlook for Windows app. `Remove` uninstalls it, the previous behaviour. `Block` also stops it coming back: it sets the Windows Update orchestrator block `BlockedOobeUpdaters = ["MS_Outlook"]` (Windows 10), deletes the orchestrator's `OutlookUpdate` key (early Windows 11 23H2), and for every user profile plus new users hides classic Outlook's "Try the new Outlook" toggle (`HideNewOutlookToggle = 1`) and turns off automatic migration (`NewOutlookMigrationUserSetting = 0`). `Keep` leaves it installed. If the parameter is left out, interactive runs ask and unattended runs (RMM/SYSTEM) take `Remove`. Keep does not undo an earlier Block. Under `irm | iex` the parameter is passed with `& ([scriptblock]::Create((irm <url>))) -NewOutlook Block`.
- `$ScriptVersion` (`1.0.0-dev`), printed at the start of the run.
- `-Copilot Remove|Keep` choice covering the Copilot app (`Microsoft.Copilot`, newly removed) and the Microsoft 365 Copilot app (`Microsoft.MicrosoftOfficeHub`, previously always removed). Keep is for users with a Copilot licence. If the parameter is left out, interactive runs ask and unattended runs take `Remove`.
- `-Norton Remove|Keep` choice. Norton is no longer removed automatically: it may be a subscription the customer pays for, and that looks the same as an OEM trial. Interactive runs ask only when Norton is installed, and the default answer is Keep. Unattended runs keep it and log that it was left in place.
- The interactive questions all come at the start of the run, through one shared numbered menu, and the run logs the choices made.

### Changed
- Renamed from `Debloat-Win11.ps1` (in a `win11-debloat/` folder) to `Debloat-Windows.ps1` (in `windows-debloat/`) - nothing in the script is actually Windows 11-specific; the appx/registry mechanisms and target apps/keys are equally applicable to Windows 10, so the naming now reflects that instead of implying Win11-only support.
- `Invoke-WithTimeout` now also prints a heartbeat every 30s while waiting, matching the lesson learned in the gold-image scripts - a long-running command going silent (e.g. DISM component cleanup) was otherwise indistinguishable from a genuine hang.
- Start menu/lock screen suggestion settings (`ContentDeliveryManager`) now go to every user profile on the machine and the default profile, not just the HKCU of whoever ran the script, which is usually the technician's admin account rather than the PC's user. Several of the `CloudContent` policies are only honoured on Enterprise/Education, so on Pro these per-user values are what does the work. Written with `reg.exe` (other users' hives are loaded and unloaded around it), following the gold-image default-profile lesson.
- Also turns off News and Interests on the Windows 10 taskbar (`Windows Feeds\EnableFeeds = 0`) alongside the existing Windows 11 Widgets policy; the old comment wrongly said that policy covered Chat.
- Appx removal queries provisioned packages once instead of once per app (each query takes several seconds), logs deprovisioning, and reports a failed removal as a warning instead of printing "removed" regardless.
- OEM trialware matching for McAfee and Norton narrowed from `McAfee*`/`Norton*` to named consumer products: McAfee LiveSafe, Total Protection, McAfee+, Internet Security, AntiVirus Plus, Security Scan, WebAdvisor and Safe Connect; Norton 360, Security, AntiVirus, Internet Security and Online Backup. A corporate McAfee/Trellix agent or endpoint product on an in-service machine is no longer matched. ® and ™ are stripped from product names before matching.
- Temp/WU cache cleanup removes the top level of each folder recursively instead of listing every nested file first.
- Option B one-liner in the header points at `develop` while this is in development (back to `main` at release).

### Fixed
- Elevation is now checked explicitly. `#Requires -RunAsAdministrator` is ignored under `irm | iex`, so a non-elevated Option B run used to carry on and fail step by step.
- An unexpected error now stops the run with the transcript closed. The trap had no `break`, so PowerShell carried on after the error with logging switched off. The trap's own `Stop-Transcript` is wrapped in try/catch, because "not transcribing" throws even with `-ErrorAction SilentlyContinue`.
