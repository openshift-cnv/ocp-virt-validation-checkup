#!/bin/bash
set -euo pipefail

MANIFEST="manifests/windows/golden-image.yaml"
SCRIPT="scripts/windows/setup-golden-image.sh"
RC=0

check_block() {
  local block_name="$1"
  local end_pattern="$2"

  local manifest_content
  manifest_content=$(awk -v name="$block_name" -v endpat="$end_pattern" '
    $0 ~ "^  " name ": \\|" {found=1; next}
    found && $0 ~ endpat {exit}
    found {sub(/^    /, ""); print}
  ' "$MANIFEST")

  local script_content
  script_content=$(awk -v name="$block_name" '
    $0 ~ "^  " name ": \\|" {found=1; next}
    found && /^EOF$/ {exit}
    found && $0 ~ "^  [a-zA-Z]" {exit}
    found {sub(/^    /, ""); print}
  ' "$SCRIPT" | sed 's/\\\$/$/g; s/\\\\/\\/g')

  if ! diff <(printf '%s\n' "$manifest_content") <(printf '%s\n' "$script_content") >/dev/null 2>&1; then
    echo "ERROR: $block_name is out of sync between:"
    echo "  - $MANIFEST"
    echo "  - $SCRIPT"
    echo ""
    diff --unified=3 <(printf '%s\n' "$manifest_content") <(printf '%s\n' "$script_content") || true
    echo ""
    RC=1
  else
    echo "OK: $block_name is in sync"
  fi
}

check_block "post-update.ps1" "^---$"
check_block "autounattend.xml" "^  post-update[.]ps1:"

exit $RC
