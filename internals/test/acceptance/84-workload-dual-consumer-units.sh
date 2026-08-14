#!/usr/bin/env bash
# Acceptance Test: dual-consumer Workload units (quadlets/ + systemd/) — #100 / ADR-0024
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
acceptance_wl_track dual-ok dual-empty wrong-q wrong-s clash-sys
trap 'acceptance_wl_cleanup' EXIT

# --- dual-ok: both consumers present ---
mkdir -p "${FIX_DIR}/dual-ok/quadlets" "${FIX_DIR}/dual-ok/systemd"
acceptance_write_artifact_stubs "${FIX_DIR}/dual-ok"
cat >"${FIX_DIR}/dual-ok/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
cat >"${FIX_DIR}/dual-ok/quadlets/dual-ok.container" <<'EOF'
[Unit]
Description=dual-ok container

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=dual-ok
Network=service-network.network

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
cat >"${FIX_DIR}/dual-ok/systemd/dual-ok-probe.service" <<'EOF'
[Unit]
Description=dual-ok native oneshot

[Service]
Type=oneshot
ExecStart=/bin/true

[Install]
WantedBy=default.target
EOF
cat >"${FIX_DIR}/dual-ok/systemd/dual-ok-probe.timer" <<'EOF'
[Unit]
Description=dual-ok native timer

[Timer]
OnBootSec=1h
Unit=dual-ok-probe.service

[Install]
WantedBy=timers.target
EOF

# --- dual-empty: missing both consumer dirs (valid) ---
mkdir -p "${FIX_DIR}/dual-empty"
acceptance_write_artifact_stubs "${FIX_DIR}/dual-empty"
cat >"${FIX_DIR}/dual-empty/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF

# --- wrong-q: native unit under quadlets/ ---
mkdir -p "${FIX_DIR}/wrong-q/quadlets"
acceptance_write_artifact_stubs "${FIX_DIR}/wrong-q"
cat >"${FIX_DIR}/wrong-q/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
cat >"${FIX_DIR}/wrong-q/quadlets/misplaced.timer" <<'EOF'
[Unit]
Description=belongs in systemd/

[Timer]
OnBootSec=1h

[Install]
WantedBy=timers.target
EOF

# --- wrong-s: Quadlet under systemd/ ---
mkdir -p "${FIX_DIR}/wrong-s/systemd"
acceptance_write_artifact_stubs "${FIX_DIR}/wrong-s"
cat >"${FIX_DIR}/wrong-s/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
cat >"${FIX_DIR}/wrong-s/systemd/misplaced.container" <<'EOF'
[Unit]
Description=belongs in quadlets/

[Container]
Image=docker.io/library/nginx:1.31.3-alpine
ContainerName=misplaced

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

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
for n in dual-ok dual-empty wrong-q wrong-s clash-sys; do
  rm -rf "/var/lib/host-volume/internals/workloads/${n}"
done
rm -f /home/platform/.config/containers/systemd/dual-ok.container \
  /home/platform/.config/systemd/user/dual-ok-probe.service \
  /home/platform/.config/systemd/user/dual-ok-probe.timer
REMOTE

"${REPO_ROOT}/internals/ensure-workload.sh" "dual-ok" --env "${PLATFORM_ENV:-test}"

host_ssh "test -f /var/lib/host-volume/internals/workloads/dual-ok/quadlets/dual-ok.container" \
  || fail "Host Volume SoT missing dual-ok quadlet"
host_ssh "test -f /var/lib/host-volume/internals/workloads/dual-ok/systemd/dual-ok-probe.service" \
  || fail "Host Volume SoT missing dual-ok systemd service"
host_ssh "test -f /var/lib/host-volume/internals/workloads/dual-ok/systemd/dual-ok-probe.timer" \
  || fail "Host Volume SoT missing dual-ok systemd timer"
host_ssh "test -f /home/platform/.config/containers/systemd/dual-ok.container" \
  || fail "Platform User Quadlet dir missing dual-ok.container"
host_ssh "test -f /home/platform/.config/systemd/user/dual-ok-probe.service" \
  || fail "Platform User systemd dir missing dual-ok-probe.service"
host_ssh "test -f /home/platform/.config/systemd/user/dual-ok-probe.timer" \
  || fail "Platform User systemd dir missing dual-ok-probe.timer"
pass "Workload Setup installs quadlets/ + systemd/ into matching Host directories and SoT"

"${REPO_ROOT}/internals/ensure-workload.sh" "dual-empty" --env "${PLATFORM_ENV:-test}"
host_ssh "test -f /var/lib/host-volume/internals/workloads/dual-empty/manifest.json" \
  || fail "empty-consumer Workload should still store Manifest"
dual_empty_q="$(host_ssh \
  "ls /home/platform/.config/containers/systemd/dual-empty* 2>/dev/null || true")"
dual_empty_s="$(host_ssh \
  "ls /home/platform/.config/systemd/user/dual-empty* 2>/dev/null || true")"
[[ -z "${dual_empty_q}${dual_empty_s}" ]] \
  || fail "missing consumer dirs must not invent units (q='${dual_empty_q}' s='${dual_empty_s}')"
pass "Missing/empty quadlets/ and systemd/ are valid"

reject_setup() {
  local label="$1"
  local name="$2"
  local needle="$3"
  set +e
  "${REPO_ROOT}/internals/ensure-workload.sh" "${name}" --env "${PLATFORM_ENV:-test}" \
    >/tmp/dual-consumer-setup.out 2>&1
  local rc=$?
  set -e
  [[ ${rc} -ne 0 ]] || fail "expected failure for ${label}"
  grep -qiE "${needle}" /tmp/dual-consumer-setup.out \
    || fail "${label} rejection unclear (output: $(cat /tmp/dual-consumer-setup.out))"
}

reject_setup "timer under quadlets/" "wrong-q" "wrong-folder|belongs in systemd"
reject_setup "container under systemd/" "wrong-s" "wrong-folder|belongs in quadlets"
pass "Workload Setup fails closed on wrong-folder authoring"

reject_setup "native systemd basename vs Edge" "clash-sys" \
  "edge-acme|already exists|not owned"
pass "Workload Setup refuses basename spanning Host unit directories (clash with Edge timer)"

# Purge both consumers for Intent trash.
cat >"${FIX_DIR}/dual-ok/manifest.json" <<'EOF'
{ "intent": "trash", "source": "internal" }
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "dual-ok" --env "${PLATFORM_ENV:-test}"
"${REPO_ROOT}/internals/purge-trash.sh" --env "${PLATFORM_ENV:-test}"

host_ssh "test ! -e /var/lib/host-volume/internals/workloads/dual-ok" \
  || fail "Purge should remove dual-ok Host Volume tree"
host_ssh "test ! -e /home/platform/.config/containers/systemd/dual-ok.container" \
  || fail "Purge should remove dual-ok Quadlet unit"
host_ssh "test ! -e /home/platform/.config/systemd/user/dual-ok-probe.service" \
  || fail "Purge should remove dual-ok native service"
host_ssh "test ! -e /home/platform/.config/systemd/user/dual-ok-probe.timer" \
  || fail "Purge should remove dual-ok native timer"
pass "Purge removes owned basenames from both Host unit directories and the Host Volume tree"
