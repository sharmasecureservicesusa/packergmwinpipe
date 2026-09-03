[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules/DeploymentLogger.psm1'
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force
} else {
    Import-Module DeploymentLogger -Force
}
$Logger = Get-DeploymentLogger

try {
    $source = 'C:\Windows\Temp\config'
    $destination = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
    foreach ($name in @('cloudbase-init.conf', 'cloudbase-init-unattend.conf')) {
        $sourceFile = Join-Path $source $name
        if (-not (Test-Path -LiteralPath $sourceFile)) {
            throw "Cloudbase-Init configuration is missing: $sourceFile"
        }
        Copy-Item -Path $sourceFile -Destination (Join-Path $destination $name) -Force
    }
    $Logger.Log('Cloudbase-Init configuration completed.', 'NOTICE')
} finally {
    if ($Logger) {
        $Logger.Flush()
    }
}
