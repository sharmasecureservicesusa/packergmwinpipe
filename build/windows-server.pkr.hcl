packer {
  required_version = ">= 1.9.0"

  required_plugins {
    qemu = {
      version = "~> 1.1"
      source  = "github.com/hashicorp/qemu"
    }
    windows-update = {
      version = "~> 0.16"
      source  = "github.com/rgl/windows-update"
    }
  }
}

variable "image_version" {
  type        = string
  description = "Semantic version of the baked image (e.g., 1.0.0)"
  default     = "1.0.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.image_version))
    error_message = "The image version must be a semantic version such as 1.0.0."
  }
}

variable "vm_name" {
  type        = string
  description = "Name of the resulting virtual machine disk image"
  default     = "windows-server-2022-golden"
}

variable "iso_url" {
  type        = string
  description = "Source URL or local path to the Windows Server ISO"

  validation {
    condition     = can(regex("^(https?://|file://|\\\\|/|[a-zA-Z]:\\\\).+", var.iso_url))
    error_message = "The iso_url must be an http(s)://, file://, or local filesystem path."
  }
}

variable "iso_checksum" {
  type        = string
  description = "Cryptographic checksum for the ISO (e.g., sha256:...)"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]+:[a-fA-F0-9]+$", var.iso_checksum))
    error_message = "The iso_checksum must be in the form '<type>:<hash>' (e.g., sha256:...)."
  }
}

variable "cpu_cores" {
  type        = number
  description = "Number of vCPUs allocated during the build"
  default     = 4

  validation {
    condition     = var.cpu_cores > 0
    error_message = "The number of CPU cores must be greater than 0."
  }
}

variable "memory_mb" {
  type        = number
  description = "RAM allocated in MB during the build"
  default     = 8192

  validation {
    condition     = var.memory_mb > 0
    error_message = "The memory size in MB must be greater than 0."
  }
}

variable "disk_size" {
  type        = string
  description = "Virtual hard disk size (e.g., 60G)"
  default     = "60G"

  validation {
    condition     = can(regex("^[0-9]+[GM]$", var.disk_size))
    error_message = "The disk size must be a value such as '60G' or '512M'."
  }
}

variable "winrm_username" {
  type        = string
  description = "Bootstrap local administrator username"
  default     = "Administrator"

  validation {
    condition     = length(trimspace(var.winrm_username)) > 0
    error_message = "The WinRM username must not be empty."
  }
}

# Build-time only temporary password. It is baked into build/config/Autounattend.xml
# so the WinRM communicator can connect during the build, then wiped by Sysprep
# during generalization. Override in CI with `-var winrm_password=...` to avoid
# sharing a committed secret.
variable "winrm_password" {
  type        = string
  description = "Temporary build password (must match build/config/Autounattend.xml)"
  default     = "P@ck3r-Build-Temp!2024"
  sensitive   = true
}

variable "winrm_timeout" {
  type        = string
  description = "How long to wait for WinRM to become available before failing the build"
  default     = "2h"
}

# Cloudflare Telemetry Variables
variable "log_ingest_url" {
  type        = string
  description = "Cloudflare Pipelines HTTP ingestion endpoint URL"
  default     = ""
}

variable "log_api_key" {
  type        = string
  description = "Bearer token / API key for Cloudflare Pipelines ingestion"
  default     = ""
  sensitive   = true
}

locals {
  # Shared environment passed to every in-guest PowerShell provisioner.
  provisioner_env = [
    "LOG_INGEST_URL=${var.log_ingest_url}",
    "LOG_API_KEY=${var.log_api_key}",
    "DEPLOYMENT_ID=packer-${var.vm_name}-${var.image_version}"
  ]
}

source "qemu" "windows" {
  vm_name          = "${var.vm_name}-v${var.image_version}.qcow2"
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "output-${var.vm_name}"

  cpus           = var.cpu_cores
  memory         = var.memory_mb
  disk_size      = var.disk_size
  disk_interface = "virtio"
  net_device     = "virtio-net"
  format         = "qcow2"
  accelerator    = "kvm"
  headless       = true

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = var.winrm_timeout
  # Cleartext WinRM (no SSL) is acceptable here because the build runs on an
  # isolated QEMU/KVM virtual network. For shared networks, set winrm_use_ssl = true.
  winrm_use_ssl  = false
  winrm_insecure = true

  # Answer file served from the generated CD (CD root).
  cd_files = [
     "./build/config/Autounattend.xml",
     "./build/config/virtio"
  ]

  # VirtIO storage/network drivers served from a floppy, which Windows Setup mounts
  # as A:\. This matches the A:\virtio driver path referenced in Autounattend.xml.
  floppy_dirs = [
    "./build/config/virtio"
  ]

  qemuargs = [
    ["-cpu", "host"],
    ["-smp", "${var.cpu_cores},sockets=1,cores=${var.cpu_cores},threads=1"]
  ]

  # Headless diagnostics: capture the guest screen over VNC so we can see where
  # Windows Setup stops (disk driver, image selection, OOBE, etc.) instead of
  # guessing while it sits at "Waiting for WinRM".
  vnc_bind_address = "0.0.0.0"
  vnc_port_min     = 5900
  vnc_port_max     = 5900
}

build {
  sources = ["source.qemu.windows"]

  provisioner "file" {
    source      = "./scripts/modules/DeploymentLogger.psm1"
    destination = "C:/Windows/System32/WindowsPowerShell/v1.0/Modules/DeploymentLogger.psm1"
  }

  provisioner "file" {
    source      = "./build/config"
    destination = "C:/Windows/Temp/config"
  }

  # ---------------------------------------------------------------------------
  # 1. Patch the base image before layering software (golden-image best practice).
  # ---------------------------------------------------------------------------
  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$*Preview$*",
      "include:$*Critical$*",
      "include:$*Security$*",
      "include:$*Update$*",
      "include:$*ServicePack$*",
      "include:$*Rollups$*",
      "include:$*Definition$*",
      "include:$*Tools$*",
      "include:$*FeaturePacks$*"
    ]
    restart_timeout = "1h"
  }

  # ---------------------------------------------------------------------------
  # 2. Cloudbase-Init single deploy (telemetry bootstrap).
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = local.provisioner_env
    scripts = [
      "./scripts/cloudbase-single-deploy.ps1"
    ]
  }

  # ---------------------------------------------------------------------------
  # 3. Handle any pending reboot demanded by Windows Updates.
  # ---------------------------------------------------------------------------
  provisioner "windows-restart" {
    restart_check_command = "powershell -command \"& {Get-Service -Name winrm}\""
    restart_timeout       = "15m"
  }

  # ---------------------------------------------------------------------------
  # 4. OpenSSH Server Setup (Port 22 & sshd_config Administrator Fix)
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = local.provisioner_env
    scripts = [
      "./scripts/setup-openssh.ps1"
    ]
  }

  # ---------------------------------------------------------------------------
  # 5. Cloudbase-Init Installation & Production Config Injection
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = local.provisioner_env
    scripts = [
      "./scripts/install-cloudbase-init.ps1",
      "./scripts/configure-cloudbase-init.ps1"
    ]
  }

  # ---------------------------------------------------------------------------
  # 6. Tier 2: Live In-Guest Verification (Fails build if VM is in bad state)
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    inline = [
      "Write-Host '=========================================' -ForegroundColor Cyan",
      "Write-Host ' RUNNING LIVE IN-GUEST SYSTEM CHECKS     ' -ForegroundColor Cyan",
      "Write-Host '=========================================' -ForegroundColor Cyan",

      # Verify OpenSSH Service
      "$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue",
      "if (-not $sshd -or $sshd.Status -ne 'Running') { throw 'Verification Failed: sshd service is not active.' }",
      "Write-Host '[PASS] OpenSSH service is running.' -ForegroundColor Green",

      # Verify Port 22 is listening
      "$port22 = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue",
      "if (-not $port22) { throw 'Verification Failed: Port 22 is not listening.' }",
      "Write-Host '[PASS] TCP Port 22 is listening.' -ForegroundColor Green",

      # Verify Cloudbase-Init Configs
      "$cbiDir = 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf'",
      "if (-not (Test-Path \"$cbiDir\\cloudbase-init.conf\")) { throw 'Verification Failed: cloudbase-init.conf missing.' }",
      "if (-not (Test-Path \"$cbiDir\\cloudbase-init-unattend.conf\")) { throw 'Verification Failed: cloudbase-init-unattend.conf missing.' }",
      "Write-Host '[PASS] Cloudbase-Init configuration files validated.' -ForegroundColor Green",

      # Verify Administrator is active
      "$admin = Get-LocalUser -Name Administrator",
      "if (-not $admin.Enabled) { throw 'Verification Failed: Local Administrator is disabled.' }",
      "Write-Host '[PASS] Administrator account is enabled.' -ForegroundColor Green"
    ]
  }

  # ---------------------------------------------------------------------------
  # 7. Final Generalization: Pre-Sysprep Flush & Sysprep Execution
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = local.provisioner_env
    scripts = [
      "./scripts/sysrep.ps1"
    ]
  }
}
