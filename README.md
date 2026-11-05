# Standalone DC DHCP watchdog

Gets the Windows **DHCP Server** service running and authorized on a domain
controller once Active Directory can answer, then exits. Built for a
single-DC domain where the DC also serves DHCP.

## The problem

On some boots, DHCP Server starts before Active Directory is ready. It can't
check its authorization, so it logs System event **1059** ("failed to see a
directory server for authorization") or **1046** ("not authorized"). Then it
either stops or keeps running without handing out leases. Starting it by
hand a few minutes later works.

Adding `NTDS` to DHCPServer's service dependencies doesn't help. Windows
counts NTDS as started as soon as its process is up, which is well before
the directory answers queries.

## What it does

`DhcpWatchdog.ps1` runs as SYSTEM from a scheduled task:

- **2 minutes after boot**, and
- **1 minute after any DHCP 1046/1059 event**. That covers DHCP's own
  hourly re-check failing later. Only one copy runs at a time.

Each pass works down the chain and fixes what it can:

| Check | Fix if failing |
|---|---|
| NTDS, DNS (if present), Netlogon running | Start them |
| Local LDAP RootDSE answers; `nltest /dsgetdc` finds this DC | Wait and retry |
| This server is in AD's authorized DHCP servers (`Get-DhcpServerInDC`) | Log what's there; add it only with `-AutoAuthorize` |
| DHCPServer running **and** `Get-DhcpServerSetting` IsAuthorized | Start it, or restart it if it's running but unauthorized, then wait up to 60s for authorization |

When every check passes, it logs the scope state and leases in use and exits.
Otherwise it retries every 30s, and gives up after 60 minutes (both are
installer parameters; `-MaxMinutes 0` retries forever).

**Logs:**

- **Full log:** `C:\ProgramData\DhcpWatchdog\dhcp-watchdog.log`. Each run starts
  with a `=====` header. New DHCP, Service Control Manager and Directory
  Service errors/warnings since boot are copied in as they appear.
- **Summary:** the Application event log, source `DhcpWatchdog`: event 1000
  means healthy, 1001 means it gave up.

The log isn't rotated. On a long-lived server it grows by a few lines per
boot.

## Install

On the DC, in elevated PowerShell:

```powershell
Invoke-WebRequest https://github.com/chriv/standalone-dc-dhcp-watchdog/archive/refs/heads/main.zip -OutFile $env:TEMP\dhcpwd.zip
Expand-Archive $env:TEMP\dhcpwd.zip -DestinationPath $env:TEMP -Force
cd $env:TEMP\standalone-dc-dhcp-watchdog-main
powershell -ExecutionPolicy Bypass -File .\Install-DhcpWatchdog.ps1 -DelayedStart -SingleDcFix
```

Both switches are optional:

- **`-DelayedStart`** sets DHCPServer to *Automatic (Delayed Start)*, which
  starts it about 2 minutes after boot. That alone often avoids the race.
- **`-SingleDcFix`** sets `HKLM\SYSTEM\CurrentControlSet\Services\NTDS\Parameters\Repl Perform Initial Synchronizations = 0`.
  After a reboot, a DC that holds the FSMO roles waits to complete an initial
  replication with a partner before it fully advertises itself. A standalone
  DC has no partner, so it waits until that times out, and that window is
  when DHCP's authorization check fails. **Only use this when the domain has
  a single DC.**

Other installer parameters: `-BootDelayMinutes` (default 2),
`-RetrySeconds` (30), `-MaxMinutes` (60). Re-running the installer updates
the task in place.

## Test

```powershell
# Report state, change nothing
powershell -ExecutionPolicy Bypass -File C:\ProgramData\DhcpWatchdog\DhcpWatchdog.ps1 -CheckOnly -Verbose

# Run the task for real and read the log
Start-ScheduledTask -TaskPath '\DhcpWatchdog\' -TaskName 'DHCP Watchdog'
Get-Content C:\ProgramData\DhcpWatchdog\dhcp-watchdog.log -Tail 30 -Wait
```

To simulate the failure: `Stop-Service DHCPServer`, then start the task.

If the server runs from a snapshot or golden image, install it, test it,
then update the image.

## Remove

```powershell
Unregister-ScheduledTask -TaskPath '\DhcpWatchdog\' -TaskName 'DHCP Watchdog' -Confirm:$false
Remove-Item C:\ProgramData\DhcpWatchdog -Recurse
Remove-EventLog -Source DhcpWatchdog
```

## Requirements

Windows Server 2012 R2 or later with Windows PowerShell 5.1, the AD DS and
DHCP Server roles on the same machine, and the DhcpServer PowerShell module
(installed with the DHCP role's management tools).

## License

MIT. See [LICENSE](LICENSE).
