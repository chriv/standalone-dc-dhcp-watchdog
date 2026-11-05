#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs DhcpWatchdog.ps1 as a scheduled task on a DC that runs DHCP Server.

.DESCRIPTION
  Copies the script to C:\ProgramData\DhcpWatchdog, registers the Application
  event source, and creates task \DhcpWatchdog\DHCP Watchdog running as SYSTEM:
    - at startup, after a delay (default 2 minutes)
    - whenever DHCP logs 1046 (not authorized) or 1059 (no directory server),
      1 minute after the event
  Only one copy runs at a time. Re-running this installer updates everything.

  Optional -DelayedStart also sets the DHCPServer service to Automatic
  (Delayed Start), and -SingleDcFix applies the single-DC initial-sync
  registry setting. See README.md for both.
#>
param(
    [int]$BootDelayMinutes = 2,
    [int]$RetrySeconds = 30,
    [int]$MaxMinutes = 60,
    [switch]$DelayedStart,
    [switch]$SingleDcFix
)
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:ProgramData 'DhcpWatchdog'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'DhcpWatchdog.ps1') -Destination $dir -Force
$script = Join-Path $dir 'DhcpWatchdog.ps1'

if (-not [System.Diagnostics.EventLog]::SourceExists('DhcpWatchdog')) {
    New-EventLog -LogName Application -Source DhcpWatchdog
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RetrySeconds {1} -MaxMinutes {2}' -f
    $script, $RetrySeconds, $MaxMinutes)

$boot = New-ScheduledTaskTrigger -AtStartup
$boot.Delay = 'PT{0}M' -f $BootDelayMinutes

$cls = Get-CimClass -Namespace Root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger
$onEvent = New-CimInstance -CimClass $cls -ClientOnly
$onEvent.Enabled = $true
$onEvent.Delay = 'PT1M'
$onEvent.Subscription = @"
<QueryList><Query Id="0" Path="System"><Select Path="System">
*[System[Provider[@Name='Microsoft-Windows-DHCP-Server' or @Name='DhcpServer'] and (EventID=1046 or EventID=1059)]]
</Select></Query></QueryList>
"@

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes ($MaxMinutes + 15))
if ($MaxMinutes -eq 0) { $settings.ExecutionTimeLimit = 'PT0S' }   # no limit

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskPath '\DhcpWatchdog\' -TaskName 'DHCP Watchdog' -Force `
    -Action $action -Trigger @($boot, $onEvent) -Settings $settings -Principal $principal `
    -Description 'Gets DHCP Server running and authorized once AD is ready. Log: C:\ProgramData\DhcpWatchdog\dhcp-watchdog.log' |
    Out-Null
Write-Host "Registered \DhcpWatchdog\DHCP Watchdog -> $script"

if ($DelayedStart) {
    & sc.exe config DHCPServer start= delayed-auto | Out-Null
    Write-Host 'DHCPServer start type: Automatic (Delayed Start)'
}

if ($SingleDcFix) {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
    Set-ItemProperty -Path $key -Name 'Repl Perform Initial Synchronizations' -Value 0 -Type DWord
    Write-Host 'Set "Repl Perform Initial Synchronizations" = 0 (takes effect next boot)'
}

Write-Host ''
Write-Host 'Test now without changing anything:'
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$script`" -CheckOnly -Verbose"
Write-Host 'Run the real task:'
Write-Host "  Start-ScheduledTask -TaskPath '\DhcpWatchdog\' -TaskName 'DHCP Watchdog'"
Write-Host "Log: $dir\dhcp-watchdog.log"
