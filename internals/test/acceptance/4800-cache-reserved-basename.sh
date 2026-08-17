#!/usr/bin/env bash
# Acceptance Test: Workload basename `cache` fails closed (ADR-0055 / #221).
# Dial identity on the Service Network is reserved for the Cache Component.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=cache
acceptance_wl_track "${WL}"
err="$(mktemp "${TMPDIR:-/tmp}/platform-cache-basename.XXXXXX")"
trap 'rm -f "${err}"; acceptance_wl_cleanup' EXIT

mkdir -p "${FIX_DIR}/${WL}/systemd"
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<'EOF'
[Unit]
Description=must not install — basename reserved

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=cache-clash
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

if "${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}" >/dev/null 2>"${err}"; then
  fail "Workload basename cache must fail closed"
fi
grep -Eqi 'cache|reserved|dial' "${err}" \
  || fail "basename rejection unclear: $(cat "${err}")"
pass "Workload basename cache fails closed"
