# Windows Golden Image Pipeline

This repository builds a generalized Windows Server 2025 QCOW2 image with Packer and QEMU. GitHub Actions validates Packer, analyzes and tests PowerShell, downloads the Windows ISO from MEGA S4, installs pinned VirtIO drivers, seals the image with Sysprep, publishes the image to S4, and records build metadata in HCP Packer when configured.

## Required Secrets

| Secret | Purpose |
| --- | --- |
| `MEGA_S4_ACCESS_KEY` | S4 access key |
| `MEGA_S4_SECRET_KEY` | S4 secret key |
| `MEGA_S4_ENDPOINT` | S4 endpoint URL |
| `MEGA_S4_BUCKET` | Image destination bucket |
| `WINRM_PASSWORD` | Temporary build-only Administrator password |

## Optional Secrets

| Secret | Purpose |
| --- | --- |
| `CLOUDFLARE_LOG_INGEST_URL` | Deployment telemetry endpoint |
| `LOG_INGEST_KEY` | Deployment telemetry API key |
| `HCP_CLIENT_ID` | HCP service principal client ID |
| `HCP_CLIENT_SECRET` | HCP service principal secret |
| `HCP_ORGANIZATION_ID` | HCP organization ID |
| `HCP_PROJECT_ID` | HCP project ID |

HCP metadata publication is enabled only when `HCP_CLIENT_ID`, `HCP_CLIENT_SECRET`, and `HCP_PROJECT_ID` are all present. The image build continues without HCP when they are absent.

## Pipeline Behavior

Pull requests run Packer validation, PSScriptAnalyzer, and Pester. Changes merged to `main` build and publish `windows-server/latest/image.qcow2`. Semantic version tags such as `v1.2.3` publish both a versioned image and the `latest` pointer, then create a GitHub release. Test-only changes do not start the expensive image build.

Failed builds upload `packer-debug.log` and VNC captures as a seven-day diagnostic artifact. The weekly retention workflow removes versioned S4 image files older than 60 days while preserving `latest`.

## Local Validation

```powershell
$env:HCP_PACKER_REGISTRY = 'OFF'
packer init build/
packer fmt -check -diff build/
packer validate -syntax-only build/
Invoke-ScriptAnalyzer -Path ./scripts -Severity Error,Warning -Recurse
Invoke-Pester ./tests
```

A full local build also requires QEMU, KVM or TCG, `xorriso`, a Windows Server ISO, the pinned VirtIO inputs, and a generated `build/config/Autounattend.xml`.
