#!/usr/bin/env bash
# Renders build/config/Autounattend.xml.tmpl into build/config/Autounattend.xml,
# substituting the WinRM password. The rendered file is gitignored (never committed).
#
# Usage: WINRM_PASSWORD='...' ./scripts/generate-autounattend.sh
set -euo pipefail

if [ -z "${WINRM_PASSWORD:-}" ]; then
  echo "ERROR: WINRM_PASSWORD is not set." >&2
  echo "Usage: WINRM_PASSWORD='<password>' $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../build/config/Autounattend.xml.tmpl"
OUTPUT="${SCRIPT_DIR}/../build/config/Autounattend.xml"

export WINRM_PASSWORD
envsubst < "$TEMPLATE" > "$OUTPUT"
echo "Generated $OUTPUT"
