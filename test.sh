#!/usr/bin/env bash
# Unified test dispatcher (ADR-0036 / ADR-0039 / ADR-0056). Suites live under internals/test/<suite>/run.sh.
# Usage: ./test.sh <suite> [<case-selector>] [--from <token>] [--verbose] [--env <slug>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="${REPO_ROOT}/internals/test"
# shellcheck source=internals/lib/cli.sh
source "${REPO_ROOT}/internals/lib/cli.sh"

usage() {
  cat <<EOF
Usage:
  ./test.sh <suite> [<case-selector>] [--from <token>] [--verbose] [--env <slug>]
  ./test.sh <suite> [--from <token>] [--verbose] [--env <slug>]
  ./test.sh <suite> [--verbose] [--env <slug>]

Suites (subdirectory of internals/test/):
  acceptance   Applied Stack external behavior (Host present; non-destructive)
  lifecycle    Park / Apply-after-Park / Teardown (destructive; opt-in)
  unit         Colocated *_test.sh under internals/ (no Applied Stack)

--from runs the named case through the end of the suite (Acceptance/Lifecycle).
--verbose (or TEST_VERBOSE=1) streams each case slot live instead of quiet-on-pass.
--env is only valid for acceptance and lifecycle (ADR-0019). --from is not valid for unit.
Flags follow positionals; flag order is free (ADR-0039). Case-selector and --from are mutually exclusive.
See docs/agents/testing.md.
EOF
}

fail_usage() {
  echo "FAIL: $*" >&2
  echo >&2
  usage >&2
  exit 1
}

if [[ $# -ge 1 ]]; then
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
  esac
fi

CLI_suite=""
CLI_selector=""
CLI_verbose=0
CLI_env=""
CLI_env_set=0
CLI_from=""
CLI_from_set=0
cli_parse CLI \
  pos:suite:required \
  pos:selector:optional \
  flag:verbose:bool \
  flag:env:value \
  flag:from:value \
  -- "$@" || fail_usage "invalid arguments"

SUITE="${CLI_suite}"
SUITE_DIR="${TEST_ROOT}/${SUITE}"
RUN_SH="${SUITE_DIR}/run.sh"

if [[ ! -d "${SUITE_DIR}" || ! -f "${RUN_SH}" ]]; then
  fail_usage "unknown suite '${SUITE}' (expected a directory with run.sh under internals/test/)"
fi

if [[ "${CLI_verbose}" -eq 1 ]]; then
  export TEST_VERBOSE=1
fi

if [[ "${CLI_env_set}" -eq 1 && "${SUITE}" == "unit" ]]; then
  fail_usage "--env is not valid for suite 'unit'"
fi

if [[ "${CLI_from_set}" -eq 1 && "${SUITE}" == "unit" ]]; then
  fail_usage "--from is not valid for suite 'unit'"
fi

if [[ -n "${CLI_selector}" && "${CLI_from_set}" -eq 1 ]]; then
  fail_usage "case-selector and --from are mutually exclusive"
fi

SELECTOR_ARGS=()
if [[ -n "${CLI_selector}" ]]; then
  SELECTOR_ARGS=("${CLI_selector}")
fi

FROM_ARGS=()
if [[ "${CLI_from_set}" -eq 1 ]]; then
  FROM_ARGS=(--from "${CLI_from}")
fi

ENV_ARGS=()
if [[ "${CLI_env_set}" -eq 1 ]]; then
  ENV_ARGS=(--env "${CLI_env}")
fi

exec bash "${RUN_SH}" \
  ${SELECTOR_ARGS[@]+"${SELECTOR_ARGS[@]}"} \
  ${FROM_ARGS[@]+"${FROM_ARGS[@]}"} \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"}
