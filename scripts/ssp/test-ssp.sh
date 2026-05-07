#!/usr/bin/env bash

set -e

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

ARTIFACTS=${RESULTS_DIR}/ssp
mkdir -p "${ARTIFACTS}"

skip_tests+=('\[QUARANTINE\]')
if [ -n "${TEST_SKIPS}" ]; then
  skip_tests+=("${TEST_SKIPS}")
fi

ginkgo_focus=""
if [ -n "${TEST_FOCUS}" ]; then
  IFS='|' read -ra focus_entries <<< "${TEST_FOCUS}"
  filtered_skip_tests=()
  for skip in "${skip_tests[@]}"; do
    dominated=false
    for f in "${focus_entries[@]}"; do
      if [[ "${skip}" == "${f}" ]]; then
        echo "WARNING: '${f}' is in both TEST_FOCUS and TEST_SKIPS. Removing from skip list so it will run."
        dominated=true
        break
      fi
    done
    if [ "${dominated}" = false ]; then
      filtered_skip_tests+=("${skip}")
    fi
  done
  skip_tests=("${filtered_skip_tests[@]}")

  focus_regex=$(printf '(%s)|' "${focus_entries[@]}")
  ginkgo_focus=$(printf -- '--ginkgo.focus=%s' "${focus_regex:0:-1}")
fi

skip_regex=$(printf '(%s)|' "${skip_tests[@]}")
skip_arg=$(printf -- '--ginkgo.skip=%s' "${skip_regex:0:-1}")


SSP_TESTS_BINARY="ssp.test"

source "${SCRIPT_DIR}/../funcs.sh"
trap tests::hco::enable EXIT INT TERM

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


if [ "${FULL_SUITE}" == "true" ]
then
  label_filter=""
  tests::hco::disable
else
  label_filter="--ginkgo.label-filter=conformance"
  export SKIP_UPDATE_SSP_TESTS=true
fi

echo "Starting SSP tests 🧪"
${SSP_TESTS_BINARY} \
  --ginkgo.junit-report="${ARTIFACTS}/junit.results.xml" \
  --ginkgo.skip='\[QUARANTINE\]' \
  ${label_filter} \
  ${ginkgo_focus} \
  --ginkgo.v \
  --ginkgo.no-color \
  ${DRY_RUN_FLAG} \
  --ginkgo.timeout='2h' \
  "${skip_arg}" 2>&1 | tee ${ARTIFACTS}/ssp-log.txt
