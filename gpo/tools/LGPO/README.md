# LGPO.exe

`Apply-Baseline.ps1` uses Microsoft's **LGPO.exe** (Local Group Policy Object utility, part of the [Security Compliance Toolkit](https://www.microsoft.com/en-us/download/details.aspx?id=55319)) to write a baseline into a machine's local policy.

**The binary is deliberately *not* committed** — this is a public repo, and LGPO.exe is Microsoft's to distribute, not ours. `Apply-Baseline.ps1` handles it one of two ways:

1. **Auto-bootstrap (default).** On first run, if it can't find `LGPO.exe`, the script downloads `LGPO.zip` from Microsoft and extracts `LGPO.exe` to `%ProgramData%\Arc Systems\GpoBaseline\tools\LGPO\`. Nothing to do.

2. **Manual staging (offline / locked-down networks).** Download the Security Compliance Toolkit **LGPO** package yourself, and drop `LGPO.exe` either:
   - next to the scripts at `gpo/tools/LGPO/LGPO.exe` (for a local repo checkout run), **or**
   - at `%ProgramData%\Arc Systems\GpoBaseline\tools\LGPO\LGPO.exe` on the target machine.

   The script checks both locations before attempting a download.

If Microsoft moves the download, update `$LgpoDownloadUrl` at the top of `Apply-Baseline.ps1`.
