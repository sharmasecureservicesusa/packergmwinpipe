[CmdletBinding()]
param(
    [ValidateSet('quit', 'shutdown', 'reboot')]
    [string]$Action = 'quit'
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules/DeploymentLogger.psm1'
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force
} else {
    Import-Module DeploymentLogger -Force
}
$Logger = Get-DeploymentLogger

try {
    $Logger.Log('Starting image generalization and cleanup...', 'NOTICE')
    $cloudbaseDirectory = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'
    $unattendFile = Join-Path $cloudbaseDirectory 'conf\Unattend.xml'
    if (-not (Test-Path -LiteralPath $unattendFile -PathType Leaf)) {
        throw "Cloudbase-Init Unattend.xml not found: $unattendFile"
    }
    $cloudbaseRegistry = 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init'
    if (Test-Path -LiteralPath $cloudbaseRegistry) {
        Remove-Item -Path $cloudbaseRegistry -Recurse -Force -ErrorAction SilentlyContinue
    }
    $cloudbaseLogDirectory = Join-Path $cloudbaseDirectory log
    if (Test-Path -LiteralPath $cloudbaseLogDirectory) {
        Get-ChildItem -Path $cloudbaseLogDirectory -File | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Enable-LocalUser -Name Administrator
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    foreach ($path in @('C:\Windows\Temp\*', "$env:TEMP\*")) {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Logger.Log('Cleanup completed. Starting Sysprep.', 'NOTICE', @{
        Action = $Action
        UnattendFile = $unattendFile
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
    })
    $Logger.Flush()
    $sysprep = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
    $arguments = @(
        '/generalize',
        '/oobe',
        "/$Action",
        "/unattend:`"$unattendFile`""
    )
    $process = Start-Process -FilePath $sysprep -ArgumentList $arguments -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw "Sysprep failed with exit code $($process.ExitCode)."
    }
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $imageState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
        if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
            break
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        throw "Sysprep did not reach the expected image state. Current state: $imageState"
    }
    $Logger.Log('Sysprep completed successfully.', 'NOTICE')
} catch {
    $Logger.LogException($_, 'Image generalization failed')
    $Logger.Flush()
    throw
} finally {
    if ($Logger) {
        $Logger.Flush()
    }
}
