$cbiConfDir = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"

# Copy both configs from your Packer build directory into Cloudbase-Init
Copy-Item -Path ".\build\config\cloudbase-init.conf" `
          -Destination "$cbiConfDir\cloudbase-init.conf" `
          -Force

Copy-Item -Path ".\build\config\cloudbase-init-unattend.conf" `
          -Destination "$cbiConfDir\cloudbase-init-unattend.conf" `
          -Force

Write-Host "Both Cloudbase-Init configurations placed successfully." -ForegroundColor Green
