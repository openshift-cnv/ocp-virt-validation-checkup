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

DRY_RUN_FLAG=""

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

echo "Starting tier2 tests 🧪"

if [ "${DRY_RUN}" == "true" ]; then
  # In dry-run mode, collect tests and generate a proper JUnit XML with all
  # testcase elements -- aligned with how Ginkgo's --ginkgo.dry-run works.
  (set +e; .venv/bin/pytest \
    -m "conformance" \
    -W "ignore::pytest.PytestRemovedIn9Warning" \
    --skip-artifactory-check \
    --latest-rhel \
    --tc=hco_subscription:${SUBSCRIPTION_NAME} \
    --conformance-storage-class=${STORAGE_CLASS} \
    ${STORAGE_CLASS_CONFIG} \
    ${HCP_FLAG} \
    --collect-only -q \
    "${K_ARGS[@]}" \
    2>&1; echo $? > "${ARTIFACTS}/.exit_code") | tee ${ARTIFACTS}/tier2-log.txt &

  TEST_PID=$!
  echo "Tier2 test process started with PID: ${TEST_PID}"
  wait ${TEST_PID} || true

  # Generate JUnit XML from collected test IDs, accounting for TEST_SKIPS
  .venv/bin/python -c "
import subprocess, sys, socket
from xml.etree.ElementTree import Element, SubElement, ElementTree
from datetime import datetime, timezone

log_path = sys.argv[1]
junit_path = sys.argv[2]
skip_entries = sys.argv[3].split('|') if sys.argv[3] else []
focus_entries = sys.argv[4].split('|') if sys.argv[4] else []

# Remove entries that are also in TEST_FOCUS (they were not skipped)
skip_entries = [e for e in skip_entries if e not in focus_entries]

with open(log_path) as f:
    lines = f.readlines()

test_ids = [l.strip() for l in lines if '::' in l and not l.startswith(('=', '-', ' '))]

# Count TEST_SKIPS entries that match real conformance tests (these were
# deselected by -k and don't appear in the collected list above).
skipped_count = 0
if skip_entries:
    result = subprocess.run(
        ['.venv/bin/pytest', '--collect-only', '-q', '-m', 'conformance'],
        capture_output=True, text=True
    )
    all_collected = result.stdout
    matched = [e for e in skip_entries if e in all_collected]
    skipped_count = len(matched)
    if matched:
        print(f'TEST_SKIPS: {skipped_count} test(s) would be skipped: {matched}')

total_tests = len(test_ids) + skipped_count

testsuites = Element('testsuites', name='pytest tests')
ts = SubElement(testsuites, 'testsuite',
    name='pytest',
    errors='0',
    failures='0',
    skipped=str(skipped_count),
    tests=str(total_tests),
    time='0.000',
    timestamp=datetime.now(timezone.utc).isoformat(),
    hostname=socket.gethostname(),
)

for tid in test_ids:
    parts = tid.split('::')
    module = parts[0].replace('/', '.').removesuffix('.py') if parts else ''
    name = parts[-1] if parts else tid
    classname = '.'.join(parts[:-1]).replace('/', '.').removesuffix('.py') if len(parts) > 1 else module
    SubElement(ts, 'testcase', classname=classname, name=name, time='0.000')

tree = ElementTree(testsuites)
tree.write(junit_path, xml_declaration=True, encoding='unicode')
print(f'Generated JUnit XML with {total_tests} test(s) ({len(test_ids)} collected, {skipped_count} skipped via TEST_SKIPS)')
" "${ARTIFACTS}/tier2-log.txt" "${ARTIFACTS}/junit.results.xml" "${TEST_SKIPS:-}" "${TEST_FOCUS:-}"

else
  (set +e; .venv/bin/pytest \
    -m "conformance" \
    -W "ignore::pytest.PytestRemovedIn9Warning" \
    --skip-artifactory-check \
    --latest-rhel \
    --tc=hco_subscription:${SUBSCRIPTION_NAME} \
    --conformance-storage-class=${STORAGE_CLASS} \
    ${STORAGE_CLASS_CONFIG} \
    ${HCP_FLAG} \
    -s -o log_cli=true \
    "${K_ARGS[@]}" \
    --data-collector \
    --data-collector-output-dir=${ARTIFACTS} \
    --pytest-log-file=${ARTIFACTS}/pytest-logs.txt \
    --junitxml="${ARTIFACTS}/junit.results.xml"; echo $? > "${ARTIFACTS}/.exit_code") 2>&1 | tee ${ARTIFACTS}/tier2-log.txt &

  TEST_PID=$!
  echo "Tier2 test process started with PID: ${TEST_PID}"
  wait ${TEST_PID} || true

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
        ts.set('tests', str(int(ts.get('tests', '0')) + len(matched)))
        ts.set('skipped', str(int(ts.get('skipped', '0')) + len(matched)))
    tree.write(junit_path, xml_declaration=True, encoding='unicode')
" "${ARTIFACTS}/junit.results.xml" "${TEST_SKIPS}" "${TEST_FOCUS}"
  fi
fi
