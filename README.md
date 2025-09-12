# WinFiRepair

A reversible, GUI-driven tool to diagnose and repair Windows Wi-Fi connectivity without memorizing commands. Safe defaults, one-click actions, and automatic backups enable recovery if changes do not help.

## Features

- **Safe Repair**: Flush DNS, restart Wi-Fi and DNS services, gently restart the adapter, and renew DHCP only when applicable.
- **Automatic Backups**: Saves adapter IPv4/DNS configuration and exports Wi-Fi profiles before making changes.
- **Rollback**: Restores the last saved network state with one click.
- **Aggressive Reset (optional)**: Executes TCP/IP and Winsock resets as a last resort, with explicit warning and logs.
- **No stored credentials**: Does not persist Wi-Fi passwords. Reconnect by SSID only if a profile already exists.
- **Minimal dependencies**: PowerShell-only implementation; can be packaged as a single EXE.

## Safety Model

- Defaults avoid destructive operations. No profile deletion or DHCP override unless the adapter already used DHCP.
- Backups are stored under `C:\ProgramData\WifiRepair\Backups\<timestamp>\` and include:
  - `state.json` (IPv4/DNS and adapter identity)
  - `wlan_profiles\*.xml` (exported profiles)
- **Aggressive Reset** can disrupt VPNs, proxies, or custom network stacks and may require a reboot.

## Requirements

- Windows 10 or 11
- Administrator privileges
- PowerShell 5.1+ or PowerShell 7+

## Quick Start (GUI)

1. Download `WinFiRepair.exe` from Releases or build from source.
2. Right-click → **Run as administrator**.
3. Select your wireless adapter.
4. Optional: enter SSID to attempt reconnect.
5. Click **Diagnose** to test, **Safe Repair** to apply non-destructive fixes.
6. If needed, use **Rollback (Latest)** to revert to the previous state.

## Rollback

- Click **Rollback (Latest)** in the GUI to restore the most recent backup.
- Backups are dated; you can manually archive or delete old backups from `C:\ProgramData\WifiRepair\Backups`.

## Aggressive Reset (Last Resort)

- Click **Aggressive Reset** only if Safe Repair fails.
- Action logs to `ip_reset.log` in the selected backup directory.
- A reboot is typically required.

## Build From Source

Repository layout:

/src   # PowerShell sources (GUI script)
/dist  # Built executables and artifacts

````

Build steps:
```powershell
# From a PowerShell prompt
Install-Module ps2exe -Scope CurrentUser   # one-time
Set-ExecutionPolicy -Scope Process Bypass -Force

# Build a no-console, elevated EXE
Invoke-PS2EXE .\src\WifiRepair.GUI.ps1 .\dist\WinFiRepair.exe -noConsole -requireAdmin
````

Run from source (without packaging):

```powershell
# Elevated PowerShell
.\src\WifiRepair.GUI.ps1
```

## Troubleshooting

* If the adapter list is empty, verify the wireless adapter is enabled and shows as **Up** in `Get-NetAdapter`.
* If SmartScreen blocks the EXE, use **More info → Run anyway**, or build locally.
* If corporate policy blocks script execution, run the packaged EXE or consult the policy owner.

## Privacy and Security

* No telemetry, no network calls beyond repair checks.
* Wi-Fi passwords are not stored by the tool. Profile exports may include keys in clear text to enable rollback; these remain local under `C:\ProgramData\WifiRepair\Backups\`.

## License

MIT
