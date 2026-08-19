#!/usr/bin/env bash
# Unit tests: API-side marker scope enforcement (ADR-0057 / #255).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MOD="${REPO_ROOT}/internals/lib/identity/identity_api_auth.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${MOD}" ]] || fail "missing ${MOD}"

python3 - "${MOD}" <<'PY'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("identity_api_auth", path)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

# scope parsing accepts RFC 9068 scp list and space-delimited scope string
claims = {"scope": "alpha:api alpha:read"}
scopes = mod.scopes_from_claims(claims)
if scopes != {"alpha:api", "alpha:read"}:
    raise SystemExit(f"scope string parse failed: {scopes!r}")

claims = {"scp": ["beta:api", "beta:write"]}
scopes = mod.scopes_from_claims(claims)
if scopes != {"beta:api", "beta:write"}:
    raise SystemExit(f"scp list parse failed: {scopes!r}")

try:
    mod.require_marker_in_scope({"alpha:read"}, "alpha:api")
except mod.AuthorizationError:
    pass
else:
    raise SystemExit("missing marker must raise AuthorizationError")

mod.require_marker_in_scope({"alpha:api", "alpha:read"}, "alpha:api")

try:
    mod.authorize_bearer_header(None, issuer="https://id.test", jwks_url="https://id.test/jwks", audience="propreator:test", marker_key="alpha:api")
except mod.AuthorizationError as exc:
    if "missing Authorization" not in str(exc):
        raise SystemExit(f"unexpected error for missing header: {exc}") from exc
else:
    raise SystemExit("missing Authorization header must fail closed")

try:
    mod.authorize_bearer_header("Token abc", issuer="https://id.test", jwks_url="https://id.test/jwks", audience="propreator:test", marker_key="alpha:api")
except mod.AuthorizationError as exc:
    if "Bearer scheme" not in str(exc):
        raise SystemExit(f"unexpected error for non-Bearer header: {exc}") from exc
else:
    raise SystemExit("non-Bearer Authorization must fail closed")
PY
pass "marker scope helpers reject missing marker and malformed Authorization"

PYJWT_OK=0
python3 - <<'PY' >/dev/null 2>&1 && PYJWT_OK=1 || true
import jwt  # noqa: F401
from jwt import PyJWKClient  # noqa: F401
PY

if [[ "${PYJWT_OK}" -eq 1 ]]; then
  pass "PyJWT available for integration-style JWT validation tests"
else
  echo "SKIP: PyJWT not installed locally — marker unit logic covered; JWT verify covered by Acceptance #5660"
fi

echo "identity_api_auth_test: all tests passed"
