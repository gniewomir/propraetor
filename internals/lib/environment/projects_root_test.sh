#!/usr/bin/env bash
# Projects root Operator Configuration (ADR-0058).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/projects-root-test.XXXXXX")"
trap 'rm -rf "${TMP}"; unset PROPRAETOR_PROJECTS_ROOT' EXIT

unset PROPRAETOR_PROJECTS_ROOT
if projects_root >/dev/null 2>&1; then
  fail "unset PROPRAETOR_PROJECTS_ROOT must fail closed"
fi
pass "unset fails closed (no default)"

mkdir -p "${TMP}/projects"
export PROPRAETOR_PROJECTS_ROOT="${TMP}/projects"
got="$(projects_root)" || fail "absolute projects_root failed"
[[ "${got}" == "${TMP}/projects" ]] || fail "want ${TMP}/projects, got '${got}'"
pass "absolute PROPRAETOR_PROJECTS_ROOT → that directory"

# HOME override so ~/… expands inside TMP (no write under real home).
export HOME="${TMP}/home"
mkdir -p "${HOME}/projects"
# shellcheck disable=SC2088  # intentional: literal '~/…' Operator Configuration
export PROPRAETOR_PROJECTS_ROOT="~/projects"
# shellcheck disable=SC2088  # intentional: message mentions ~/…
got="$(projects_root)" || fail "~/… projects_root failed"
[[ "${got}" == "${TMP}/home/projects" ]] \
  || fail "want ${TMP}/home/projects, got '${got}'"
# shellcheck disable=SC2088  # intentional: message mentions ~/…
pass "~/… PROPRAETOR_PROJECTS_ROOT → expanded under HOME"

export PROPRAETOR_PROJECTS_ROOT=relative/path
if projects_root >/dev/null 2>&1; then
  fail "relative PROPRAETOR_PROJECTS_ROOT must fail closed"
fi
pass "relative path fails closed"

export PROPRAETOR_PROJECTS_ROOT="${TMP}/no-such-dir"
if projects_root >/dev/null 2>&1; then
  fail "non-directory PROPRAETOR_PROJECTS_ROOT must fail closed"
fi
pass "non-directory fails closed"

echo "All projects_root checks passed."
