#!/usr/bin/env bash
# Offline Unit Tests: deep Edge Setup outcome (#137).
# Exercises edge_setup through its public interface with temp dirs + stubs —
# no grepping setup.sh call sites; no SSH / live Host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=edge-setup-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/edge-setup-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/edge-setup.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
STATE="${TMP}/state"
mkdir -p "${TMP}/bin" "${STATE}"

# Fast front-door settle for offline tests.
export EDGE_FRONT_DOOR_WAIT_ATTEMPTS=5
export EDGE_FRONT_DOOR_WAIT_SLEEP=0

# --- stubs: curl (front-door), systemctl, runuser, id/getent soft path ---
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# lego download path: refuse network; tests pre-plant lego.
if [[ "$*" == *github.com/go-acme/lego* ]]; then
  echo "stub curl: unexpected lego download" >&2
  exit 1
fi
# edge_wait_front_door: emit http_code via -w
count_file="${STUB_STATE}/curl_count"
n=0
if [[ -f "${count_file}" ]]; then
  n="$(cat "${count_file}")"
fi
n=$((n + 1))
printf '%s\n' "${n}" >"${count_file}"
need="${CURL_SUCCEED_AFTER:-1}"
if [[ "${n}" -ge "${need}" ]]; then
  printf '%s' "404"
  exit 0
fi
exit 7
EOF
chmod +x "${TMP}/bin/curl"

cat >"${TMP}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STUB_STATE}/systemctl.calls"
# user@ start (session reload)
if [[ "$*" == start\ user@* ]]; then
  exit 0
fi
# edge-pod inactive until first restart (first bring-up must bounce).
if [[ "$*" == *is-active*edge-pod.service* ]]; then
  if [[ -f "${STUB_STATE}/edge-pod-started" ]]; then
    exit 0
  fi
  exit 3
fi
if [[ "$*" == *restart\ edge-pod.service* ]]; then
  : >"${STUB_STATE}/edge-pod-started"
  exit 0
fi
# daemon-reload / reset-failed / enable / restart / is-active / status
if [[ "$*" == *is-active* ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "${TMP}/bin/systemctl"

cat >"${TMP}/bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# runuser -u USER -- env XDG_RUNTIME_DIR=... CMD...
# Drop -u USER -- and env assignments; exec the rest.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u)
      shift 2
      ;;
    --)
      shift
      break
      ;;
    env)
      shift
      while [[ $# -gt 0 && "$1" == *=* ]]; do
        shift
      done
      ;;
    *)
      break
      ;;
  esac
done
exec "$@"
EOF
chmod +x "${TMP}/bin/runuser"

export PATH="${TMP}/bin:${PATH}"
export STUB_STATE="${STATE}"

# Offline: never invoke live podman nginx -t.
edge_validate_nginx_config() {
  printf '%s\n' "validate" >>"${STUB_STATE}/validate.calls"
  if [[ "${EDGE_VALIDATE_FAIL:-0}" == "1" ]]; then
    echo "edge_validate_nginx_config: nginx -t failed" >&2
    return 1
  fi
  return 0
}

# Session begin without a real Platform User account: point unit dirs at TMP.
quadlet_user_session_begin() {
  HOME_DIR="${TMP}/home"
  UID_NUM="$(id -u)"
  UNIT_DIR="${HOME_DIR}/.config/containers/systemd"
  SYSTEMD_USER_DIR="${HOME_DIR}/.config/systemd/user"
  mkdir -p "${UNIT_DIR}" "${SYSTEMD_USER_DIR}" "${HOME_DIR}/.config"
  export XDG_RUNTIME_DIR="${TMP}/runtime"
  mkdir -p "${XDG_RUNTIME_DIR}"
}

quadlet_user_session_reload() {
  # Skip real user@; daemon-reload via stub systemctl is enough.
  quadlet_user systemctl --user daemon-reload
}

# Minimal Component tree (nginx.conf + domain front template + acme-run + optional units).
TREE="${TMP}/edge-tree"
mkdir -p "${TREE}/quadlets" "${TREE}/systemd"
printf 'worker_processes 1;\n' >"${TREE}/nginx.conf"
cp "${REPO_ROOT}/internals/components/edge/domain-template.conf" \
  "${TREE}/domain-template.conf"
printf '#!/usr/bin/env bash\nexit 0\n' >"${TREE}/acme-run.sh"
chmod a+x "${TREE}/acme-run.sh"
printf '[Container]\nImage=docker.io/library/nginx:1.31.3-alpine\n' >"${TREE}/quadlets/edge-nginx.container"

# Ambient Edge data root (Host Volume substitute).
DATA_ROOT="${TMP}/edge-data"
WORKLOADS_ROOT="${TMP}/workloads"
USER_NAME="$(id -un)"
STAGE="${TMP}/staged-want-list"
printf '%s\n' 'alpha.example.test' '# comment' 'beta.example.test' >"${STAGE}"

# Pre-plant lego at the expected version so Setup never hits the network.
mkdir -p "${DATA_ROOT}/acme/bin" "${WORKLOADS_ROOT}"
cat >"${DATA_ROOT}/acme/bin/lego" <<'EOF'
#!/usr/bin/env bash
echo "lego version 5.3.1"
EOF
chmod +x "${DATA_ROOT}/acme/bin/lego"

# --- success: Domains present + units installed + front door answers ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=1
edge_setup "${TREE}" "${STAGE}" || fail "edge_setup should succeed"

WANT_LIST="${DATA_ROOT}/acme/want-list"
[[ -f "${WANT_LIST}" ]] || fail "expected Host want-list after Setup"
grep -Fxq 'alpha.example.test' "${WANT_LIST}" || fail "want-list missing alpha.example.test"
grep -Fxq 'beta.example.test' "${WANT_LIST}" || fail "want-list missing beta.example.test"

ACME_ENV_FILE="${DATA_ROOT}/acme/environment"
[[ -f "${ACME_ENV_FILE}" ]] || fail "expected Host ACME EnvironmentFile after Setup"
grep -Fxq 'EDGE_ACME_DIRECTORY=staging' "${ACME_ENV_FILE}" \
  || fail "missing staged ACME env must plant staging default"

[[ -f "${DATA_ROOT}/domains/alpha.example.test.conf" ]] \
  || fail "expected Domain front for alpha.example.test"
[[ -f "${DATA_ROOT}/domains/beta.example.test.conf" ]] \
  || fail "expected Domain front for beta.example.test"
[[ -f "${DATA_ROOT}/certs/alpha.example.test/fullchain.pem" ]] \
  || fail "expected placeholder fullchain for alpha"
[[ -f "${DATA_ROOT}/certs/alpha.example.test/privkey.pem" ]] \
  || fail "expected placeholder privkey for alpha"

[[ -f "${UNIT_DIR}/edge-nginx.container" ]] \
  || fail "expected Component quadlet installed under UNIT_DIR"

grep -Fq 'restart edge-pod.service' "${STATE}/systemctl.calls" \
  || fail "expected edge-pod restart"
grep -Fq 'enable --now edge-acme.timer' "${STATE}/systemctl.calls" \
  || fail "expected ACME timer enable"
grep -Fq 'restart edge-acme.service' "${STATE}/systemctl.calls" \
  || fail "expected ACME oneshot restart"
pass "edge_setup succeeds: Domains present, units active path, front door answers"

# --- staged ACME env installs into Host EnvironmentFile (ADR-0045) ---
STAGE_ACME="${TMP}/staged-acme.env"
printf '%s\n' 'EDGE_ACME_DIRECTORY=production' 'EDGE_ACME_EMAIL=ops@example.com' >"${STAGE_ACME}"
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=1
edge_setup "${TREE}" "${STAGE}" "${STAGE_ACME}" || fail "edge_setup with staged ACME env should succeed"
grep -Fxq 'EDGE_ACME_DIRECTORY=production' "${ACME_ENV_FILE}" || fail "staged DIRECTORY not installed"
grep -Fxq 'EDGE_ACME_EMAIL=ops@example.com' "${ACME_ENV_FILE}" || fail "staged EMAIL not installed"
pass "edge_setup installs staged ACME EnvironmentFile"

# --- gathers Intent-run Route Declarations from Workload SoT (ADR-0040) ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=1
DATA_ROOT="${TMP}/edge-data"
WORKLOADS_ROOT="${TMP}/workloads"
mkdir -p "${WORKLOADS_ROOT}/alpha/routes"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/alpha/manifest.json"
printf '%s\n' 'location /gather { return 200 "g"; }' \
  >"${WORKLOADS_ROOT}/alpha/routes/alpha.example.test.conf"
# Prior Edge install must be replaced from SoT on gather.
printf '%s\n' '# stale' >"${DATA_ROOT}/routes/stale--alpha.example.test.conf"
edge_setup "${TREE}" "${STAGE}" || fail "edge_setup with Workload SoT should succeed"
[[ -f "${DATA_ROOT}/routes/alpha--alpha.example.test.conf" ]] \
  || fail "edge_setup must fulfill Intent-run Route from Workload SoT"
grep -Fq 'location /gather' "${DATA_ROOT}/routes/alpha--alpha.example.test.conf" \
  || fail "fulfilled Route must keep SoT bytes"
[[ ! -f "${DATA_ROOT}/routes/stale--alpha.example.test.conf" ]] \
  || fail "edge_setup gather must drop orphan Edge Route installs"
pass "edge_setup gathers Intent-run Route Declarations from Workload SoT"

# --- unchanged gather skips front-door bounce (Setup noop for Routes) ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=1
# Pod already active from prior Setup; SoT unchanged → EDGE_ROUTES_CHANGED=0.
edge_setup "${TREE}" "${STAGE}" || fail "edge_setup noop re-run should succeed"
if grep -Fq 'restart edge-pod.service' "${STATE}/systemctl.calls"; then
  fail "unchanged gather must not restart edge-pod"
fi
grep -Fq 'restart edge-acme.service' "${STATE}/systemctl.calls" \
  || fail "Edge Setup must still trigger ACME oneshot when Route gather is unchanged (ADR-0015)"
grep -Fq 'is-active edge-pod.service' "${STATE}/systemctl.calls" \
  || fail "noop re-run must still assert edge-pod is active"
pass "edge_setup skips pod bounce when Route gather is unchanged; ACME oneshot still runs"

# --- fail closed when front door never answers ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=999
export EDGE_FRONT_DOOR_WAIT_ATTEMPTS=3
# Fresh data root so want-list/fronts still reconcile; outcome fails on wait.
DATA_ROOT="${TMP}/edge-data-fail"
WORKLOADS_ROOT="${TMP}/workloads"
mkdir -p "${DATA_ROOT}/acme/bin" "${WORKLOADS_ROOT}"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
if edge_setup "${TREE}" "${STAGE}" 2>"${STATE}/setup.err"; then
  fail "edge_setup should fail when front door never answers"
fi
grep -Fq 'did not answer on :80' "${STATE}/setup.err" \
  || fail "expected :80 timeout in Setup failure, got: $(cat "${STATE}/setup.err")"
# Domain presence still reconciled before wait (implementation ordering).
[[ -f "${DATA_ROOT}/domains/alpha.example.test.conf" ]] \
  || fail "Domain fronts should exist even when wait fails"
pass "edge_setup fails closed when front door never answers"

# --- staging pathname is Setup-seam only (not every helper's public interface) ---
for helper in \
  edge-want-list-host.sh \
  edge-acme-env-host.sh \
  edge-domain-fronts-host.sh \
  edge-front-door-host.sh \
  edge-routes-host.sh; do
  path="${REPO_ROOT}/internals/host-scripts/lib/${helper}"
  [[ -f "${path}" ]] || fail "missing ${helper}"
  # Helpers must not require a staged want-list / ACME-env path argument in their public surface.
  if grep -E 'staged_want_list|staged_acme_env|/tmp/platform-acme-want-list|/tmp/platform-acme\.env' "${path}" >/dev/null; then
    fail "${helper} must not thread staging pathname as public interface"
  fi
done
# edge_install_want_list / edge_install_acme_env keep a staged_path arg (install seam).
grep -Eq '^edge_install_want_list\(\)' \
  "${REPO_ROOT}/internals/host-scripts/lib/edge-want-list-host.sh" \
  || fail "edge_install_want_list should remain the install seam"
grep -Eq '^edge_install_acme_env\(\)' \
  "${REPO_ROOT}/internals/host-scripts/lib/edge-acme-env-host.sh" \
  || fail "edge_install_acme_env should remain the install seam"
grep -Eq '^edge_want_list_fqdns\(\)' \
  "${REPO_ROOT}/internals/host-scripts/lib/edge-want-list-host.sh" \
  || fail "shared FQDN reader must remain for Route/ACME gating"
pass "staging pathname stays at Setup/install seam; helpers keep ambient WANT_LIST/ACME_ENV"

# --- thin slot scripts call deep edge_setup_* (not a caller checklist) ---
PRE="${REPO_ROOT}/internals/components/edge/pre-workloads.sh"
POST="${REPO_ROOT}/internals/components/edge/post-workloads.sh"
[[ -f "${PRE}" ]] || fail "missing pre-workloads.sh"
[[ -f "${POST}" ]] || fail "missing post-workloads.sh"
[[ ! -e "${REPO_ROOT}/internals/components/edge/setup.sh" ]] \
  || fail "monolithic setup.sh must be removed (ADR-0018 / ADR-0043)"
grep -Fq 'edge-setup-host.sh' "${PRE}" \
  || fail "pre-workloads.sh must source edge-setup-host.sh"
grep -Fq 'edge_setup_pre_workloads' "${PRE}" \
  || fail "pre-workloads.sh must call edge_setup_pre_workloads"
grep -Fq 'edge_setup_post_workloads' "${POST}" \
  || fail "post-workloads.sh must call edge_setup_post_workloads"
for step in edge_install_want_list edge_install_acme_env edge_plant_placeholder_pems edge_reconcile_domain_fronts edge_gather_workload_routes edge_wait_front_door; do
  if grep -Eq "${step}" "${PRE}" "${POST}"; then
    fail "slot scripts must not expose ${step} as a caller checklist"
  fi
done
# Slots pass Component tree only; handoff paths resolve inside edge_setup.
if grep -E '/tmp/platform-acme|/tmp/platform-database' "${PRE}" "${POST}" >/dev/null; then
  fail "Edge slot scripts must not hardcode ephemeral handoff paths"
fi
# Exactly one non-flag arg to edge_setup_* (the Component tree).
grep -Eq 'edge_setup_pre_workloads[[:space:]]+"\$\{SRC\}"[[:space:]]*$' "${PRE}" \
  || fail "pre-workloads must call edge_setup_pre_workloads with Component tree only"
grep -Eq 'edge_setup_post_workloads[[:space:]]+"\$\{SRC\}"[[:space:]]*$' "${POST}" \
  || fail "post-workloads must call edge_setup_post_workloads with Component tree only"
pass "Edge slot scripts are thin: ambient + edge_setup_pre/post_workloads only"

# --- pre-workloads cold: clear Routes, start, ACME; no gather from SoT ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
rm -f "${STATE}/edge-pod-started"
export CURL_SUCCEED_AFTER=1
DATA_ROOT="${TMP}/edge-data-pre-cold"
WORKLOADS_ROOT="${TMP}/workloads-pre-cold"
mkdir -p "${DATA_ROOT}/acme/bin" "${DATA_ROOT}/routes" \
  "${WORKLOADS_ROOT}/welcome/routes"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/welcome/manifest.json"
printf '%s\n' 'location /welcome { return 200 "w"; }' \
  >"${WORKLOADS_ROOT}/welcome/routes/alpha.example.test.conf"
printf '%s\n' 'location /stale { return 200 "s"; }' \
  >"${DATA_ROOT}/routes/welcome--alpha.example.test.conf"
edge_setup_pre_workloads "${TREE}" "${STAGE}" \
  || fail "edge_setup_pre_workloads cold should succeed"
[[ ! -f "${DATA_ROOT}/routes/welcome--alpha.example.test.conf" ]] \
  || fail "cold pre-workloads must clear fulfilled Workload Routes"
[[ -z "$(find "${DATA_ROOT}/routes" -maxdepth 1 -type f 2>/dev/null)" ]] \
  || fail "cold pre-workloads must not gather Workload SoT Routes"
grep -Fq 'restart edge-pod.service' "${STATE}/systemctl.calls" \
  || fail "cold pre-workloads must start/bounce edge-pod"
grep -Fq 'restart edge-acme.service' "${STATE}/systemctl.calls" \
  || fail "cold pre-workloads must run ACME oneshot"
pass "edge_setup_pre_workloads cold: clear Routes, start, ACME; no gather"

# --- pre-workloads warm: no gather, no front-door bounce, no ACME bounce ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=1
DATA_ROOT="${TMP}/edge-data-pre-warm"
WORKLOADS_ROOT="${TMP}/workloads-pre-warm"
mkdir -p "${DATA_ROOT}/acme/bin" "${DATA_ROOT}/routes" \
  "${WORKLOADS_ROOT}/welcome/routes"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/welcome/manifest.json"
printf '%s\n' 'location /from-sot { return 200 "sot"; }' \
  >"${WORKLOADS_ROOT}/welcome/routes/alpha.example.test.conf"
printf '%s\n' 'location /live { return 200 "live"; }' \
  >"${DATA_ROOT}/routes/welcome--alpha.example.test.conf"
: >"${STATE}/edge-pod-started"
edge_setup_pre_workloads "${TREE}" "${STAGE}" \
  || fail "edge_setup_pre_workloads warm should succeed"
grep -Fq 'location /live' "${DATA_ROOT}/routes/welcome--alpha.example.test.conf" \
  || fail "warm pre-workloads must preserve live Routes"
if grep -Fq 'restart edge-pod.service' "${STATE}/systemctl.calls"; then
  fail "warm pre-workloads must not bounce edge-pod"
fi
if grep -Fq 'restart edge-acme.service' "${STATE}/systemctl.calls"; then
  fail "warm pre-workloads must not run ACME oneshot that bounces the door"
fi
pass "edge_setup_pre_workloads warm: no gather, no front-door/ACME bounce"

# --- post-workloads: gather, validate, bounce when needed, ACME ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
: >"${STATE}/validate.calls"
rm -f "${STATE}/edge-pod-started"
export CURL_SUCCEED_AFTER=1
export EDGE_VALIDATE_FAIL=0
DATA_ROOT="${TMP}/edge-data-post"
WORKLOADS_ROOT="${TMP}/workloads-post"
mkdir -p "${DATA_ROOT}/acme/bin" "${WORKLOADS_ROOT}/welcome/routes"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/welcome/manifest.json"
printf '%s\n' 'location /post { return 200 "p"; }' \
  >"${WORKLOADS_ROOT}/welcome/routes/alpha.example.test.conf"
edge_setup_post_workloads "${TREE}" "${STAGE}" \
  || fail "edge_setup_post_workloads should succeed"
[[ -f "${DATA_ROOT}/routes/welcome--alpha.example.test.conf" ]] \
  || fail "post-workloads must gather Intent-run Routes"
grep -Fq 'validate' "${STATE}/validate.calls" \
  || fail "post-workloads must validate nginx config before bounce"
grep -Fq 'restart edge-pod.service' "${STATE}/systemctl.calls" \
  || fail "post-workloads must start/reload edge-pod when down or Routes changed"
grep -Fq 'restart edge-acme.service' "${STATE}/systemctl.calls" \
  || fail "post-workloads must run ACME oneshot"
pass "edge_setup_post_workloads gathers, validates, starts, runs ACME"

# --- post-workloads fails closed when validate rejects config ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export EDGE_VALIDATE_FAIL=1
DATA_ROOT="${TMP}/edge-data-post-bad"
WORKLOADS_ROOT="${TMP}/workloads-post-bad"
mkdir -p "${DATA_ROOT}/acme/bin" "${WORKLOADS_ROOT}/welcome/routes"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/welcome/manifest.json"
printf '%s\n' 'location /bad { return 200 "b"; }' \
  >"${WORKLOADS_ROOT}/welcome/routes/alpha.example.test.conf"
: >"${STATE}/edge-pod-started"
if edge_setup_post_workloads "${TREE}" "${STAGE}" 2>"${STATE}/post-bad.err"; then
  fail "post-workloads must fail closed when nginx -t fails"
fi
if grep -Fq 'restart edge-pod.service' "${STATE}/systemctl.calls"; then
  fail "failed validate must not bounce edge-pod"
fi
export EDGE_VALIDATE_FAIL=0
pass "edge_setup_post_workloads fails closed on invalid config"

# --- mode: clear fulfilled Workload Routes (Domain fronts stay) ---
# Intent-run SoT would re-fulfill on gather; clear + skip-gather must leave Routes empty.
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=1
export EDGE_FRONT_DOOR_WAIT_ATTEMPTS=5
export EDGE_FRONT_DOOR_WAIT_SLEEP=0
DATA_ROOT="${TMP}/edge-data-clear"
WORKLOADS_ROOT="${TMP}/workloads-clear"
mkdir -p "${DATA_ROOT}/acme/bin" "${DATA_ROOT}/routes" "${DATA_ROOT}/domains" \
  "${WORKLOADS_ROOT}/welcome/routes"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/welcome/manifest.json"
printf '%s\n' 'location /welcome { return 200 "w"; }' \
  >"${WORKLOADS_ROOT}/welcome/routes/alpha.example.test.conf"
printf '%s\n' 'location /stale { return 200 "s"; }' \
  >"${DATA_ROOT}/routes/welcome--alpha.example.test.conf"
printf '%s\n' '# prior domain front' >"${DATA_ROOT}/domains/alpha.example.test.conf"
: >"${STATE}/edge-pod-started"
edge_setup "${TREE}" "${STAGE}" --clear-fulfilled-routes --skip-gather \
  || fail "edge_setup --clear-fulfilled-routes --skip-gather should succeed"
[[ ! -f "${DATA_ROOT}/routes/welcome--alpha.example.test.conf" ]] \
  || fail "clear-fulfilled-routes must remove fulfilled Workload Routes under Edge data"
[[ -z "$(find "${DATA_ROOT}/routes" -maxdepth 1 -type f 2>/dev/null)" ]] \
  || fail "clear + skip-gather must not re-fulfill from Workload SoT"
[[ -f "${DATA_ROOT}/domains/alpha.example.test.conf" ]] \
  || fail "clear-fulfilled-routes must leave Domain fronts in place"
pass "edge_setup --clear-fulfilled-routes clears fulfilled Routes; Domain fronts stay"

# --- mode: skip-gather leaves live fulfilled Routes untouched ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=1
DATA_ROOT="${TMP}/edge-data-skip-gather"
WORKLOADS_ROOT="${TMP}/workloads-skip-gather"
mkdir -p "${DATA_ROOT}/acme/bin" "${DATA_ROOT}/routes" \
  "${WORKLOADS_ROOT}/welcome/routes"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/welcome/manifest.json"
printf '%s\n' 'location /from-sot { return 200 "sot"; }' \
  >"${WORKLOADS_ROOT}/welcome/routes/alpha.example.test.conf"
printf '%s\n' 'location /live { return 200 "live"; }' \
  >"${DATA_ROOT}/routes/welcome--alpha.example.test.conf"
: >"${STATE}/edge-pod-started"
edge_setup "${TREE}" "${STAGE}" --skip-gather \
  || fail "edge_setup --skip-gather should succeed"
grep -Fq 'location /live' "${DATA_ROOT}/routes/welcome--alpha.example.test.conf" \
  || fail "skip-gather must preserve live fulfilled Route bytes"
if grep -Fq 'location /from-sot' "${DATA_ROOT}/routes/welcome--alpha.example.test.conf"; then
  fail "skip-gather must not load Workload SoT Routes into Edge interior"
fi
pass "edge_setup --skip-gather preserves live Routes; does not load SoT"

# --- mode: skip-front-door-bounce does not reload/restart Edge when Routes change ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
rm -f "${STATE}/edge-pod-started"
export CURL_SUCCEED_AFTER=1
DATA_ROOT="${TMP}/edge-data-skip-bounce"
WORKLOADS_ROOT="${TMP}/workloads-skip-bounce"
mkdir -p "${DATA_ROOT}/acme/bin" "${DATA_ROOT}/routes" \
  "${WORKLOADS_ROOT}/welcome/routes"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/welcome/manifest.json"
printf '%s\n' 'location /new { return 200 "n"; }' \
  >"${WORKLOADS_ROOT}/welcome/routes/alpha.example.test.conf"
# Pod already healthy (warm path); gather will change Routes → default would bounce.
: >"${STATE}/edge-pod-started"
edge_setup "${TREE}" "${STAGE}" --skip-front-door-bounce \
  || fail "edge_setup --skip-front-door-bounce should succeed"
[[ -f "${DATA_ROOT}/routes/welcome--alpha.example.test.conf" ]] \
  || fail "skip-front-door-bounce still gathers Routes into Edge data"
if grep -Fq 'restart edge-pod.service' "${STATE}/systemctl.calls"; then
  fail "skip-front-door-bounce must not restart edge-pod when Routes change"
fi
grep -Fq 'restart edge-acme.service' "${STATE}/systemctl.calls" \
  || fail "skip-front-door-bounce alone must still run ACME oneshot (use --skip-acme-bounce to gate that)"
pass "edge_setup --skip-front-door-bounce skips pod reload/restart"

# --- mode: skip-acme-bounce does not restart ACME oneshot (door stay) ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
export CURL_SUCCEED_AFTER=1
DATA_ROOT="${TMP}/edge-data-skip-acme"
WORKLOADS_ROOT="${TMP}/workloads-skip-acme"
mkdir -p "${DATA_ROOT}/acme/bin" "${WORKLOADS_ROOT}"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
: >"${STATE}/edge-pod-started"
edge_setup "${TREE}" "${STAGE}" --skip-gather --skip-front-door-bounce --skip-acme-bounce \
  || fail "edge_setup --skip-acme-bounce should succeed"
if grep -Fq 'restart edge-acme.service' "${STATE}/systemctl.calls"; then
  fail "skip-acme-bounce must not restart edge-acme oneshot (ACME reloads the front door)"
fi
grep -Fq 'enable --now edge-acme.timer' "${STATE}/systemctl.calls" \
  || fail "skip-acme-bounce must still arm the ACME timer"
grep -Fq 'is-active edge-pod.service' "${STATE}/systemctl.calls" \
  || fail "warm skip modes must still assert edge-pod is active"
pass "edge_setup --skip-acme-bounce skips ACME oneshot that would bounce the door"

# --- default path (no mode flags) still gathers, bounces when needed, runs ACME ---
: >"${STATE}/curl_count"
: >"${STATE}/systemctl.calls"
rm -f "${STATE}/edge-pod-started"
export CURL_SUCCEED_AFTER=1
DATA_ROOT="${TMP}/edge-data-default"
WORKLOADS_ROOT="${TMP}/workloads-default"
mkdir -p "${DATA_ROOT}/acme/bin" "${WORKLOADS_ROOT}/welcome/routes"
cp "${TMP}/edge-data/acme/bin/lego" "${DATA_ROOT}/acme/bin/lego"
printf '%s\n' '{"intent":"run"}' >"${WORKLOADS_ROOT}/welcome/manifest.json"
printf '%s\n' 'location /default { return 200 "d"; }' \
  >"${WORKLOADS_ROOT}/welcome/routes/alpha.example.test.conf"
edge_setup "${TREE}" "${STAGE}" || fail "default edge_setup should succeed"
[[ -f "${DATA_ROOT}/routes/welcome--alpha.example.test.conf" ]] \
  || fail "default edge_setup must gather Intent-run Routes"
grep -Fq 'restart edge-pod.service' "${STATE}/systemctl.calls" \
  || fail "default cold edge_setup must bounce/start edge-pod"
grep -Fq 'restart edge-acme.service' "${STATE}/systemctl.calls" \
  || fail "default edge_setup must restart ACME oneshot"
pass "default edge_setup path unchanged: gather + bounce + ACME"

echo "All edge-setup-host offline tests passed."
