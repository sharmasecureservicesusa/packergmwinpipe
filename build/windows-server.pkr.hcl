packer {
  required_version = ">= 1.9.0"

  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
    windows-update = {
      version = ">= 0.16.0"
      source  = "github.com/rgl/windows-update"
    }
  }
}

variable "image_version" {
  type        = string
  description = "Semantic version of the baked image (e.g., 1.0.0)"
  default     = "1.0.0"
}

variable "vm_name" {
  type        = string
  description = "Name of the resulting virtual machine disk image"
  default     = "windows-server-2022-golden"
}

variable "iso_url" {
  type        = string
  description = "Source URL or local path to the Windows Server ISO"
}

variable "iso_checksum" {
  type        = string
  description = "Cryptographic checksum for the ISO (e.g., sha256:...)"
}

variable "cpu_cores" {
  type        = number
  description = "Number of vCPUs allocated during the build"
  default     = 4
}

variable "memory_mb" {
  type        = number
  description = "RAM allocated in MB during the build"
  default     = 8192
}

variable "disk_size" {
  type        = string
  description = "Virtual hard disk size (e.g., 60G)"
  default     = "60G"
}

variable "winrm_username" {
  type        = string
  description = "Bootstrap local administrator username"
  default     = "Administrator"
}

variable "winrm_password" {
  type        = string
  description = "Temporary password configured in Autounattend.xml"
  sensitive   = true
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

source "qemu" "windows" {
  vm_name          = "${var.vm_name}-v${var.image_version}.qcow2"
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  output_directory = "output-${var.vm_name}"

  cpus             = var.cpu_cores
  memory           = var.memory_mb
  disk_size        = var.disk_size
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  format           = "qcow2"
  accelerator      = "kvm"
  headless         = true

  communicator     = "winrm"
  winrm_username   = var.winrm_username
  winrm_password   = var.winrm_password
  winrm_timeout    = "2h"
  winrm_use_ssl    = false
  winrm_insecure   = true

  cd_files = [
    "./build/config/Autounattend.xml"
  ]

  qemuargs = [
    ["-cpu", "host"],
    ["-smp", "${var.cpu_cores},sockets=1,cores=${var.cpu_cores},threads=1"]
  ]
}

build {
  sources = ["source.qemu.windows"]


  provisioner "file" {
    source      = "./scripts/modules"
    destination = "C:/Windows/System32/WindowsPowerShell/v1.0/Modules"
  }

  provisioner "file" {
    source      = "./build/config"
    destination = "C:/Windows/Temp/config"
  }

    provisioner "powershell" {
    environment_vars = [
      "LOG_INGEST_URL=${var.log_ingest_url}",
      "LOG_API_KEY=${var.log_api_key}",
      "DEPLOYMENT_ID=packer-${var.vm_name}-${var.image_version}"
    ]
    scripts = [
      "./scripts/cloudbase-single-deploy.ps1"
    ]
  }

  # ---------------------------------------------------------------------------
  # 3. Handle Any Pending Reboot Demanded by Windows Updates / WinGet
  # ---------------------------------------------------------------------------
  provisioner "windows-restart" {
    restart_check_command = "powershell -command \"& {Get-Service -Name winrm}\""
    restart_timeout       = "15m"
  }

  # ---------------------------------------------------------------------------
  # 4. OpenSSH Server Setup (Port 22 & sshd_config Administrator Fix)
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = [
      "LOG_INGEST_URL=${var.log_ingest_url}",
      "LOG_API_KEY=${var.log_api_key}",
      "DEPLOYMENT_ID=packer-${var.vm_name}-${var.image_version}"
    ]
    scripts = [
      "./scripts/setup-openssh.ps1"
    ]
  }

  # ---------------------------------------------------------------------------
  # 5. Cloudbase-Init Installation & Production Config Injection
  # ---------------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = [
      "LOG_INGEST_URL=${var.log_ingest_url}",
      "LOG_API_KEY=${var.log_api_key}",
      "DEPLOYMENT_ID=packer-${var.vm_name}-${var.image_version}"
    ]
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
    environment_vars = [
      "LOG_INGEST_URL=${var.log_ingest_url}",
      "LOG_API_KEY=${var.log_api_key}",
      "DEPLOYMENT_ID=packer-${var.vm_name}-${var.image_version}"
    ]
    scripts = [
      "./scripts/sysprep.ps1"
    ]
  }
}
