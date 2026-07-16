# Changelog

All notable changes to `Prep-W11-VDI-GoldenImage.ps1`, `Prep-WS2025-RDSH-Template.ps1`, and `Prep-WS2025-Server-Template.ps1`.

## [Unreleased]

### Added
- Domain join + computer naming, prompted interactively (domain FQDN, target OU, join account/password, hostname prefix) in all three scripts, all optional and independent of each other. Rather than a static value baked into the shared generalized image (which would collide across every clone), a helper script computes its own random suffix fresh on each clone's own first boot, then calls `Add-Computer -NewName` (rename + domain join in a single reboot) or `Rename-Computer` if no domain join was requested. Results are logged to `C:\Windows\Temp\ArcDomainJoin.log` on the clone. Credentials never touch disk outside the same `unattend.xml` that's already deleted by the existing Order-1 `FirstLogonCommand` immediately after first boot - no new credential-handling risk introduced. Added a shared `ConvertTo-PSStringLiteral` helper to safely embed arbitrary values (including passwords containing quotes) into the generated script without any injection/escaping risk.

### Fixed
- Removed the legacy `SkipUserOOBE`/`SkipMachineOOBE` elements from the `OOBE` block in all three scripts, and `EnableFirstLogonAnimation` from the W11 script (all added in v1.3). These are not present in the modern Microsoft-Windows-Shell-Setup catalog, so Windows 10/11 and Server 2022/2025 reject them at first boot with "Windows could not parse or process unattend answer file... for pass [oobeSystem]. A component or setting specified in the answer file does not exist." The `Skip*` failure was confirmed on a real W11 clone (2026-07-16) - the first time any clone had actually OOBE-booted from the generated answer file, so the bad elements had never been exercised. The parser reports only the FIRST offending element, so after removing `Skip*` the next boot would have failed on `EnableFirstLogonAnimation` (which sits just after the `OOBE` block); that second one was caught pre-emptively by validating the generated answer file in Windows System Image Manager (WSIM) against a catalog built from the actual W11 image (`Tools > Validate Answer File`), saving another build cycle. OOBE is still fully skipped by the remaining `Hide*` flags plus the declared `UserAccounts` (the modern mechanism); nothing replaces them. `NetworkLocation` also validates as *deprecated* (not *does-not-exist*) in the current image - left in place since deprecated settings are still honoured at boot and it does no harm. Only W11 is re-tested this cycle; RDSH/Server received the identical `Skip*` removal but remain OOBE-boot-untested.
- The first version of the domain-join/naming FirstLogonCommand embedded the helper script inline as a base64-encoded `-EncodedCommand` blob directly in the `CommandLine` value - on a real test clone this produced "Windows could not parse or process unattend answer file... for pass [oobeSystem]. The answer file is invalid," even though the file was confirmed well-formed XML (`[xml](Get-Content ... -Raw)` parsed it fine), pointing at a schema/content validation rejection rather than a syntax error. Rather than keep guessing at the exact cause of a very long, opaque CommandLine value, replaced it with the standard approach: the helper script is now written to a real file at `C:\Windows\Setup\Scripts\ArcDomainJoin.ps1` (the same location Microsoft documents for `SetupComplete.cmd`, which survives generalize/sysprep fine) and invoked with a short `-File <path>` CommandLine instead - also easier to debug afterwards since the script is plainly readable on the clone rather than base64-encoded. The script deletes itself when done.

## [v1.3] - 2026-07-14

### Added
- `DisablePrivacyExperience` registry policy in all three scripts, suppressing the "Choose privacy settings" screen for every future new user on a cloned machine - not just the image's own first boot (unlike unattend.xml).
- The RDSH template now writes a sysprep `unattend.xml` (step 13) - it never did before, so RDSH clones were hitting the full OOBE (region, keyboard, EULA, account creation, privacy screens) instead of a suppressed one.
- Expanded the unattend.xml `OOBE` block in all three scripts with `NetworkLocation`, `SkipUserOOBE`/`SkipMachineOOBE`, and `EnableFirstLogonAnimation=false` to cut down first-boot noise after generalizing.
- `unattend.xml` now declares the standing admin account (when step 0 set one up) so `HideLocalAccountScreen` reliably suppresses the "Who's going to use this device?" account-creation screen - OOBE's CloudExperienceHost still wants a concretely provisioned account regardless of that flag. Step 0 now interactively prompts for (and confirms) the account's password, which is both applied to the real account there and reused in `unattend.xml`. A `FirstLogonCommand` deletes the answer file immediately after specialize completes as cleanup.
- Step 0 in all three scripts now prompts for and sets the standing admin's password interactively (masked, never logged) instead of leaving it unchanged.
- Progress heartbeats for every long silent `Start-Process -Wait`-style install (VMware Tools, Teams bootstrapper, WebRTC redirector, FSLogix, and the winget 7-Zip/Foxit installs) via a shared `Start-ProcessWithHeartbeat` helper - prints `still running <label>... (Ns elapsed)` every 30s instead of going silent for minutes, which had been indistinguishable from a genuine hang during testing.

### Changed
- Replaced `Foxit.FoxitReader` with `SumatraPDF.SumatraPDF` in the W11 and RDSH scripts' common-apps step. Foxit's winget package remained unpredictable even with the timeout/heartbeat safety net (still hung and had to be killed on a confirmed-good W11 run) - rather than keep tolerating an unreliable install, swapped to SumatraPDF, which is lightweight, open-source, and doesn't have the same documented winget hang history.

### Fixed
- `Install-WingetApp` in the W11 and RDSH scripts could hang indefinitely with a winget package stuck mid-install (observed with `Foxit.FoxitReader` - a documented upstream issue, see microsoft/winget-pkgs #10072 and #364274 - hanging with 0% CPU and no network activity, behind a hidden installer dialog `--disable-interactivity` doesn't suppress). The winget call now runs via `Start-Process -PassThru` with a 5-minute timeout; on timeout the whole process tree is force-killed and the run continues with a warning instead of blocking forever.
- All three scripts' baseline-hardening sections (~15 raw `Set-ItemProperty` calls per script under `HKLM:\SOFTWARE\Policies\...` and similar) could abort the entire run if any single key had a tightened ACL denying the write - observed on `AllowNewsAndInterests` under `Policies\Microsoft\Dsh` in the W11 script, which Microsoft has locked to SYSTEM/TrustedInstaller on some builds even for an elevated Administrator token, throwing a terminating `UnauthorizedAccessException` under `$ErrorActionPreference = 'Stop'`. Added a shared `Set-RegistryValue` helper (try/catch, warn-and-continue) to all three scripts and routed every registry write through it, since these are explicitly best-effort baseline settings, not mission-critical ones.
- The RDSH template's final instructions told you to run `sysprep /oobe /generalize /shutdown` with no path and no `/unattend` flag - `sysprep.exe` isn't on PATH, so this failed with "term not recognized". All three scripts now print the full explicit path and flag it clearly as required.
- The RDSH and Server Template scripts' `unattend.xml` included client-only OOBE elements (`HideLocalAccountScreen`, `HideOnlineAccountScreens`, `HideWirelessSetupInOOBE`, `EnableFirstLogonAnimation`) that don't exist in Windows Server's unattend catalog, causing a hard "Windows could not parse or process unattend answer file... a component or setting specified in the answer file does not exist" error on first boot after sysprep. Trimmed both scripts' `OOBE` block to the Server-valid subset (`HideEULAPage`, `NetworkLocation`, `ProtectYourPC`, `SkipMachineOOBE`, `SkipUserOOBE`); the W11 script's fuller client-oriented block is unaffected since it parses correctly there.
- The first version of the account-declaration fix above used a randomly-generated, never-displayed password (deleted from disk automatically after first boot), which caused a real lockout on a test host - nobody had a copy of the password once the answer file self-deleted, and LAPS coverage was never actually verified before relying on it as the safety net. Replaced with an operator-supplied password (prompted interactively in step 0) so there's always a known credential.

## [v1.2] - 2026-07-07

### Added
- `Prep-WS2025-Server-Template.ps1` - general-purpose Windows Server 2025 template prep for member/app/file servers that do NOT run the RD Session Host role. Reuses the RDSH template's VMware Tools handling, Defender-for-Sentinel removal, appx/BitLocker/regional/hardening/cleanup/sysprep steps, but deliberately leaves out anything RDSH/VDI-specific (no M365 Apps, Teams, WebRTC redirector, FSLogix, or winget common apps) to keep it minimal.

## [v1.1] - 2026-07-07

### Added
- VMware platform detection (via BIOS/SMBIOS manufacturer) with automatic VMware Tools install/upgrade from `packages.vmware.com`.
- 7-Zip and Foxit PDF Reader installed via `winget` (Foxit chosen over Adobe Acrobat Reader DC - lighter weight for multi-session/RDSH).
- Full-run transcript logging to `C:\ArcLogs\GoldImagePrep\`.
- Pre-run instructions at the top of each script: log in as the persistent/standing admin first, plus a direct `irm | iex` one-liner to run the current `main` branch version without cloning.
- Windows Defender removal in the RDSH template, to hand the AV/EDR role to Sentinel.

### Changed
- VMware Tools step now compares the installed version against the latest available and skips the download/install if already current, instead of always re-running the installer.
- Microsoft 365 Apps, Teams, WebRTC Redirector, FSLogix, and both winget apps now check whether they're already installed and skip re-downloading/re-running if so.
- Windows feature/role removals (RD Session Host, Windows Defender, FS-SMB1) check `.Installed` first and report "already present/absent" instead of blindly re-running.

### Fixed
- `Start-Process` and bare native-exe calls (e.g. `winget install`) failing with "the directory name is invalid" when the script is run via the `irm | iex` one-liner - fixed by pinning the process's actual working directory to the script's temp work folder.
- `Disable-WindowsOptionalFeature` throwing a hard `COMException` (not suppressed by `-ErrorAction SilentlyContinue`) for a feature name that doesn't exist on a given Windows build/edition - now wrapped in `try/catch`.
- Slow `Invoke-WebRequest` downloads in the W11 script due to the progress bar rendering overhead - fixed by setting `$ProgressPreference = 'SilentlyContinue'`.

## [v1.0] - 2026-07-06

### Added
- Initial gold image prep scripts:
  - `Prep-W11-VDI-GoldenImage.ps1` - Windows 11 VDI golden image prep.
  - `Prep-WS2025-RDSH-Template.ps1` - Windows Server 2025 RD Session Host template prep.
