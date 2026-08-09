#!/usr/bin/env bash
# Buffered test-case runner: print --- label ---, spin while the case slot runs with
# stdout+stderr captured; dump the log only on failure. Sourced by suite run.sh.
# Set TEST_VERBOSE=1 (or pass --verbose to ./test.sh) to stream slot output live.
#
# A case slot is the buffered unit under --- label ---. Optional baseline_fn runs
# before the case script (Acceptance/Lifecycle suite baseline); marker is printed
# into the slot log first when baseline_fn is set (hidden on quiet pass).
# Optional after_baseline_fn runs after baseline (stdout captured as mid-state).
# Optional after_case_fn runs after the case as: after_case_fn <mid-state> <case_rc>;
# its failure fails the slot (Environment tree identity gate).

# Usage: run_buffered_case <label> <case_path> [baseline_fn [marker [after_baseline_fn [after_case_fn]]]]
# Returns the slot's exit status. Spinner only when stderr is a TTY (quiet mode).
run_buffered_case() {
  local label="$1"
  local case_path="$2"
  local baseline_fn="${3:-}"
  local marker="${4:-}"
  local after_baseline_fn="${5:-}"
  local after_case_fn="${6:-}"
  local log pid rc i frame
  local spin_chars="|/-\\"

  printf '%s\n' "--- ${label} ---"

  _run_buffered_case_slot() {
    local mid="" case_rc=0 gate_rc=0
    if [[ -n "${baseline_fn}" ]]; then
      if [[ -n "${marker}" ]]; then
        printf '%s\n' "${marker}"
      fi
      "${baseline_fn}" || return $?
    fi
    if [[ -n "${after_baseline_fn}" ]]; then
      mid="$("${after_baseline_fn}")" || return $?
    fi
    set +e
    bash "${case_path}"
    case_rc=$?
    set -e
    if [[ -n "${after_case_fn}" ]]; then
      set +e
      "${after_case_fn}" "${mid}" "${case_rc}"
      gate_rc=$?
      set -e
      if [[ "${gate_rc}" -ne 0 ]]; then
        return "${gate_rc}"
      fi
    fi
    return "${case_rc}"
  }

  if [[ "${TEST_VERBOSE:-}" == "1" ]]; then
    set +e
    _run_buffered_case_slot
    rc=$?
    set -e
    return "${rc}"
  fi

  log="$(mktemp "${TMPDIR:-/tmp}/propraetor-test-case.XXXXXX")" || return 1

  (
    _run_buffered_case_slot
  ) >"${log}" 2>&1 &
  pid=$!

  # Propagate interrupt to the slot; clear on normal completion.
  # shellcheck disable=SC2064  # expand pid/log now for this case
  trap "kill '${pid}' 2>/dev/null || true; rm -f '${log}'; trap - INT TERM; exit 130" INT TERM

  i=0
  if [[ -t 2 ]]; then
    while kill -0 "${pid}" 2>/dev/null; do
      frame="${spin_chars:$((i % 4)):1}"
      printf '\r[%s] ' "${frame}" >&2
      i=$((i + 1))
      sleep 0.1
    done
    # Clear spinner glyphs (CSI K = erase to end of line).
    printf '\r\033[K' >&2
  fi

  set +e
  wait "${pid}"
  rc=$?
  set -e

  trap - INT TERM

  if [[ ${rc} -eq 0 ]]; then
    rm -f "${log}"
    return 0
  fi

  cat "${log}"
  rm -f "${log}"
  return "${rc}"
}
