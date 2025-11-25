#!/bin/bash

set -euo pipefail

# Validate that JUnit files match summary-log.txt counts
# Usage: verify-results.sh <results-directory>

if [ $# -ne 1 ]; then
  echo "Error: Results directory argument is required"
  echo "Usage: $0 <results-directory>"
  exit 1
fi

RESULTS_DIR="$1"

if [ ! -d "${RESULTS_DIR}" ]; then
  echo "Error: Results directory does not exist: ${RESULTS_DIR}"
  exit 1
fi

SUMMARY_LOG="${RESULTS_DIR}/summary-log.txt"

if [ ! -f "${SUMMARY_LOG}" ]; then
  echo "Error: summary-log.txt not found at ${SUMMARY_LOG}"
  exit 1
fi

echo "=== Validating JUnit files match summary log ==="
VALIDATION_FAILED=0

# Parse summary-log.txt to extract counts per suite
declare -A SUMMARY_TESTS_RUN
declare -A SUMMARY_TESTS_PASSED
declare -A SUMMARY_TESTS_FAILED
declare -A SUMMARY_TESTS_SKIPPED

while IFS= read -r line; do
  if [[ $line =~ ^Summary\ for\ (.+)$ ]]; then
    CURRENT_SUITE="${BASH_REMATCH[1]}"
  elif [[ $line =~ ^Tests\ Run:\ ([0-9]+)$ ]]; then
    SUMMARY_TESTS_RUN["$CURRENT_SUITE"]="${BASH_REMATCH[1]}"
  elif [[ $line =~ ^Tests\ Passed:\ ([0-9]+)$ ]]; then
    SUMMARY_TESTS_PASSED["$CURRENT_SUITE"]="${BASH_REMATCH[1]}"
  elif [[ $line =~ ^Tests\ Failed:\ ([0-9]+)$ ]]; then
    SUMMARY_TESTS_FAILED["$CURRENT_SUITE"]="${BASH_REMATCH[1]}"
  elif [[ $line =~ ^Tests\ Skipped:\ ([0-9]+)$ ]]; then
    SUMMARY_TESTS_SKIPPED["$CURRENT_SUITE"]="${BASH_REMATCH[1]}"
  fi
done < "${SUMMARY_LOG}"

# Collect all JUnit suite names
declare -A JUNIT_SUITES

# Find and validate each JUnit file
for junit_file in $(find "${RESULTS_DIR}" -type f -name "junit*.xml"); do
  # Determine suite name from path (e.g., _out/compute/junit.results.xml -> compute)
  SUITE_NAME=$(basename $(dirname "${junit_file}"))
  JUNIT_SUITES["$SUITE_NAME"]=1
done

# Check that all JUnit suites have a corresponding summary section
echo "Checking that all JUnit suites have summary sections..."
for suite in "${!JUNIT_SUITES[@]}"; do
  if [ -z "${SUMMARY_TESTS_RUN[$suite]:-}" ]; then
    echo "  ERROR: JUnit file found for suite '$suite' but no corresponding section in summary-log.txt"
    VALIDATION_FAILED=1
  fi
done

# Check that all summary sections have a corresponding JUnit file
echo "Checking that all summary sections have JUnit files..."
for suite in "${!SUMMARY_TESTS_RUN[@]}"; do
  if [ -z "${JUNIT_SUITES[$suite]:-}" ]; then
    echo "  ERROR: Summary section found for suite '$suite' but no corresponding JUnit file"
    VALIDATION_FAILED=1
  fi
done

echo ""

# Validate counts for each JUnit file
for junit_file in $(find "${RESULTS_DIR}" -type f -name "junit*.xml"); do
  # Determine suite name from path (e.g., _out/compute/junit.results.xml -> compute)
  SUITE_NAME=$(basename $(dirname "${junit_file}"))

  # Skip if this suite is not in the summary
  if [ -z "${SUMMARY_TESTS_RUN[$SUITE_NAME]:-}" ]; then
    continue
  fi

  # Parse JUnit XML header to extract counts
  # Use word boundary to match <testsuite but not <testsuites
  JUNIT_LINE=$(head -10 "${junit_file}" | grep -m 1 '<testsuite ')

  # Detect format: pytest includes skipped in header, ginkgo doesn't
  IS_PYTEST=false
  if [[ $JUNIT_LINE =~ skipped=\"([0-9]+)\" ]]; then
    IS_PYTEST=true
  fi

  if [[ $JUNIT_LINE =~ failures=\"([0-9]+)\" ]]; then
    JUNIT_FAILURES="${BASH_REMATCH[1]}"
  else
    JUNIT_FAILURES=0
  fi

  if [[ $JUNIT_LINE =~ errors=\"([0-9]+)\" ]]; then
    JUNIT_ERRORS="${BASH_REMATCH[1]}"
  else
    JUNIT_ERRORS=0
  fi

  if [ "$IS_PYTEST" = true ]; then
    # pytest (tier2): tests attribute includes all tests, skipped in header
    if [[ $JUNIT_LINE =~ tests=\"([0-9]+)\" ]]; then
      JUNIT_TOTAL_TESTS="${BASH_REMATCH[1]}"
    else
      JUNIT_TOTAL_TESTS=0
    fi

    if [[ $JUNIT_LINE =~ skipped=\"([0-9]+)\" ]]; then
      JUNIT_SKIPPED="${BASH_REMATCH[1]}"
    else
      JUNIT_SKIPPED=0
    fi

    # Check for disabled attribute (SSP uses this)
    JUNIT_DISABLED=0
    if [[ $JUNIT_LINE =~ disabled=\"([0-9]+)\" ]]; then
      JUNIT_DISABLED="${BASH_REMATCH[1]}"
    fi

    # Total skipped = skipped + disabled
    JUNIT_SKIPPED=$((JUNIT_SKIPPED + JUNIT_DISABLED))
    JUNIT_RUN=$((JUNIT_TOTAL_TESTS - JUNIT_SKIPPED))
  else
    # ginkgo (compute/network/storage): tests attribute is only run tests, count skipped tags
    if [[ $JUNIT_LINE =~ tests=\"([0-9]+)\" ]]; then
      JUNIT_RUN="${BASH_REMATCH[1]}"
    else
      JUNIT_RUN=0
    fi

    JUNIT_SKIPPED=$(grep -c '<skipped' "${junit_file}" || true)
    if [ -z "${JUNIT_SKIPPED}" ]; then
      JUNIT_SKIPPED=0
    fi
  fi

  # Calculate passed tests (run - failures - errors)
  JUNIT_PASSED=$((JUNIT_RUN - JUNIT_FAILURES - JUNIT_ERRORS))

  # Get expected values from summary
  EXPECTED_RUN="${SUMMARY_TESTS_RUN[$SUITE_NAME]}"
  EXPECTED_PASSED="${SUMMARY_TESTS_PASSED[$SUITE_NAME]}"
  EXPECTED_FAILED="${SUMMARY_TESTS_FAILED[$SUITE_NAME]}"
  EXPECTED_SKIPPED="${SUMMARY_TESTS_SKIPPED[$SUITE_NAME]}"

  # Validate counts
  SUITE_VALID=1

  if [ "$JUNIT_RUN" != "$EXPECTED_RUN" ]; then
    echo "  ERROR [$SUITE_NAME]: Tests Run mismatch - JUnit: $JUNIT_RUN, Summary: $EXPECTED_RUN"
    SUITE_VALID=0
  fi

  if [ "$JUNIT_PASSED" != "$EXPECTED_PASSED" ]; then
    echo "  ERROR [$SUITE_NAME]: Tests Passed mismatch - JUnit: $JUNIT_PASSED, Summary: $EXPECTED_PASSED"
    SUITE_VALID=0
  fi

  JUNIT_TOTAL_FAILED=$((JUNIT_FAILURES + JUNIT_ERRORS))
  if [ "$JUNIT_TOTAL_FAILED" != "$EXPECTED_FAILED" ]; then
    echo "  ERROR [$SUITE_NAME]: Tests Failed mismatch - JUnit: $JUNIT_TOTAL_FAILED, Summary: $EXPECTED_FAILED"
    SUITE_VALID=0
  fi

  if [ "$JUNIT_SKIPPED" != "$EXPECTED_SKIPPED" ]; then
    echo "  ERROR [$SUITE_NAME]: Tests Skipped mismatch - JUnit: $JUNIT_SKIPPED, Summary: $EXPECTED_SKIPPED"
    SUITE_VALID=0
  fi

  if [ "$SUITE_VALID" -eq 1 ]; then
    echo "  ✓ $SUITE_NAME: JUnit counts match summary (Run: $JUNIT_RUN, Passed: $JUNIT_PASSED, Failed: $JUNIT_TOTAL_FAILED, Skipped: $JUNIT_SKIPPED)"
  else
    VALIDATION_FAILED=1
  fi
done

if [ "$VALIDATION_FAILED" -eq 1 ]; then
  echo ""
  echo "Error: JUnit validation failed - counts do not match summary log"
  exit 1
fi

echo ""
echo "=== All validation checks passed successfully ==="
