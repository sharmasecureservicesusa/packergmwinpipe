# Powershell 5.1
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [Security.SecureString]$AdminPassword = $null
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

# Get-DeploymentLogger reads LOG_INGEST_URL / LOG_API_KEY / DEPLOYMENT_ID from the
# environment, which the Packer provisioner_env block injects during the build.
$Logger = Get-DeploymentLogger

function New-LocalAdminUser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$Password,

        [DeploymentLogger]$Logger
    )
    process {
        try {
            $existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
            if (-not $existingUser) {
                $Logger.Log("Creating local user: $Username", "INFO")
                New-LocalUser -Name $Username `
                    -Password $Password `
                    -FullName "Local Service Admin" `
                    -Description "Automated deployment account" `
                    -PasswordNeverExpires -ErrorAction Stop | Out-Null

                Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction Stop
                $Logger.Log("Added '$Username' to Administrators group.", "INFO")
            } else {
                $Logger.Log("User '$Username' already exists. Skipping creation.", "INFO")
            }
        } catch {
            $Logger.LogException($_, "Failed to provision user '$Username'")
        }
    }
}

function Install-WingetPackages {
    param (
        [string[]]$Packages,
        [DeploymentLogger]$Logger
    )
    $Logger.Log("Updating winget sources...", "INFO")
    winget source update --disable-interactivity 2>$null | Out-Null

    foreach ($app in $Packages) {
        $Logger.Log("Installing package: $app", "INFO")
        $proc = Start-Process winget -ArgumentList "install --id $app --scope machine -e --silent --accept-source-agreements --accept-package-agreements" -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            $Logger.Log("Successfully installed $app.", "INFO")
        } else {
            $Logger.Log("Package $app returned non-zero exit code ($($proc.ExitCode)).", "WARN")
        }
    }
}

function Configure-RemoteDesktop {
    param ([DeploymentLogger]$Logger)
    $Logger.Log("Enabling Remote Desktop...", "INFO")
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
}

function Configure-OpenSSH {
    param (
        [hashtable]$KeySources,
        [DeploymentLogger]$Logger
    )
    $Logger.Log("Configuring OpenSSH Server...", "INFO")
    $sshCapability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
    if ($sshCapability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $sshCapability.Name -ErrorAction Stop | Out-Null
    }

    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType Automatic

    $fwRule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $fwRule) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }

    # Retrieve and install public SSH keys
    $allKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($source in $KeySources.GetEnumerator()) {
        $url = switch ($source.Key) {
            "githubUser"    { "https://github.com/$($source.Value).keys" }
            "launchpadUser" { "https://launchpad.net/~$($source.Value)/+sshkeys" }
            default         { $null }
        }

        if ($url) {
            try {
                $keys = (Invoke-RestMethod -Uri $url -UseBasicParsing)
                if ($keys) {
                    $keys.Trim() -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $allKeys.Add($_) }
                }
            } catch {
                $Logger.LogException($_, "Failed to retrieve SSH keys from $url")
            }
        }
    }

    if ($allKeys.Count -gt 0) {
        $sshDir = "$env:ProgramData\ssh"
        if (-not (Test-Path $sshDir)) { New-Item -Path $sshDir -ItemType Directory -Force | Out-Null }
        $authKeysPath = Join-Path -Path $sshDir -ChildPath "administrators_authorized_keys"
        Set-Content -Path $authKeysPath -Value $allKeys -Encoding UTF8

        # Lock down ACLs according to OpenSSH security specifications
        $acl = Get-Acl -Path $authKeysPath
        $acl.SetAccessRuleProtection($true, $false)
        $adminSid  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($adminSid, "FullControl", "Allow")))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, "FullControl", "Allow")))
        Set-Acl -Path $authKeysPath -AclObject $acl
    }

    $pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) { $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe" }
    if (Test-Path $pwshPath) {
        if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) { New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null }
        New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value $pwshPath -PropertyType String -Force | Out-Null
    }
    Restart-Service sshd -ErrorAction SilentlyContinue
}

$OS          = Get-CimInstance Win32_OperatingSystem
$BuildNumber = [int]$OS.BuildNumber
$ProductType = [int]$OS.ProductType
$IsServer    = ($ProductType -ne 1)
$IsClient    = ($ProductType -eq 1)

try {
$Logger.Log("Provisioning initiated on $($OS.Caption) (Build $BuildNumber)", "INFO")
powercfg /setactive SCHEME_MIN 2>$null
Configure-RemoteDesktop -Logger $Logger
$commonApps = @(
    "7zip.7zip",
    "Devolutions.UniGetUI",
    "Microsoft.Sysinternals",
    "Microsoft.VCRedist.2015+.x64",
    "Microsoft.VisualStudioCode",
    "jqlang.jq",
    "BurntSushi.ripgrep.MSVC",
    "junegunn.fzf",
    "Microsoft.Git",
    "GitHub.cli",
    "Microsoft.PowerShell",
    "Microsoft.WindowsTerminal",
    "JanDeDobbeleer.OhMyPosh",
    "Starship.Starship",
    "Microsoft.DotNet.SDK.8",
    "Microsoft.DotNet.SDK.9",
    "Amazon.Corretto.21.JDK",
    "OpenJS.NodeJS.LTS",
    "Python.Python.3.13",
    "GoLang.Go",
    "Kubernetes.kubectl",
    "HashiCorp.Terraform",
    "Microsoft.AzureCLI",
    "Amazon.AWSCLI",
    "Google.Chrome",
    "Mozilla.Firefox",
    "Rclone.Rclone",
    "Bdrive.RcloneView",
    "HashiCorp.Vagrant",
    "HashiCorp.Packer",
    "Anaconda.Anaconda3",
    "Chocolatey.Chocolatey",
    "Microsoft.DSC",
    "Microsoft.Azure.Az"
)

Install-WingetPackages -Packages $commonApps -Logger $Logger
try {
    wsl --install --no-distribution
    $Logger.Log("WSL base component enabled.", "INFO")
} catch {
    $Logger.LogException($_, "WSL installation failed")
}

if ($IsServer) {
    $Logger.Log("Executing Server provisioning tasks...", "INFO")
    Install-WindowsFeature -Name Web-Server, Web-App-Dev -IncludeManagementTools -ErrorAction SilentlyContinue
    Install-WindowsFeature -Name RSAT-Feature-Tools-BitLocker -ErrorAction SilentlyContinue
    Get-ScheduledTask -TaskName "ServerManager" -ErrorAction SilentlyContinue | Disable-ScheduledTask

    if ($BuildNumber -ge 26100) {
        $sshKeys = @{
            "launchpadUser" = "sharmasecureusa"
            "githubUser"    = "adminsharmasecureservicescausa"
        }
        Configure-OpenSSH -KeySources $sshKeys -Logger $Logger
    }

} elseif ($IsClient) {
    $Logger.Log("Executing Client/Workstation provisioning tasks...", "INFO")

    # Target specific optional developer features instead of a blanket enablement
    $clientFeatures = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")
    foreach ($feat in $clientFeatures) {
        Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
    }

    $clientApps = @(
    "Mirantis.Lens",
    "RedHat.Podman-Desktop",
    "dbeaver.dbeaver",
    "JetBrains.Toolbox",
    "GitHub.GitHubDesktop.Beta",
    "GlassWire.GlassWire",
    "JetBrains.PyCharm",
    "JetBrains.DataGrip",
    "JetBrains.WebStorm",
    "JetBrains.Rider",
    "JetBrains.IntelliJ",
    "JetBrains.CLion",
    "Atlassian.Sourcetree",
    "JetBrains.GoLand",
    "JetBrains.PHPStorm",
    "JetBrains.RubyMine",
    "JetBrains.AppCode",
    "JetBrains.ReSharperUltimate",
    "JetBrains.dotUltimate",
    "JetBrains.FleetLauncher.Preview",
    "Google.Chrome",
    "Yandex.Browser",
    "XPFFTQ037JWMHS",
    "Brave.Brave",
    "Vivaldi.Vivaldi",
    "Mozilla.Firefox",
    "Telegram.TelegramDesktop",
    "Termius.Termius",
    "WinMerge.WinMerge",
    "Notepad++.Notepad++",
    "PuTTY.PuTTY",
    "Anysphere.Cursor",
    "VideoLAN.VLC",
    "Daum.PotPlayer",
    "RARLab.WinRAR",
    "qBittorrent.qBittorrent",
    "IrfanSkiljan.IrfanView",
    "XnSoft.XnView.Classic",
    "FastStone.Viewer",
    "ShareX.ShareX",
    "SlackTechnologies.Slack",
    "Notion.Notion",
    "Foxit.FoxitReader",
    "Microsoft.OneDrive",
    "Google.GoogleDrive",
    "Python.PythonInstallManager"
    )
    Install-WingetPackages -Packages $clientApps -Logger $Logger
}

$Logger.Log("Deployment script finished successfully.", "NOTICE")
} finally {
    # Ensure buffered telemetry is shipped even if the script fails mid-way.
    if ($Logger) { $Logger.Flush() }
}
