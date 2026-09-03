<#
.SYNOPSIS
    Cleans system state, flushes telemetry to Cloudflare, and executes Sysprep.
.DESCRIPTION
    Prepares a Windows Golden Image for Cloudbase-Init cloning:
      1. Initializes logger and verifies Unattend.xml.
      2. Purges Cloudbase-Init state, logs, and temp artifacts.
      3. Re-enables the local Administrator account.
      4. Flushes all pending telemetry to Cloudflare Pipelines.
      5. Runs sysprep.exe /generalize /oobe /unattend.
#>
[CmdletBinding()]
param(
    [ValidateSet('quit', 'shutdown', 'reboot')]
    [string]$Action = 'quit'
)

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

function Write-DeployLog([string]$msg, [string]$lvl = "INFO", [hashtable]$meta = @{}) {
    if ($Logger) {
        $Logger.Log($msg, $lvl, $meta)
    } else {
        Write-Host "[$lvl] $msg"
    }
}

try {
    Write-DeployLog "Starting image generalization and pre-Sysprep cleanup..." "NOTICE"

    # -------------------------------------------------------------------------
    # 2. Prerequisite Check: Cloudbase-Init Unattend.xml
    # -------------------------------------------------------------------------
    $cbiDir = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init"
    $unattendXml = Join-Path $cbiDir "conf\Unattend.xml"

    if (-not (Test-Path -LiteralPath $unattendXml -PathType Leaf)) {
        throw "Cloudbase-Init Unattend.xml not found at expected location: $unattendXml"
    }
    Write-DeployLog "Validated Cloudbase-Init Unattend.xml at: $unattendXml" "INFO"

    # -------------------------------------------------------------------------
    # 3. Purge Cloudbase-Init Run History & Temporary State
    # -------------------------------------------------------------------------
    Write-DeployLog "Purging Cloudbase-Init registry keys and previous run metadata..." "INFO"

    # Remove Cloudbase-Init registry tracking keys so cloned instances run fresh
    $cbiRegKey = "HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init"
    if (Test-Path $cbiRegKey) {
        Remove-Item -Path $cbiRegKey -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Clean old Cloudbase-Init logs so the template image starts clean
    $cbiLogDir = Join-Path $cbiDir "log"
    if (Test-Path $cbiLogDir) {
        Get-ChildItem -Path $cbiLogDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # -------------------------------------------------------------------------
    # 4. Reset & Ensure Administrator Account is Active
    # -------------------------------------------------------------------------
    Write-DeployLog "Ensuring built-in Administrator account is active..." "INFO"
    & net.exe user Administrator /active:yes | Out-Null

    # Reset execution policy to RemoteSigned for safety
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

    # Clear Windows temporary files
    $tempPaths = @("C:\Windows\Temp\*", "$env:TEMP\*")
    foreach ($path in $tempPaths) {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -------------------------------------------------------------------------
    # 5. Flush Telemetry BEFORE Network Shutdown (CRITICAL)
    # -------------------------------------------------------------------------
    Write-DeployLog "Pre-Sysprep cleanup complete. Sealing image and launching Sysprep..." "NOTICE" @{
        Action      = $Action
        UnattendXml = $unattendXml
        Timestamp   = (Get-Date).ToUniversalTime().ToString("o")
    }

    # Flush the buffer now while outbound TCP/DNS is still alive
    $Logger.Log("Flushing telemetry events to Cloudflare Pipelines before network shutdown...", "NOTICE")
    $Logger.Flush()

    # -------------------------------------------------------------------------
    # 6. Execute Sysprep
    # -------------------------------------------------------------------------
    $sysprepExe = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
    $sysprepArgs = @(
        "/generalize",
        "/oobe",
        "/$Action",
        "/unattend:`"$unattendXml`""
    )

    $Logger.Log("Invoking Sysprep with parameters: $($sysprepArgs -join ' ')", "WARN")

    $proc = Start-Process -FilePath $sysprepExe `
                          -ArgumentList $sysprepArgs `
                          -NoNewWindow `
                          -PassThru `
                          -Wait

    if ($proc.ExitCode -ne 0) {
        throw "Sysprep failed with exit code $($proc.ExitCode)"
    }

    $Logger.Log("Sysprep completed successfully with exit code 0.", "NOTICE")

} catch {
    $errMsg = $_.Exception.Message
    $Logger.Log("CRITICAL ERROR in sysprep.ps1: $errMsg", "ERROR")

    # Best-effort error report before halting
    try {
        $Logger.LogException($_, "Fatal failure during Sysprep execution")
        $Logger.Flush()
    } catch {
        # Network may already be disconnected
    }

    throw $_
} finally {
    if ($Logger) { $Logger.Flush() }
}
