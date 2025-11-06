#!/bin/bash

set -e

function cleanup_test_namespaces() {
    echo "Cleaning up tier2 test namespaces..."
    for ns in cnv-tests-run-in-progress-ns cnv-tests-utilities; do
        if oc get namespace "$ns" &>/dev/null; then
            echo "Deleting namespace: $ns"
            oc delete namespace "$ns" --ignore-not-found=true
        fi
    done
    echo "Tier2 test namespaces deletion initiated"
}

function cleanup_and_exit() {
    echo "Tier2 script interrupted, cleaning up..."
    
    # Terminate the test process gracefully if it's running
    if [ -n "${TEST_PID}" ] && kill -0 "${TEST_PID}" 2>/dev/null; then
        echo "Sending SIGTERM to tier2 test process (PID: ${TEST_PID})..."
        kill -TERM "${TEST_PID}" 2>/dev/null || true
        echo "Waiting for tier2 test process to terminate..."
        wait "${TEST_PID}" 2>/dev/null || true
        echo "Tier2 test process terminated."
    fi
    
    cleanup_test_namespaces
    exit 1
}

# Set up signal traps for cleanup EARLY
trap cleanup_and_exit SIGINT SIGTERM

cd /openshift-virtualization-tests

# Check if uv binaries already exist to avoid re-extraction
if [ ! -f "./uv" ] || [ ! -f "./uvx" ]; then
    echo "Extracting uv binaries..."
    oc image extract ghcr.io/astral-sh/uv:latest --file /uv,/uvx
    chmod +x uv uvx
else
    echo "uv binaries already exist, skipping extraction"
fi

./uv sync --locked
./uv export --no-hashes

export ARTIFACTS=${RESULTS_DIR}/tier2
mkdir -p "${ARTIFACTS}"


SUBSCRIPTION_NAME=$(oc get subs -n openshift-cnv -l operators.coreos.com/kubevirt-hyperconverged.openshift-cnv= -o json | jq -r '.items[0].metadata.name')

DEFAULT_STORAGE_CLASS=$(oc get sc -o json | jq -r '[.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true")][0]'.metadata.name)
if [ -z "${STORAGE_CLASS}" ]; then
  STORAGE_CLASS=${DEFAULT_STORAGE_CLASS}
fi

if [ -n "${STORAGE_CAPABILITIES}" ]; then
  # Parse storage capabilities and determine volume_mode, access_mode, and additional properties
  # Priority order: storageRWXBlock > storageRWXFileSystem > storageRWOBlock > storageRWOFileSystem

  IFS=',' read -ra capabilities_array <<< "${STORAGE_CAPABILITIES}"
  volume_mode=""
  access_mode=""
  snapshot=""
  online_resize=""
  wffc=""

  for capability in "${capabilities_array[@]}"; do
    capability=$(echo "$capability" | xargs)  # Trim whitespace

    case "$capability" in
      "storageRWXBlock")
        volume_mode="Block"
        access_mode="RWX"
        break  # Highest priority, stop checking
        ;;
      "storageRWXFileSystem")
        if [ -z "$volume_mode" ]; then
          volume_mode="Filesystem"
          access_mode="RWX"
        fi
        ;;
      "storageRWOBlock")
        if [ -z "$volume_mode" ]; then
          volume_mode="Block"
          access_mode="RWO"
        fi
        ;;
      "storageRWOFileSystem")
        if [ -z "$volume_mode" ]; then
          volume_mode="Filesystem"
          access_mode="RWO"
        fi
        ;;
    esac
  done

  # Check for additional capabilities (can be combined with volume/access mode)
  for capability in "${capabilities_array[@]}"; do
    capability=$(echo "$capability" | xargs)  # Trim whitespace

    case "$capability" in
      "storageSnapshot")
        snapshot="True"
        ;;
      "onlineResize")
        online_resize="True"
        ;;
      "WFFC")
        wffc="True"
        ;;
    esac
  done

  # Build the configuration string
  config_parts=""
  if [ -n "$volume_mode" ] && [ -n "$access_mode" ]; then
    config_parts="volume_mode=${volume_mode},access_mode=${access_mode}"
  fi

  # Add additional properties if present
  if [ -n "$snapshot" ]; then
    if [ -n "$config_parts" ]; then
      config_parts="${config_parts},snapshot=${snapshot}"
    else
      config_parts="snapshot=${snapshot}"
    fi
  fi

  if [ -n "$online_resize" ]; then
    if [ -n "$config_parts" ]; then
      config_parts="${config_parts},online_resize=${online_resize}"
    else
      config_parts="online_resize=${online_resize}"
    fi
  fi

  if [ -n "$wffc" ]; then
    if [ -n "$config_parts" ]; then
      config_parts="${config_parts},wffc=${wffc}"
    else
      config_parts="wffc=${wffc}"
    fi
  fi

  # Set the final configuration
  if [ -n "$config_parts" ]; then
    STORAGE_CLASS_CONFIG="--conformance-storage-class-config=${config_parts}"
  else
    STORAGE_CLASS_CONFIG=""
  fi
else
  STORAGE_CLASS_CONFIG=""
fi

if [ "${DRY_RUN}" == "true" ]
then
  DRY_RUN_FLAG="--collect-only"
else
  DRY_RUN_FLAG=""
fi

export OPENSHIFT_PYTHON_WRAPPER_LOG_FILE=${ARTIFACTS}/ocp-wrapper-log.txt

echo "Starting tier2 tests 🧪"
./uv run pytest \
  -m "conformance" \
  --skip-artifactory-check \
  --tc=hco_subscription:${SUBSCRIPTION_NAME} \
  --conformance-storage-class=${STORAGE_CLASS} \
  ${STORAGE_CLASS_CONFIG} \
  -s -o log_cli=true \
  ${DRY_RUN_FLAG} \
  --data-collector \
  --data-collector-output-dir=${ARTIFACTS} \
  --pytest-log-file=${ARTIFACTS}/pytest-logs.txt \
  --junitxml="${ARTIFACTS}/junit.results.xml" 2>&1 | tee ${ARTIFACTS}/tier2-log.txt &

# Store the PID for cleanup
TEST_PID=$!
echo "Tier2 test process started with PID: ${TEST_PID}"

# Wait for the test to complete
wait ${TEST_PID} || true
