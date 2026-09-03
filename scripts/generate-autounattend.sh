#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${WINRM_PASSWORD:-}" ]]; then
  echo 'WINRM_PASSWORD is required.' >&2
  exit 1
fi
if [[ "$WINRM_PASSWORD" == *$'\n'* || "$WINRM_PASSWORD" == *$'\r'* ]]; then
  echo 'WINRM_PASSWORD cannot contain line breaks.' >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$script_dir/../build/config/Autounattend.xml.tmpl"
output="$script_dir/../build/config/Autounattend.xml"
WINRM_PASSWORD_XML=$(printf '%s' "$WINRM_PASSWORD" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
export WINRM_PASSWORD_XML
envsubst '${WINRM_PASSWORD_XML}' < "$template" > "$output"
echo "Generated $output"
