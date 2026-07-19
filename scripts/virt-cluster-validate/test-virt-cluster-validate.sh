#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
readonly SUITE_NAME="virt-cluster-validate"
readonly ARTIFACTS="${RESULTS_DIR}/${SUITE_NAME}"
readonly LOG_FILE="${ARTIFACTS}/${SUITE_NAME}-log.txt"
readonly JUNIT_FILE="${ARTIFACTS}/junit.results.xml"
readonly RESULTS_JSON="${ARTIFACTS}/results.json"
readonly STDERR_FILE="${ARTIFACTS}/validator-stderr.txt"
readonly EXIT_CODE_FILE="${ARTIFACTS}/.exit_code"
readonly RAW_RESULTS_DIR="${ARTIFACTS}/raw"
readonly SUMMARY_BUILDER="${SCRIPT_DIR}/build_summary.py"
readonly CONVERTER="${SCRIPT_DIR}/json_to_junit.py"
readonly RUNTIME_HOME="${HOME:-/home/ocp-virt-validation-checkup}"
readonly VALIDATOR_HOME_DEFAULT="${RUNTIME_HOME}/virt-cluster-validate"

VALIDATOR_HOME="${VALIDATOR_HOME:-${VALIDATOR_HOME_DEFAULT}}"
VALIDATOR_BIN="${VALIDATOR_BIN:-${VALIDATOR_HOME}/virt-cluster-validate}"
export PATH="${VALIDATOR_HOME}/bin:${RUNTIME_HOME}:${PATH}"

mkdir -p "${ARTIFACTS}" "${RAW_RESULTS_DIR}"

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

emit_failure_artifacts() {
    local message=$1

    printf '%s\n' "${message}" > "${STDERR_FILE}"
    (
        echo "Starting ${SUITE_NAME} checks"
        if ! python3 "${CONVERTER}" \
            --suite-name "${SUITE_NAME}" \
            --junit-output "${JUNIT_FILE}" \
            --stderr-file "${STDERR_FILE}" \
            --emit-run-log; then
            :
        fi
        echo "1" > "${EXIT_CODE_FILE}"
        exit 0
    ) 2>&1 | tee "${LOG_FILE}"
}

write_fallback_result() {
    local output_file=$1
    local testpath=$2
    local exit_code=$3
    local duration=$4
    local stderr_file=$5

    python3 - "${output_file}" "${testpath}" "${exit_code}" "${duration}" "${stderr_file}" <<'PY'
import json
import pathlib
import sys

output_file = pathlib.Path(sys.argv[1])
testpath = sys.argv[2]
exit_code = int(sys.argv[3])
duration = int(sys.argv[4])
stderr_path = pathlib.Path(sys.argv[5])

stderr_text = stderr_path.read_text() if stderr_path.exists() else ""
stderr_lines = [line for line in stderr_text.splitlines() if line]
message = f"validator wrapper did not receive valid JSON output (exit code {exit_code})"
if stderr_lines:
    message = stderr_lines[0]

payload = {
    "summary": "Passed: 0, Failed: 1, Total: 1",
    "results": [
        {
            "testpath": testpath,
            "success": False,
            "has_warnings": False,
            "cancelled": False,
            "duration": duration,
            "report_messages": [f"FAIL: {message}"],
            "log": stderr_lines,
            "errors": stderr_lines or [message],
            "warnings": [],
        }
    ],
}

output_file.write_text(json.dumps(payload, indent=2) + "\n")
PY
}

is_valid_single_result_json() {
    local json_file=$1

    python3 - "${json_file}" <<'PY' > /dev/null
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
results = data.get("results")
if not isinstance(results, list) or len(results) != 1:
    raise SystemExit(1)
result = results[0]
if "testpath" not in result or "success" not in result:
    raise SystemExit(1)
PY
}

emit_check_progress() {
    local json_file=$1

    python3 - "${json_file}" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
result = data["results"][0]
status = "PASSED" if result.get("success") else "FAILED"
print(f'TEST: {result.get("testpath", "validator-check")} STATUS: {status}')
PY
}

check_succeeded() {
    local json_file=$1

    python3 - "${json_file}" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if data["results"][0].get("success") else 1)
PY
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
        dry_run_args=()
        for check in "${CHECKS[@]}"; do
            dry_run_args+=(--dry-run-check "${check}")
        done
        python3 "${CONVERTER}" \
            --suite-name "${SUITE_NAME}" \
            --junit-output "${JUNIT_FILE}" \
            "${dry_run_args[@]}"
        echo "0" > "${EXIT_CODE_FILE}"
    ) 2>&1 | tee "${LOG_FILE}"
    exit 0
fi

(
    echo "Starting ${SUITE_NAME} checks"
    overall_rc=0
    builder_rc=0
    converter_rc=0

    cd "${VALIDATOR_HOME}"

    : > "${STDERR_FILE}"
    index=0
    for check in "${CHECKS[@]}"; do
        index=$((index + 1))
        start_epoch=$(date +%s)
        json_tmp=$(mktemp)
        stderr_tmp=$(mktemp)
        validator_rc=0
        output_json="${RAW_RESULTS_DIR}/$(printf '%03d' "${index}")-$(echo "${check}" | tr '/.' '__' | tr -cd '[:alnum:]_-').json"

        if ! "${VALIDATOR_BIN}" -o json --select "${check}" > "${json_tmp}" 2> "${stderr_tmp}"; then
            validator_rc=$?
        fi

        end_epoch=$(date +%s)
        duration=$((end_epoch - start_epoch))

        if ! is_valid_single_result_json "${json_tmp}"; then
            write_fallback_result "${json_tmp}" "${check}" "${validator_rc}" "${duration}" "${stderr_tmp}"
        fi

        mv "${json_tmp}" "${output_json}"

        if [[ -s "${stderr_tmp}" ]]; then
            {
                echo "=== ${check} ==="
                cat "${stderr_tmp}"
                echo
            } >> "${STDERR_FILE}"
        fi

        emit_check_progress "${output_json}"
        if ! check_succeeded "${output_json}"; then
            overall_rc=1
        fi

        rm -f "${stderr_tmp}"
    done

    if ! python3 "${SUMMARY_BUILDER}" \
        --raw-dir "${RAW_RESULTS_DIR}" \
        --combined-json "${RESULTS_JSON}"; then
        builder_rc=$?
    fi

    if ! python3 "${CONVERTER}" \
        --suite-name "${SUITE_NAME}" \
        --junit-output "${JUNIT_FILE}" \
        --input-json "${RESULTS_JSON}" \
        --stderr-file "${STDERR_FILE}"; then
        converter_rc=$?
    fi

    effective_rc="${overall_rc}"
    if [[ "${effective_rc}" -eq 0 && "${builder_rc}" -ne 0 ]]; then
        effective_rc="${builder_rc}"
    fi
    if [[ "${effective_rc}" -eq 0 && "${converter_rc}" -ne 0 ]]; then
        effective_rc="${converter_rc}"
    fi

    echo "${effective_rc}" > "${EXIT_CODE_FILE}"
    exit 0
) 2>&1 | tee "${LOG_FILE}"
