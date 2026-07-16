# Gold image prep

Prep scripts that turn a freshly-installed VM into a sysprep-ready golden image for cloning.

| Script | Target |
| --- | --- |
| `Prep-W11-VDI-GoldenImage.ps1` | Windows 11 VDI desktops |
| `Prep-WS2025-RDSH-Template.ps1` | Windows Server 2025 RDSH (session hosts) |
| `Prep-WS2025-Server-Template.ps1` | Windows Server 2025 general server template |

Each script is run **once**, in an elevated PowerShell session, on the template VM. It installs the standard app set, debloats, hardens a baseline, prompts for optional domain-join / computer-naming details, and finally writes a sysprep answer file to `C:\Windows\Panther\unattend.xml`. You then sysprep + generalize, and clone.

See `CHANGELOG.md` for version history.

## Run order

1. **Run the prep script** on the template VM (elevated):
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/gold-image/Prep-W11-VDI-GoldenImage.ps1 | iex
   ```
   Note down the standing-admin password when prompted — you need it for console access until LAPS rotates it post-deploy. The full run is logged to `C:\ArcLogs\GoldImagePrep\`.

2. **Reboot once, offline.** Several installs suppress their own reboot (VMware Tools) and the locale change needs one to apply. Do it with the NIC disconnected so the Store doesn't re-provision the appx packages the script just removed.

3. **Validate the answer file in WSIM** — see below. Do this *before* sysprep; it's a desk-check that catches invalid `unattend.xml` settings without burning a sysprep/clone cycle.

4. **Sysprep + generalize** with the exact command the script prints (`sysprep.exe` is not on PATH):
   ```
   C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /unattend:C:\Windows\Panther\unattend.xml
   ```

5. **Clone**, then on first boot of a clone confirm:
   - OOBE is fully skipped (boots straight to sign-in).
   - The rename/domain-join fired — check `C:\Windows\Temp\ArcDomainJoin.log` on the clone.

## Validating the answer file in WSIM before sysprep

**Why.** The `unattend.xml` the script generates is parsed by Windows Setup at first boot. If it contains a setting that isn't in the target build's schema, OOBE fails with:

> Windows could not parse or process unattend answer file [C:\WINDOWS\Panther\unattend.xml] for pass [oobeSystem]. A component or setting specified in the answer file does not exist.

The parser reports **only the first** offending element, so fixing one and re-syspreping can just surface the next. Windows System Image Manager (WSIM) validates the *whole* file against a catalog built from the actual image, listing every problem at once — a 30-second desk-check instead of a multi-cycle guessing game. (This is how the deprecated `SkipUserOOBE`/`SkipMachineOOBE` and `EnableFirstLogonAnimation` elements were found and removed — see CHANGELOG `[Unreleased]`.)

### One-time setup

1. Install the **Windows ADK** and select only **Deployment Tools** (installs WSIM). The other ADK features aren't needed for this.

2. Get the `install.wim` for the **exact Windows build and edition** your image uses (from the mounted ISO, under `\sources\`). WSIM must be able to **write** a catalog next to it, and a mounted ISO is read-only — so copy the wim to a writable local folder first:
   ```powershell
   mkdir C:\wim
   copy D:\sources\install.wim C:\wim\
   ```
   > If the ISO ships `install.esd` instead of `install.wim`, export it to WIM first:
   > ```powershell
   > dism /Get-WimInfo /WimFile:D:\sources\install.esd
   > dism /Export-Image /SourceImageFile:D:\sources\install.esd /SourceIndex:<n> /DestinationImageFile:C:\wim\install.wim /Compress:max /CheckIntegrity
   > ```

3. In WSIM: **File ▸ Select Windows Image** → `C:\wim\install.wim`. Pick the **edition your image uses** (e.g. Pro / Enterprise), and let it build the catalog (a few minutes). Run the **amd64** WSIM against an amd64 image.

> The catalog is **per-build and per-edition** — regenerate it whenever you move to a new ISO/build.

### Each time

1. Copy the generated answer file off the template VM (before or instead of syspreping) — it lives at `C:\Windows\Panther\unattend.xml`.
2. WSIM: **File ▸ Open Answer File** → select it. If prompted to associate it with the open image/catalog, click **Yes** — that binds it to the build's schema.
3. **Tools ▸ Validate Answer File**. Read the **Messages** pane.

### Interpreting the results

| Message | Tab | Meaning | Action |
| --- | --- | --- | --- |
| `The specified setting <X> does not exist` | Validation | `<X>` isn't in this build's catalog — **this will fail OOBE parsing.** | Remove `<X>` (or move it to a pass where it's valid), re-version, push. |
| `Setting <X> is deprecated in the Windows image` | Validation | Still in the catalog and still honoured at boot — noise, not a failure. | Safe to leave. |
| `Cannot find Windows image information in answer file` | XML | The file has no embedded image/servicing metadata. Expected for a sysprep `oobeSystem` answer file — that block is only for full-OS-install (WDS/setup-from-media) files. | Ignore. |

A clean result for these scripts is **zero "does not exist" errors** — the `NetworkLocation` deprecation warning and the "Cannot find Windows image information" note are both expected and harmless.

> WSIM validates **schema** (does the setting exist / belong in this pass), not **apply-time behaviour**. It will not catch things like re-declaring the built-in `Administrator` account (SID-500), which can only misbehave at first logon. Still eyeball the first boot.
