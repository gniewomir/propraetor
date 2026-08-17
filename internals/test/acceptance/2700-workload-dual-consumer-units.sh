#!/usr/bin/env bash
# Acceptance Test: unified systemd/ bag + Quadlet directory symlink farm — #216 / ADR-0054
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track unified-ok unified-empty bad-ext clash-sys
trap 'acceptance_wl_cleanup' EXIT

# --- unified-ok: Quadlet + native under one systemd/ bag ---
mkdir -p "${FIX_DIR}/unified-ok/systemd"
acceptance_write_artifact_stubs "${FIX_DIR}/unified-ok"
cat >"${FIX_DIR}/unified-ok/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
cat >"${FIX_DIR}/unified-ok/systemd/unified-ok.container" <<'EOF'
[Unit]
Description=unified-ok container

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=unified-ok
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
cat >"${FIX_DIR}/unified-ok/systemd/unified-ok-probe.service" <<'EOF'
[Unit]
Description=unified-ok native oneshot

[Service]
Type=oneshot
ExecStart=/bin/true

[Install]
WantedBy=default.target
EOF
cat >"${FIX_DIR}/unified-ok/systemd/unified-ok-probe.timer" <<'EOF'
[Unit]
Description=unified-ok native timer

[Timer]
OnBootSec=1h
Unit=unified-ok-probe.service

[Install]
WantedBy=timers.target
EOF

# --- unified-empty: missing systemd/ must fail (≥1 unit) ---
mkdir -p "${FIX_DIR}/unified-empty"
acceptance_write_artifact_stubs "${FIX_DIR}/unified-empty"
cat >"${FIX_DIR}/unified-empty/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF

# --- bad-ext: unsupported extension under systemd/ ---
mkdir -p "${FIX_DIR}/bad-ext/systemd"
acceptance_write_artifact_stubs "${FIX_DIR}/bad-ext"
cat >"${FIX_DIR}/bad-ext/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
printf 'not-a-unit\n' >"${FIX_DIR}/bad-ext/systemd/nope.txt"
printf '[Container]\nImage=docker.io/library/nginx:1.31.3-alpine\n' \
  >"${FIX_DIR}/bad-ext/systemd/ok.container"

# --- clash-sys: claim Component native systemd basename ---
mkdir -p "${FIX_DIR}/clash-sys/systemd"
acceptance_write_artifact_stubs "${FIX_DIR}/clash-sys"
cat >"${FIX_DIR}/clash-sys/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
cat >"${FIX_DIR}/clash-sys/systemd/edge-acme.timer" <<'EOF'
[Unit]
Description=should collide with Edge

[Timer]
OnBootSec=1h

[Install]
WantedBy=timers.target
EOF

host_ssh bash -s <<'REMOTE'
set -euo pipefail
for n in unified-ok unified-empty bad-ext clash-sys; do
  rm -rf "/host-volume/workloads/${n}"
  rm -f "/home/platform/.config/containers/systemd/workload-${n}"
done
rm -f /home/platform/.config/systemd/user/unified-ok-probe.service \
  /home/platform/.config/systemd/user/unified-ok-probe.timer
REMOTE

"${REPO_ROOT}/internals/ensure-workload.sh" "unified-ok" --env "${PLATFORM_ENV:-test}"

host_ssh "test -f /host-volume/workloads/unified-ok/systemd/unified-ok.container" \
  || fail "Host Volume SoT missing unified-ok container"
host_ssh "test -f /host-volume/workloads/unified-ok/systemd/unified-ok-probe.service" \
  || fail "Host Volume SoT missing unified-ok native service"
host_ssh "test -L /home/platform/.config/containers/systemd/workload-unified-ok" \
  || fail "expected Quadlet farm directory symlink"
host_ssh "test -f /home/platform/.config/containers/systemd/workload-unified-ok/unified-ok.container" \
  || fail "Quadlet must be visible via farm symlink"
host_ssh "test ! -e /home/platform/.config/containers/systemd/unified-ok.container" \
  || fail "must not flat-install Quadlet into UNIT_DIR"
host_ssh "test -f /home/platform/.config/systemd/user/unified-ok-probe.service" \
  || fail "Platform User systemd dir missing native service"
host_ssh "test -f /home/platform/.config/systemd/user/unified-ok-probe.timer" \
  || fail "Platform User systemd dir missing native timer"
pass "Workload Setup installs unified systemd/ via farm symlink + native copies"

reject_setup() {
  local label="$1"
  local name="$2"
  local needle="$3"
  set +e
  "${REPO_ROOT}/internals/ensure-workload.sh" "${name}" --env "${PLATFORM_ENV:-test}" \
    >/tmp/unified-systemd-setup.out 2>&1
  local rc=$?
  set -e
  [[ ${rc} -ne 0 ]] || fail "expected failure for ${label}"
  grep -qiE "${needle}" /tmp/unified-systemd-setup.out \
    || fail "${label} rejection unclear (output: $(cat /tmp/unified-systemd-setup.out))"
}

reject_setup "empty systemd/ bag" "unified-empty" "systemd/ bag missing|need ≥1|need >=1|empty"
pass "Workload Setup fails closed when systemd/ bag is missing/empty"

reject_setup "unsupported extension" "bad-ext" "unsupported extension"
pass "Workload Setup fails closed on unsupported systemd/ extension"

reject_setup "native systemd basename vs Edge" "clash-sys" \
  "edge-acme|already exists|not owned"
pass "Workload Setup refuses basename spanning Host unit directories (clash with Edge timer)"
