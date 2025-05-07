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


REGISTRY_CONFIG=$(mktemp)
oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${REGISTRY_CONFIG}"
VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[0].image}')
KUBEVIRT_TAG=$(oc image info -a ${REGISTRY_CONFIG} ${VIRT_OPERATOR_IMAGE} -o json --filter-by-os=linux/amd64 | jq -r '.config.config.Labels["upstream-version"]')
export KUBEVIRT_RELEASE="v${KUBEVIRT_TAG%%-[0-9]*}"

mkdir -p ${RESULTS_DIR}
START_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo ${START_TIMESTAMP} > ${RESULTS_DIR}/startTimestamp

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

COMPLETION_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo ${COMPLETION_TIMESTAMP} > ${RESULTS_DIR}/completionTimestamp

# =========
# Summarize
# =========
junitparser --results-dir=${RESULTS_DIR}  --start-timestamp=${START_TIMESTAMP} --completion-timestamp=${COMPLETION_TIMESTAMP} | tee ${RESULTS_DIR}/summary-log.txt

# Archive test results into tar.gz
tar -czf /tmp/test-results-${TIMESTAMP}.tar.gz -C ${RESULTS_DIR} .
mv /tmp/test-results-${TIMESTAMP}.tar.gz ${RESULTS_DIR}/test-results-${TIMESTAMP}.tar.gz

echo "Self Validation test run is done."