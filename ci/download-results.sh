#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Verify TIMESTAMP is provided
if [ -z "${TIMESTAMP:-}" ]; then
  echo "Error: TIMESTAMP environment variable is required"
  exit 1
fi

TIMESTAMP="${TIMESTAMP}" \
  ${REPO_ROOT}/manifests/fetch/get_results.sh | oc apply -f -

echo "=== Waiting for pvc-reader pod to be ready ==="
oc wait --for=condition=ready --timeout=2m pod -n ocp-virt-validation -l app=pvc-reader

RESULTS_URL=$(oc get route pvcreader-${TIMESTAMP} -n ocp-virt-validation -o jsonpath='{.status.ingress[0].host}')

echo "=== Waiting for nginx service to be available ==="
if timeout 120 bash -c "until wget --no-check-certificate --spider --timeout=5 -q 'https://${RESULTS_URL}/'; do sleep 5; done"; then
  echo "Service is available!"
else
  echo "Error: Service did not become available after 120 seconds"
  exit 1
fi

echo "=== Downloading all results ==="
# Create results directory and clean if it exists
RESULTS_DIR="${REPO_ROOT}/_out"
rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"

# Download all content recursively from the nginx server
wget --no-check-certificate \
     --recursive \
     --no-parent \
     --no-host-directories \
     --directory-prefix="${RESULTS_DIR}" \
     --quiet \
     https://${RESULTS_URL}/ || true

SUMMARY_LOG="${RESULTS_DIR}/summary-log.txt"
if [ ! -s "${SUMMARY_LOG}" ]; then
  echo "Error: summary-log.txt is empty or does not exist at ${SUMMARY_LOG}"
  exit 1
fi

# Copy JUnit files to ARTIFACT_DIR if the variable is set (for Prow CI)
if [ -n "${ARTIFACT_DIR:-}" ]; then
  echo "=== Copying JUnit files to ${ARTIFACT_DIR} ==="

  # Find all JUnit XML files and copy them to ARTIFACT_DIR
  JUNIT_FILES=$(find "${RESULTS_DIR}" -type f -name "junit*.xml" -o -name "*junit*.xml")
  JUNIT_COUNT=0

  if [ -n "${JUNIT_FILES}" ]; then
    while IFS= read -r junit_file; do
      if [ -f "${junit_file}" ]; then
        # Generate unique filename using the subdirectory name
        BASENAME=$(basename "${junit_file}")
        PARENT_DIR=$(basename "$(dirname "${junit_file}")")
        DEST_FILE="${ARTIFACT_DIR}/${PARENT_DIR}_${BASENAME}"
        cp "${junit_file}" "${DEST_FILE}"
        JUNIT_COUNT=$((JUNIT_COUNT + 1))
        echo "  Copied: ${junit_file} -> $(basename ${DEST_FILE})"
      fi
    done <<< "${JUNIT_FILES}"
    echo "Total JUnit files copied: ${JUNIT_COUNT}"
  else
    echo "Warning: No JUnit files found in ${RESULTS_DIR}"
  fi
  echo ""
fi

echo "=== Results download completed successfully ==="
echo "Full results available at: ${RESULTS_DIR}"
