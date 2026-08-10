#!/usr/bin/env bash
# Environments root Operator Configuration (ADR-0051).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=environment.sh
source "${REPO_ROOT}/internals/lib/environment/environment.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/environments-root-test.XXXXXX")"
trap 'rm -rf "${TMP}"; unset PROPRAETOR_ENVIRONMENTS_ROOT' EXIT

unset PROPRAETOR_ENVIRONMENTS_ROOT
got="$(environments_root)" || fail "default environments_root failed"
[[ "${got}" == "${REPO_ROOT}/environments" ]] \
  || fail "want default ${REPO_ROOT}/environments, got '${got}'"
pass "unset → repo environments/"

mkdir -p "${TMP}/envs/test"
export PROPRAETOR_ENVIRONMENTS_ROOT="${TMP}/envs"
got="$(environments_root)" || fail "relocated environments_root failed"
[[ "${got}" == "${TMP}/envs" ]] || fail "want ${TMP}/envs, got '${got}'"
pass "absolute PROPRAETOR_ENVIRONMENTS_ROOT → that directory"

dir="$(environments_dir_for test)" || fail "environments_dir_for test failed"
[[ "${dir}" == "${TMP}/envs/test" ]] || fail "want ${TMP}/envs/test, got '${dir}'"
pass "environments_dir_for → <root>/<slug>"

if environments_dir_for missing-slug >/dev/null 2>&1; then
  fail "missing slug directory must fail closed"
fi
pass "missing <root>/<slug>/ fails closed"

export PROPRAETOR_ENVIRONMENTS_ROOT=relative/path
if environments_root >/dev/null 2>&1; then
  fail "relative PROPRAETOR_ENVIRONMENTS_ROOT must fail closed"
fi
pass "relative path fails closed"

export PROPRAETOR_ENVIRONMENTS_ROOT="${TMP}/no-such-dir"
if environments_root >/dev/null 2>&1; then
  fail "non-directory PROPRAETOR_ENVIRONMENTS_ROOT must fail closed"
fi
pass "non-directory fails closed"

unset PROPRAETOR_ENVIRONMENTS_ROOT
environments_forbid_relocated_root || fail "unset must allow suites"
export PROPRAETOR_ENVIRONMENTS_ROOT="${TMP}/envs"
if environments_forbid_relocated_root >/dev/null 2>&1; then
  fail "set PROPRAETOR_ENVIRONMENTS_ROOT must forbid Acceptance/Lifecycle"
fi
pass "suites forbid relocated root when set"

unset PROPRAETOR_ENVIRONMENTS_ROOT
environments_export_tf_var || fail "export tf var failed"
[[ "${TF_VAR_environments_root}" == "${REPO_ROOT}/environments" ]] \
  || fail "TF_VAR default mismatch: ${TF_VAR_environments_root-}"
pass "environments_export_tf_var sets TF_VAR_environments_root"

echo "All environments_root checks passed."
