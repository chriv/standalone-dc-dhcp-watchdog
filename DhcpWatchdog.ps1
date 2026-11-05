<#
.SYNOPSIS
  Gets the DHCP Server service running and authorized once Active Directory is
  ready, then exits.

.DESCRIPTION
  Runs from a scheduled task late in boot, and again if DHCP logs an
  authorization failure (events 1046/1059). Each pass works through the chain
  DHCP depends on, fixing what it can, and retries until DHCP is running and
  authorized or the time limit is reached:

    1. Core services: NTDS, DNS (if installed), Netlogon. Starts any that are stopped.
    2. Directory ready: local LDAP RootDSE answers and DC locator (nltest) finds this DC.
    3. Authorization: this server is listed in AD's authorized DHCP servers.
    4. DHCP Server service is running and reports IsAuthorized, restarting it if not.

  Everything goes to a text log, plus a one-line summary to the Application
  event log (source DhcpWatchdog). New DHCP, Service Control Manager and
  Directory Service errors since boot are copied into the log as they appear.

.PARAMETER RetrySeconds
  Wait between passes. Default 30.

.PARAMETER MaxMinutes
  Give up after this long. 0 = keep trying forever. Default 60.

.PARAMETER CheckOnly
  Report state without starting, restarting or authorizing anything.

.PARAMETER AutoAuthorize
  If this server is missing from AD's authorized list, add it
  (Add-DhcpServerInDC). Off by default: on a server that was already
  authorized, a missing entry usually means something else is wrong.
#>
[CmdletBinding()]
param(
    [int]$RetrySeconds = 30,
    [int]$MaxMinutes = 60,
    [switch]$CheckOnly,
    [switch]$AutoAuthorize,
    [string]$LogPath = (Join-Path $env:ProgramData 'DhcpWatchdog\dhcp-watchdog.log')
)

$ErrorActionPreference = 'Stop'
$EventSource = 'DhcpWatchdog'

# ---------------------------------------------------------------- logging

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null

function Write-Log {
    param([ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO', [string]$Message)
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $line
    Write-Verbose $line
}

function Write-Summary {
    param([string]$Message, [System.Diagnostics.EventLogEntryType]$Type, [int]$Id)
    try {
        if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            Write-EventLog -LogName Application -Source $EventSource -EventId $Id -EntryType $Type -Message $Message
        }
    } catch { Write-Log WARN "Could not write Application event: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- helpers

$BootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$script:EventsSince = $BootTime

function Write-NewEvents {
    # Copy errors/warnings logged since the last call, so each one appears once.
    $now = Get-Date
    $found = @()
    $found += Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $script:EventsSince
        ProviderName = 'Microsoft-Windows-DHCP-Server' } -ErrorAction SilentlyContinue
    $found += Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $script:EventsSince
        ProviderName = 'Service Control Manager'; Level = 1, 2, 3 } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'DHCP|Active Directory|Netlogon|DNS Server' }
    $found += Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; StartTime = $script:EventsSince
        Level = 1, 2, 3 } -ErrorAction SilentlyContinue
    foreach ($e in ($found | Where-Object { $_ } | Sort-Object TimeCreated)) {
        $msg = ($e.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' / '
        Write-Log INFO ("  event {0} {1} {2} id={3} {4}: {5}" -f $e.TimeCreated.ToString('HH:mm:ss'),
            $e.LogName, $e.LevelDisplayName, $e.Id, $e.ProviderName, $msg)
    }
    $script:EventsSince = $now
}

function Wait-ServiceState {
    param([string]$Name, [string]$State = 'Running', [int]$Seconds = 60)
    $svc = Get-Service -Name $Name
    try { $svc.WaitForStatus($State, [TimeSpan]::FromSeconds($Seconds)) } catch { }
    (Get-Service -Name $Name).Status -eq $State
}

function Confirm-ServiceRunning {
    # Returns $true if the service is running (starting it if needed and allowed).
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log ERROR "Service $Name is not installed"; return $false }
    if ($svc.Status -eq 'Running') { return $true }
    Write-Log WARN "Service $Name is $($svc.Status) (start type $($svc.StartType))"
    if ($CheckOnly) { return $false }
    try {
        if ($svc.Status -ne 'StartPending') { Start-Service -Name $Name }
        if (Wait-ServiceState $Name) { Write-Log OK "Started $Name"; return $true }
        Write-Log ERROR "$Name did not reach Running within 60s"
    } catch { Write-Log ERROR "Start-Service $Name failed: $($_.Exception.Message)" }
    return $false
}

function Test-Directory {
    # Is AD on this DC answering, and does DC locator see it?
    try {
        $root = [ADSI]'LDAP://localhost/RootDSE'
        $dns = [string]$root.dnsHostName
        if (-not $dns) { throw 'RootDSE returned no dnsHostName' }
        Write-Log INFO "LDAP RootDSE ok: $dns isSynchronized=$($root.isSynchronized) isGlobalCatalogReady=$($root.isGlobalCatalogReady)"
    } catch {
        Write-Log WARN "LDAP RootDSE not answering yet: $($_.Exception.Message)"
        return $false
    }
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain
    $out = & nltest.exe /dsgetdc:$domain /force 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log WARN "nltest /dsgetdc:$domain failed (exit $LASTEXITCODE): $(($out | Select-Object -First 3) -join ' / ')"
        return $false
    }
    $dc = ($out | Where-Object { $_ -match '^\s*DC:' }) -replace '^\s*DC:\s*', ''
    Write-Log INFO "DC locator ok: $dc"
    return $true
}

function Get-ThisServerIdentity {
    $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -ExpandProperty IPAddress
    [pscustomobject]@{ Fqdn = $fqdn; IPs = @($ips) }
}

function Test-AuthorizedInAD {
    $me = Get-ThisServerIdentity
    try {
        $list = @(Get-DhcpServerInDC)
    } catch {
        Write-Log WARN "Get-DhcpServerInDC failed: $($_.Exception.Message)"
        return $false
    }
    $hit = $list | Where-Object { $_.DnsName -eq $me.Fqdn -or $me.IPs -contains $_.IPAddress.ToString() }
    if ($hit) { Write-Log INFO "Authorized in AD as $($hit[0].DnsName) [$($hit[0].IPAddress)]"; return $true }
    Write-Log ERROR ("Not in AD's authorized DHCP servers. This server: {0} [{1}]. Authorized: {2}" -f
        $me.Fqdn, ($me.IPs -join ', '), (($list | ForEach-Object { "$($_.DnsName) [$($_.IPAddress)]" }) -join '; '))
    if ($CheckOnly -or -not $AutoAuthorize) { return $false }
    try {
        Add-DhcpServerInDC -DnsName $me.Fqdn -IPAddress $me.IPs[0]
        Write-Log OK "Authorized $($me.Fqdn) [$($me.IPs[0])] in AD"
        return $true
    } catch { Write-Log ERROR "Add-DhcpServerInDC failed: $($_.Exception.Message)"; return $false }
}

function Get-DhcpAuthorized {
    try { return [bool](Get-DhcpServerSetting).IsAuthorized } catch {
        Write-Log WARN "Get-DhcpServerSetting failed: $($_.Exception.Message)"; return $false
    }
}

function Wait-DhcpAuthorized {
    # The service checks authorization shortly after it starts.
    for ($i = 0; $i -lt 12; $i++) {
        if (Get-DhcpAuthorized) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Test-Dhcp {
    $svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log ERROR 'DHCPServer service is not installed'; return $false }
    if ($svc.Status -eq 'Running') {
        if (Get-DhcpAuthorized) { return $true }
        Write-Log WARN 'DHCPServer is running but not authorized (it will not hand out leases)'
        if ($CheckOnly) { return $false }
        Write-Log INFO 'Restarting DHCPServer so it re-checks authorization'
        try { Restart-Service -Name DHCPServer -Force } catch {
            Write-Log ERROR "Restart-Service DHCPServer failed: $($_.Exception.Message)"; return $false
        }
    } else {
        Write-Log WARN "DHCPServer is $($svc.Status)"
        if ($CheckOnly) { return $false }
        try { Start-Service -Name DHCPServer } catch {
            Write-Log ERROR "Start-Service DHCPServer failed: $($_.Exception.Message)"; return $false
        }
    }
    if (-not (Wait-ServiceState DHCPServer)) { Write-Log ERROR 'DHCPServer did not stay Running'; return $false }
    if (Wait-DhcpAuthorized) { Write-Log OK 'DHCPServer running and authorized'; return $true }
    Write-Log ERROR 'DHCPServer running but still not authorized after 60s'
    return $false
}

function Write-ScopeSummary {
    try {
        foreach ($s in Get-DhcpServerv4Scope) {
            $st = Get-DhcpServerv4ScopeStatistics -ScopeId $s.ScopeId
            Write-Log INFO ("  scope {0} {1} {2}-{3} in use {4}/{5}" -f $s.ScopeId, $s.State,
                $s.StartRange, $s.EndRange, $st.InUse, ($st.InUse + $st.Free))
        }
    } catch { Write-Log WARN "Could not read scopes: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- main

$started = Get-Date
$deadline = if ($MaxMinutes -gt 0) { $started.AddMinutes($MaxMinutes) } else { [datetime]::MaxValue }
$mode = if ($CheckOnly) { 'check-only' } else { 'fix' }
Write-Log INFO ('===== DhcpWatchdog start ({0}); boot {1}; up {2:N1} min; retry {3}s; limit {4} =====' -f
    $mode, $BootTime, ((Get-Date) - $BootTime).TotalMinutes, $RetrySeconds,
    $(if ($MaxMinutes -gt 0) { "$MaxMinutes min" } else { 'none' }))

$pass = 0
while ($true) {
    $pass++
    Write-Log INFO "--- pass $pass"
    Write-NewEvents

    $ok = $true
    foreach ($name in 'NTDS', 'DNS', 'Netlogon') {
        if ($name -eq 'DNS' -and -not (Get-Service DNS -ErrorAction SilentlyContinue)) { continue }
        if (-not (Confirm-ServiceRunning $name)) { $ok = $false }
    }
    if ($ok) { $ok = Test-Directory }
    if ($ok) { $ok = Test-AuthorizedInAD }
    if ($ok) { $ok = Test-Dhcp }

    if ($ok) {
        Write-ScopeSummary
        $msg = "DHCP Server is running and authorized (pass $pass, {0:N1} min after boot)." -f ((Get-Date) - $BootTime).TotalMinutes
        Write-Log OK $msg
        Write-Summary $msg Information 1000
        exit 0
    }
    if ($CheckOnly) {
        Write-Log WARN 'Check-only: not healthy, no changes made'
        exit 1
    }
    if ((Get-Date).AddSeconds($RetrySeconds) -gt $deadline) {
        Write-NewEvents
        $msg = "DHCP Server still not healthy after $MaxMinutes min ($pass passes). See $LogPath"
        Write-Log ERROR $msg
        Write-Summary $msg Error 1001
        exit 2
    }
    Write-Log INFO "Not healthy yet; retrying in $RetrySeconds s"
    Start-Sleep -Seconds $RetrySeconds
}
