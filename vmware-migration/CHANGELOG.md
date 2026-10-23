# Changelog

All notable changes to `Save-PreMigrationConfig.ps1` and `Remove-VMwareTools.ps1`. Each script versions independently.

## [Unreleased]

### Added
- Brought both scripts into the repository, unchanged from the versions already in use on migrations:
  - `Save-PreMigrationConfig.ps1` v1.0: records the VM's network, persistent routes, disks, volumes and VMware Tools install before migration, to `C:\ProgramData\Arc\Migration\pre-migration.json` and `.txt`.
  - `Remove-VMwareTools.ps1` v2.0: on Hyper-V, disables the VMware-only steps (`VM_CheckRequirements`, `VM_LogStart`, `VM_UninstGHIRestGuestHandle`) in the cached VMware Tools installer so the uninstall no longer rolls back with 1603, backs up and restores the cached installer on failure, then checks the VM against the pre-migration capture. `-Inspect` is read-only; `-Restart` restarts after a successful uninstall.
- Download-then-run one-liners in the README and both script headers. They force TLS 1.2, save the script to `C:\ProgramData\Arc\Migration\` and run it from there. `irm | iex` isn't used because the scripts' `exit` would close the console and the switches couldn't be passed. Copying the script to the VM by hand remains the fallback when the VM has no internet.
