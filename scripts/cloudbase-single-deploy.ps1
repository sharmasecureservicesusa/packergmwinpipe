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

function Initialize-WinGet {
    param([DeploymentLogger]$Logger)

    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        return
    }
    $Logger.Log('WinGet is unavailable. Bootstrapping Windows Package Manager.', 'WARN')
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force | Out-Null
    Import-Module Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'WinGet bootstrap completed but winget.exe is still unavailable.'
    }
}

function Install-WingetPackage {
    param(
        [string[]]$Packages,
        [DeploymentLogger]$Logger
    )

    $Logger.Log('Updating WinGet sources...', 'INFO')
    winget source update --disable-interactivity --accept-source-agreements 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet source update failed with exit code $LASTEXITCODE."
    }
    foreach ($app in $Packages) {
        $Logger.Log("Installing package: $app", 'INFO')
        $arguments = "install --id $app --scope machine -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements"
        $process = Start-Process winget.exe -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        if ($process.ExitCode -eq 0) {
            $Logger.Log("Successfully installed $app.", 'INFO')
        } else {
            $Logger.Log("Package $app returned exit code $($process.ExitCode).", 'WARN')
        }
    }
}

function Initialize-RemoteDesktop {
    param([DeploymentLogger]$Logger)

    $Logger.Log('Enabling Remote Desktop...', 'INFO')
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
}

function Initialize-OpenSSH {
    param(
        [hashtable]$KeySources,
        [DeploymentLogger]$Logger
    )

    $Logger.Log('Configuring OpenSSH Server...', 'INFO')
    $sshCapability = Get-WindowsCapability -Online | Where-Object Name -Like 'OpenSSH.Server*'
    if ($sshCapability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $sshCapability.Name -ErrorAction Stop | Out-Null
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    if (-not (Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    $allKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($source in $KeySources.GetEnumerator()) {
        $url = switch ($source.Key) {
            githubUser { "https://github.com/$($source.Value).keys" }
            launchpadUser { "https://launchpad.net/~$($source.Value)/+sshkeys" }
            default { $null }
        }
        if ($url) {
            try {
                $keys = Invoke-RestMethod -Uri $url -UseBasicParsing
                if ($keys) {
                    $keys.Trim() -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $allKeys.Add($_) }
                }
            } catch {
                $Logger.LogException($_, "Failed to retrieve SSH keys from $url")
            }
        }
    }
    if ($allKeys.Count -gt 0) {
        $sshDirectory = "$env:ProgramData\ssh"
        New-Item -Path $sshDirectory -ItemType Directory -Force | Out-Null
        $authorizedKeys = Join-Path $sshDirectory administrators_authorized_keys
        Set-Content -Path $authorizedKeys -Value $allKeys -Encoding utf8
        $acl = Get-Acl -Path $authorizedKeys
        $acl.SetAccessRuleProtection($true, $false)
        $administrators = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($administrators, 'FullControl', 'Allow'))
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($system, 'FullControl', 'Allow'))
        Set-Acl -Path $authorizedKeys -AclObject $acl
    }
    $pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) {
        $pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
    }
    if (Test-Path -LiteralPath $pwshPath) {
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $pwshPath -PropertyType String -Force | Out-Null
    }
    Restart-Service sshd
}

$operatingSystem = Get-CimInstance Win32_OperatingSystem
$buildNumber = [int]$operatingSystem.BuildNumber
$isServer = [int]$operatingSystem.ProductType -ne 1

try {
    $Logger.Log("Provisioning initiated on $($operatingSystem.Caption) (Build $buildNumber)", 'INFO')
    powercfg /setactive SCHEME_MIN 2>$null
    Initialize-RemoteDesktop -Logger $Logger
    Initialize-WinGet -Logger $Logger
    $commonApps = @(
        '7zip.7zip',
        'Devolutions.UniGetUI',
        'Microsoft.Sysinternals',
        'Microsoft.VCRedist.2015+.x64',
        'Microsoft.VisualStudioCode',
        'jqlang.jq',
        'BurntSushi.ripgrep.MSVC',
        'junegunn.fzf',
        'Microsoft.Git',
        'GitHub.cli',
        'Microsoft.PowerShell',
        'Microsoft.WindowsTerminal',
        'JanDeDobbeleer.OhMyPosh',
        'Starship.Starship',
        'Microsoft.DotNet.SDK.8',
        'Microsoft.DotNet.SDK.9',
        'Amazon.Corretto.21.JDK',
        'OpenJS.NodeJS.LTS',
        'Python.Python.3.13',
        'GoLang.Go',
        'Kubernetes.kubectl',
        'HashiCorp.Terraform',
        'Microsoft.AzureCLI',
        'Amazon.AWSCLI',
        'Google.Chrome',
        'Mozilla.Firefox',
        'Rclone.Rclone',
        'Bdrive.RcloneView',
        'HashiCorp.Vagrant',
        'HashiCorp.Packer',
        'Anaconda.Anaconda3',
        'Chocolatey.Chocolatey',
        'Microsoft.DSC',
        'Microsoft.Azure.Az'
    )
    Install-WingetPackage -Packages $commonApps -Logger $Logger
    wsl --install --no-distribution
    if ($LASTEXITCODE -eq 0) {
        $Logger.Log('WSL base component enabled.', 'INFO')
    } else {
        $Logger.Log("WSL installation returned exit code $LASTEXITCODE.", 'WARN')
    }
    if ($isServer) {
        $Logger.Log('Executing server provisioning tasks...', 'INFO')
        Install-WindowsFeature -Name Web-Server, Web-App-Dev -IncludeManagementTools -ErrorAction SilentlyContinue
        Install-WindowsFeature -Name RSAT-Feature-Tools-BitLocker -ErrorAction SilentlyContinue
        Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask
        $sshKeys = @{
            launchpadUser = 'sharmasecureusa'
            githubUser = 'adminsharmasecureservicescausa'
        }
        Initialize-OpenSSH -KeySources $sshKeys -Logger $Logger
    } else {
        $Logger.Log('Executing client provisioning tasks...', 'INFO')
        foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
        }
        $clientApps = @(
            'Mirantis.Lens',
            'RedHat.Podman-Desktop',
            'dbeaver.dbeaver',
            'JetBrains.Toolbox',
            'GitHub.GitHubDesktop.Beta',
            'GlassWire.GlassWire',
            'JetBrains.PyCharm',
            'JetBrains.DataGrip',
            'JetBrains.WebStorm',
            'JetBrains.Rider',
            'JetBrains.IntelliJ',
            'JetBrains.CLion',
            'Atlassian.Sourcetree',
            'JetBrains.GoLand',
            'JetBrains.PHPStorm',
            'JetBrains.RubyMine',
            'JetBrains.AppCode',
            'JetBrains.ReSharperUltimate',
            'JetBrains.dotUltimate',
            'JetBrains.FleetLauncher.Preview',
            'Google.Chrome',
            'Yandex.Browser',
            'XPFFTQ037JWMHS',
            'Brave.Brave',
            'Vivaldi.Vivaldi',
            'Mozilla.Firefox',
            'Telegram.TelegramDesktop',
            'Termius.Termius',
            'WinMerge.WinMerge',
            'Notepad++.Notepad++',
            'PuTTY.PuTTY',
            'Anysphere.Cursor',
            'VideoLAN.VLC',
            'Daum.PotPlayer',
            'RARLab.WinRAR',
            'qBittorrent.qBittorrent',
            'IrfanSkiljan.IrfanView',
            'XnSoft.XnView.Classic',
            'FastStone.Viewer',
            'ShareX.ShareX',
            'SlackTechnologies.Slack',
            'Notion.Notion',
            'Foxit.FoxitReader',
            'Microsoft.OneDrive',
            'Google.GoogleDrive',
            'Python.PythonInstallManager'
        )
        Install-WingetPackage -Packages $clientApps -Logger $Logger
    }
    $Logger.Log('Deployment script finished successfully.', 'NOTICE')
} finally {
    if ($Logger) {
        $Logger.Flush()
    }
}
