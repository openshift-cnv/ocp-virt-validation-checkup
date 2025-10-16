#!/bin/bash

set -e

function escape() {
    echo "$1" | sed -E 's/([][()| ])/\\\1/g'
}

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
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


if [ "${FULL_SUITE}" == "true" ]
then
  label_filter+=( "(sig-${SIG})" )
else
  label_filter+=( "(sig-${SIG}&&conformance)" )
fi

label_filter_joined=$(printf '%s&&' "${label_filter[@]}")
label_filter_joined=${label_filter_joined%&&}

if [ "${SIG}" == "storage" ]
then
  label_filter_joined="${label_filter_joined}||(StorageCritical)"
fi

# Determine the storage configuration file path
STORAGE_CONFIG_PATH=""
if [ -n "${KUBEVIRT_STORAGE_CONFIGURATION_FILE}" ]; then
  # Check if custom config exists in results directory first
  if [ -f "${RESULTS_DIR}/${KUBEVIRT_STORAGE_CONFIGURATION_FILE}" ]; then
    STORAGE_CONFIG_PATH="${RESULTS_DIR}/${KUBEVIRT_STORAGE_CONFIGURATION_FILE}"
    echo "Using custom storage configuration from results directory: ${STORAGE_CONFIG_PATH}"
  elif [ -f "${SCRIPT_DIR}/config/storage/${KUBEVIRT_STORAGE_CONFIGURATION_FILE}" ]; then
    STORAGE_CONFIG_PATH="${SCRIPT_DIR}/config/storage/${KUBEVIRT_STORAGE_CONFIGURATION_FILE}"
    echo "Using predefined storage configuration: ${STORAGE_CONFIG_PATH}"
  else
    echo "Error: Storage configuration file not found: ${KUBEVIRT_STORAGE_CONFIGURATION_FILE}"
    echo "The selected storage class was not found and neither STORAGE_CAPABILITIES have been provided"
    exit 1
  fi
elif [ -n "${KUBEVIRT_TESTING_CONFIGURATION_FILE}" ]; then
  # Use fallback configuration if specified
  STORAGE_CONFIG_PATH="${SCRIPT_DIR}/config/${KUBEVIRT_TESTING_CONFIGURATION_FILE}"
  if [ ! -f "${STORAGE_CONFIG_PATH}" ]; then
    echo "Error: Storage configuration file not found: ${KUBEVIRT_TESTING_CONFIGURATION_FILE}"
    echo "The selected storage class was not found and neither STORAGE_CAPABILITIES have been provided"
    exit 1
  fi
else
  echo "Error: No storage configuration provided"
  echo "The selected storage class was not found and neither STORAGE_CAPABILITIES have been provided"
  exit 1
fi

# Check storage configuration and modify label filter if block storage is not supported
if [ -f "${STORAGE_CONFIG_PATH}" ]; then
  # Check if both storageRWOBlock and storageRWXBlock are missing from the config
  if ! grep -q '"storageRWOBlock"' "${STORAGE_CONFIG_PATH}" && ! grep -q '"storageRWXBlock"' "${STORAGE_CONFIG_PATH}"; then
    label_filter_joined="${label_filter_joined}&&(!RequiresBlockStorage)"
    echo "Block storage not supported, added (!RequiresBlockStorage) filter"
  fi
fi

label_filter_str="--ginkgo.label-filter=${label_filter_joined}"

echo "Starting ${SIG} tests 🧪"
${TESTS_BINARY} \
    -cdi-namespace="$TARGET_NAMESPACE" \
    -config="${STORAGE_CONFIG_PATH}" \
    -installed-namespace="$TARGET_NAMESPACE" \
    -junit-output="${ARTIFACTS}/junit.results.xml" \
    "${label_filter_str}" \
    ${ginkgo_focus} \
    ${GINKGO_SLOW} \
    --ginkgo.v \
    --ginkgo.no-color \
    --ginkgo.timeout=7h \
    -test.timeout=7h \
    -kubectl-path=/usr/bin/oc \
    -kubeconfig ${SCRIPT_DIR}/../../kubeconfig \
    -utility-container-prefix=quay.io/kubevirt \
    -utility-container-tag="${KUBEVIRT_RELEASE}" \
    ${GINKGO_FLAKE} \
    ${DRY_RUN_FLAG} \
    "${skip_arg}" 2>&1 | tee ${ARTIFACTS}/${SIG}-log.txt
