#!/bin/bash

set -ex

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/funcs.sh"
TEST_KUBEVIRT_SCRIPT="${SCRIPT_DIR}/kubevirt/test-kubevirt.sh"

DRY_RUN_FLAG=""
if [ "${DRY_RUN}" == "true" ]
then
  DRY_RUN_FLAG="--ginkgo.dry-run"
fi
export DRY_RUN_FLAG

create_kubeconfig

REGISTRY_CONFIG=$(mktemp)
oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${REGISTRY_CONFIG}"
VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[0].image}')
KUBEVIRT_TAG=$(oc image info -a ${REGISTRY_CONFIG} ${VIRT_OPERATOR_IMAGE} -o json --filter-by-os=linux/amd64 | jq -r '.config.config.Labels["upstream-version"]')
if [ -z "${KUBEVIRT_TAG}" ]
then
  KUBEVIRT_TAG=$(oc image info -a ${REGISTRY_CONFIG} brew.${VIRT_OPERATOR_IMAGE} -o json --filter-by-os=linux/amd64 | jq -r '.config.config.Labels["upstream-version"]')
fi
if [ -z "${KUBEVIRT_TAG}" ]
then
  echo "Error: could not get kubevirt tag from virt-operator image."
  exit 1
fi
export KUBEVIRT_RELEASE="v${KUBEVIRT_TAG%%-[0-9]*}"

mkdir -p ${RESULTS_DIR}
START_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo ${START_TIMESTAMP} > ${RESULTS_DIR}/startTimestamp

# Start progress watcher in background
echo "Starting progress watcher for multi-suite monitoring..."
progress_watcher --results-dir="${RESULTS_DIR}" &
PROGRESS_WATCHER_PID=$!
echo "Progress watcher started with PID: ${PROGRESS_WATCHER_PID}"

# Function to cleanup progress watcher
cleanup_progress_watcher() {
    if [[ -n "${PROGRESS_WATCHER_PID}" ]] && kill -0 "${PROGRESS_WATCHER_PID}" 2>/dev/null; then
        echo "Stopping progress watcher (PID: ${PROGRESS_WATCHER_PID})..."
        kill "${PROGRESS_WATCHER_PID}" 2>/dev/null || true
        wait "${PROGRESS_WATCHER_PID}" 2>/dev/null || true
        echo "Progress watcher stopped."
    fi
}

# Set trap to cleanup progress watcher on script exit
trap cleanup_progress_watcher EXIT INT TERM

ALLOWED_TEST_SUITES="compute|network|storage|ssp|tier2"
if [[ ! "$TEST_SUITES" =~ ^($ALLOWED_TEST_SUITES)(,($ALLOWED_TEST_SUITES))*$ ]]; then
  echo "Invalid TEST_SUITES format: \"$TEST_SUITES\""
  echo "Allowed values: comma-separated list of [$ALLOWED_TEST_SUITES]"
  exit 1
fi


VALID_SKIP_REGEX='^([a-zA-Z0-9_:|-]+)(\|([a-zA-Z0-9_:|-]+))*$'
if [[ -n "${TEST_SKIPS}" && ! "${TEST_SKIPS}" =~ ${VALID_SKIP_REGEX} ]]; then
  echo "Invalid TEST_SKIPS format: \"${TEST_SKIPS}\""
  echo "Expected: pipe-separated list of test cases"
  exit 1
fi

IFS=',' read -ra SUITES <<< "$TEST_SUITES"

suite_enabled() {
  local target="$1"
  for suite in "${SUITES[@]}"; do
    if [[ "$suite" == "$target" ]]; then
      return 0
    fi
  done
  return 1
}

if [ -z "${STORAGE_CLASS}" ]; then
  STORAGE_CLASS=$(oc get sc -o json | jq -r '[.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true")][0]'.metadata.name)
fi

if [ -z "${STORAGE_CLASS}" ]; then
  echo "Error: No storage class specified with STORAGE_CLASS env var and a default storage class was not found in the cluster"
  exit 1
fi

# Find matching storage configuration file
STORAGE_CONFIG_FILE=""
if [ -n "${STORAGE_CLASS}" ]; then
  echo "Looking for storage configuration file matching storage class: ${STORAGE_CLASS}"
  
  # Search through all JSON files in the storage config directory
  for config_file in "${SCRIPT_DIR}/kubevirt/config/storage"/*.json; do
    if [ -f "$config_file" ]; then
      # Check if any value in the JSON file matches our storage class
      if jq -e --arg storage_class "${STORAGE_CLASS}" '. as $obj | [$obj[]] | any(. == $storage_class)' "$config_file" >/dev/null 2>&1; then
        # Extract just the filename (without path and extension)
        STORAGE_CONFIG_FILE=$(basename "$config_file" .json)
        echo "Found matching storage configuration: ${STORAGE_CONFIG_FILE}"
        break
      fi
    fi
  done
  
  if [ -z "${STORAGE_CONFIG_FILE}" ]; then
    echo "Warning: No storage configuration file found for storage class '${STORAGE_CLASS}'"
    echo "Available storage configurations:"
    ls "${SCRIPT_DIR}/kubevirt/config/storage"/*.json 2>/dev/null | xargs -n1 basename | sed 's/\.json$//' || echo "  None found"
  fi
else
  echo "Warning: No storage class specified or detected"
fi

# Export the storage config file name for use in ginkgo
export STORAGE_CONFIG_FILE

# Handle custom storage capabilities if specified
if [ -n "${STORAGE_CAPABILITIES}" ]; then
  echo "Processing custom storage capabilities: ${STORAGE_CAPABILITIES}"
  
  # Define valid storage capabilities
  valid_capabilities=("storageClassRhel" "storageClassWindows" "storageRWXBlock" "storageRWXFileSystem" "storageRWOFileSystem" "storageRWOBlock" "storageSnapshot" "onlineResize" "WFFC")
  
  # Validate STORAGE_CAPABILITIES format and content
  IFS=',' read -ra capabilities_array <<< "${STORAGE_CAPABILITIES}"
  for capability in "${capabilities_array[@]}"; do
    # Trim whitespace
    capability=$(echo "$capability" | xargs)
    
    # Check if capability is valid
    valid=false
    for valid_cap in "${valid_capabilities[@]}"; do
      if [ "$capability" = "$valid_cap" ]; then
        valid=true
        break
      fi
    done
    
    if [ "$valid" = false ]; then
      echo "Error: Invalid storage capability '${capability}' in STORAGE_CAPABILITIES"
      echo "Valid capabilities are: ${valid_capabilities[*]}"
      exit 1
    fi
  done
  
  # Ensure we have a storage class for the custom configuration
  if [ -z "${STORAGE_CLASS}" ]; then
    echo "Error: STORAGE_CLASS must be set when using STORAGE_CAPABILITIES"
    exit 1
  fi
  
  # Create custom storage configuration file in writable results directory
  custom_config_file="${RESULTS_DIR}/custom-storage-config.json"
  echo "Creating custom storage configuration: ${custom_config_file}"
  
  # Build JSON object with specified capabilities
  json_content="{"
  first=true
  for capability in "${capabilities_array[@]}"; do
    # Trim whitespace
    capability=$(echo "$capability" | xargs)
    
    if [ "$first" = true ]; then
      first=false
    else
      json_content="${json_content},"
    fi
    json_content="${json_content}\"${capability}\": \"${STORAGE_CLASS}\""
  done
  json_content="${json_content}}"
  
  # Write the custom configuration file
  echo "$json_content" | jq '.' > "$custom_config_file"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to create custom storage configuration file"
    exit 1
  fi
  
  # Use the custom configuration
  export KUBEVIRT_STORAGE_CONFIGURATION_FILE="$(basename "$custom_config_file")"
  echo "Custom storage configuration created and will be used: ${KUBEVIRT_STORAGE_CONFIGURATION_FILE}"
  echo "Configuration content:"
  cat "$custom_config_file"
  
else
  # Use existing logic for predefined storage configurations
  # Also export in a format similar to KUBEVIRT_TESTING_CONFIGURATION_FILE for consistency
  if [ -n "${STORAGE_CONFIG_FILE}" ]; then
    export KUBEVIRT_STORAGE_CONFIGURATION_FILE="${STORAGE_CONFIG_FILE}.json"
    echo "Storage configuration will use: ${KUBEVIRT_STORAGE_CONFIGURATION_FILE}"
  else
    # Clear the variable if no storage config file was found
    unset KUBEVIRT_STORAGE_CONFIGURATION_FILE
  fi
fi


# =======
# compute
# =======
if suite_enabled "compute"; then
  echo "Running KubeVirt test suite..."
  SIG="compute" "${TEST_KUBEVIRT_SCRIPT}"
  echo "KubeVirt test suite has finished."
else
  echo "KubeVirt test suite has been skipped."
fi


# =======
# Network
# =======
if suite_enabled "network"; then
  echo "Running Network test suite..."
  SIG="network" "${TEST_KUBEVIRT_SCRIPT}"
  echo "Network test suite has finished."
else
  echo "Network test suite has been skipped."
fi


# =======
# Storage
# =======
if suite_enabled "storage"; then
  echo "Running Storage test suite..."
  SIG="storage" "${TEST_KUBEVIRT_SCRIPT}"
  echo "Storage test suite has finished."
else
  echo "Storage test suite has been skipped."
fi


# ====
# SSP
# ====
if suite_enabled "ssp"; then
  echo "Running SSP test suite..."
  ${SCRIPT_DIR}/ssp/test-ssp.sh
else
  echo "SSP test suite has been skipped."
fi


# =======
# Tier-2
# =======
if suite_enabled "tier2"; then
  echo "Running Tier-2 (openshift-virtualization-tests) test suite..."
  ${SCRIPT_DIR}/tier2/test-tier2.sh
  echo "Tier-2 test suite has finished."
else
  echo "Tier-2 test suite has been skipped."
fi


COMPLETION_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo ${COMPLETION_TIMESTAMP} > ${RESULTS_DIR}/completionTimestamp

# =========
# Summarize
# =========
junit_parser --results-dir=${RESULTS_DIR}  --start-timestamp=${START_TIMESTAMP} --completion-timestamp=${COMPLETION_TIMESTAMP} | tee ${RESULTS_DIR}/summary-log.txt

# Archive test results into tar.gz
tar -czf /tmp/test-results-${TIMESTAMP}.tar.gz -C ${RESULTS_DIR} .
mv /tmp/test-results-${TIMESTAMP}.tar.gz ${RESULTS_DIR}/test-results-${TIMESTAMP}.tar.gz

echo "Self Validation test run is done."