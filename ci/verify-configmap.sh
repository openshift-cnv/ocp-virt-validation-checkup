#!/bin/bash
# Verify that a ConfigMap has the required structure and data keys
# Usage: verify-configmap.sh <configmap-name>

set -euo pipefail

# Verify ConfigMap name is provided as parameter
if [ -z "${1:-}" ]; then
  echo "Error: ConfigMap name is required as first parameter"
  echo "Usage: $0 <configmap-name>"
  exit 1
fi

CONFIGMAP_NAME="$1"

# Check if ConfigMap exists
if ! oc get configmap "${CONFIGMAP_NAME}" -n ocp-virt-validation &>/dev/null; then
  echo "Error: ConfigMap '${CONFIGMAP_NAME}' not found"
  exit 1
fi

echo "> ConfigMap '${CONFIGMAP_NAME}' exists"

# Verify required data keys exist
REQUIRED_KEYS=("self-validation-results" "status.completionTimestamp" "status.startTimestamp")
MISSING_KEYS=()

for key in "${REQUIRED_KEYS[@]}"; do
  # Use jq to properly handle keys with dots in their names
  VALUE=$(oc get configmap "${CONFIGMAP_NAME}" -n ocp-virt-validation -o json | jq -r --arg key "${key}" '.data[$key] // empty')
  if [ -z "${VALUE}" ]; then
    MISSING_KEYS+=("${key}")
  fi
done

if [ ${#MISSING_KEYS[@]} -gt 0 ]; then
  echo "Error: ConfigMap '${CONFIGMAP_NAME}' is missing required data keys:"
  for key in "${MISSING_KEYS[@]}"; do
    echo "  - ${key}"
  done
  echo ""
  echo "ConfigMap data keys found:"
  oc get configmap "${CONFIGMAP_NAME}" -n ocp-virt-validation -o jsonpath='{.data}' | jq 'keys'
  exit 1
fi

echo "> ConfigMap '${CONFIGMAP_NAME}' has all required data keys: ${REQUIRED_KEYS[*]}"
