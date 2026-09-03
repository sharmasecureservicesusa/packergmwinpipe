# Powershell 5.1
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$IngestUrl = $env:LOG_INGEST_URL,

    [Parameter(Mandatory = $false)]
    [string]$IngestKey = $env:LOG_INGEST_KEY,

    [Parameter(Mandatory = $false)]
    [string]$DeploymentId = "win-deploy-$(Get-Date -Format 'yyyyMMdd-HHmm')",

    [Parameter(Mandatory = $false)]
    [Security.SecureString]$AdminPassword = (ConvertTo-SecureString "ChangeMeSecurely123!" -AsPlainText -Force)
)
class DeploymentLogger {
    [string]$Endpoint
    [string]$ApiKey
    [string]$DeploymentId
    [string]$Hostname
    [System.Collections.Generic.List[hashtable]]$Buffer

    DeploymentLogger([string]$endpoint, [string]$apiKey, [string]$deploymentId) {
        $this.Endpoint     = $endpoint
        $this.ApiKey       = $apiKey
        $this.DeploymentId = $deploymentId
        $this.Hostname     = $env:COMPUTERNAME
        $this.Buffer       = [System.Collections.Generic.List[hashtable]]::new()
    }

    # --- Log Overload 1: 1 argument (defaults to INFO, empty data) ---
    [void] Log([string]$message) {
        $this.Log($message, "INFO", @{})
    }

    # --- Log Overload 2: 2 arguments (defaults to empty data) ---
    [void] Log([string]$message, [string]$level) {
        $this.Log($message, $level, @{})
    }

    # --- Log Overload 3: Full implementation (3 arguments) ---
    [void] Log([string]$message, [string]$level, [hashtable]$customData) {
        $timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Write-Host "[$timestamp] [$level] $message" -ForegroundColor $(
            switch ($level) {
                "ERROR"  { [ConsoleColor]::Red }
                "WARN"   { [ConsoleColor]::Yellow }
                "NOTICE" { [ConsoleColor]::Cyan }
                default  { [ConsoleColor]::Gray }
            }
        )

        $entry = @{
            timestamp    = $timestamp
            deploymentId = $this.DeploymentId
            hostname     = $this.Hostname
            level        = $level
            message      = $message
            data         = $customData
        }

        $this.Buffer.Add($entry)

        if ($this.Buffer.Count -ge 25) {
            $this.Flush()
        }
    }

    # --- LogException Overload 1: 1 argument (defaults context message) ---
    [void] LogException([System.Management.Automation.ErrorRecord]$err) {
        $this.LogException($err, "An unhandled exception occurred")
    }

    # --- LogException Overload 2: Full implementation (2 arguments) ---
    [void] LogException([System.Management.Automation.ErrorRecord]$err, [string]$contextMessage) {
        $meta = @{
            ExceptionMessage = $err.Exception.Message
            InvocationInfo   = $err.InvocationInfo.PositionMessage
            ScriptStackTrace = $err.ScriptStackTrace
        }
        $this.Log("$contextMessage - Error: $($err.Exception.Message)", "ERROR", $meta)
    }

    # --- Flush buffered events ---
    [void] Flush() {
        if ($this.Buffer.Count -eq 0 -or [string]::IsNullOrWhiteSpace($this.Endpoint)) { return }

        $payload = $this.Buffer | ConvertTo-Json -Depth 5 -Compress
        $headers = @{
            "Authorization" = "Bearer $($this.ApiKey)"
            "Content-Type"  = "application/json"
        }

        try {
            Invoke-RestMethod -Uri $this.Endpoint `
                              -Method Post `
                              -Headers $headers `
                              -Body $payload `
                              -TimeoutSec 5 `
                              -ErrorAction Stop | Out-Null
            $this.Buffer.Clear()
        } catch {
            Write-Warning "Failed to flush logs to remote endpoint: $($_.Exception.Message)"
        }
    }
}


$logger = [DeploymentLogger]::new($IngestUrl, $IngestKey, $DeploymentId)

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
                $logger.Log("User '$Username' already exists. Skipping creation.", "INFO")
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

$logger.Log("Provisioning initiated on $($OS.Caption) (Build $BuildNumber)", "INFO")
powercfg /setactive SCHEME_MIN 2>$null
Configure-RemoteDesktop -Logger $logger
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
    "Kubernetes.kubectl",
    "HashiCorp.Terraform",
    "Microsoft.AzureCLI",
    "Amazon.AWSCLI",
    "Rclone.Rclone",
    "Bdrive.RcloneView",
    "HashiCorp.Vagrant",
    "HashiCorp.Packer",
    "Anaconda.Anaconda3",
    "Chocolatey.Chocolatey",
    "Microsoft.DSC",
    "Microsoft.Azure.Az"
)

Install-WingetPackages -Packages $commonApps -Logger $logger
try {
    wsl --install --no-distribution
    $logger.Log("WSL base component enabled.", "INFO")
} catch {
    $logger.LogException($_, "WSL installation failed")
}

if ($IsServer) {
    $logger.Log("Executing Server provisioning tasks...", "INFO")
    Install-WindowsFeature -Name Web-Server, Web-App-Dev -IncludeManagementTools -ErrorAction SilentlyContinue
    Install-WindowsFeature -Name RSAT-Feature-Tools-BitLocker -ErrorAction SilentlyContinue
    Get-ScheduledTask -TaskName "ServerManager" -ErrorAction SilentlyContinue | Disable-ScheduledTask

    if ($BuildNumber -ge 26100) {
        $sshKeys = @{
            "launchpadUser" = "sharmasecureusa"
            "githubUser"    = "adminsharmasecureservicescausa"
        }
        Configure-OpenSSH -KeySources $sshKeys -Logger $logger
    }

} elseif ($IsClient) {
    $logger.Log("Executing Client/Workstation provisioning tasks...", "INFO")

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
    Install-WingetPackages -Packages $clientApps -Logger $logger
}

$logger.Log("Deployment script finished successfully.", "NOTICE")
$logger.Flush()
