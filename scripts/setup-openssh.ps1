# scripts/setup-openssh.ps1
[CmdletBinding()]
param(
    [DeploymentLogger]$Logger
)

$ErrorActionPreference = 'Stop'

# Auto-initialize logger if not passed as parameter
if (-not $Logger) {
    Import-Module "$PSScriptRoot/modules/DeploymentLogger.psm1" -Force -ErrorAction SilentlyContinue
    if (Get-Command Get-DeploymentLogger -ErrorAction SilentlyContinue) {
        $Logger = Get-DeploymentLogger
    }
}

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
    # Ensure remaining logs are dispatched to Cloudflare before process exit
    if ($Logger) { $Logger.Flush() }
}
