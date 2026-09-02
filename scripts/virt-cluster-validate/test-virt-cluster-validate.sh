#!/usr/bin/env bash

set -euo pipefail

readonly SUITE_NAME="virt-cluster-validate"
readonly ARTIFACTS="${RESULTS_DIR}/${SUITE_NAME}"
readonly LOG_FILE="${ARTIFACTS}/${SUITE_NAME}-log.txt"
readonly JUNIT_FILE="${ARTIFACTS}/junit.results.xml"
readonly CTRF_FILE="${ARTIFACTS}/ctrf-results.json"
readonly RAW_JUNIT_FILE="${ARTIFACTS}/junit-results.xml"
readonly RUNNER_LOG_FILE="${ARTIFACTS}/runner.log"
readonly EXIT_CODE_FILE="${ARTIFACTS}/.exit_code"
readonly DRY_RUN="${DRY_RUN:-false}"
readonly VALIDATOR_HOME_DEFAULT="/opt/app-root/src"
readonly VALIDATOR_GATHER_DEFAULT="/usr/bin/gather"

VALIDATOR_HOME="${VALIDATOR_HOME:-${VALIDATOR_HOME_DEFAULT}}"
VALIDATOR_BIN="${VALIDATOR_BIN:-${VALIDATOR_HOME}/virt-cluster-validate}"
VALIDATOR_GATHER="${VALIDATOR_GATHER:-${VALIDATOR_GATHER_DEFAULT}}"
export PATH="${VALIDATOR_HOME}/bin:${PATH}"

mkdir -p "${ARTIFACTS}"
CHECKS=()

collect_checks() {
    local checks=()

    (
        shopt -s globstar nullglob
        cd "${VALIDATOR_HOME}" || exit 1
        checks=(
            checks.d/**/test.sh
        )
        printf '%s\n' "${checks[@]}"
    )
}

emit_failure_artifacts() {
    local message=$1

    printf '%s\n' "${message}" > "${RUNNER_LOG_FILE}"
    (
        echo "Starting ${SUITE_NAME} checks"
        write_failure_junit "${message}"
        echo "collecting ... collected 1 items"
        echo "TEST: ${SUITE_NAME} STATUS: FAILED"
        echo "0 passed, 1 failed in 0 seconds"
        echo "1" > "${EXIT_CODE_FILE}"
    ) 2>&1 | tee "${LOG_FILE}"
}

write_dry_run_junit() {
    local check

    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '<testsuites name="%s"><testsuite name="%s" tests="%d" failures="0" errors="0" skipped="%d" time="0.000">' \
            "${SUITE_NAME}" "${SUITE_NAME}" "${#CHECKS[@]}" "${#CHECKS[@]}"
        for check in "${CHECKS[@]}"; do
            printf '<testcase classname="%s" name="%s" time="0.000"><skipped /></testcase>' \
                "${SUITE_NAME}" "${check}"
        done
        printf '%s\n' '</testsuite></testsuites>'
    } > "${JUNIT_FILE}"
}

write_failure_junit() {
    local details=${1:-virt-cluster-validate failed before producing JUnit output}
    local output

    if [[ -s "${RUNNER_LOG_FILE}" ]]; then
        output=$(<"${RUNNER_LOG_FILE}")
    else
        output=${details}
    fi

    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '<testsuites name="%s"><testsuite name="%s" tests="1" failures="1" errors="0" skipped="0" time="0.000">' \
            "${SUITE_NAME}" "${SUITE_NAME}"
        printf '<testcase classname="%s" name="%s" time="0.000">' "${SUITE_NAME}" "${SUITE_NAME}"
        printf '<failure message="virt-cluster-validate failed"><![CDATA[%s]]></failure>' "${output}"
        printf '<system-out><![CDATA[%s]]></system-out>' "${output}"
        printf '%s\n' '</testcase></testsuite></testsuites>'
    } > "${JUNIT_FILE}"
}

emit_ctrf_progress() {
    local total_count=0
    local pass_count=0
    local fail_count=0
    local skipped_count=0
    local duration=0

    total_count=$(jq -r '.results.summary.tests // 0' "${CTRF_FILE}")
    pass_count=$(jq -r '.results.summary.passed // 0' "${CTRF_FILE}")
    fail_count=$(jq -r '.results.summary.failed // 0' "${CTRF_FILE}")
    skipped_count=$(jq -r '.results.summary.skipped // 0' "${CTRF_FILE}")
    duration=$(jq -r '
        ((.results.summary.stop // 0) - (.results.summary.start // 0)) / 1000
        | floor
        | if . < 0 then 0 else . end
    ' "${CTRF_FILE}")

    echo "collecting ... collected ${total_count} items"
    echo "${pass_count} passed, ${fail_count} failed, ${skipped_count} skipped in ${duration} seconds"
}

preflight_checks() {
    if [[ ! -x "${VALIDATOR_GATHER}" ]]; then
        emit_failure_artifacts "Missing must-gather entrypoint at ${VALIDATOR_GATHER}"
        return 1
    fi

    if [[ ! -x "${VALIDATOR_BIN}" ]]; then
        emit_failure_artifacts "Missing validator binary at ${VALIDATOR_BIN}"
        return 1
    fi

    if [[ ! -d "${VALIDATOR_HOME}/checks.d" ]]; then
        emit_failure_artifacts "Missing validator checks directory at ${VALIDATOR_HOME}/checks.d"
        return 1
    fi

    mapfile -t CHECKS < <(collect_checks)
    if [[ ${#CHECKS[@]} -eq 0 ]]; then
        emit_failure_artifacts "No validator checks were found under ${VALIDATOR_HOME}/checks.d"
        return 1
    fi
}

run_dry_run() {
    (
        echo "Starting ${SUITE_NAME} dry-run"
        write_dry_run_junit
        echo "collecting ... collected ${#CHECKS[@]} items"
        echo "0" > "${EXIT_CODE_FILE}"
    ) 2>&1 | tee "${LOG_FILE}"
}

run_validator() {
    (
        local gather_rc=0
        local validator_rc=0

        echo "Starting ${SUITE_NAME} checks"
        cd "${VALIDATOR_HOME}"

        rm -f "${JUNIT_FILE}" "${RAW_JUNIT_FILE}" "${CTRF_FILE}" "${RUNNER_LOG_FILE}"
        : > "${RUNNER_LOG_FILE}"

        echo "Running through must-gather entrypoint"
        POD_NAME="virt-cluster-validate-must-gather" \
        MUST_GATHER="${RESULTS_DIR}" \
        "${VALIDATOR_GATHER}" 2>> "${RUNNER_LOG_FILE}" || gather_rc=$?

        if [[ -f "${RAW_JUNIT_FILE}" ]]; then
            mv "${RAW_JUNIT_FILE}" "${JUNIT_FILE}"
        fi

        if [[ -s "${RUNNER_LOG_FILE}" ]]; then
            echo "=== validator log ==="
            cat "${RUNNER_LOG_FILE}"
        fi

        if [[ ! -f "${JUNIT_FILE}" ]] || [[ ! -f "${CTRF_FILE}" ]]; then
            write_failure_junit
            validator_rc=1
            echo "collecting ... collected 1 items"
            echo "0 passed, 1 failed, 0 skipped in 0 seconds"
        else
            emit_ctrf_progress
        fi

        if (( gather_rc != 0 )) || (( $(jq -r '.results.summary.failed // 0' "${CTRF_FILE}" 2>/dev/null || echo 0) > 0 )); then
            validator_rc=1
        fi
        echo "${validator_rc}" > "${EXIT_CODE_FILE}"
    ) 2>&1 | tee "${LOG_FILE}"
}

main() {
    if ! preflight_checks; then
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        run_dry_run
        return 0
    fi

    run_validator
}

main "$@"
