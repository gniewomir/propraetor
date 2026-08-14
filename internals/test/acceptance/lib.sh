# Shared helpers for Acceptance Tests. Sourced by case scripts (not executed by the runner).
# Requires fixture env from ./test.sh acceptance: IP and provider-observed HOST_JSON.

# SSH port twin of Terraform recreatables ssh_port (ADR-0030) — see internals/lib/ssh.sh.
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi
# shellcheck source=../../lib/ssh.sh
source "${REPO_ROOT}/internals/lib/ssh.sh"
# shellcheck source=../../lib/ihp.sh
source "${REPO_ROOT}/internals/lib/ihp.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

require_do_token() {
  [[ -n "${DIGITALOCEAN_TOKEN:-}" ]] || fail "DIGITALOCEAN_TOKEN is not set"
}

do_api_get() {
  local path="$1"
  require_do_token
  curl -fsS \
    -H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.digitalocean.com${path}"
}

provider_cloud_project_json() {
  local project_name="propraetor-${PLATFORM_ENV}"
  do_api_get "/v2/projects?per_page=200" \
    | jq -c --arg name "${project_name}" '.projects[] | select(.name == $name)'
}

provider_cloud_project_id() {
  provider_cloud_project_json | jq -r '.id'
}

provider_host_volume_json() {
  local volume_name="propraetor-${PLATFORM_ENV}-web-data"
  do_api_get "/v2/volumes?name=${volume_name}&region=fra1" \
    | jq -c '.volumes[0] // empty'
}

environment_domains_path() {
  # Prefer domains.override.json when present (ADR-0021); empty when neither exists.
  if ! declare -F domains_assignment_path >/dev/null 2>&1; then
    # shellcheck source=../../lib/domains/domains.sh
    source "${REPO_ROOT}/internals/lib/domains/domains.sh"
  fi
  domains_assignment_path "${PLATFORM_ENV}"
}

configured_domain_names() {
  local domains_path
  domains_path="$(environment_domains_path)"
  [[ -n "${domains_path}" && -f "${domains_path}" ]] || return 0
  jq -r 'keys[]' "${domains_path}"
}

require_ip() {
  [[ -n "${IP:-}" ]] || fail "fixture missing IP (run via ./test.sh acceptance)"
}

# Zero-I/O TCP probe to $IP:$1. Prints nc stdout+stderr; exit status is nc's.
# Darwin: -w alone often does not bound connect to DROP'd ports; -G is the connect timeout.
# Linux nc typically honors -w for connect and rejects unknown -G.
probe_tcp_nc() {
  local port="$1"
  local -a args=(-z -w 5 -v)
  require_ip
  if [[ "$(uname -s)" == Darwin ]]; then
    args=(-z -G 5 -w 5 -v)
  fi
  nc "${args[@]}" "${IP}" "${port}" 2>&1
}

# Allowed TCP: open or connection-refused both mean Firewall allowed the packet through.
# Timeout/drop means filtered — fail for allow-listed ports.
probe_allowed_tcp() {
  local port="$1"
  local out
  local rc
  set +e
  out="$(probe_tcp_nc "${port}")"
  rc=$?
  set -e
  if [[ ${rc} -eq 0 ]] || echo "${out}" | grep -qi "refused"; then
    pass "inbound TCP ${port} not filtered"
  else
    fail "inbound TCP ${port} appears filtered/unreachable"
  fi
}

# True when the Environment Firewall inbound allow-set includes TCP $1 (DO API).
# Cloud Firewall is default-deny; absence from the allow-set means not allowed.
firewall_inbound_allows_tcp_port() {
  local port="$1"
  local fw_name="propraetor-${PLATFORM_ENV:-test}-public-web"
  local rules
  require_do_token
  rules="$(do_api_get "/v2/firewalls?per_page=200" | jq -c --arg n "${fw_name}" '
    [.firewalls[] | select(.name == $n) | .inbound_rules[]?]
  ')"
  [[ -n "${rules}" && "${rules}" != "null" ]] || {
    echo "firewall_inbound_allows_tcp_port: Firewall '${fw_name}' not found" >&2
    return 2
  }
  PORT="${port}" RULES="${rules}" python3 - <<'PY'
import json, os, sys
port = int(os.environ["PORT"])
rules = json.loads(os.environ["RULES"])
for rule in rules:
    if rule.get("protocol") != "tcp":
        continue
    ports = str(rule.get("ports") or "")
    if ports in ("0", "all"):
        sys.exit(0)
    if "-" in ports:
        lo, _, hi = ports.partition("-")
        if lo.isdigit() and hi.isdigit() and int(lo) <= port <= int(hi):
            sys.exit(0)
    elif ports.isdigit() and int(ports) == port:
        sys.exit(0)
sys.exit(1)
PY
}

# Host-side SYN capture around one operator TCP probe to $IP:$1.
# Sets: PROBE_DENIED_SYN (SAW_SYN|NO_SYN), PROBE_DENIED_RC, PROBE_DENIED_OUT.
# Cloud Firewall sits before the Host — forwarded packets are visible; DROP is not.
_probe_denied_host_syn_capture() {
  local port="$1"

  host_ssh env "PORT=${port}" bash -s <<'REMOTE'
set -euo pipefail
port="${PORT}"
rm -f "/tmp/propraetor-fw-${port}.log" "/tmp/propraetor-fw-${port}.pid"
timeout 25 tcpdump -ni any "tcp and dst port ${port}" -c 20 -tttt \
  >"/tmp/propraetor-fw-${port}.log" 2>&1 &
echo $! >"/tmp/propraetor-fw-${port}.pid"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if grep -q 'listening on' "/tmp/propraetor-fw-${port}.log" 2>/dev/null; then
    exit 0
  fi
  sleep 0.2
done
exit 0
REMOTE

  set +e
  PROBE_DENIED_OUT="$(probe_tcp_nc "${port}")"
  PROBE_DENIED_RC=$?
  set -e

  sleep 1
  PROBE_DENIED_SYN="$(host_ssh env "PORT=${port}" bash -s <<'REMOTE'
set -euo pipefail
port="${PORT}"
pid="$(cat "/tmp/propraetor-fw-${port}.pid" 2>/dev/null || true)"
if [[ -n "${pid}" ]]; then
  kill "${pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    if ! ps -p "${pid}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
fi
if grep -E 'Flags \[S\]' "/tmp/propraetor-fw-${port}.log" >/dev/null 2>&1; then
  printf 'SAW_SYN\n'
else
  printf 'NO_SYN\n'
fi
REMOTE
)"
}

# Denied TCP (Cloud Firewall before Host).
# Verdict:
#   Host saw SYN  → Firewall forwarded → fail (deny expectation broken).
#   Host saw nothing + operator timeout → data-plane DROP → pass.
#   Host saw nothing + operator accept/refuse → path forged reply; pass only if
#   allow-set excludes the port (control-plane deny). Never treat forged SYN-ACK
#   as Firewall allow.
probe_denied_tcp() {
  local port="$1"
  local allow_rc=0

  require_ip
  # Capture needs verify Host-session (caller opens via acceptance_host_session).
  _probe_denied_host_syn_capture "${port}"

  if [[ "${PROBE_DENIED_SYN}" == "SAW_SYN" ]]; then
    fail "inbound TCP ${port} reached Host (Firewall forwarded SYN) — deny expectation broken"
  fi
  [[ "${PROBE_DENIED_SYN}" == "NO_SYN" ]] || fail "unexpected Host SYN verdict: ${PROBE_DENIED_SYN}"

  if [[ "${PROBE_DENIED_RC}" -eq 0 ]] || echo "${PROBE_DENIED_OUT}" | grep -qi "refused"; then
    set +e
    firewall_inbound_allows_tcp_port "${port}"
    allow_rc=$?
    set -e
    if [[ "${allow_rc}" -eq 0 ]]; then
      fail "inbound TCP ${port}: operator got a reply and Host saw no SYN, but Firewall allow-set includes ${port}"
    elif [[ "${allow_rc}" -ne 1 ]]; then
      fail "inbound TCP ${port}: could not read Firewall allow-set (rc=${allow_rc})"
    fi
    pass "inbound TCP ${port} not Firewall-allowed (Host saw no SYN; operator path forged a reply; allow-set excludes port)"
  else
    pass "inbound TCP ${port} filtered (denied by Firewall)"
  fi
}

# Bind verify Host-session for Acceptance (fixture IP from ./test.sh acceptance).
# Identity: PROPRAETOR_PRIVATE_KEY_PATH (Operator Configuration).
acceptance_host_session() {
  require_ip
  host_session_bind verify "${IP}" || fail "host_session_bind verify failed for ${IP}"
}

# Run the Host-local ihp-done gate over SSH (retries across ADR-0030 reboot).
# Requires: ambient verify Host-session (acceptance_host_session), REPO_ROOT. Optional: PLATFORM_USER.
wait_until_ihp_done() {
  require_ip
  [[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"
  local script="${REPO_ROOT}/internals/host-scripts/wait-until-ihp-done.sh"
  local user="${PLATFORM_USER:-platform}"
  if ! host_wait_until_ihp_done "${script}" "${user}"; then
    fail "Host not ready for Component Setup (see Host output above)"
  fi
}

# First Domain want-list FQDN for this Environment (operator config SoT), or empty.
# Soft-skip Route attach assertions when empty (ADR-0028 fail-closed needs a want-list name).
acceptance_route_fqdn() {
  if ! declare -F domains_acme_fqdns_for >/dev/null 2>&1; then
    # shellcheck source=../../lib/domains/domains.sh
    source "${REPO_ROOT}/internals/lib/domains/domains.sh"
  fi
  domains_acme_fqdns_for "${PLATFORM_ENV:-test}" | awk 'NF { print; exit }'
}

# Ephemeral Workload trees under environments/<slug>/ (ADR-0033).
acceptance_env_dir() {
  printf '%s/environments/%s\n' "${REPO_ROOT}" "${PLATFORM_ENV:-test}"
}

# Host Volume data/ root. Override ACCEPTANCE_HV_DATA_ROOT for Unit Tests (no live Host).
acceptance_hv_data_root() {
  printf '%s\n' "${ACCEPTANCE_HV_DATA_ROOT:-/var/lib/host-volume/data}"
}

ACCEPTANCE_WL_TRACKED=()
ACCEPTANCE_SOT_TRACKED=()
ACCEPTANCE_DATA_TRACKED=()

# Environment fixtures / SoT mutation tracking is test-Environment only (ADR-0042 / #176).
acceptance_require_test_env_for_sot_mutation() {
  local env_slug="${PLATFORM_ENV:?acceptance_require_test_env_for_sot_mutation: PLATFORM_ENV required}"
  if [[ "${env_slug}" != "test" ]]; then
    echo "FAIL: Environment fixtures / SoT mutation tracking is test-Environment only (got PLATFORM_ENV='${env_slug}'; ADR-0042)" >&2
    return 1
  fi
}

acceptance_wl_track() {
  acceptance_require_test_env_for_sot_mutation || return 1
  ACCEPTANCE_WL_TRACKED+=("$@")
}

# Opt-in: paths relative to environments/<slug>/ that the case mutated in committed
# SoT — restored from git HEAD on cleanup (ADR-0042 / #178). Ephemeral fixtures use
# acceptance_wl_track instead; no live Acceptance case mutates committed SoT today.
acceptance_sot_track() {
  acceptance_require_test_env_for_sot_mutation || return 1
  ACCEPTANCE_SOT_TRACKED+=("$@")
}

# Paths relative to Host Volume data/ that the case created and that would survive
# the next Deploy — case-owned cleanup + tracked G (ADR-0042).
acceptance_data_track() {
  local rel
  for rel in "$@"; do
    case "${rel}" in
      "" | /*)
        echo "FAIL: acceptance_data_track: path must be relative under data/ (got '${rel}')" >&2
        return 1
        ;;
    esac
    # Reject .. segments (undeclared escape outside data/).
    case "/${rel}/" in
      */../*)
        echo "FAIL: acceptance_data_track: path must not contain '..' (got '${rel}')" >&2
        return 1
        ;;
    esac
    ACCEPTANCE_DATA_TRACKED+=("${rel}")
  done
}

acceptance_data_path() {
  local rel="${1:?acceptance_data_path: relative data/ path required}"
  printf '%s/%s\n' "$(acceptance_hv_data_root)" "${rel}"
}

# True if the tracked Host data/ path exists (local override or via Host SSH).
acceptance_data_exists() {
  local rel="${1:?acceptance_data_exists: relative data/ path required}"
  local full
  full="$(acceptance_data_path "${rel}")"
  if [[ -n "${ACCEPTANCE_HV_DATA_ROOT:-}" ]]; then
    [[ -e "${full}" ]]
    return
  fi
  host_ssh "test -e $(printf '%q' "${full}")"
}

acceptance_data_rm() {
  local rel="${1:?acceptance_data_rm: relative data/ path required}"
  local full
  full="$(acceptance_data_path "${rel}")"
  if [[ -n "${ACCEPTANCE_HV_DATA_ROOT:-}" ]]; then
    rm -rf "${full}"
    return
  fi
  host_ssh "rm -rf $(printf '%q' "${full}")"
}

# Tracked-G: every registered survive-Deploy data/ path must be gone.
acceptance_data_assert_gone() {
  local rel
  for rel in "${ACCEPTANCE_DATA_TRACKED[@]+"${ACCEPTANCE_DATA_TRACKED[@]}"}"; do
    if acceptance_data_exists "${rel}"; then
      echo "FAIL: tracked Host Volume data/ path still present after cleanup: ${rel}" >&2
      return 1
    fi
  done
}

acceptance_sot_restore() {
  local rel env_slug env_path
  env_slug="${PLATFORM_ENV:-test}"
  [[ -n "${REPO_ROOT:-}" ]] || {
    echo "FAIL: acceptance_sot_restore: REPO_ROOT required" >&2
    return 1
  }
  for rel in "${ACCEPTANCE_SOT_TRACKED[@]+"${ACCEPTANCE_SOT_TRACKED[@]}"}"; do
    env_path="environments/${env_slug}/${rel}"
    git -C "${REPO_ROOT}" checkout HEAD -- "${env_path}"
    # Drop untracked files under the restored path so the tree matches committed truth.
    git -C "${REPO_ROOT}" clean -fd -- "${env_path}" >/dev/null
  done
}

# Shared EXIT protocol: remove fixture Workloads, restore tracked SoT, clean + assert
# tracked survive-Deploy data/ (ADR-0042 / #163).
acceptance_wl_cleanup() {
  local root name rel
  root="$(acceptance_env_dir)"
  for name in "${ACCEPTANCE_WL_TRACKED[@]+"${ACCEPTANCE_WL_TRACKED[@]}"}"; do
    rm -rf "${root:?}/${name}"
  done
  acceptance_sot_restore
  for rel in "${ACCEPTANCE_DATA_TRACKED[@]+"${ACCEPTANCE_DATA_TRACKED[@]}"}"; do
    acceptance_data_rm "${rel}"
  done
  acceptance_data_assert_gone || return 1
  ACCEPTANCE_WL_TRACKED=()
  ACCEPTANCE_SOT_TRACKED=()
  ACCEPTANCE_DATA_TRACKED=()
}

# Wait until a Platform User systemd unit reports ActiveState=active.
acceptance_wait_user_unit_active() {
  local unit="${1:?unit required}"
  local retries="${2:-60}"
  local state="" _
  for _ in $(seq 1 "${retries}"); do
    state="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p ActiveState --value ${unit} 2>/dev/null || echo ""
REMOTE
)"
    [[ "${state}" == "active" ]] && return 0
    sleep 1
  done
  return 1
}

# Read one process-env key from a running container (podman exec printenv).
# Prints the value; empty stdout and non-zero when missing or unreachable.
acceptance_container_printenv() {
  local cname="${1:?container name required}"
  local key="${2:?env key required}"
  host_ssh env "CNAME=${cname}" "KEY=${key}" bash -s <<'REMOTE'
set -euo pipefail
UID_NUM=$(id -u platform)
HOME_DIR=$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/${UID_NUM}
runuser -u platform -- env HOME="${HOME_DIR}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  CNAME="${CNAME}" KEY="${KEY}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
  bash -c 'cd "$HOME" && podman exec "$CNAME" printenv "$KEY"'
REMOTE
}

# Assert container process environment eventually has KEY=want.
acceptance_assert_container_env() {
  local cname="${1:?container name required}"
  local key="${2:?env key required}"
  local want="${3:?expected value required}"
  local got="" _
  for _ in $(seq 1 30); do
    got="$(acceptance_container_printenv "${cname}" "${key}" 2>/dev/null || true)"
    [[ "${got}" == "${want}" ]] && return 0
    sleep 1
  done
  fail "container ${cname} process env: expected ${key}=${want}, got '${got}'"
}

# Assert KEY is absent from container process environment (after restart/clear).
acceptance_assert_container_env_absent() {
  local cname="${1:?container name required}"
  local key="${2:?env key required}"
  local got="" _
  for _ in $(seq 1 30); do
    got="$(acceptance_container_printenv "${cname}" "${key}" 2>/dev/null || true)"
    [[ -z "${got}" ]] && return 0
    sleep 1
  done
  fail "container ${cname} process env: expected ${key} absent, got '${got}'"
}

# Minimal Artifact + Binding stubs so Workload Setup can resolve Environment
# Configuration (empty Requires environment → no bag injection).
acceptance_write_artifact_stubs() {
  local tree="${1:?acceptance_write_artifact_stubs: Workload tree required}"
  mkdir -p "${tree}"
  printf '{}\n' >"${tree}/provides.json"
  printf '{}\n' >"${tree}/binding.json"
  printf '{ "database": false }\n' >"${tree}/requires.json"
}

# Re-run Component Setup post-workloads so Edge gathers Route Declarations (ADR-0043).
# Workload Setup / Purge sync SoT only; fulfillment refreshes on Edge Component Setup.
ensure_edge_route_fulfillment() {
  [[ -n "${REPO_ROOT:-}" ]] || fail "ensure_edge_route_fulfillment: REPO_ROOT required"
  "${REPO_ROOT}/internals/ensure-components.sh" post-workloads --env "${PLATFORM_ENV:-test}"
}

# Re-run Component Setup pre-workloads so Database gathers Declarations (ADR-0049 / #189).
# Workload Setup syncs SoT only; create/publish is Database Component Setup.
ensure_database_fulfillment() {
  [[ -n "${REPO_ROOT:-}" ]] || fail "ensure_database_fulfillment: REPO_ROOT required"
  "${REPO_ROOT}/internals/ensure-components.sh" pre-workloads --env "${PLATFORM_ENV:-test}"
}

# Re-run Component Setup post-workloads so Database drops Purge/Orphan fulfillment (ADR-0049 / #191).
# Purge / Orphan Reap remove SoT only; role/db/client drop is Database Component Setup.
ensure_database_post_workloads() {
  [[ -n "${REPO_ROOT:-}" ]] || fail "ensure_database_post_workloads: REPO_ROOT required"
  "${REPO_ROOT}/internals/ensure-components.sh" post-workloads --env "${PLATFORM_ENV:-test}"
}
