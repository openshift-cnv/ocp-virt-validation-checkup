#!/bin/bash

set -ex

function escape() {
    echo "$1" | sed -E 's/([][()| ])/\\\1/g'
}

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
KUBEVIRT_TESTING_CONFIGURATION_FILE=${KUBEVIRT_TESTING_CONFIGURATION_FILE:-'kubevirt-testing-configuration.json'}
readonly TARGET_NAMESPACE="openshift-cnv"

skip_tests+=('\[QUARANTINE\]')
if [ -n "${TEST_SKIPS}" ]; then
  skip_tests+=("${TEST_SKIPS}")
fi

IFS=$'\n'
for test_id in $(
    jq -s '.[0] + .[1]' \
        "${SCRIPT_DIR}/config/quarantined_tests.json" \
        "${SCRIPT_DIR}/config/dont_run_tests.json" | \
        jq -r '.[].id'
); do
    skip_tests+=("$(escape "${test_id}")")
done

label_filter=()

skip_tests_labels_file="${SCRIPT_DIR}/config/dont_run_tests_labels.json"
for ginkgo_label_name in $(jq -r '.[].ginkgo_label_name' $skip_tests_labels_file); do
  label_filter+=( "!($ginkgo_label_name)" )
done

skip_regex=$(printf '(%s)|' "${skip_tests[@]}")
skip_arg=$(printf -- '--ginkgo.skip=%s' "${skip_regex:0:-1}")

TESTS_BINARY="kubevirt.test"
export ARTIFACTS=${RESULTS_DIR}/${SIG}
mkdir -p "${ARTIFACTS}"

GINKGO_FLAKE="--ginkgo.flake-attempts=3"
GINKGO_SLOW="--ginkgo.poll-progress-after=60s"

if [ "${SIG}" == "network" ]
then
  label_filter+=( "sig-${SIG}" )
elif [ "${SIG}" == "compute" ]
then
  label_filter+=( "(sig-${SIG}&&conformance)" )
elif [ "${SIG}" == "storage" ]
then
  label_filter+=( "(sig-${SIG}&&conformance),(StorageCritical)" )
fi

label_filter_joined=$(printf '%s&&' "${label_filter[@]}")
label_filter_joined=${label_filter_joined%&&}
label_filter_str="--ginkgo.label-filter=${label_filter_joined}"

echo "Starting ${SIG} tests 🧪"
${TESTS_BINARY} \
    -cdi-namespace="$TARGET_NAMESPACE" \
    -config="${SCRIPT_DIR}/config/${KUBEVIRT_TESTING_CONFIGURATION_FILE}" \
    -installed-namespace="$TARGET_NAMESPACE" \
    -junit-output="${ARTIFACTS}/junit.results.xml" \
    "${label_filter_str}" \
    ${ginkgo_focus} \
    ${GINKGO_SLOW} \
    --ginkgo.v \
    --ginkgo.no-color \
    -kubectl-path=/usr/bin/oc \
    -kubeconfig ${SCRIPT_DIR}/../../kubeconfig \
    -utility-container-prefix=quay.io/kubevirt \
    -test.timeout=7h \
    -utility-container-tag="${KUBEVIRT_RELEASE}" \
    ${GINKGO_FLAKE} \
    ${DRY_RUN_FLAG} \
    "${skip_arg}" 2>&1 | tee ${ARTIFACTS}/${SIG}-log.txt
