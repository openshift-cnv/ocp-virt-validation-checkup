#!/bin/bash

set -e

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/../funcs.sh"
source "${SCRIPT_DIR}/../test-suites.sh"

# Prefer selection resolved by entrypoint; otherwise resolve from TEST_SUITES.
if [[ -z "${RESOLVED_TIER2_SUITES:-}" ]]; then
  resolve_test_suites "${TEST_SUITES:-tier2}" || exit 1
fi
TIER2_ALL_MODULES="${TIER2_ALL_MODULES:-false}"

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
        local i
        for i in $(seq 1 10); do
            kill -0 "${TEST_PID}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${TEST_PID}" 2>/dev/null; then
            echo "Process did not exit after SIGTERM — sending SIGKILL."
            kill -KILL "${TEST_PID}" 2>/dev/null || true
        fi
        wait "${TEST_PID}" 2>/dev/null || true
        echo "Tier2 test process terminated."
    fi
    
    cleanup_test_namespaces
    exit 1
}

function wait_for_pytest_pipeline() {
    local pid=$1
    local exit_code_file=$2

    while kill -0 "${pid}" 2>/dev/null; do
        if [ -f "${exit_code_file}" ]; then
            sleep 5
            if kill -0 "${pid}" 2>/dev/null; then
                echo "pytest finished but pipeline still running (likely orphaned child process holding pipe open) — sending SIGTERM."
                kill "${pid}" 2>/dev/null || true
                local i
                for i in $(seq 1 10); do
                    kill -0 "${pid}" 2>/dev/null || break
                    sleep 1
                done
                if kill -0 "${pid}" 2>/dev/null; then
                    echo "Pipeline did not exit after SIGTERM — sending SIGKILL."
                    kill -KILL "${pid}" 2>/dev/null || true
                fi
            fi
            break
        fi
        sleep 5
    done
    wait "${pid}" 2>/dev/null || true
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

WINDOWS_REQUESTED=false
if tier2_sig_enabled "windows"; then
  WINDOWS_REQUESTED=true
fi

# Runs tests matching @pytest.mark.conformance; when Windows is not selected or
# no golden image is available, tests with @pytest.mark.windows are excluded.
# A golden image is available when either:
# - ACCEPT_WINDOWS_EULA=true (tool creates golden image), or
# - A user-provided (BYOI) DataSource exists and is Ready
# A tool-labeled DataSource (app=ocp-virt-validation) without ACCEPT_WINDOWS_EULA
# is treated as stale from a previous run and cleaned up, not reused as BYOI.
MARKERS="conformance"
WIN_IMAGE_FLAG=""
GOLDEN_IMAGE_NAMESPACE="${GOLDEN_IMAGE_NAMESPACE:-validation-os-images}"
GOLDEN_IMAGE_NAME="${GOLDEN_IMAGE_NAME:-win2k22}"
DS_READY="$(oc get datasource "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
DS_LABEL="$(oc get datasource "${GOLDEN_IMAGE_NAME}" -n "${GOLDEN_IMAGE_NAMESPACE}" \
  -o jsonpath='{.metadata.labels.app}' 2>/dev/null || true)"
if [ "${DS_LABEL}" == "ocp-virt-validation" ] && [ "${ACCEPT_WINDOWS_EULA}" != "true" ]; then
  echo "WARNING: Found stale tool-managed DataSource from a previous run. Cleaning up..."
  cleanup_golden_image_resources "${GOLDEN_IMAGE_NAMESPACE}" selective
  DS_READY=""
fi

# Generate OS login configuration.
# When --skip-artifactory-check is passed (always in self-validation),
# py_config["os_login_param"] is never populated by the test session hook.
# Fedora VMs that are cloned need these credentials because the target VM
# already exists and set_login_params() cannot generate fresh random creds.
# Windows credentials are appended when a golden image is available.
OS_LOGIN_CONFIG="${ARTIFACTS}/os_login_config.py"

cat > "${OS_LOGIN_CONFIG}" <<'PYEOF'
os_login_param = {
    "fedora": {
        "username": "fedora",
        "password": "fedora",
    },
    "rhel": {
        "username": "cloud-user",
        "password": "redhat",
    },
}
PYEOF

# Image is usable when:
# - EULA tool-managed path is active (setup already ran, or dry-run discovery), or
# - BYOI DataSource is Ready and not a stale tool-managed leftover.
WINDOWS_IMAGE_AVAILABLE=false
if [ "${ACCEPT_WINDOWS_EULA}" == "true" ]; then
  WINDOWS_IMAGE_AVAILABLE=true
elif [ "${DS_READY}" == "True" ] && [ "${DS_LABEL}" != "ocp-virt-validation" ]; then
  WINDOWS_IMAGE_AVAILABLE=true
fi

WINDOWS_WILL_RUN=false
TIER2_SPLIT_WINDOWS=false
if [ "${WINDOWS_REQUESTED}" == "true" ] && [ "${WINDOWS_IMAGE_AVAILABLE}" == "true" ]; then
  WINDOWS_WILL_RUN=true
  echo "Windows golden image available - Windows tests will be included"
  cat >> "${OS_LOGIN_CONFIG}" <<'PYEOF'
os_login_param["win-container-disk"] = {
    "username": "Administrator",
    "password": "Administrator",
}
PYEOF
  WIN_IMAGE_FLAG="--tc=win_golden_image_name:${GOLDEN_IMAGE_NAME}"
elif [ "${WINDOWS_REQUESTED}" == "true" ] && [ "${WINDOWS_IMAGE_AVAILABLE}" != "true" ]; then
  if tier2_windows_only; then
    # Explicit Windows-only request with no image must not report a green empty run.
    if [ "${DRY_RUN}" == "true" ]; then
      echo "WARNING: tier2/windows selected but no golden image is available (dry-run)."
      MARKERS="conformance and windows"
    else
      echo "ERROR: tier2/windows selected but no golden image is available."
      echo "Provide a Ready BYOI DataSource or set ACCEPT_WINDOWS_EULA=true."
      echo 1 > "${ARTIFACTS}/.exit_code"
      exit 1
    fi
  else
    echo "WARNING: tier2/windows selected but no golden image is available; Windows tests will be skipped"
    MARKERS="conformance and not windows"
  fi
else
  # Windows not selected — exclude even if a golden image happens to exist.
  MARKERS="conformance and not windows"
fi

# Path SIGs map to OVT module directories. Mixed path+Windows keeps these paths for
# the non-Windows phase and runs Windows cross-module in a second phase.
build_tier2_path_args

if [ "${WINDOWS_WILL_RUN}" == "true" ]; then
  if tier2_windows_only; then
    MARKERS="conformance and windows"
  elif [[ ${#TIER2_PATH_ARGS[@]} -gt 0 ]]; then
    # Keep path scope for non-Windows; Windows runs separately across modules.
    MARKERS="conformance and not windows"
    TIER2_SPLIT_WINDOWS=true
    echo "Mixed path + Windows selection: path-scoped non-Windows, then cross-module Windows"
  else
    # Legacy / unrestricted Tier-2 with Windows available.
    MARKERS="conformance"
  fi
fi

cat >> "${OS_LOGIN_CONFIG}" <<'PYEOF'

config = globals().get("config") or {}
config["os_login_param"] = os_login_param
PYEOF

OS_LOGIN_FLAG="--tc-file=${OS_LOGIN_CONFIG}"

echo "Starting tier2 tests 🧪"
echo "Resolved Tier-2 suites: ${RESOLVED_TIER2_SUITES}"
echo "Using markers: ${MARKERS}"
if [[ ${#TIER2_PATH_ARGS[@]} -gt 0 ]]; then
  echo "Using module paths: ${TIER2_PATH_ARGS[*]}"
else
  echo "Using module paths: <all modules>"
fi

# Only TEST_FOCUS/TEST_SKIPS may legitimately collect zero tests.
# Path filters and windows-only markers must NOT mask empty collection as success.
TIER2_SELECTIVE_FILTER=false
if [ -n "${K_EXPR}" ]; then
  TIER2_SELECTIVE_FILTER=true
fi

# Python literal list of selected module paths for auxiliary collect-only calls
# (TEST_SKIPS counting must use the same path scope as the main pytest run).
TIER2_PATH_ARGS_PY="[]"
if [[ ${#TIER2_PATH_ARGS[@]} -gt 0 ]]; then
  TIER2_PATH_ARGS_PY="$(printf '%s\n' "${TIER2_PATH_ARGS[@]}" | .venv/bin/python -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))')"
fi

merge_junit_files() {
  local primary="$1"
  local secondary="$2"
  local output="$3"
  .venv/bin/python -c "
import sys
import xml.etree.ElementTree as ET

primary, secondary, output = sys.argv[1:4]

def as_testsuites(root):
    if root.tag == 'testsuites':
        return root
    if root.tag == 'testsuite':
        wrapper = ET.Element('testsuites')
        wrapper.append(root)
        return wrapper
    return root

def suites_of(root):
    if root.tag == 'testsuite':
        return [root]
    return list(root.findall('testsuite'))

root = as_testsuites(ET.parse(primary).getroot())
for suite in suites_of(ET.parse(secondary).getroot()):
    root.append(suite)

tests = failures = errors = skipped = 0
for suite in root.findall('testsuite'):
    tests += int(suite.get('tests') or 0)
    failures += int(suite.get('failures') or 0)
    errors += int(suite.get('errors') or 0)
    skipped += int(suite.get('skipped') or 0)
root.set('tests', str(tests))
root.set('failures', str(failures))
root.set('errors', str(errors))
root.set('skipped', str(skipped))
ET.ElementTree(root).write(output, xml_declaration=True, encoding='unicode')
print(f'Merged JUnit XML into {output}')
" "${primary}" "${secondary}" "${output}"
}

# TODO: Remove --skip-artifactory-check before GA once openshift-virtualization-tests
# removes the unconditional artifactory dependency from session-scoped fixtures.

# Drop split-phase markers from any prior invocation in this results dir so a
# non-split rerun cannot inherit old setup-failure classification, and so phase1
# evidence cannot be a stale primary JUnit from a previous attempt.
clear_tier2_result_artifacts() {
  rm -f "${ARTIFACTS}/.exit_code" \
        "${ARTIFACTS}/.exit_code_phase1" \
        "${ARTIFACTS}/.exit_code_windows" \
        "${ARTIFACTS}/junit.results.xml" \
        "${ARTIFACTS}/junit.phase1.xml" \
        "${ARTIFACTS}/junit.windows.xml"
}

if [ "${DRY_RUN}" == "true" ]; then
  # In dry-run mode, collect tests and generate a proper JUnit XML with all
  # testcase elements -- aligned with how Ginkgo's --ginkgo.dry-run works.
  clear_tier2_result_artifacts
  (set +e; .venv/bin/pytest \
    -m "${MARKERS}" \
    --skip-artifactory-check \
    --latest-rhel \
    --tc=hco_subscription:${SUBSCRIPTION_NAME} \
    --conformance-storage-class=${STORAGE_CLASS} \
    --tc=storage_class_a:${STORAGE_CLASS} \
    --tc=storage_class_b:${STORAGE_CLASS} \
    ${STORAGE_CLASS_CONFIG} \
    ${HCP_FLAG} \
    ${OS_LOGIN_FLAG} \
    ${WIN_IMAGE_FLAG} \
    --collect-only -q \
    "${K_ARGS[@]}" \
    "${TIER2_PATH_ARGS[@]}" \
    2>&1; echo $? > "${ARTIFACTS}/.exit_code") | tee ${ARTIFACTS}/tier2-log.txt &

  TEST_PID=$!
  echo "Tier2 test process started with PID: ${TEST_PID}"
  wait_for_pytest_pipeline "${TEST_PID}" "${ARTIFACTS}/.exit_code"

  # Handle pytest exit code 5 (no tests collected due to -k/-m/path filter deselection).
  # Only treat as success when a selective filter was explicitly set;
  # without filters, exit 5 indicates a genuine collection failure (broken markers, etc.).
  TIER2_EXIT=$(cat "${ARTIFACTS}/.exit_code" 2>/dev/null || echo "0")
  if [ "${TIER2_EXIT}" == "5" ] && [ "${TIER2_SELECTIVE_FILTER}" == "true" ]; then
    echo "No tier2 tests matched the filter (pytest exit code 5). Treating as success with 0 tests run."
    echo "0" > "${ARTIFACTS}/.exit_code"
  fi

  # Generate JUnit XML from collected test IDs, accounting for TEST_SKIPS
  # Overwrite .exit_code after successful JUnit generation so junit_parser
  # does not flag the suite as a setup failure when pytest --collect-only
  # exits non-zero (e.g. import warnings in CI or no tests collected).
  .venv/bin/python -c "
import re, subprocess, sys, socket
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

# When 0 tests are collected (all deselected by -k/-m filters), count the
# deselected tests as skipped to match ginkgo suite behavior.
# In this case, skip TEST_SKIPS counting since those entries are already
# included in the total deselected count.
skipped_count = 0
if not test_ids:
    log_text = ''.join(lines)
    m = re.search(r'(\d+) deselected', log_text)
    if m:
        skipped_count = int(m.group(1))
        print(f'All tests deselected by filter: {skipped_count} counted as skipped')
elif skip_entries:
    result = subprocess.run(
        ['.venv/bin/pytest', '--collect-only', '-q', '-m', '${MARKERS}'] + ${TIER2_PATH_ARGS_PY},
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
print(f'Generated JUnit XML with {total_tests} test(s) ({len(test_ids)} collected, {skipped_count} skipped)')
" "${ARTIFACTS}/tier2-log.txt" "${ARTIFACTS}/junit.results.xml" "${TEST_SKIPS:-}" "${TEST_FOCUS:-}"

  if [ -f "${ARTIFACTS}/junit.results.xml" ]; then
    echo 0 > "${ARTIFACTS}/.exit_code"
  fi

  # Second phase: cross-module Windows collect for mixed path+Windows selections.
  # Run even if phase 1 failed so Windows coverage still appears in the report.
  if [ "${TIER2_SPLIT_WINDOWS}" == "true" ]; then
    PHASE1_EXIT=$(cat "${ARTIFACTS}/.exit_code" 2>/dev/null || echo "1")
    echo "${PHASE1_EXIT}" > "${ARTIFACTS}/.exit_code_phase1"
    rm -f "${ARTIFACTS}/junit.phase1.xml" "${ARTIFACTS}/junit.windows.xml" "${ARTIFACTS}/.exit_code_windows"
    if [ -f "${ARTIFACTS}/junit.results.xml" ]; then
      cp "${ARTIFACTS}/junit.results.xml" "${ARTIFACTS}/junit.phase1.xml"
    fi
    echo "Collecting cross-module Windows tests (dry-run phase 2)..."
    (set +e; .venv/bin/pytest \
      -m "conformance and windows" \
      --skip-artifactory-check \
      --latest-rhel \
      --tc=hco_subscription:${SUBSCRIPTION_NAME} \
      --conformance-storage-class=${STORAGE_CLASS} \
      --tc=storage_class_a:${STORAGE_CLASS} \
      --tc=storage_class_b:${STORAGE_CLASS} \
      ${STORAGE_CLASS_CONFIG} \
      ${HCP_FLAG} \
      ${OS_LOGIN_FLAG} \
      ${WIN_IMAGE_FLAG} \
      --collect-only -q \
      "${K_ARGS[@]}" \
      2>&1; echo $? > "${ARTIFACTS}/.exit_code_windows") | tee "${ARTIFACTS}/tier2-windows-log.txt" &
    TEST_PID=$!
    wait_for_pytest_pipeline "${TEST_PID}" "${ARTIFACTS}/.exit_code_windows"
    cat "${ARTIFACTS}/tier2-windows-log.txt" >> "${ARTIFACTS}/tier2-log.txt"
    WIN_EXIT=$(cat "${ARTIFACTS}/.exit_code_windows" 2>/dev/null || echo "0")
    # Exit 5 (no tests collected) is success only with an explicit focus/skip filter.
    # Persist the normalized status so NewResultMap sees the same accepted code.
    if [ "${WIN_EXIT}" == "5" ] && [ "${TIER2_SELECTIVE_FILTER}" == "true" ]; then
      WIN_EXIT=0
      echo 0 > "${ARTIFACTS}/.exit_code_windows"
    fi
    if [ "${WIN_EXIT}" == "0" ]; then
      .venv/bin/python -c "
import sys, socket
from xml.etree.ElementTree import Element, SubElement, ElementTree
from datetime import datetime, timezone

log_path, junit_path = sys.argv[1:3]
with open(log_path) as f:
    lines = f.readlines()
test_ids = [l.strip() for l in lines if '::' in l and not l.startswith(('=', '-', ' '))]
testsuites = Element('testsuites', name='pytest tests')
ts = SubElement(testsuites, 'testsuite',
    name='pytest-windows',
    errors='0', failures='0', skipped='0',
    tests=str(len(test_ids)), time='0.000',
    timestamp=datetime.now(timezone.utc).isoformat(),
    hostname=socket.gethostname(),
)
for tid in test_ids:
    parts = tid.split('::')
    module = parts[0].replace('/', '.').removesuffix('.py') if parts else ''
    name = parts[-1] if parts else tid
    classname = '.'.join(parts[:-1]).replace('/', '.').removesuffix('.py') if len(parts) > 1 else module
    SubElement(ts, 'testcase', classname=classname, name=name, time='0.000')
ElementTree(testsuites).write(junit_path, xml_declaration=True, encoding='unicode')
print(f'Generated Windows dry-run JUnit with {len(test_ids)} test(s)')
" "${ARTIFACTS}/tier2-windows-log.txt" "${ARTIFACTS}/junit.windows.xml"
      if [ -f "${ARTIFACTS}/junit.results.xml" ] && [ -f "${ARTIFACTS}/junit.windows.xml" ]; then
        merge_junit_files "${ARTIFACTS}/junit.results.xml" "${ARTIFACTS}/junit.windows.xml" "${ARTIFACTS}/junit.results.xml"
      elif [ -f "${ARTIFACTS}/junit.windows.xml" ]; then
        cp "${ARTIFACTS}/junit.windows.xml" "${ARTIFACTS}/junit.results.xml"
      fi
    fi
    if [ "${PHASE1_EXIT}" != "0" ]; then
      echo "${PHASE1_EXIT}" > "${ARTIFACTS}/.exit_code"
    elif [ "${WIN_EXIT}" != "0" ]; then
      echo "${WIN_EXIT}" > "${ARTIFACTS}/.exit_code"
    else
      echo 0 > "${ARTIFACTS}/.exit_code"
    fi
  fi

else
  clear_tier2_result_artifacts
  (set +e; .venv/bin/pytest \
    -m "${MARKERS}" \
    --skip-artifactory-check \
    --latest-rhel \
    --tc=hco_subscription:${SUBSCRIPTION_NAME} \
    --conformance-storage-class=${STORAGE_CLASS} \
    --tc=storage_class_a:${STORAGE_CLASS} \
    --tc=storage_class_b:${STORAGE_CLASS} \
    ${STORAGE_CLASS_CONFIG} \
    ${HCP_FLAG} \
    ${OS_LOGIN_FLAG} \
    ${WIN_IMAGE_FLAG} \
    -s -o log_cli=true \
    "${K_ARGS[@]}" \
    "${TIER2_PATH_ARGS[@]}" \
    --data-collector \
    --data-collector-output-dir=${ARTIFACTS} \
    --pytest-log-file=${ARTIFACTS}/pytest-logs.txt \
    --junitxml="${ARTIFACTS}/junit.results.xml"; echo $? > "${ARTIFACTS}/.exit_code") 2>&1 | tee ${ARTIFACTS}/tier2-log.txt &

  TEST_PID=$!
  echo "Tier2 test process started with PID: ${TEST_PID}"
  wait_for_pytest_pipeline "${TEST_PID}" "${ARTIFACTS}/.exit_code"

  # Handle pytest exit code 5 (no tests collected due to -k/-m/path filter deselection).
  # Only treat as success when a selective filter was explicitly set;
  # without filters, exit 5 indicates a genuine collection failure (broken markers, etc.).
  TIER2_EXIT=$(cat "${ARTIFACTS}/.exit_code" 2>/dev/null || echo "0")
  if [ "${TIER2_EXIT}" == "5" ] && [ "${TIER2_SELECTIVE_FILTER}" == "true" ]; then
    echo "No tier2 tests matched the filter (pytest exit code 5). Treating as success with 0 tests run."
    echo "0" > "${ARTIFACTS}/.exit_code"

    # Parse the deselected count from pytest output and generate a valid JUnit XML
    # with deselected tests counted as skipped (matching ginkgo suite behavior).
    .venv/bin/python -c "
import re, sys, socket
from xml.etree.ElementTree import Element, SubElement, ElementTree
from datetime import datetime, timezone

log_path = sys.argv[1]
junit_path = sys.argv[2]

deselected = 0
with open(log_path) as f:
    log_text = f.read()
m = re.search(r'(\d+) deselected', log_text)
if m:
    deselected = int(m.group(1))

testsuites = Element('testsuites', name='pytest tests')
SubElement(testsuites, 'testsuite',
    name='pytest',
    errors='0',
    failures='0',
    skipped=str(deselected),
    tests=str(deselected),
    time='0.000',
    timestamp=datetime.now(timezone.utc).isoformat(),
    hostname=socket.gethostname(),
)
tree = ElementTree(testsuites)
tree.write(junit_path, xml_declaration=True, encoding='unicode')
print(f'Generated JUnit XML: 0 tests run, {deselected} deselected (counted as skipped)')
" "${ARTIFACTS}/tier2-log.txt" "${ARTIFACTS}/junit.results.xml"
  fi

  # Add manually deselected tests (via TEST_SKIPS) to the JUnit XML skipped count,
  # since pytest -k deselection omits them from the report entirely.
  # Only count entries that match real conformance test names.
  # Exclude any entries that also appear in TEST_FOCUS (those were not skipped).
  # Skip when exit code was 5: either the deselected count already includes these
  # (K_EXPR was set), or it's a genuine collection failure (K_EXPR was empty).
  if [ -n "${TEST_SKIPS}" ] && [ "${TIER2_EXIT}" != "5" ]; then
    .venv/bin/python -c "
import subprocess, sys, xml.etree.ElementTree as ET

junit_path = sys.argv[1]
skip_entries = sys.argv[2].split('|')
focus_entries = sys.argv[3].split('|') if sys.argv[3] else []

# Remove entries that are also in TEST_FOCUS (they were not skipped)
skip_entries = [e for e in skip_entries if e not in focus_entries]

# Collect conformance test node IDs within the same path scope as the main run
result = subprocess.run(
    ['.venv/bin/pytest', '--collect-only', '-q', '-m', '${MARKERS}'] + ${TIER2_PATH_ARGS_PY},
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

  # Second phase: cross-module Windows for mixed path+Windows selections.
  # Always run after phase 1 (including ordinary test failures) so Windows
  # coverage is not lost; combine statuses and merge available JUnit files.
  if [ "${TIER2_SPLIT_WINDOWS}" == "true" ]; then
    PHASE1_EXIT=$(cat "${ARTIFACTS}/.exit_code" 2>/dev/null || echo "1")
    echo "${PHASE1_EXIT}" > "${ARTIFACTS}/.exit_code_phase1"
    # Drop stale per-phase artifacts so retries cannot merge a previous run's XML.
    rm -f "${ARTIFACTS}/junit.phase1.xml" "${ARTIFACTS}/junit.windows.xml" "${ARTIFACTS}/.exit_code_windows"
    if [ -f "${ARTIFACTS}/junit.results.xml" ]; then
      cp "${ARTIFACTS}/junit.results.xml" "${ARTIFACTS}/junit.phase1.xml"
    fi
    echo "Running cross-module Windows tests (phase 2)..."
    (set +e; .venv/bin/pytest \
      -m "conformance and windows" \
      --skip-artifactory-check \
      --latest-rhel \
      --tc=hco_subscription:${SUBSCRIPTION_NAME} \
      --conformance-storage-class=${STORAGE_CLASS} \
      --tc=storage_class_a:${STORAGE_CLASS} \
      --tc=storage_class_b:${STORAGE_CLASS} \
      ${STORAGE_CLASS_CONFIG} \
      ${HCP_FLAG} \
      ${OS_LOGIN_FLAG} \
      ${WIN_IMAGE_FLAG} \
      -s -o log_cli=true \
      "${K_ARGS[@]}" \
      --data-collector \
      --data-collector-output-dir=${ARTIFACTS} \
      --pytest-log-file=${ARTIFACTS}/pytest-windows-logs.txt \
      --junitxml="${ARTIFACTS}/junit.windows.xml"; echo $? > "${ARTIFACTS}/.exit_code_windows") 2>&1 | tee -a "${ARTIFACTS}/tier2-log.txt" &
    TEST_PID=$!
    echo "Tier2 Windows phase started with PID: ${TEST_PID}"
    wait_for_pytest_pipeline "${TEST_PID}" "${ARTIFACTS}/.exit_code_windows"
    WIN_EXIT=$(cat "${ARTIFACTS}/.exit_code_windows" 2>/dev/null || echo "0")
    if [ "${WIN_EXIT}" == "5" ] && [ "${TIER2_SELECTIVE_FILTER}" == "true" ]; then
      echo "No Windows tests matched the filter (pytest exit code 5). Treating Windows phase as success."
      WIN_EXIT=0
      echo 0 > "${ARTIFACTS}/.exit_code_windows"
    fi
    # Merge only XML produced by this invocation (file was removed before the phase).
    # Merge even on failure so real Windows failures appear in the primary report.
    if [ -f "${ARTIFACTS}/junit.windows.xml" ] && [ -f "${ARTIFACTS}/junit.results.xml" ]; then
      merge_junit_files "${ARTIFACTS}/junit.results.xml" "${ARTIFACTS}/junit.windows.xml" "${ARTIFACTS}/junit.results.xml"
    elif [ -f "${ARTIFACTS}/junit.windows.xml" ]; then
      cp "${ARTIFACTS}/junit.windows.xml" "${ARTIFACTS}/junit.results.xml"
    fi
    if [ "${PHASE1_EXIT}" != "0" ]; then
      echo "${PHASE1_EXIT}" > "${ARTIFACTS}/.exit_code"
    elif [ "${WIN_EXIT}" != "0" ]; then
      echo "${WIN_EXIT}" > "${ARTIFACTS}/.exit_code"
    else
      echo 0 > "${ARTIFACTS}/.exit_code"
    fi
  fi
fi
