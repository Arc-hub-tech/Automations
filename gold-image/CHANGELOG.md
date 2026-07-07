# Changelog

All notable changes to `Prep-W11-VDI-GoldenImage.ps1`, `Prep-WS2025-RDSH-Template.ps1`, and `Prep-WS2025-Server-Template.ps1`.

## [Unreleased]

### Added
- `DisablePrivacyExperience` registry policy in all three scripts, suppressing the "Choose privacy settings" screen for every future new user on a cloned machine - not just the image's own first boot (unlike unattend.xml).
- The RDSH template now writes a sysprep `unattend.xml` (step 13) - it never did before, so RDSH clones were hitting the full OOBE (region, keyboard, EULA, account creation, privacy screens) instead of a suppressed one.
- Expanded the unattend.xml `OOBE` block in all three scripts with `NetworkLocation`, `SkipUserOOBE`/`SkipMachineOOBE`, and `EnableFirstLogonAnimation=false` to cut down first-boot noise after generalizing.
- `unattend.xml` now declares the standing admin account (when step 0 set one up) with a freshly-generated, one-time random password - `HideLocalAccountScreen` alone doesn't reliably suppress the "Who's going to use this device?" account-creation screen on Windows 11/Server, since OOBE's CloudExperienceHost still wants a concretely provisioned account. A `FirstLogonCommand` deletes the answer file immediately after specialize completes, so the placeholder password only exists on disk for seconds before LAPS takes over.

### Fixed
- The RDSH template's final instructions told you to run `sysprep /oobe /generalize /shutdown` with no path and no `/unattend` flag - `sysprep.exe` isn't on PATH, so this failed with "term not recognized". All three scripts now print the full explicit path and flag it clearly as required.

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
