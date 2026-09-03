[CmdletBinding()]
param(
    [string]$DownloadUrl = "https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host "Downloading Cloudbase-Init from $DownloadUrl..." -ForegroundColor Cyan
$msiFile = "$env:TEMP\CloudbaseInitSetup.msi"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $msiFile -UseBasicParsing

Write-Host "Installing Cloudbase-Init silently..." -ForegroundColor Cyan
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
    throw "MSI installation failed with exit code $($proc.ExitCode)"
}

# Ensure the service is set to start automatically on the next boot
Set-Service -Name "cloudbase-init" -StartupType Automatic [source: 4]

# Clean up installer artifact
Remove-Item -Path $msiFile -Force -ErrorAction SilentlyContinue

Write-Host "Cloudbase-Init installation and service configuration complete." -ForegroundColor Green
