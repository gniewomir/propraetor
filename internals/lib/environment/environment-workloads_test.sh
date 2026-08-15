#!/usr/bin/env bash
# Unit tests: Environment Workload discovery by immediate non-hidden dirs (ADR-0047).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=environment-workloads.sh
source "${REPO_ROOT}/internals/lib/environment/environment-workloads.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/env-workloads.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
ENV_DIR="${TMP}/env"
mkdir -p "${ENV_DIR}"

# Empty Environment → no Workloads
got="$(environment_discover_workloads "${ENV_DIR}")"
[[ -z "${got}" ]] || fail "empty env should discover nothing, got: ${got}"
pass "empty Environment discovers no Workloads"

# Non-Workload files and hidden dirs are ignored; Manifest-less dirs are Workloads
printf '{}\n' >"${ENV_DIR}/domains.json"
printf 'X=1\n' >"${ENV_DIR}/.env"
mkdir -p "${ENV_DIR}/.hidden" "${ENV_DIR}/no-manifest"
printf '{"intent":"run"}\n' >"${ENV_DIR}/.hidden/manifest.json"
printf 'note\n' >"${ENV_DIR}/no-manifest/README.md"
got="$(environment_discover_workloads "${ENV_DIR}" | paste -sd, -)"
[[ "${got}" == "no-manifest" ]] || fail "want no-manifest only, got: ${got}"
pass "domains.json, .env, and hidden dirs ignored; Manifest-less dir is a Workload"

# Discover immediate dirs; sort stable; Manifest optional / unvalidated
mkdir -p "${ENV_DIR}/zeta" "${ENV_DIR}/alpha" "${ENV_DIR}/beta"
printf 'not-json\n' >"${ENV_DIR}/zeta/manifest.json"
printf '{"intent":"run"}\n' >"${ENV_DIR}/alpha/manifest.json"
printf '{"intent":"stop"}\n' >"${ENV_DIR}/beta/manifest.json"
# Nested tree must not be discovered (immediate children only)
mkdir -p "${ENV_DIR}/alpha/nested"
printf '{"intent":"run"}\n' >"${ENV_DIR}/alpha/nested/manifest.json"

got="$(environment_discover_workloads "${ENV_DIR}" | paste -sd, -)"
[[ "${got}" == "alpha,beta,no-manifest,zeta" ]] || fail "want alpha,beta,no-manifest,zeta got '${got}'"
pass "discovers immediate Workload dirs sorted; ignores nested; Manifest not required"

echo "All environment-workloads discovery checks passed."
