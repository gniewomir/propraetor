#!/usr/bin/env bash
# Edge ACME on-demand runner (systemd user oneshot).
# Empty want-list → success with no CA contact.
# EDGE_ACME_DIRECTORY / EDGE_ACME_EMAIL come from the Host ACME EnvironmentFile
# (acme.json directory + Operator Configuration PROPRAETOR_ACME_EMAIL via
# ensure-components — ADR-0045 / ADR-0038).
# EDGE_ACME_ISSUE=0 skips CA contact (Acceptance / fixture) but still reloads Edge when names exist.
# Missing EDGE_ACME_DIRECTORY defaults to staging; production is Environment acme.json opt-in.
set -euo pipefail

# Path vocabulary bootstrap (#214). Host Volume SoT segment "internals/" ≠ repo internals/.
# shellcheck source=../../host-scripts/lib/host-volume-paths-host.sh
source "${HV_ROOT:-/host-volume}/host-scripts/lib/host-volume-paths-host.sh"

DATA_ROOT="$(host_volume_component_persist edge)"
ROUTES_DIR="${DATA_ROOT}/routes"
CERTS_DIR="${DATA_ROOT}/certs"
ACME_DIR="${DATA_ROOT}/acme"
ACME_WWW="${DATA_ROOT}/acme-www"
WANT_LIST="${ACME_DIR}/want-list"
LEGO_BIN="${LEGO_BIN:-${DATA_ROOT}/acme/bin/lego}"
USER_NAME="${PLATFORM_USER:-platform}"
_hv_lib="$(host_volume_host_scripts_root)/lib"

# shellcheck source=../../host-scripts/lib/quadlet-user-session.sh
source "${_hv_lib}/quadlet-user-session.sh"
# shellcheck source=../../host-scripts/lib/edge-want-list-host.sh
source "${_hv_lib}/edge-want-list-host.sh"
# shellcheck source=../../host-scripts/lib/edge-acme-issue-host.sh
source "${_hv_lib}/edge-acme-issue-host.sh"
# shellcheck source=../../host-scripts/lib/edge-front-door-host.sh
source "${_hv_lib}/edge-front-door-host.sh"

mkdir -p "${ACME_DIR}" "${ACME_WWW}" "${CERTS_DIR}" "${ROUTES_DIR}"

# Shared want-list FQDN reader (same helper as Domain fronts / Route fail-closed).
names=()
while IFS= read -r _acme_fqdn || [[ -n "${_acme_fqdn}" ]]; do
  [[ -n "${_acme_fqdn}" ]] || continue
  names+=("${_acme_fqdn}")
done < <(edge_want_list_fqdns)
unset _acme_fqdn
# Stamp every oneshot invocation so Acceptance Tests can observe triggers without a live CA.
date -u +%Y-%m-%dT%H:%M:%SZ >"${ACME_DIR}/last-run"

if ((${#names[@]} == 0)); then
  exit 0
fi

acme_server() {
  case "${EDGE_ACME_DIRECTORY:-staging}" in
    production|prod)
      echo "https://acme-v02.api.letsencrypt.org/directory"
      ;;
    staging|*)
      echo "https://acme-staging-v02.api.letsencrypt.org/directory"
      ;;
  esac
}

issue_one() {
  local host="$1"
  local email="${EDGE_ACME_EMAIL:-}"
  local server
  server="$(acme_server)"
  # Let's Encrypt rejects .invalid and example.com contacts; default from the name's apex.
  if [[ -z "${email}" ]]; then
    if [[ "${host}" == *.*.* ]]; then
      email="acme@${host#*.}"
    else
      email="acme@${host}"
    fi
  fi

  # Staging↔production cutover: lego would "renew" the wrong-CA leaf with a
  # multi-minute random sleep (and ARI against the wrong issuer). Drop lego's
  # stored cert so `run` issues fresh against the configured directory.
  if acme_installed_pem_wrong_ca "${host}"; then
    echo "edge-acme: ${host} LE PEM CA mismatches EDGE_ACME_DIRECTORY=${EDGE_ACME_DIRECTORY:-staging}; clearing lego cert for fresh issue" >&2
    acme_clear_lego_certificate "${host}" || true
  fi

  # lego v5: flags are command options; `run` issues and renews (no separate renew).
  # Bound CA wait so a mispointed DNS name cannot stall the oneshot forever.
  # --no-random-sleep: Setup blocks on this oneshot; lego's renewal jitter can be
  # minutes and trips the timeout while looking like a Deploy hang.
  # Do not bind :80/:443 — webroot only (Edge serves challenges).
  if ! timeout 120 "${LEGO_BIN}" run \
    --path "${ACME_DIR}" \
    --accept-tos \
    --email "${email}" \
    --server "${server}" \
    --domains "${host}" \
    --http \
    --http.webroot "${ACME_WWW}" \
    --renew-days 30 \
    --no-random-sleep; then
    echo "edge-acme: CA issue/renew failed for ${host} (leaving existing PEMs untouched)" >&2
    return 1
  fi
  install_pems_from_lego "${host}" || {
    echo "edge-acme: lego succeeded but PEMs missing for ${host}" >&2
    return 1
  }
}

# One-shot v4→v5 storage migrate (idempotent). lego prompts; answer yes non-interactively.
ensure_lego_storage() {
  if [[ ! -x "${LEGO_BIN}" ]]; then
    return 0
  fi
  printf 'y\n' | "${LEGO_BIN}" migrate --path "${ACME_DIR}" >/dev/null 2>&1 || true
}

issue_failed=0
if [[ "${EDGE_ACME_ISSUE:-1}" != "0" ]]; then
  if [[ ! -x "${LEGO_BIN}" ]]; then
    echo "edge-acme: lego missing or not executable at ${LEGO_BIN}" >&2
    exit 1
  fi
  ensure_lego_storage
  for host in "${names[@]}"; do
    if ! issue_one "${host}"; then
      issue_failed=1
    fi
  done
else
  echo "edge-acme: EDGE_ACME_ISSUE=0 — skipping CA contact; reloading Edge only" >&2
fi

# Oneshot runs as the Platform User (systemd --user); only use root helpers when root.
if [[ "$(id -un)" == "${USER_NAME}" ]]; then
  UID_NUM="$(id -u)"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID_NUM}}"
else
  quadlet_user_session_begin
fi

# Operator-owned Routes are not rewritten; reload so new PEMs are picked up by existing Routes.
edge_reload_front_door

if [[ "${issue_failed}" -ne 0 ]]; then
  echo "edge-acme: one or more CA contacts failed; usable PEMs left untouched; Edge reloaded" >&2
fi
# Always succeed after reload attempt: DNS/CA failures are logged; Setup must not depend on issuance.
exit 0
