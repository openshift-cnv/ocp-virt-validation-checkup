#!/usr/bin/env bash

set -ex

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

ARTIFACTS=${RESULTS_DIR}/ssp
mkdir -p "${ARTIFACTS}"

SSP_TESTS_BINARY="ssp.test"

# SSP configuration
export SSP_DEPLOYMENT_NAME='ssp-operator'
export SSP_DEPLOYMENT_NAMESPACE='openshift-cnv'
export SSP_WEBHOOK_SERVICE_NAME='ssp-operator-service'
export VM_CONSOLE_PROXY_NAMESPACE="${SSP_DEPLOYMENT_NAMESPACE}"

SSP_CR=$(
  oc get ssps \
    --namespace="${SSP_DEPLOYMENT_NAMESPACE}" \
    --output=jsonpath='{$.items[0].metadata.name}'
)
CLUSTER_TOPOLOGY=$(
  oc get infrastructure cluster \
    --output=jsonpath='{$.status.controlPlaneTopology}'
)

export \
  TEST_EXISTING_CR_NAME="${SSP_CR}" \
  TEST_EXISTING_CR_NAMESPACE=${SSP_DEPLOYMENT_NAMESPACE} \
  TOPOLOGY_MODE="${CLUSTER_TOPOLOGY}"

echo "Starting SSP tests 🧪"
${SSP_TESTS_BINARY} \
  --ginkgo.junit-report="${ARTIFACTS}/junit.results.xml" \
  --ginkgo.skip='\[QUARANTINE\]' \
  --ginkgo.v \
  --ginkgo.no-color \
  ${DRY_RUN_FLAG} \
  --ginkgo.timeout='2h' 2>&1 | tee ${ARTIFACTS}/ssp-log.txt

source "${SCRIPT_DIR}/../funcs.sh"
tests::hco::enable