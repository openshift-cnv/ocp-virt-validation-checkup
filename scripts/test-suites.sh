#!/bin/bash
# Shared TEST_SUITES parsing for generate.sh, entrypoint.sh, and test-tier2.sh.
#
# New syntax:  tier1/<sig>,tier2/<sig>
# Legacy:      compute,network,storage,ssp,tier2  (kept as aliases)
#
# After resolve_test_suites "$TEST_SUITES":
#   RESOLVED_TIER1_SUITES     - comma-separated: compute,network,storage,ssp
#   RESOLVED_TIER2_SUITES     - comma-separated: compute,storage,network,infrastructure,windows
#   TIER2_ALL_MODULES        - "true" when legacy `tier2` was selected (unrestricted OVT paths)
#   PROGRESS_SUITES          - comma-separated execution units for progress_watcher
#                              (tier1 SIGs + "tier2" if any tier2 selected)
#
# Windows exists only under Tier-2. ACCEPT_WINDOWS_EULA=true always adds tier2/windows.

TIER1_SIGS="compute network storage ssp"
TIER2_SIGS="compute storage network infrastructure windows"
TIER2_PATH_SIGS="compute storage network infrastructure"

TIER2_PATH_compute="tests/virt"
TIER2_PATH_storage="tests/storage"
TIER2_PATH_network="tests/network"
TIER2_PATH_infrastructure="tests/infrastructure"

# Returns 0 if needle is in comma-separated haystack.
_suite_list_contains() {
  local haystack="$1"
  local needle="$2"
  local item
  IFS=',' read -ra _items <<< "${haystack}"
  for item in "${_items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

# Append $2 to the variable named by $1 if not already present (comma-separated).
_append_unique() {
  local var_name="$1"
  local value="$2"
  local current="${!var_name}"
  if [[ -z "${current}" ]]; then
    printf -v "${var_name}" '%s' "${value}"
    return
  fi
  if ! _suite_list_contains "${current}" "${value}"; then
    printf -v "${var_name}" '%s' "${current},${value}"
  fi
}

_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# Validate a single suite token. Prints error to stderr and returns 1 on failure.
validate_suite_token() {
  local token="$1"
  case "${token}" in
    compute|network|storage|ssp|tier2)
      return 0
      ;;
    tier1/compute|tier1/network|tier1/storage|tier1/ssp)
      return 0
      ;;
    tier2/compute|tier2/storage|tier2/network|tier2/infrastructure|tier2/windows)
      return 0
      ;;
    *)
      echo "Invalid TEST_SUITES entry: \"${token}\"" >&2
      echo "Allowed legacy values: compute, network, storage, ssp, tier2" >&2
      echo "Allowed hierarchical values: tier1/{compute,network,storage,ssp}, tier2/{compute,storage,network,infrastructure,windows}" >&2
      echo "Note: Windows exists only under Tier-2 (tier2/windows). There is no tier1/windows." >&2
      return 1
      ;;
  esac
}

validate_test_suites() {
  local input="$1"
  local token
  if [[ -z "${input}" ]]; then
    echo "Invalid TEST_SUITES: empty value" >&2
    return 1
  fi
  # Reject malformed lists that bash "read -ra" would silently drop
  # (trailing/leading comma) or that contain empty fields.
  if [[ "${input}" == ,* || "${input}" == *, || "${input}" == *,,* ]]; then
    echo "Invalid TEST_SUITES: empty entry in \"${input}\"" >&2
    echo "Expected a comma-separated list without leading/trailing/duplicate commas." >&2
    return 1
  fi
  IFS=',' read -ra _tokens <<< "${input}"
  for token in "${_tokens[@]}"; do
    token="$(_trim "${token}")"
    if [[ -z "${token}" ]]; then
      echo "Invalid TEST_SUITES: empty entry in \"${input}\"" >&2
      return 1
    fi
    validate_suite_token "${token}" || return 1
  done
  return 0
}

# Resolve TEST_SUITES into RESOLVED_TIER1_SUITES / RESOLVED_TIER2_SUITES / PROGRESS_SUITES.
# Emits non-fatal warnings for bare legacy aliases when Tier-2 was not also requested.
resolve_test_suites() {
  local input="$1"
  RESOLVED_TIER1_SUITES=""
  RESOLVED_TIER2_SUITES=""
  PROGRESS_SUITES=""
  TIER2_ALL_MODULES="false"

  validate_test_suites "${input}" || return 1

  local token
  local input_requests_tier2="false"
  IFS=',' read -ra _tokens <<< "${input}"
  for token in "${_tokens[@]}"; do
    token="$(_trim "${token}")"
    case "${token}" in
      tier2|tier2/*)
        input_requests_tier2="true"
        ;;
    esac
  done

  for token in "${_tokens[@]}"; do
    token="$(_trim "${token}")"
    case "${token}" in
      compute|network|storage|ssp)
        # Warn only for subset runs where partners may think bare names include Tier-2.
        # Skip noise when legacy `tier2` (or any tier2/*) is already in the same list,
        # and skip ssp (no Tier-2 ssp equivalent).
        if [[ "${input_requests_tier2}" != "true" && "${token}" != "ssp" ]]; then
          echo "WARNING: '${token}' maps to tier1/${token} only. To include Tier-2 coverage use tier1/${token},tier2/${token}." >&2
        fi
        _append_unique RESOLVED_TIER1_SUITES "${token}"
        ;;
      tier2)
        # Legacy blob: all Tier-2 SIGs + unrestricted OVT module paths (same as today).
        TIER2_ALL_MODULES="true"
        local sig
        for sig in ${TIER2_SIGS}; do
          _append_unique RESOLVED_TIER2_SUITES "${sig}"
        done
        ;;
      tier1/*)
        _append_unique RESOLVED_TIER1_SUITES "${token#tier1/}"
        ;;
      tier2/*)
        _append_unique RESOLVED_TIER2_SUITES "${token#tier2/}"
        ;;
    esac
  done

  # Windows exists only under Tier-2. The Accept EULA control enables Windows
  # testing, so when ACCEPT_WINDOWS_EULA=true always include tier2/windows.
  WINDOWS_ADDED_BY_EULA="false"
  if [ "${ACCEPT_WINDOWS_EULA}" == "true" ]; then
    if ! _suite_list_contains "${RESOLVED_TIER2_SUITES}" "windows"; then
      echo "ACCEPT_WINDOWS_EULA=true: adding tier2/windows (Windows is Tier-2 only)." >&2
      _append_unique RESOLVED_TIER2_SUITES "windows"
      WINDOWS_ADDED_BY_EULA="true"
    fi
  fi

  _rebuild_progress_suites
  return 0
}

# Rebuild PROGRESS_SUITES from the current RESOLVED_* selection.
_rebuild_progress_suites() {
  PROGRESS_SUITES=""
  local sig
  IFS=',' read -ra _t1 <<< "${RESOLVED_TIER1_SUITES}"
  for sig in "${_t1[@]}"; do
    [[ -z "${sig}" ]] && continue
    _append_unique PROGRESS_SUITES "${sig}"
  done
  if [[ -n "${RESOLVED_TIER2_SUITES}" ]]; then
    _append_unique PROGRESS_SUITES "tier2"
  fi
}

# Remove a SIG from a comma-separated suite list variable.
remove_from_suite_list() {
  local var_name="$1"
  local remove="$2"
  local current="${!var_name}"
  local result=""
  local item
  IFS=',' read -ra _items <<< "${current}"
  for item in "${_items[@]}"; do
    item="$(_trim "${item}")"
    [[ -z "${item}" || "${item}" == "${remove}" ]] && continue
    if [[ -z "${result}" ]]; then
      result="${item}"
    else
      result="${result},${item}"
    fi
  done
  printf -v "${var_name}" '%s' "${result}"
}

# After Windows setup is skipped for prerequisites, drop Windows that was only
# added by ACCEPT_WINDOWS_EULA so Tier-1 (and other) suites can finish cleanly.
drop_eula_added_windows() {
  if [[ "${WINDOWS_ADDED_BY_EULA}" != "true" ]]; then
    return 0
  fi
  echo "Removing implicitly added tier2/windows after Windows setup skip." >&2
  remove_from_suite_list RESOLVED_TIER2_SUITES "windows"
  WINDOWS_ADDED_BY_EULA="false"
  _rebuild_progress_suites
}

tier1_enabled() {
  local sig="$1"
  _suite_list_contains "${RESOLVED_TIER1_SUITES}" "${sig}"
}

tier2_enabled() {
  [[ -n "${RESOLVED_TIER2_SUITES}" ]]
}

tier2_sig_enabled() {
  local sig="$1"
  _suite_list_contains "${RESOLVED_TIER2_SUITES}" "${sig}"
}

# True when Windows golden-image setup should run for this selection.
tier2_windows_setup_needed() {
  tier2_sig_enabled "windows"
}

# True when the only Tier-2 SIG selected is windows (no path SIGs).
tier2_windows_only() {
  tier2_sig_enabled "windows" || return 1
  local sig
  for sig in ${TIER2_PATH_SIGS}; do
    if tier2_sig_enabled "${sig}"; then
      return 1
    fi
  done
  return 0
}

# Build pytest path args for selected Tier-2 module SIGs (excludes windows).
# Sets TIER2_PATH_ARGS as a bash array.
# Empty array means unrestricted modules when:
#   - legacy `tier2` was selected (TIER2_ALL_MODULES=true), or
#   - windows-only selection (no path SIGs)
# Hierarchical path SIGs always get explicit paths. Mixed path+windows runs keep
# these paths for the non-Windows phase and run Windows in a second phase.
build_tier2_path_args() {
  TIER2_PATH_ARGS=()
  local selected_paths=()
  local sig path
  local selected_count=0

  if [[ "${TIER2_ALL_MODULES}" == "true" ]]; then
    TIER2_PATH_ARGS=()
    return 0
  fi

  for sig in ${TIER2_PATH_SIGS}; do
    if tier2_sig_enabled "${sig}"; then
      selected_count=$((selected_count + 1))
      case "${sig}" in
        compute) path="${TIER2_PATH_compute}" ;;
        storage) path="${TIER2_PATH_storage}" ;;
        network) path="${TIER2_PATH_network}" ;;
        infrastructure) path="${TIER2_PATH_infrastructure}" ;;
      esac
      selected_paths+=("${path}")
    fi
  done

  # No path SIGs (windows-only / empty) → unrestricted.
  if [[ ${selected_count} -eq 0 ]]; then
    TIER2_PATH_ARGS=()
    return 0
  fi

  TIER2_PATH_ARGS=("${selected_paths[@]}")
}

# PVC Gi estimate from a raw TEST_SUITES string (used by generate.sh).
# Tier-1 SIG: +2Gi each. Any Tier-2 selection: +10Gi once.
estimate_storage_gi_for_suites() {
  local input="$1"
  resolve_test_suites "${input}" || return 1
  local total=0
  local sig
  IFS=',' read -ra _t1 <<< "${RESOLVED_TIER1_SUITES}"
  for sig in "${_t1[@]}"; do
    [[ -z "${sig}" ]] && continue
    total=$((total + 2))
  done
  if [[ -n "${RESOLVED_TIER2_SUITES}" ]]; then
    total=$((total + 10))
  fi
  # Floor so a theoretically empty resolution still gets a usable PVC.
  if [[ ${total} -eq 0 ]]; then
    total=2
  fi
  echo "${total}"
}
