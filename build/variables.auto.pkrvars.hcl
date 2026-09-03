# Auto-loaded Packer variables for this project.
#
# Required inputs (NO defaults in the template) MUST be supplied here or via
# `-var` / CI. Provide real values before running `packer build`.
#
# iso_url      = "file:///path/to/Windows_Server_2022.iso"  # or https://...
# iso_checksum = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
#
# winrm_password is optional here: the template defaults it (build-time only,
# removed by Sysprep) and it must match build/config/Autounattend.xml. Override
# with a secret in CI instead of committing a value:
#
# winrm_password = "your-strong-temp-password"
