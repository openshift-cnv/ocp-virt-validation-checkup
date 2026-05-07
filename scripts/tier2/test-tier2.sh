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

# Check if cluster is running on hosted control plane
CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}' 2>/dev/null || echo "")
if [ "${CONTROL_PLANE_TOPOLOGY}" == "External" ]; then
  echo "Detected hosted control plane (External topology), adding --tc=no_unprivileged_client:True"
  HCP_FLAG="--tc=no_unprivileged_client:True"
else
  HCP_FLAG=""
fi

export OPENSHIFT_PYTHON_WRAPPER_LOG_FILE=${ARTIFACTS}/ocp-wrapper-log.txt

grep -A 3 "oc image" utilities/virt.py

K_EXPR=""

if [ -n "${TEST_FOCUS}" ] && [ -n "${TEST_SKIPS}" ]; then
  IFS='|' read -ra focus_entries <<< "${TEST_FOCUS}"
  IFS='|' read -ra skip_entries <<< "${TEST_SKIPS}"
  filtered_skips=()
  for s in "${skip_entries[@]}"; do
    overlap=false
    for f in "${focus_entries[@]}"; do
      if [[ "${s}" == "${f}" ]]; then
        echo "WARNING: '${f}' is in both TEST_FOCUS and TEST_SKIPS. TEST_FOCUS takes precedence; test will run."
        overlap=true
        break
      fi
    done
    if [ "${overlap}" = false ]; then
      filtered_skips+=("${s}")
    fi
  done

  focus_expr="$(echo "${TEST_FOCUS}" | sed 's/|/ or /g')"
  if [ ${#filtered_skips[@]} -gt 0 ]; then
    skip_expr="$(IFS='|'; echo "${filtered_skips[*]}" | sed 's/|/ or /g')"
    K_EXPR="(${focus_expr}) and not (${skip_expr})"
  else
    K_EXPR="${focus_expr}"
  fi
elif [ -n "${TEST_FOCUS}" ]; then
  K_EXPR="$(echo "${TEST_FOCUS}" | sed 's/|/ or /g')"
elif [ -n "${TEST_SKIPS}" ]; then
  K_EXPR="not ($(echo "${TEST_SKIPS}" | sed 's/|/ or /g'))"
fi

K_ARGS=()
if [ -n "${K_EXPR}" ]; then
  K_ARGS=(-k "${K_EXPR}")
fi

# Build pytest marker expression
# Note: Windows tests require @pytest.mark.windows marker in openshift-virtualization-tests
# When Windows tests are added with this marker, they will be automatically included
# when ACCEPT_WINDOWS_EULA=true
MARKERS="conformance"
if [ "${ACCEPT_WINDOWS_EULA}" == "true" ]; then
  echo "Windows EULA accepted - Windows tests will be included when available"
  MARKERS="${MARKERS} or windows"
fi

echo "Starting tier2 tests 🧪"
echo "Using markers: ${MARKERS}"

(set +e; .venv/bin/pytest \
  -m "${MARKERS}" \
  -W "ignore::pytest.PytestRemovedIn9Warning" \
  --skip-artifactory-check \
  --latest-rhel \
  --tc=hco_subscription:${SUBSCRIPTION_NAME} \
  --conformance-storage-class=${STORAGE_CLASS} \
  ${STORAGE_CLASS_CONFIG} \
  ${HCP_FLAG} \
  -s -o log_cli=true \
  ${DRY_RUN_FLAG} \
  "${K_ARGS[@]}" \
  --data-collector \
  --data-collector-output-dir=${ARTIFACTS} \
  --pytest-log-file=${ARTIFACTS}/pytest-logs.txt \
  --junitxml="${ARTIFACTS}/junit.results.xml"; echo $? > "${ARTIFACTS}/.exit_code") 2>&1 | tee ${ARTIFACTS}/tier2-log.txt &

# Store the PID for cleanup
TEST_PID=$!
echo "Tier2 test process started with PID: ${TEST_PID}"

# Wait for the test to complete
wait ${TEST_PID} || true

# Run local Windows tests if EULA is accepted
if [ "${ACCEPT_WINDOWS_EULA}" == "true" ]; then
  echo ""
  echo "=== Running local Windows VM tests ==="
  SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
  if [ -d "${SCRIPT_DIR}/tests" ]; then
    (set +e; .venv/bin/pytest \
      "${SCRIPT_DIR}/tests" \
      -m "windows" \
      -v \
      --junitxml="${ARTIFACTS}/junit.windows.xml" \
      -s -o log_cli=true; echo $? > "${ARTIFACTS}/.windows_exit_code") 2>&1 | tee -a ${ARTIFACTS}/tier2-log.txt
    
    WINDOWS_EXIT_CODE=$(cat "${ARTIFACTS}/.windows_exit_code" 2>/dev/null || echo "1")
    if [ "${WINDOWS_EXIT_CODE}" == "0" ]; then
      echo "Windows tests PASSED!"
    else
      echo "Windows tests had failures (exit code: ${WINDOWS_EXIT_CODE})"
    fi
  else
    echo "No local Windows tests found in ${SCRIPT_DIR}/tests"
  fi
fi

# Add manually deselected tests (via TEST_SKIPS) to the JUnit XML skipped count,
# since pytest -k deselection omits them from the report entirely.
# Only count entries that match real conformance test names.
# Exclude any entries that also appear in TEST_FOCUS (those were not skipped).
if [ -n "${TEST_SKIPS}" ]; then
  .venv/bin/python -c "
import subprocess, sys, xml.etree.ElementTree as ET

junit_path = sys.argv[1]
skip_entries = sys.argv[2].split('|')
focus_entries = sys.argv[3].split('|') if sys.argv[3] else []

# Remove entries that are also in TEST_FOCUS (they were not skipped)
skip_entries = [e for e in skip_entries if e not in focus_entries]

# Collect all conformance test node IDs (without running them)
result = subprocess.run(
    ['.venv/bin/pytest', '--collect-only', '-q', '-m', 'conformance'],
    capture_output=True, text=True
)
collected = result.stdout

matched = [e for e in skip_entries if e in collected]
skipped_names = ', '.join(matched) if matched else '(none)'
ignored = [e for e in skip_entries if e not in collected]
if ignored:
    print(f'TEST_SKIPS entries not matching any conformance test (ignored): {ignored}')
print(f'Matched {len(matched)} real test(s) to mark as skipped: {skipped_names}')

if matched:
    tree = ET.parse(junit_path)
    for ts in tree.iter('testsuite'):
        ts.set('skipped', str(int(ts.get('skipped', '0')) + len(matched)))
    tree.write(junit_path, xml_declaration=True, encoding='unicode')
" "${ARTIFACTS}/junit.results.xml" "${TEST_SKIPS}" "${TEST_FOCUS}"
fi
