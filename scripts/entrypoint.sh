#!/bin/bash

set -ex

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
TEST_KUBEVIRT_SCRIPT="${SCRIPT_DIR}/kubevirt/test-kubevirt.sh"

DRY_RUN_FLAG=""
if [ "${DRY_RUN}" == "true" ]
then
  DRY_RUN_FLAG="--ginkgo.dry-run"
fi
export DRY_RUN_FLAG


date -u +"%Y-%m-%dT%H:%M:%SZ" > ${RESULTS_DIR}/startTimestamp

# =======
# compute
# =======
echo "Running KubeVirt test suite..."
SIG="compute" "${TEST_KUBEVIRT_SCRIPT}"
echo "KubeVirt test suite has finished."


# =======
# Network
# =======
echo "Running Network test suite..."
SIG="network" "${TEST_KUBEVIRT_SCRIPT}"


# =======
# Storage
# =======
echo "Running Storage test suite..."
SIG="storage" "${TEST_KUBEVIRT_SCRIPT}"


# ====
# SSP
# ====
echo "Building SSP test suite..."
${SCRIPT_DIR}/ssp/setup-ssp.sh

echo "Running SSP test suite..."
${SCRIPT_DIR}/ssp/test-ssp.sh

echo "SSP test suite has finished. Restoring the environment"
${SCRIPT_DIR}/ssp/teardown-ssp.sh

date -u +"%Y-%m-%dT%H:%M:%SZ" > ${RESULTS_DIR}/completionTimestamp

# =========
# Summarize
# =========
python ./summarize/junit_parser.py ${RESULTS_DIR} | tee ${RESULTS_DIR}/summary-log.txt

# Archive test results into tar.gz
tar -czf /tmp/test-results-${TIMESTAMP}.tar.gz -C ${RESULTS_DIR} .
mv /tmp/test-results-${TIMESTAMP}.tar.gz ${RESULTS_DIR}/test-results-${TIMESTAMP}.tar.gz

echo "Self Validation test run is done."