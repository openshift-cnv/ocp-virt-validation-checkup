#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
readonly SUITE_NAME="virt-cluster-validate"
readonly ARTIFACTS="${RESULTS_DIR}/${SUITE_NAME}"
readonly LOG_FILE="${ARTIFACTS}/${SUITE_NAME}-log.txt"
readonly JUNIT_FILE="${ARTIFACTS}/junit.results.xml"
readonly STDERR_FILE="${ARTIFACTS}/validator-stderr.txt"
readonly EXIT_CODE_FILE="${ARTIFACTS}/.exit_code"
readonly DRY_RUN="${DRY_RUN:-false}"
readonly RUNTIME_HOME="${HOME:-/home/ocp-virt-validation-checkup}"
readonly VALIDATOR_HOME_DEFAULT="${RUNTIME_HOME}/virt-cluster-validate"

VALIDATOR_HOME="${VALIDATOR_HOME:-${VALIDATOR_HOME_DEFAULT}}"
VALIDATOR_BIN="${VALIDATOR_BIN:-${VALIDATOR_HOME}/virt-cluster-validate}"
export PATH="${VALIDATOR_HOME}/bin:${RUNTIME_HOME}:${PATH}"

mkdir -p "${ARTIFACTS}"

collect_checks() {
    local checks=()

    (
        shopt -s globstar nullglob
        cd "${VALIDATOR_HOME}" || exit 1
        checks=(
            checks.d/10-openshift.d/**/test.sh
            checks.d/50-openshift-virtualization.d/**/test.sh
        )
        printf '%s\n' "${checks[@]}"
    )
}

xml_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e "s/'/\&apos;/g" \
        -e 's/"/\&quot;/g'
}

first_nonempty_line() {
    local file=$1

    while IFS= read -r line; do
        if [[ -n "${line//[[:space:]]/}" ]]; then
            printf '%s\n' "${line}"
            return 0
        fi
    done < "${file}"

    return 1
}

tokenize_junit() {
    sed 's/></>\
</g' "${JUNIT_FILE}"
}

emit_failure_artifacts() {
    local message=$1

    printf '%s\n' "${message}" > "${STDERR_FILE}"
    (
        echo "Starting ${SUITE_NAME} checks"
        write_failure_junit "${message}"
        echo "collecting ... collected 1 items"
        echo "TEST: ${SUITE_NAME} STATUS: FAILED"
        echo "0 passed, 1 failed in 0 seconds"
        echo "1" > "${EXIT_CODE_FILE}"
        exit 0
    ) 2>&1 | tee "${LOG_FILE}"
}

write_dry_run_junit() {
    local check
    local escaped_check

    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '<testsuites name="%s"><testsuite name="%s" tests="%d" failures="0" errors="0" skipped="%d" time="0.000">' \
            "${SUITE_NAME}" "${SUITE_NAME}" "${#CHECKS[@]}" "${#CHECKS[@]}"
        for check in "${CHECKS[@]}"; do
            escaped_check=$(printf '%s' "${check}" | xml_escape)
            printf '<testcase classname="%s" name="%s" time="0.000"><skipped /></testcase>' \
                "${SUITE_NAME}" "${escaped_check}"
        done
        printf '%s\n' '</testsuite></testsuites>'
    } > "${JUNIT_FILE}"
}

write_failure_junit() {
    local message=$1
    local escaped_message
    local escaped_stderr=""

    escaped_message=$(printf '%s' "${message}" | xml_escape)
    if [[ -f "${STDERR_FILE}" ]]; then
        escaped_stderr=$(xml_escape < "${STDERR_FILE}")
    fi

    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '<testsuites name="%s"><testsuite name="%s" tests="1" failures="1" errors="0" skipped="0" time="0.000">' \
            "${SUITE_NAME}" "${SUITE_NAME}"
        printf '<testcase classname="%s" name="%s" time="0.000">' "${SUITE_NAME}" "${SUITE_NAME}"
        printf '<failure message="%s">' "${escaped_message}"
        if [[ -n "${escaped_stderr}" ]]; then
            printf '%s' "${escaped_stderr}"
        else
            printf '%s' "${escaped_message}"
        fi
        printf '%s' '</failure>'
        if [[ -n "${escaped_stderr}" ]]; then
            printf '<system-out>%s</system-out>' "${escaped_stderr}"
        fi
        printf '%s\n' '</testcase></testsuite></testsuites>'
    } > "${JUNIT_FILE}"
}

emit_junit_progress() {
    local testcase_count
    local pass_count=0
    local fail_count=0
    local duration
    local name
    local status

    testcase_count=$(tokenize_junit | grep -c '^<testcase ' || true)
    echo "collecting ... collected ${testcase_count} items"

    while IFS=$'\t' read -r name status; do
        [[ -n "${name}" ]] || continue
        echo "TEST: ${name} STATUS: ${status}"
        case "${status}" in
            PASSED) pass_count=$((pass_count + 1)) ;;
            FAILED) fail_count=$((fail_count + 1)) ;;
        esac
    done < <(
        tokenize_junit | awk '
            function decode_entities(value) {
                gsub(/&quot;/, "\"", value)
                gsub(/&apos;/, "\047", value)
                gsub(/&lt;/, "<", value)
                gsub(/&gt;/, ">", value)
                gsub(/&amp;/, "\\&", value)
                return value
            }

            function emit_case() {
                if (current_name == "") {
                    return
                }
                current_status = "PASSED"
                if (current_failed) {
                    current_status = "FAILED"
                } else if (current_skipped) {
                    current_status = "SKIPPED"
                }
                printf "%s\t%s\n", decode_entities(current_name), current_status
            }

            /^<testcase / {
                if (in_case) {
                    emit_case()
                }
                in_case = 1
                current_failed = 0
                current_skipped = 0
                current_name = $0
                sub(/.* name="/, "", current_name)
                sub(/".*/, "", current_name)
                next
            }

            in_case && /^<failure[ >]/ { current_failed = 1; next }
            in_case && /^<error[ >]/ { current_failed = 1; next }
            in_case && /^<skipped[ >]/ { current_skipped = 1; next }

            in_case && /^<\/testcase>/ {
                emit_case()
                in_case = 0
                current_name = ""
                next
            }

            END {
                if (in_case) {
                    emit_case()
                }
            }
        '
    )

    duration=$(tokenize_junit | sed -n 's/.*<testsuite[^>]* time="\([^"]*\)".*/\1/p' | head -n 1)
    duration=${duration%%.*}
    duration=${duration:-0}

    echo "${pass_count} passed, ${fail_count} failed in ${duration} seconds"
}

junit_is_valid() {
    grep -q '<testsuite ' "${JUNIT_FILE}"
}

if [[ ! -x "${VALIDATOR_BIN}" ]]; then
    emit_failure_artifacts "Missing validator binary at ${VALIDATOR_BIN}"
    exit 0
fi

if [[ ! -d "${VALIDATOR_HOME}/checks.d" ]]; then
    emit_failure_artifacts "Missing validator checks directory at ${VALIDATOR_HOME}/checks.d"
    exit 0
fi

mapfile -t CHECKS < <(collect_checks)
if [[ ${#CHECKS[@]} -eq 0 ]]; then
    emit_failure_artifacts "No validator checks were found under ${VALIDATOR_HOME}/checks.d"
    exit 0
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    (
        echo "Starting ${SUITE_NAME} dry-run"
        write_dry_run_junit
        echo "collecting ... collected ${#CHECKS[@]} items"
        echo "0" > "${EXIT_CODE_FILE}"
    ) 2>&1 | tee "${LOG_FILE}"
    exit 0
fi

(
    echo "Starting ${SUITE_NAME} checks"
    cd "${VALIDATOR_HOME}"

    : > "${STDERR_FILE}"
    validator_rc=0
    if ! "${VALIDATOR_BIN}" -o junit > "${JUNIT_FILE}" 2> "${STDERR_FILE}"; then
        validator_rc=$?
    fi

    if [[ -s "${STDERR_FILE}" ]]; then
        echo "=== validator stderr ==="
        cat "${STDERR_FILE}"
    fi

    if ! junit_is_valid; then
        message="validator did not produce valid JUnit output"
        if [[ -s "${STDERR_FILE}" ]]; then
            message=$(first_nonempty_line "${STDERR_FILE}" || true)
            message=${message:-validator did not produce valid JUnit output}
        fi
        write_failure_junit "${message}"
        validator_rc=1
    fi

    emit_junit_progress
    echo "${validator_rc}" > "${EXIT_CODE_FILE}"
    exit 0
) 2>&1 | tee "${LOG_FILE}"
