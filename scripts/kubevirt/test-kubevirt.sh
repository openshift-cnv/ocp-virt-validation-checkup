#!/bin/bash

set -ex

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
KUBEVIRT_TESTING_CONFIGURATION_FILE=${KUBEVIRT_TESTING_CONFIGURATION_FILE:-'kubevirt-testing-configuration.json'}

skip_tests+=('\[QUARANTINE\]')

skip_regex=$(printf '(%s)|' "${skip_tests[@]}")
skip_arg=$(printf -- '--ginkgo.skip=%s' "${skip_regex:0:-1}")

TESTS_BINARY="kubevirt.test"
export ARTIFACTS=${RESULTS_DIR}/${SIG}
mkdir -p "${ARTIFACTS}"

GINKGO_FLAKE="--ginkgo.flake-attempts=1"
GINKGO_SLOW="--ginkgo.poll-progress-after=60s"

if [ "${SIG}" == "network" ]
then
  label_filter="--ginkgo.label-filter=sig-${SIG}"
  ginkgo_focus="--ginkgo.focus=Services"
elif [ "${SIG}" == "compute" ]
then
  label_filter="--ginkgo.label-filter=(sig-${SIG}&&conformance)"
  ginkgo_focus="--ginkgo.focus=rfe_id:1177"
elif [ "${SIG}" == "storage" ]
then
  label_filter="--ginkgo.label-filter=(sig-${SIG}&&conformance)"
fi

echo "Starting ${SIG} tests 🧪"
${TESTS_BINARY} \
    -cdi-namespace="$TARGET_NAMESPACE" \
    -config="${SCRIPT_DIR}/config/${KUBEVIRT_TESTING_CONFIGURATION_FILE}" \
    -installed-namespace="$TARGET_NAMESPACE" \
    -junit-output="${ARTIFACTS}/junit.results.xml" \
    "${label_filter}" \
    ${ginkgo_focus} \
    ${GINKGO_SLOW} \
    --ginkgo.v \
    --ginkgo.no-color \
    -oc-path=/usr/bin/oc \
    -kubectl-path=/usr/bin/oc \
    -utility-container-prefix=quay.io/kubevirt \
    -test.timeout=3h \
    -utility-container-tag="${KUBEVIRT_RELEASE}" \
    ${GINKGO_FLAKE} \
    ${DRY_RUN_FLAG} \
    "${skip_arg}" 2>&1 | tee ${ARTIFACTS}/${SIG}-log.txt
