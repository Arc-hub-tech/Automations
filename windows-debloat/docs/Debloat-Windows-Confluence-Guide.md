# Windows debloat and cleanup.

> **What this guide covers**
>
> `Debloat-Windows.ps1` cleans up a Windows 10 or 11 PC. It removes preinstalled consumer apps and OEM trialware, turns off Start menu and lock screen adverts, and frees disk space.
>
> → **Safe on a PC already in use:** it only removes and turns off. It never touches user accounts, domain join, BitLocker or security settings, and it can be run as many times as you like.
>
> → **Three questions at the start:** what to do about new Outlook, the Copilot apps and Norton. After that it runs to the end without stopping.
>
> → **Every user on the PC:** settings go to every user profile and to new users, not just the account running the script.
>
> → **Not a gold-image script:** for VDI, RDSH and server templates, use the gold-image scripts instead.

> **Status:** version 1.0 on the main branch. The questions, defaults and parameters have been tested, but the new Outlook, Copilot and Norton removal and the new Outlook block have not yet been run on a real Windows 11 PC. Check the result on the first few PCs and report anything unexpected to the script owner.

## Scope

| Item | Supported |
|---|---|
| Operating system | Windows 10 and Windows 11, any edition |
| Devices | New PCs, end-user laptops and desktops already in service, and VMs |
| Run by | An engineer, interactively, or unattended (for example from Datto RMM) |
| Needs | An elevated PowerShell session (Run as Administrator) and internet access for the download |
| Reboot | Not needed. Some Start menu changes show after the user next signs in |

## Before you run it

→ **Windows.old is deleted.** If the PC had a feature update in the last 10 days, deleting `C:\Windows.old` ends the option to roll back to the previous Windows version.

→ **Ask about Copilot.** If the user has a Microsoft 365 Copilot licence, choose Keep for the Copilot apps.

→ **Ask about Norton.** Arc doesn't usually supply Norton. It may be an OEM trial, or a subscription the customer pays for, and the two look the same to the script.

→ **Ask about new Outlook.** Find out whether the user works in new Outlook or classic Outlook before choosing.

## Running it

Open PowerShell as Administrator and run:

```
irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/windows-debloat/Debloat-Windows.ps1 | iex
```

The script asks its questions at the start (see below), then works through the five steps.

To give the answers up front, for example from Datto RMM or to save typing, use this form instead. A plain `irm | iex` can't pass answers.

```
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Arc-hub-tech/Automations/main/windows-debloat/Debloat-Windows.ps1))) -NewOutlook Block -Copilot Keep -Norton Keep
```

With a local copy of the script:

```
Set-ExecutionPolicy Bypass -Scope Process -Force; .\Debloat-Windows.ps1 -NewOutlook Block
```

Leave out any parameter you want the script to ask about.

## The three questions

| Question | Choices | Default if you press Enter | Default when unattended |
|---|---|---|---|
| New Outlook (`-NewOutlook`) | Remove, Block, Keep | Remove | Remove |
| Copilot apps (`-Copilot`) | Remove, Keep | Remove | Remove |
| Norton (`-Norton`) | Keep, Remove | Keep | Keep, and the log notes it was left in place |

The Norton question is only asked when Norton is installed. An unattended run (Datto RMM, or no keyboard) never stops to ask, and takes the defaults for anything not given as a parameter.

### New Outlook

This is the new Outlook for Windows app. It is not classic Outlook from Microsoft 365 Apps, which the script never touches.

| Choice | What happens |
|---|---|
| Remove | Uninstalls it for every user and for new users |
| Block | Uninstalls it, and stops it coming back (see below) |
| Keep | Leaves it installed |

Block stops new Outlook coming back in three ways:

→ Windows Update is told not to install it. This affects Windows 10, where Windows Update would otherwise reinstall it. On Windows 11, uninstalling it is enough to stop Windows Update.

→ On early Windows 11 23H2 builds, the key Windows uses to reinstall it is deleted.

→ In classic Outlook, the "Try the new Outlook" toggle is hidden and automatic migration to new Outlook is turned off, for every user and for new users.

A user can still install new Outlook from the Microsoft Store. Choosing Keep on a later run does not undo a Block; see "Undoing a choice".

### Copilot apps

This covers two apps: Copilot, and the Microsoft 365 Copilot app (previously called Office). Choose Keep if the user has a Copilot licence. Removing them doesn't affect Word, Excel, Outlook or the other Office apps.

### Norton

The script looks for Norton 360, Norton Security, Norton AntiVirus, Norton Internet Security and Norton Online Backup. Remove runs each product's own uninstaller. Check the PC afterwards, because some Norton uninstallers ignore the silent switches and may need finishing by hand.

## What the script does

### Step 1: removes preinstalled apps

Each app is removed for every user on the PC and for new users.

| Group | Apps |
|---|---|
| Microsoft consumer apps | Cortana, News, Weather, Finance, Xbox apps and overlays, Phone Link, Films & TV, Solitaire, Mixed Reality Portal, People, Get Help, Tips, Feedback Hub, Maps, To Do, Power Automate Desktop, Skype, personal Teams (the old consumer app), Clipchamp, Family, Mail and Calendar, Journal |
| Third-party promo apps | Spotify, Netflix, Disney+, Amazon, Prime Video, TikTok, Facebook, Instagram, Candy Crush (Saga and Soda), Bubble Witch 3, Shazam, Duolingo, Viber |
| Depending on the answers | New Outlook (unless Keep), Copilot and Microsoft 365 Copilot (if Remove) |

These are kept on purpose:

| App | Why it stays |
|---|---|
| Quick Assist | Used for remote support |
| Media Player | The Windows 11 default music and video player |
| Work Teams | The current Teams app is a different package and isn't touched |

An app that isn't on the PC is skipped without a message.

### Step 2: new Outlook

Applies the Block settings if that was chosen. Remove and Keep are handled in step 1.

### Step 3: removes OEM trialware

Looks for these products and runs each one's own uninstaller silently:

| Vendor | Products |
|---|---|
| McAfee | LiveSafe, Total Protection, McAfee+, Internet Security, AntiVirus Plus, Security Scan, WebAdvisor, Safe Connect |
| Norton | Only if the Norton answer was Remove |
| WildTangent | Games |
| Dell | SupportAssist, Optimizer, Digital Delivery, Customer Connect, MyDell |
| HP | Support Assistant, Documentation, JumpStart, myHP |

Business security products such as McAfee Agent, McAfee Endpoint Security, Trellix and Symantec Endpoint Protection are not matched and are left alone.

Each uninstaller gets two minutes. If one hangs on a prompt it ignored the silent switches for, the script stops it and tells you to remove that product by hand. On a VM or a clean business image, this step normally finds nothing.

### Step 4: turns off adverts and suggestions

→ Turns off Start menu suggestions, lock screen adverts, silently installed suggested apps and other consumer content, for every user profile and for new users.

→ Turns off Widgets on Windows 11, and News and Interests on the Windows 10 taskbar.

→ Skips the "Choose privacy settings" screen when a new user first signs in.

Some of the machine-wide settings only work on Enterprise and Education editions. On Pro, the per-user settings do the work, which is why they go to every profile.

### Step 5: frees disk space

→ Clears temporary files and the Windows Update download cache.

→ Empties the Recycle Bin and the Delivery Optimization cache.

→ Deletes `C:\Windows.old` if it exists (see "Before you run it").

→ Runs the Windows component store cleanup (DISM). This can take several minutes, and the script shows a progress line every 30 seconds. It is stopped after 20 minutes; it's safe to run again later.

## Logs

Every run is logged to `C:\ArcLogs\WindowsDebloat\Debloat-Windows_<date-time>.log`. The log starts with the script version and the three choices, and records each app removed, each warning and each uninstaller's result.

If the script hits an unexpected error, it stops, closes the log and shows the error.

## Undoing a choice

| To undo | Do this |
|---|---|
| A removed app | Reinstall it from the Microsoft Store |
| Removed trialware | Reinstall it from the vendor's website |
| New Outlook Block, Windows Update part | In `HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe`, remove `"MS_Outlook"` from the `BlockedOobeUpdaters` value, or delete the value if nothing else is in it |
| New Outlook Block, classic Outlook part | In each user's registry, delete `HideNewOutlookToggle` under `Software\Microsoft\Office\16.0\Outlook\Options\General` and `NewOutlookMigrationUserSetting` under `Software\Policies\Microsoft\Office\16.0\Outlook\Preferences` |

Windows.old can't be restored once it's deleted.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "must run in an elevated PowerShell session" | PowerShell isn't running as Administrator. Open it with Run as Administrator and run the command again |
| "could not fully remove" for an app | The app was in use, or is part of Windows on that build. Usually harmless; run the script again after the user has signed out |
| An uninstaller "did not finish within the timeout" | It showed a prompt despite the silent switches. Remove that product from Settings, Apps |
| "could not load the registry hive" for a user | That user's profile is locked or damaged. Their settings weren't changed; everyone else's were |
| A hive "did not unload cleanly" | It releases at the next reboot. Nothing else is needed |
| C:\Windows.old "could not be fully removed" | Some files are protected. Use Disk Cleanup, Clean up system files, Previous Windows installations |
| Adverts still showing in Start | They clear after the user next signs in |

## Reference

| Item | Location |
|---|---|
| Script | `windows-debloat/Debloat-Windows.ps1` in the Arc-hub-tech/Automations repository on GitHub, main branch |
| Change history | `windows-debloat/CHANGELOG.md` |
| This guide's source | `windows-debloat/docs/Debloat-Windows-Confluence-Guide.md` |
| Microsoft guidance on new Outlook | "Control installing and using new Outlook" on Microsoft Learn |
