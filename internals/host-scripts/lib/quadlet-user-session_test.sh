#!/usr/bin/env bash
# Offline tests: Platform User session helpers must not inherit root session env.
# Repro 1: root SSH XDG_RUNTIME_DIR=/run/user/0 → systemctl --user Operation not permitted.
# Repro 2: root DBUS_SESSION_BUS_ADDRESS=…/run/user/0/bus → podman/crun cgroup Permission denied
#          (nginx -t via podman exec during post-workloads validate).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=quadlet-user-session.sh
source "${REPO_ROOT}/internals/host-scripts/lib/quadlet-user-session.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/quadlet-user-session.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/home" "${TMP}/run/user/1000"

# Soft-path stubs: pretend Platform User uid 1000 with HOME under TMP.
cat >"${TMP}/bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == "-u" ]]; then
  echo 1000
  exit 0
fi
# id USERNAME existence check
exit 0
EOF
chmod +x "${TMP}/bin/id"

cat >"${TMP}/bin/getent" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'platform:x:1000:1000::%s:/bin/bash\n' "${TMP}/home"
EOF
chmod +x "${TMP}/bin/getent"

# Capture env assignments that quadlet_user passes through env.
# Also record cwd: root SSH /root is unsafe for Platform User Podman.
cat >"${TMP}/bin/runuser" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\${PWD}" >"${TMP}/runuser-cwd"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -u) shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [[ "\${1-}" == env ]]; then
  shift
  while [[ \$# -gt 0 && "\$1" == *=* ]]; do
    printf '%s\n' "\$1"
    shift
  done
  exit 0
fi
exit 0
EOF
chmod +x "${TMP}/bin/runuser"

export PATH="${TMP}/bin:${PATH}"
USER_NAME=platform

# Simulate root SSH session exporting root's runtime + session bus (live prod failure).
export XDG_RUNTIME_DIR=/run/user/0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus

quadlet_user_session_begin
[[ "${XDG_RUNTIME_DIR}" == "/run/user/1000" ]] \
  || fail "begin must set XDG_RUNTIME_DIR to Platform User runtime, got '${XDG_RUNTIME_DIR}'"
[[ "${UID_NUM}" == "1000" ]] || fail "UID_NUM want 1000, got '${UID_NUM}'"
pass "quadlet_user_session_begin exports Platform User XDG_RUNTIME_DIR"

got="$(quadlet_user true)"
echo "${got}" | grep -Fxq 'XDG_RUNTIME_DIR=/run/user/1000' \
  || fail "quadlet_user must pass Platform User XDG, got: ${got}"
if echo "${got}" | grep -Fq 'XDG_RUNTIME_DIR=/run/user/0'; then
  fail "quadlet_user must not pass root XDG_RUNTIME_DIR=/run/user/0"
fi
pass "quadlet_user does not inherit root XDG_RUNTIME_DIR"

echo "${got}" | grep -Fxq 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' \
  || fail "quadlet_user must pass Platform User DBUS session bus, got: ${got}"
if echo "${got}" | grep -Fq 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus'; then
  fail "quadlet_user must not pass root DBUS_SESSION_BUS_ADDRESS"
fi
pass "quadlet_user does not inherit root DBUS_SESSION_BUS_ADDRESS"

# Simulate root SSH landing in /root; quadlet_user must cd to Platform HOME first.
mkdir -p "${TMP}/fake-root"
(
  cd "${TMP}/fake-root"
  quadlet_user true >/dev/null
)
got_cwd="$(cat "${TMP}/runuser-cwd")"
if [[ "${got_cwd}" != "${HOME_DIR}" && ! "${got_cwd}" -ef "${HOME_DIR}" ]]; then
  fail "quadlet_user must runuser from Platform HOME (${HOME_DIR}), got cwd '${got_cwd}'"
fi
pass "quadlet_user cds to Platform HOME before runuser"

# edge_setup_pre_workloads must ensure session before is-active (source contract).
PRE_FN="${REPO_ROOT}/internals/host-scripts/lib/edge-setup-host.sh"
grep -A20 '^edge_setup_pre_workloads()' "${PRE_FN}" | grep -Fq 'quadlet_user_session_begin' \
  || fail "pre-workloads must call quadlet_user_session_begin before is-active"
grep -Eq 'export XDG_RUNTIME_DIR=' "${REPO_ROOT}/internals/host-scripts/lib/quadlet-user-session.sh" \
  || fail "session helper must export XDG_RUNTIME_DIR"
pass "pre-workloads / begin contract covers bus before is-active"

echo "All quadlet-user-session offline tests passed."
