# setup-winrm.ps1 — Placed on supplemental CD (E:\) and executed from FirstLogonCommands.
# Configures WinRM for unencrypted Basic auth on port 5985 and retries until the
# listener is confirmed reachable, working around NIC-not-ready races at first logon.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$ts] $Message"
    Add-Content -Path 'C:\Windows\Temp\setup-winrm.log' -Value "[$ts] $Message" -ErrorAction SilentlyContinue
}

Write-Log 'Starting WinRM setup.'

# Open firewall for WinRM before configuring the service so quickconfig succeeds.
Write-Log 'Adding firewall rule for WinRM port 5985.'
netsh advfirewall firewall add rule `
    name='WinRM-HTTP-In' `
    protocol=TCP `
    dir=in `
    localport=5985 `
    action=allow | Out-Null

# Retry loop: wait for a NIC with a non-link-local address before running quickconfig.
Write-Log 'Waiting for a network interface to become ready...'
$maxWait = 120
$waited  = 0
while ($waited -lt $maxWait) {
    $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' }
    if ($addrs) {
        Write-Log "Network ready: $($addrs[0].IPAddress)"
        break
    }
    Start-Sleep -Seconds 5
    $waited += 5
}
if ($waited -ge $maxWait) {
    Write-Log 'WARNING: No routable NIC found after waiting; proceeding anyway.'
}

# Configure WinRM.
Write-Log 'Running winrm quickconfig.'
cmd /c 'winrm quickconfig -q -force' 2>&1 | ForEach-Object { Write-Log $_ }

Write-Log 'Enabling unencrypted transport.'
cmd /c 'winrm set winrm/config/service @{AllowUnencrypted="true"}' 2>&1 | Out-Null

Write-Log 'Enabling Basic authentication.'
cmd /c 'winrm set winrm/config/service/auth @{Basic="true"}' 2>&1 | Out-Null

Write-Log 'Setting max envelope size.'
cmd /c 'winrm set winrm/config @{MaxEnvelopeSizekb="1024"}' 2>&1 | Out-Null

# Ensure WinRM service is started and listener is bound.
Write-Log 'Starting WinRM service.'
Stop-Service -Name winrm -Force -ErrorAction SilentlyContinue
Start-Service -Name winrm

# Verify a listener is actually bound on port 5985.
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $l = Get-NetTCPConnection -LocalPort 5985 -State Listen -ErrorAction SilentlyContinue
    if ($l) { Write-Log 'WinRM listener confirmed on port 5985.'; break }
    Start-Sleep -Seconds 3
}

Write-Log 'WinRM setup complete.'
