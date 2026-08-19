#!/usr/bin/env bash
# Identity issuer hostname contract (ADR-0057 / #251).
# Seam: identity_config_*.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=identity-config.sh
source "${REPO_ROOT}/internals/lib/identity/identity-config.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/identity-config.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
REPO_ROOT="${TMP}"

mkdir -p "${TMP}/environments/valid"
printf '%s\n' '{"enraged.dev":{"names":["@","auth"]}}' \
  >"${TMP}/environments/valid/domains.json"
printf '%s\n' '{"fqdn":"auth.enraged.dev"}' \
  >"${TMP}/environments/valid/identity.json"

path="$(identity_config_path valid)" \
  || fail "identity_config_path failed"
[[ "${path}" == "${TMP}/environments/valid/identity.json" ]] \
  || fail "identity_config_path wrong: ${path}"
pass "identity_config_path resolves committed file"

identity_config_validate valid || fail "valid identity.json must pass"
got="$(identity_config_issuer_fqdn_for valid)" \
  || fail "issuer_fqdn_for valid failed"
[[ "${got}" == "auth.enraged.dev" ]] || fail "want auth.enraged.dev, got '${got}'"
pass "valid issuer FQDN on want-list"

stage="${TMP}/staged.json"
identity_config_stage_for valid "${stage}" || fail "stage_for valid failed"
python3 - "${stage}" <<'PY' || fail "staged identity.json content wrong"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
assert raw == {"fqdn": "auth.enraged.dev"}, raw
PY
pass "stage_for copies validated identity.json"

# Missing identity.json → fail closed.
mkdir -p "${TMP}/environments/missing"
printf '%s\n' '{"example.test":{"names":["@"]}}' \
  >"${TMP}/environments/missing/domains.json"
if identity_config_validate missing >/dev/null 2>"${TMP}/err-missing"; then
  fail "missing identity.json must fail closed"
fi
grep -Eqi 'identity\.json missing|fail closed' "${TMP}/err-missing" \
  || fail "missing identity.json rejection unclear: $(cat "${TMP}/err-missing")"
pass "missing identity.json fails closed"

# Invalid issuer FQDN (not on want-list) → fail closed.
mkdir -p "${TMP}/environments/bad-fqdn"
printf '%s\n' '{"example.test":{"names":["@"]}}' \
  >"${TMP}/environments/bad-fqdn/domains.json"
printf '%s\n' '{"fqdn":"other.example.test"}' \
  >"${TMP}/environments/bad-fqdn/identity.json"
if identity_config_validate bad-fqdn >/dev/null 2>"${TMP}/err-bad"; then
  fail "off want-list issuer FQDN must fail closed"
fi
grep -Eqi 'want-list|fail closed|other\.example\.test' "${TMP}/err-bad" \
  || fail "bad fqdn rejection unclear: $(cat "${TMP}/err-bad")"
pass "issuer FQDN off want-list fails closed"

# Empty fqdn → fail closed.
mkdir -p "${TMP}/environments/empty-fqdn"
printf '%s\n' '{"example.test":{"names":["@","auth"]}}' \
  >"${TMP}/environments/empty-fqdn/domains.json"
printf '%s\n' '{"fqdn":""}' >"${TMP}/environments/empty-fqdn/identity.json"
if identity_config_validate empty-fqdn >/dev/null 2>&1; then
  fail "empty fqdn must fail closed"
fi
pass "empty issuer FQDN fails closed"

# Unexpected keys → fail closed.
mkdir -p "${TMP}/environments/extra-key"
printf '%s\n' '{"example.test":{"names":["@","auth"]}}' \
  >"${TMP}/environments/extra-key/domains.json"
printf '%s\n' '{"fqdn":"auth.example.test","extra":true}' \
  >"${TMP}/environments/extra-key/identity.json"
if identity_config_validate extra-key >/dev/null 2>&1; then
  fail "unexpected identity.json keys must fail closed"
fi
pass "unexpected identity.json keys fail closed"

echo "All identity-config unit tests passed."
