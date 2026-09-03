[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
$DownloadUrl = "https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$Logger.Log("Downloading Cloudbase-Init from $DownloadUrl...", "INFO")

$msiFile = "$env:TEMP\CloudbaseInitSetup.msi"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $msiFile -UseBasicParsing

$Logger.Log("Installing Cloudbase-Init silently...", "INFO")
$installArgs = @(
    "/i", "`"$msiFile`"",
    "/qn",
    "/norestart",
    "/l*v", "`"$env:TEMP\cloudbase-init-msi.log`"",
    "RUN_SERVICE_AS_LOCAL_SYSTEM=1",
    "LOGGINGSERIALPORTNAME=COM1"
)

$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -NoNewWindow -PassThru

if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    $Logger.Log("MSI installation failed with exit code $($proc.ExitCode)", "ERROR")
    throw "MSI installation failed with exit code $($proc.ExitCode)"
}

# Ensure the service is set to start automatically on the next boot
Set-Service -Name "cloudbase-init" -StartupType Automatic

# Clean up installer artifact
Remove-Item -Path $msiFile -Force -ErrorAction SilentlyContinue

$Logger.Log("Cloudbase-Init installation and service configuration complete.", "NOTICE")
} finally {
    # Ensure buffered telemetry is shipped even if the script fails mid-way.
    if ($Logger) { $Logger.Flush() }
}
