#!/usr/bin/env bash
# Offline tests: Identity first-admin bootstrap prints one-time login URL (ADR-0057).
# Stubs Pocket ID admin HTTP; does not talk to Pocket ID.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=identity-setup-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/identity-setup-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/identity-bootstrap.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

HOME_DIR="${TMP}/home"
DATA_ROOT="${TMP}/data"
ADMIN_ENV="${DATA_ROOT}/admin/environment"
mkdir -p "${HOME_DIR}" "${DATA_ROOT}/admin"
cat >"${ADMIN_ENV}" <<'EOF'
STATIC_API_KEY=test-api-key-0123456789
ENCRYPTION_KEY=test-encryption-key
IDENTITY_ADMIN_EMAIL=ops@example.test
APP_URL=https://auth.example.test
EOF

POCKET_ID_STATE="${TMP}/pocket-id-state.json"
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"setup_available": True, "users": [], "tokens": {}}, f)
PY

identity_pocket_id_admin_curl() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  python3 - "${POCKET_ID_STATE}" "${method}" "${path}" "${body}" <<'PY'
import json, sys

state_path, method, path, body = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(state_path, encoding="utf-8") as f:
    state = json.load(f)

if method == "GET" and path == "/api/signup/setup":
    if state.get("setup_available"):
        # 204 No Content — empty body, success via admin_curl (<400).
        print("")
        raise SystemExit(0)
    print(json.dumps({"error": "Not found", "code": "setup_not_available"}))
    raise SystemExit(1)

if method == "POST" and path == "/api/users":
    payload = json.loads(body or "{}")
    if not payload.get("isAdmin"):
        raise SystemExit("create must set isAdmin true")
    if payload.get("email") != "ops@example.test":
        raise SystemExit(f"unexpected email {payload.get('email')!r}")
    user = {
        "id": "user-admin-1",
        "username": payload["username"],
        "email": payload["email"],
        "isAdmin": True,
    }
    state["users"].append(user)
    state["setup_available"] = False
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print(json.dumps(user))
    raise SystemExit(0)

if method == "POST" and path.endswith("/one-time-access-token"):
    user_id = path.split("/")[3]
    if user_id != "user-admin-1":
        raise SystemExit(f"unexpected user id {user_id!r}")
    token = "otk-test-token-abc"
    state["tokens"][user_id] = token
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print(json.dumps({"token": token}))
    raise SystemExit(0)

raise SystemExit(f"unexpected {method} {path}")
PY
}

# --- first deploy: create admin + print /lc/{token} ---
out="$(mktemp "${TMP}/out.XXXXXX")"
err="$(mktemp "${TMP}/err.XXXXXX")"
identity_bootstrap_first_admin >"${out}" 2>"${err}" \
  || fail "bootstrap on empty Pocket ID must succeed"
grep -Fq 'https://auth.example.test/lc/otk-test-token-abc' "${err}" \
  || fail "bootstrap must print one-time login URL on stderr (got: $(cat "${err}"))"
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
assert len(state["users"]) == 1, state
assert state["users"][0]["isAdmin"] is True
assert state["setup_available"] is False
assert state["tokens"]["user-admin-1"] == "otk-test-token-abc"
PY
pass "first deploy creates admin and prints /lc/{token}"

# --- re-deploy: setup already completed → noop, no second user ---
: >"${err}"
identity_bootstrap_first_admin >"${out}" 2>"${err}" \
  || fail "bootstrap when setup completed must succeed as noop"
if grep -Fq '/lc/' "${err}"; then
  fail "completed setup must not print a new one-time URL"
fi
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
assert len(state["users"]) == 1, state
PY
pass "re-deploy skips bootstrap when setup completed"

# --- standing ensure contract calls bootstrap ---
grep -Fq 'identity_bootstrap_first_admin' \
  "${REPO_ROOT}/internals/host-scripts/lib/identity-setup-host.sh" \
  || fail "standing ensure must invoke identity_bootstrap_first_admin"
pass "standing ensure wires first-admin bootstrap"

echo "All identity-bootstrap-host offline tests passed."
