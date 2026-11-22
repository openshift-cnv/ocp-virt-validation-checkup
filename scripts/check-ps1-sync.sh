#!/bin/bash
set -euo pipefail

MANIFEST="manifests/windows/golden-image.yaml"
SCRIPT="scripts/windows/setup-golden-image.sh"
RC=0

extract_quoted() {
  local var="$1"
  local val
  val=$(sed -n "s/^${var}=\"\\(.*\\)\"/\\1/p" "$SCRIPT" | head -1)
  if [ -z "$val" ]; then
    echo "ERROR: could not extract ${var} from $SCRIPT" >&2
    exit 1
  fi
  printf '%s' "$val"
}

extract_default() {
  local var="$1"
  local val
  val=$(sed -n "s/^${var}=\"\${${var}:-\\(.*\\)}\"/\\1/p" "$SCRIPT" | head -1)
  if [ -z "$val" ]; then
    echo "ERROR: could not extract default for ${var} from $SCRIPT" >&2
    exit 1
  fi
  printf '%s' "$val"
}

OPENSSH_MSI_URL=$(extract_quoted OPENSSH_MSI_URL)
OPENSSH_MSI_FILENAME=$(extract_quoted OPENSSH_MSI_FILENAME)
OPENSSH_MSI_HASH=$(extract_quoted OPENSSH_MSI_HASH)
OPENSSH_MSI_SERVER_NAME=$(extract_quoted OPENSSH_MSI_SERVER_NAME)
GOLDEN_IMAGE_NAMESPACE=$(extract_default GOLDEN_IMAGE_NAMESPACE)

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
  ' "$SCRIPT" | sed 's/\\\$/$/g; s/\\\\/\\/g' \
    | OPENSSH_MSI_SERVER_NAME="${OPENSSH_MSI_SERVER_NAME}" \
      GOLDEN_IMAGE_NAMESPACE="${GOLDEN_IMAGE_NAMESPACE}" \
      OPENSSH_MSI_FILENAME="${OPENSSH_MSI_FILENAME}" \
      OPENSSH_MSI_URL="${OPENSSH_MSI_URL}" \
      OPENSSH_MSI_HASH="${OPENSSH_MSI_HASH}" \
      python3 -c 'import os, sys
s = sys.stdin.read()
for k in ("OPENSSH_MSI_SERVER_NAME", "GOLDEN_IMAGE_NAMESPACE", "OPENSSH_MSI_FILENAME", "OPENSSH_MSI_URL", "OPENSSH_MSI_HASH"):
    s = s.replace("${" + k + "}", os.environ[k])
sys.stdout.write(s)
')

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
