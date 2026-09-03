# scripts/setup-openssh.ps1
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
    $Logger.Log("Starting OpenSSH Server installation...", "INFO")

    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    $Logger.Log("OpenSSH capability added.", "NOTICE")

    # Service configuration ...
    Start-Service -Name sshd
    $Logger.Log("OpenSSH Server configured and running on port 22.", "NOTICE")

} catch {
    $Logger.LogException($_, "Failed to configure OpenSSH")
    throw $_
} finally {
    if ($Logger) { $Logger.Flush() }
}
