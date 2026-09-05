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
  default     = "windows-server-2025-golden"
}

variable "git_commit" {
  type        = string
  description = "Git commit associated with the image build"
  default     = "local"
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

variable "accelerator" {
  type        = string
  description = "QEMU accelerator: 'kvm' for hardware virtualization, 'tcg' for software emulation"
  default     = "kvm"

  validation {
    condition     = contains(["kvm", "tcg"], var.accelerator)
    error_message = "The accelerator must be either 'kvm' or 'tcg'."
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

variable "winrm_password" {
  type        = string
  description = "Temporary build password (must match build/config/Autounattend.xml)"
  sensitive   = true
}

variable "winrm_timeout" {
  type        = string
  description = "How long to wait for WinRM to become available before failing the build"
  default     = "2h"
}

variable "supplemental_iso" {
  type        = string
  description = "Path to the pre-built supplemental ISO (Autounattend.xml + VirtIO drivers + setup-winrm.ps1)"
}

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
  net_device     = "e1000"
  format         = "qcow2"
  accelerator    = var.accelerator
  headless       = true

  # Windows Server 2025 requires a UEFI (q35) machine with emulated TPM 2.0.
  # Ubuntu 24.04 ships only the 4MB OVMF images, so the plugin defaults
  # (/usr/share/OVMF/OVMF_CODE.fd) do not exist and must be overridden.
  machine_type      = "q35"
  efi_boot          = true
  efi_firmware_code = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  efi_firmware_vars = "/usr/share/OVMF/OVMF_VARS_4M.fd"
  vtpm              = true
  efi_drop_efivars  = true

  boot_wait = "5s"

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = false
  winrm_insecure = true

  # On a q35 machine OVMF can only boot from CD-ROMs on an AHCI bus.
  # Packer's plugin attaches ISOs as plain "-drive media=cdrom" which lands on
  # an implicit ISA-IDE controller invisible to OVMF — causing the
  # "BdsDxe: failed to start DVD-ROM: Time out" failure seen in VNC captures.
  #
  # The fix: build the supplemental ISO ourselves in CI at a known path and pass
  # it via var.supplemental_iso, then use qemuargs to wire both discs onto an
  # explicit ich9-ahci controller that OVMF can enumerate correctly.
  #
  # qemuargs replaces ALL Packer-generated QEMU args, so every device is listed.
  qemuargs = [
    ["-cpu", var.accelerator == "kvm" ? "host" : "max"],
    ["-smp", "${var.cpu_cores},sockets=1,cores=${var.cpu_cores},threads=1"],
    ["-m", "${var.memory_mb}M"],
    ["-machine", "type=q35,accel=${var.accelerator}"],

    # OS disk — virtio-blk
    ["-drive", "file=output-${var.vm_name}/${var.vm_name}-v${var.image_version}.qcow2,if=virtio,cache=writeback,discard=ignore,format=qcow2"],

    # AHCI controller so OVMF can see CD-ROMs on q35
    ["-device", "ich9-ahci,id=ahci"],

    # Windows install ISO → D: in Windows
    ["-drive", "file=${var.iso_url},media=cdrom,if=none,id=cdrom0,readonly=on"],
    ["-device", "ide-cd,bus=ahci.0,drive=cdrom0"],

    # Supplemental ISO (Autounattend + VirtIO drivers + setup-winrm.ps1) → E: in Windows
    ["-drive", "file=${var.supplemental_iso},media=cdrom,if=none,id=cdrom1,readonly=on"],
    ["-device", "ide-cd,bus=ahci.1,drive=cdrom1"],

    # Network with WinRM port-forward
    ["-device", "e1000,netdev=user.0"],
    ["-netdev", "user,id=user.0,hostfwd=tcp::{{.WinRMPort}}-:5985"],

    # OVMF firmware pflash
    ["-drive", "file=/usr/share/OVMF/OVMF_CODE_4M.fd,if=pflash,unit=0,format=raw,readonly=on"],
    ["-drive", "file=output-${var.vm_name}/efivars.fd,if=pflash,unit=1,format=raw"],

    # TPM 2.0 via swtpm socket (started automatically by Packer vtpm=true)
    ["-chardev", "socket,id=vtpm,path=/tmp/{{.BuildName}}/vtpm.sock"],
    ["-tpmdev", "emulator,id=tpm0,chardev=vtpm"],
    ["-device", "tpm-tis,tpmdev=tpm0"],

    ["-vnc", "0.0.0.0:0"],
    ["-name", "${var.vm_name}-v${var.image_version}.qcow2"],
  ]

  vnc_bind_address = "0.0.0.0"
  vnc_port_min     = 5900
  vnc_port_max     = 5900

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer image sealed\""
  shutdown_timeout = "30m"
}

build {
  sources = ["source.qemu.windows"]

  hcp_packer_registry {
    bucket_name = var.vm_name
    description = "Windows Server 2025 golden image built with Packer QEMU"

    bucket_labels = {
      "os"      = "windows"
      "edition" = "server-2025-golden"
      "team"    = "platform"
    }

    build_labels = {
      "image_version" = var.image_version
      "git_commit"    = var.git_commit
    }
  }

  provisioner "powershell" {
    inline = [
      "New-Item -Path 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\Modules\\DeploymentLogger' -ItemType Directory -Force | Out-Null"
    ]
  }

  provisioner "file" {
    source      = "./scripts/modules/DeploymentLogger.psm1"
    destination = "C:/Windows/System32/WindowsPowerShell/v1.0/Modules/DeploymentLogger/DeploymentLogger.psm1"
  }

  provisioner "file" {
    source      = "./build/config"
    destination = "C:/Windows/Temp/"
  }

  provisioner "powershell" {
    timeout = "15m"
    inline = [
      "$installer = 'C:\\Windows\\Temp\\config\\virtio\\virtio-win-gt-x64.msi'",
      "if (-not (Test-Path -LiteralPath $installer)) { throw \"VirtIO installer missing: $installer\" }",
      "$signature = Get-AuthenticodeSignature -FilePath $installer",
      "if ($signature.Status -ne 'Valid') { throw \"VirtIO installer signature is $($signature.Status)\" }",
      "$process = Start-Process msiexec.exe -ArgumentList @('/i', \"`\"$installer`\"\", '/qn', '/norestart', '/l*v', 'C:\\Windows\\Temp\\virtio-install.log') -Wait -PassThru",
      "if ($process.ExitCode -notin @(0, 3010)) { throw \"VirtIO installation failed with exit code $($process.ExitCode)\" }"
    ]
  }

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

  provisioner "powershell" {
    environment_vars = local.provisioner_env
    timeout          = "3h"
    scripts = [
      "./scripts/cloudbase-single-deploy.ps1"
    ]
  }

  provisioner "windows-restart" {
    restart_check_command = "powershell -command \"& {Get-Service -Name winrm}\""
    restart_timeout       = "30m"
  }

  provisioner "powershell" {
    environment_vars = local.provisioner_env
    timeout          = "30m"
    scripts = [
      "./scripts/install-cloudbase-init.ps1",
      "./scripts/configure-cloudbase-init.ps1"
    ]
  }

  provisioner "powershell" {
    inline = [
      "Write-Host '=========================================' -ForegroundColor Cyan",
      "Write-Host ' RUNNING LIVE IN-GUEST SYSTEM CHECKS     ' -ForegroundColor Cyan",
      "Write-Host '=========================================' -ForegroundColor Cyan",
      "$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue",
      "if (-not $sshd -or $sshd.Status -ne 'Running') { throw 'Verification Failed: sshd service is not active.' }",
      "Write-Host '[PASS] OpenSSH service is running.' -ForegroundColor Green",
      "$port22 = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue",
      "if (-not $port22) { throw 'Verification Failed: Port 22 is not listening.' }",
      "Write-Host '[PASS] TCP Port 22 is listening.' -ForegroundColor Green",
      "$cbiDir = 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf'",
      "if (-not (Test-Path \"$cbiDir\\cloudbase-init.conf\")) { throw 'Verification Failed: cloudbase-init.conf missing.' }",
      "if (-not (Test-Path \"$cbiDir\\cloudbase-init-unattend.conf\")) { throw 'Verification Failed: cloudbase-init-unattend.conf missing.' }",
      "Write-Host '[PASS] Cloudbase-Init configuration files validated.' -ForegroundColor Green",
      "$admin = Get-LocalUser -Name Administrator",
      "if (-not $admin.Enabled) { throw 'Verification Failed: Local Administrator is disabled.' }",
      "Write-Host '[PASS] Administrator account is enabled.' -ForegroundColor Green"
    ]
  }

  provisioner "powershell" {
    environment_vars = local.provisioner_env
    timeout          = "30m"
    scripts = [
      "./scripts/sysrep.ps1"
    ]
  }
}
