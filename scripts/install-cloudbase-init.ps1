[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'modules/DeploymentLogger.psm1'
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force
} else {
    Import-Module DeploymentLogger -Force
}
$Logger = Get-DeploymentLogger

try {
    $downloadUrl = 'https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi'
    $installer = "$env:TEMP\CloudbaseInitSetup.msi"
    $Logger.Log("Downloading Cloudbase-Init from $downloadUrl...", 'INFO')
    Invoke-WebRequest -Uri $downloadUrl -OutFile $installer -UseBasicParsing
    $signature = Get-AuthenticodeSignature -FilePath $installer
    if ($signature.Status -ne 'Valid') {
        throw "Cloudbase-Init installer signature is $($signature.Status)."
    }
    $Logger.Log('Installing Cloudbase-Init...', 'INFO')
    $arguments = @(
        '/i', "`"$installer`"",
        '/qn',
        '/norestart',
        '/l*v', "`"$env:TEMP\cloudbase-init-msi.log`"",
        'RUN_SERVICE_AS_LOCAL_SYSTEM=1',
        'LOGGINGSERIALPORTNAME=COM1'
    )
    $process = Start-Process msiexec.exe -ArgumentList $arguments -Wait -NoNewWindow -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Cloudbase-Init installation failed with exit code $($process.ExitCode)."
    }
    Set-Service -Name cloudbase-init -StartupType Automatic
    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
    $Logger.Log('Cloudbase-Init installation completed.', 'NOTICE')
} finally {
    if ($Logger) {
        $Logger.Flush()
    }
}
