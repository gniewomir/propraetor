#!/usr/bin/env bash
# Fail if Stack Domain config path no longer resolves to Environments root (ADR-0021 / ADR-0033 / ADR-0051).
# Regression: after moving the Stack under internals/, a wrong relative path loaded Domains as {} —
# Cloud Project membership dropped Domain URNs on Apply.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STACK_DIR="${REPO_ROOT}/internals/terraform"
DOMAIN_TF="${STACK_DIR}/domain.tf"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${DOMAIN_TF}" ]] || fail "missing ${DOMAIN_TF}"

# Contract: domains_dir uses var.environments_root when set, else ../../environments (ADR-0051).
if ! grep -Eq 'environments_root_effective' "${DOMAIN_TF}"; then
  fail "domain.tf must define environments_root_effective (ADR-0051)"
fi
if ! grep -Eq 'var\.environments_root' "${DOMAIN_TF}"; then
  fail "domain.tf must honor var.environments_root"
fi
if ! grep -Eq '\$\{path\.root\}/\.\./\.\./environments' "${DOMAIN_TF}"; then
  fail "domain.tf default Environments root must be ../../environments from the Stack root"
fi

resolved="$(cd "${STACK_DIR}/../../environments" && pwd)"
expected="$(cd "${REPO_ROOT}/environments" && pwd)"
[[ "${resolved}" == "${expected}" ]] \
  || fail "Stack ../../environments resolves to ${resolved}, expected ${expected}"

pass "Domain config path resolves to repository environments/"
