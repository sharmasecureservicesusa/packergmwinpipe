[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# --- Load shared DeploymentLogger module (single source of truth) -----------
if (-not (Get-Module -Name DeploymentLogger)) {
    Import-Module DeploymentLogger -Force -ErrorAction SilentlyContinue
}
if (-not (Get-Command Get-DeploymentLogger -ErrorAction SilentlyContinue)) {
    $moduleCandidates = @(
        (Join-Path $PSScriptRoot 'modules/DeploymentLogger.psm1')
        (Join-Path $PSScriptRoot '../modules/DeploymentLogger.psm1')
    )
    foreach ($candidate in $moduleCandidates) {
        if (Test-Path $candidate) {
            Import-Module $candidate -Force -ErrorAction SilentlyContinue
            if (Get-Command Get-DeploymentLogger -ErrorAction SilentlyContinue) { break }
        }
    }
}
if (-not (Get-Command Get-DeploymentLogger -ErrorAction SilentlyContinue)) {
    throw 'DeploymentLogger module not found. Ensure the Packer file provisioner copied scripts/modules/DeploymentLogger.psm1 into the guest PowerShell module path.'
}

$Logger = Get-DeploymentLogger

try {
$cbiConfDir = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"
# The Packer file provisioner copies build/config -> C:\Windows\Temp\config on the guest.
$configSrc = "C:\Windows\Temp\config"

Copy-Item -Path "$configSrc\cloudbase-init.conf" `
          -Destination "$cbiConfDir\cloudbase-init.conf" `
          -Force

Copy-Item -Path "$configSrc\cloudbase-init-unattend.conf" `
          -Destination "$cbiConfDir\cloudbase-init-unattend.conf" `
          -Force

$Logger.Log("Both Cloudbase-Init configurations placed successfully.", "NOTICE")
} finally {
    # Ensure buffered telemetry is shipped even if the script fails mid-way.
    if ($Logger) { $Logger.Flush() }
}
