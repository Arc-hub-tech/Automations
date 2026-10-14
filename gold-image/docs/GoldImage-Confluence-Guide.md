# Gold image template build.

> **What this guide covers**
>
> Three PowerShell scripts turn a freshly installed VM into a sysprep-ready template for cloning: Windows 11 VDI desktops, Windows Server 2025 RD Session Hosts (RDSH) and general Windows Server 2025 servers.
>
> → **Two stages, mostly hands-free:** stage 1 installs and configures, then reboots and signs back in by itself. Stage 2 finishes off and asks before it runs sysprep.
>
> → **Clones set themselves up:** on first boot each clone skips the Windows setup screens, renames itself with your prefix and a random suffix, and joins the domain if you asked it to.
>
> → **A few questions at the start:** the standing admin password, whether clones join a domain, and a computer name prefix. After that, stage 1 runs to the end without stopping.
>
> → **For new templates only:** the server scripts remove Defender and every script changes security settings, so never run one on a machine already in service. For a PC in use, see "Windows debloat and cleanup".

> **Status:** version 1.7 on the main branch, released 14 October 2026. All three templates were tested end to end on Hyper-V lab VMs: stage 1, the automatic reboot, stage 2, sysprep and a cloned first boot. The VMware Tools step, domain join and the winget apps were not part of that test; domain join last passed on a real W11 clone in July 2026. Check those on the first VMware build and report anything unexpected to the script owner.

## Which script

| Template | Script | Use for |
|---|---|---|
| W11 VDI | `Prep-W11-VDI-GoldenImage.ps1` | Windows 11 virtual desktops |
| WS2025 RDSH | `Prep-WS2025-RDSH-Template.ps1` | Windows Server 2025 multi-user session hosts |
| WS2025 Server | `Prep-WS2025-Server-Template.ps1` | Windows Server 2025 member, application and file servers. No Office, Teams or FSLogix |

## Scope

| Item | Supported |
|---|---|
| Operating system | Windows 11 (lab-tested on 25H2 Enterprise). Windows Server 2025 Standard or Datacenter with Desktop Experience; not Server Core |
| Platform | VMware or Hyper-V, detected automatically. VMware Tools is installed or updated on VMware only |
| Run by | An engineer at the VM console. Not for Datto RMM: it asks questions and reboots part-way through |
| Needs | An elevated PowerShell session, internet access, and being signed in as the local admin account the image should keep |
| Time | In the lab, stage 1 took about 2 minutes for Server, 12 for W11 and 16 for RDSH, mostly the Microsoft 365 Apps install. Add decryption time if the drive is BitLocker-encrypted |
| Reboots | One automatic reboot between stage 1 and stage 2. Sysprep then shuts the VM down |

## Before you run it

→ **Start from a fresh install.** Install Windows on the VM; for Server, choose Desktop Experience. Don't join the domain: the clones do that.

→ **Sign in as the admin account the image should keep,** for example XXXAdmin. Not the built-in Administrator, and not a domain account. The script adopts the signed-in account as the standing admin and disables the built-in Administrator. Run as anyone else, it skips the account step.

→ **Have the domain details ready** if clones should join a domain: the domain name, the OU distinguished name, and a join account and its password.

→ **Choose the computer name prefix,** up to 8 characters, for example XXX-VDI. Each clone becomes the prefix plus 6 random characters, such as XXX-VDI-A1B2C3.

→ **Plan Sentinel enrolment for RDSH and Server.** Defender is removed, so a clone has no antivirus until Sentinel is enrolled.

→ **Snapshot or checkpoint the VM first,** so you can go back if a step fails.

## Running it

Open PowerShell as Administrator on the template VM and paste this as a single line. It saves the script next to the logs and runs it. Change both filenames for the template you're building.

```
$p="$env:SystemDrive\ArcLogs\GoldImagePrep\Prep-W11-VDI-GoldenImage.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/gold-image/Prep-W11-VDI-GoldenImage.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p
```

Use this download-then-run form, not `irm | iex`. The automatic reboot needs a script file on disk to resume from; a piped run warns that it can't resume, and you then reboot by hand and run the saved script with `-Resume`.

The first line of the output and of the log shows the script name and version, for example `Prep-W11-VDI-GoldenImage.ps1  v1.7`.

### The questions

| Question | What to enter |
|---|---|
| Password for the account, then Confirm password | The standing admin password. It becomes the account's real password straight away, and the clones use it too. Note it down: LAPS rotates it after deployment, but you need it for console access until then |
| Join a domain on first boot? | y or n. For y: the domain name (for example corp.contoso.com), the OU distinguished name (blank for the default Computers container), the join account, and its password twice |
| Computer name prefix | Up to 8 characters; a longer prefix is shortened. Leave it blank to keep Windows' own random name |

The script checks the OU before going on. It signs in to the domain with the join account: if the OU doesn't exist it asks again, which catches typos such as U= for OU=. If the domain can't be reached from the build network, it warns and carries on without checking, so double-check the OU, because every clone uses it.

### Stage 1

Stage 1 runs the build steps in "What the script does", writes the answer file, sets a one-time automatic sign-in and reboots after 15 seconds. Press Ctrl+C in those 15 seconds to stop the reboot.

### Stage 2

After the reboot the VM signs in by itself and stage 2 opens in a PowerShell window. It:

→ removes the resume task and the temporary automatic sign-in, so neither ends up in the image;

→ installs the Remote Desktop WebRTC redirector (W11 and RDSH), which can't install until after the reboot;

→ removes again any per-user apps the Store added during the reboot, because they would stop sysprep;

→ checks that the C: drive is decrypted;

→ on RDSH and Server, reminds you to enrol Sentinel, and on RDSH, to check that Office and Teams open. The prompt waits, so do these in another window first;

→ asks "Run sysprep /generalize /shutdown now? (y/N)".

Answer y and the VM generalises and shuts down. Snapshot it or clone it in that state. Answer n to leave it for now; later, run the sysprep command the script prints, or run the saved script again with `-Resume`. Sysprep is not on the path, so use the full command:

```
C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /unattend:C:\Windows\Panther\unattend.xml
```

If stage 2 hasn't started within two minutes of the automatic sign-in, run it by hand, changing the filename for your template:

```
& 'C:\ArcLogs\GoldImagePrep\Prep-W11-VDI-GoldenImage.ps1' -Resume
```

## What the script does

| Step | W11 VDI | RDSH | Server |
|---|---|---|---|
| Standing admin set up; built-in Administrator disabled | Yes | Yes | Yes |
| Domain join and naming questions, applied on each clone | Yes | Yes | Yes |
| RD Session Host role installed | No | Yes | No |
| VMware Tools installed or updated (on VMware) | Yes | Yes | Yes |
| Windows Defender removed; Sentinel replaces it | No | Yes | Yes |
| Microsoft 365 Apps | Yes | Yes | No |
| New Teams, for all users | Yes | Yes | No |
| 7-Zip and SumatraPDF, through winget | Yes | Yes | No |
| FSLogix agent, installed but not turned on | Yes | Yes | No |
| Consumer apps removed | Yes | No | No |
| Consumer content, Widgets and suggestions turned off | Yes | No | No |
| "Choose privacy settings" screen skipped for new users | Yes | Yes | Yes |
| BitLocker off, and kept off on clones | Yes | Yes | Yes |
| UK regional and time settings | Yes | Yes | Yes |
| Security baseline | Yes | Yes | Yes |
| Performance tuning | Full | Full | Server set |
| Server Manager doesn't open at sign-in | No | Yes | Yes |
| Temporary files and Windows Update cache cleared | Yes | Yes | Yes |
| Sysprep answer file written | Yes | Yes | Yes |
| WebRTC redirector, in stage 2 | Yes | Yes | No |

### Apps

→ **Microsoft 365 Apps:** 64-bit, Monthly Enterprise Channel, English (UK), with shared computer activation on, which multi-user and non-persistent desktops need. Skype for Business and the old OneDrive for Business sync app are left out, and on RDSH so is OneDrive. Updates stay on. The script waits up to 40 minutes for the install to finish before it carries on.

→ **New Teams:** provisioned for every user, and marked as running on a virtual desktop so it uses media optimisation.

→ **Remote Desktop WebRTC redirector:** gives Teams media optimisation in Azure Virtual Desktop and Windows 365 sessions. It does nothing on plain Remote Desktop Services, but does no harm.

→ **7-Zip and SumatraPDF:** installed through winget, so they're always the current version. If winget isn't on the image, which is common on Server 2025, the script warns and skips them; install them by hand. An install that hangs is stopped after 5 minutes. Office, Teams, the WebRTC redirector and FSLogix also install the current version, downloaded from Microsoft's own links.

→ **FSLogix:** the agent is installed but stays off until profile containers are turned on for the environment, by GPO or registry. That configuration doesn't belong in the image.

→ **RDS licensing (RDSH):** the script doesn't set the Remote Desktop licensing mode or licence server. Set them by GPO on the clones. The alternative is the commented-out registry block in the script's session-host tweaks section.

### Consumer apps removed (W11)

Cortana, News, Weather, Bing Search, the Xbox apps and overlays, Get Help, Tips, 3D Viewer, the Office hub app, Solitaire, Mixed Reality Portal, People, Power Automate Desktop, Skype, To Do, Feedback Hub, Maps, Phone Link, Media Player, Films & TV, new Outlook, personal Teams, Clipchamp, Quick Assist, Family, and Mail and Calendar. Each is removed for current and future users. New Outlook goes because the image uses classic Outlook from Microsoft 365 Apps.

### Security baseline

These are the floor, not the ceiling: domain policy or Intune can tighten or override any of them.

→ SMBv1 off. On W11, PowerShell 2.0 is removed as well.

→ SMB signing required in both directions.

→ Windows Firewall on for every profile.

→ TLS 1.0, TLS 1.1 and SSL 3.0 turned off. This is the one setting that can break very old line-of-business applications.

→ NTLMv2 only, with LM and NTLMv1 refused. WDigest plain-text credentials off.

→ LLMNR off, and AutoRun and AutoPlay off for every drive type.

→ UAC on, using the secure desktop. The screen locks after 15 minutes idle.

→ Remote Desktop on, requiring Network Level Authentication, TLS and high encryption.

→ Accounts lock for 15 minutes after 10 wrong passwords. The Guest account is off.

→ On W11, Defender blocks potentially unwanted apps and uses cloud protection.

### Performance tuning

W11 and RDSH get the full set. Server gets the same apart from the display settings for new users.

→ High performance power plan, and hibernation off.

→ NTFS last-access timestamps and 8.3 short names off. Storage Sense off.

→ Services that only cost resources on a shared VM turned off: Windows Error Reporting, Maps, Offline Files and the Xbox services.

→ Scheduled tasks for defragmentation, compatibility telemetry, the Customer Experience Improvement Program, disk diagnostics, Maps, error reporting and feedback turned off.

→ The first sign-in animation and network adapter power saving off.

→ For new users (W11 and RDSH): transparency off, which matters most over a remote session, and fewer animations.

Windows Search, OneDrive, Print Spooler, Windows Update and Themes are left on on purpose, because Office, Teams and FSLogix rely on them.

### The answer file and the clone's first boot

The answer file is written to `C:\Windows\Panther\unattend.xml`. When a clone first boots, it:

→ skips the Windows setup screens, with a UK keyboard, UK locale and the GMT time zone;

→ creates the standing admin with its password, so setup doesn't ask for an account;

→ signs in once automatically, when there's a rename or domain join to do;

→ at that sign-in, deletes the answer file, which holds passwords in plain text, and removes any leftover resume task or automatic sign-in;

→ runs `C:\Windows\Setup\Scripts\ArcDomainJoin.ps1`, which picks the random suffix and renames the clone. If joining a domain, it waits up to 5 minutes for a domain controller to answer and makes up to 5 join attempts. It then clears the automatic sign-in password, deletes itself and reboots once. If the join fails, it doesn't reboot, so you can read the log.

The answer file sets the display language to English (UK). If you build from an English (US) ISO, which doesn't include it, speak to the script owner first.

## Checking a clone

After the first boot, sign in as the standing admin and check:

| Check | Expected |
|---|---|
| Computer name | The prefix plus 6 random characters |
| `C:\Windows\Temp\ArcDomainJoin.log` | A line ending `OK:` and the new name |
| `C:\Windows\Panther\unattend.xml` | Gone |
| `DefaultPassword` under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` | Not present |
| Domain membership | Joined, in the right OU, if you asked for a domain join |
| Sentinel (RDSH and Server) | Enrolled before the server goes into service |

## Logs

| Log | Where |
|---|---|
| Template build, one per stage | `C:\ArcLogs\GoldImagePrep\<script>_<date-time>.log` on the template |
| Clone rename and domain join | `C:\Windows\Temp\ArcDomainJoin.log` on the clone |
| Microsoft 365 Apps install | `C:\Windows\Temp\<computer>-<date>-<time>.log` on the template |
| Sysprep | `C:\Windows\System32\Sysprep\Panther\setuperr.log` on the template |

If a step fails, the script stops, closes the log and shows the error. Fix the cause and run the same command again: steps that already finished are skipped. Optional steps, such as a winget app or the WebRTC redirector, warn and carry on instead of stopping.

## Checking the answer file before sysprep

When you move to a new Windows build, check the answer file with Windows System Image Manager (WSIM) before the first sysprep. Windows setup reports only the first setting it doesn't recognise, so each problem otherwise costs a full sysprep and boot. WSIM lists them all at once. The steps are in the README in the repository.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| An error about `#Requires` and running as Administrator | PowerShell isn't elevated. Open it with Run as Administrator and run the command again |
| "No script file on disk ... cannot auto-resume" | The script was piped instead of downloaded. Reboot, then run the saved script with `-Resume`, and use the one-line command next time |
| Stage 2 doesn't start after the reboot | Run the saved script with `-Resume` (see "Stage 2") |
| "is not a LOCAL account" or "logged in as the BUILT-IN Administrator" | The account step was skipped. Sign in as the named local admin and run the script again |
| "OU ... not found" | The OU doesn't exist in that domain, usually a typo. Enter it again when asked |
| "Couldn't reach or authenticate to" the domain | The build network can't reach a domain controller, or the join account details are wrong. The OU wasn't checked, so check it by hand |
| "Timed out after 40 min waiting for Office to finish" | Slow download or failed install. Check the Microsoft 365 Apps log, and make sure Office works before sysprep |
| "... failed (exit code N)" for an installer | That install failed. Install it by hand before sysprep |
| "winget not found on this image" | Install 7-Zip and SumatraPDF by hand |
| "C: is not fully decrypted" | Wait for decryption to finish. Sysprep refuses an encrypted drive |
| Sysprep fails: "Sysprep was not able to validate your Windows installation" | Usually a per-user app. Find it in `setuperr.log`, remove it, then run the script with `-Resume`, which clears these again |
| A clone stops at "Windows could not parse or process unattend answer file" | The answer file has a setting this Windows build doesn't support. Check it in WSIM and tell the script owner |
| A clone sits at the sign-in screen without renaming | No standing admin was set up, so there's no automatic sign-in. Sign in once and the rename runs |
| A clone didn't join the domain | Read `ArcDomainJoin.log`: the FAILED line gives the reason. Join it by hand |

## Reference

| Item | Location |
|---|---|
| Scripts | `gold-image/` in the Arc-hub-tech/Automations repository on GitHub, main branch |
| Change history | `gold-image/CHANGELOG.md` |
| Branching, release process and WSIM steps | `gold-image/README.md` |
| This guide's source | `gold-image/docs/GoldImage-Confluence-Guide.md` |
| For PCs already in use | "Windows debloat and cleanup" in this space |
