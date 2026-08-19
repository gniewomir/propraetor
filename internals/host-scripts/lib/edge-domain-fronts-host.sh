#!/usr/bin/env bash
# Edge Domain fronts + placeholder PEM helpers (sourced by Edge Component Setup).
# Expects: CERTS_DIR, WANT_LIST; for Domain fronts also DOMAINS_DIR, ROUTES_DIR,
# DOMAIN_FRONT_TEMPLATE (Edge Component SoT; fail closed if missing).
# Optional: USER_NAME for ownership after writes.
#
# ADR-0028 / ADR-0029 / #78.

_edge_domain_fronts_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edge-want-list-host.sh
source "${_edge_domain_fronts_lib_dir}/edge-want-list-host.sh"
# shellcheck source=edge-identity-issuer-host.sh
source "${_edge_domain_fronts_lib_dir}/edge-identity-issuer-host.sh"

# Create-if-missing self-signed PEMs for each want-list FQDN (ADR-0029).
# Both fullchain.pem + privkey.pem present → never touch.
# Either missing → write a fresh pair (CN+SAN = FQDN).
# Names leaving the want-list are not pruned.
edge_plant_placeholder_pems() {
  local fqdn dest full key tmpcnf
  local -a names=()

  mkdir -p "${CERTS_DIR}"
  while IFS= read -r fqdn || [[ -n "${fqdn}" ]]; do
    [[ -n "${fqdn}" ]] || continue
    names+=("${fqdn}")
  done < <(edge_want_list_fqdns)

  for fqdn in "${names[@]+"${names[@]}"}"; do
    dest="${CERTS_DIR}/${fqdn}"
    full="${dest}/fullchain.pem"
    key="${dest}/privkey.pem"
    mkdir -p "${dest}"
    if [[ -f "${full}" && -f "${key}" ]]; then
      continue
    fi
    tmpcnf="$(mktemp "${TMPDIR:-/tmp}/platform-placeholder-XXXXXX.cnf")"
    cat >"${tmpcnf}" <<EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_req
prompt = no
[req_dn]
CN = ${fqdn}
[v3_req]
subjectAltName = DNS:${fqdn}
EOF
    # Fresh pair: remove any incomplete half so openssl can rewrite both.
    rm -f "${full}" "${key}"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${key}" \
      -out "${full}" \
      -days 365 \
      -config "${tmpcnf}" >/dev/null 2>&1
    rm -f "${tmpcnf}"
    chmod 0644 "${full}"
    chmod 0600 "${key}"
  done

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${CERTS_DIR}" 2>/dev/null || true
  fi
}

# Render template for one FQDN (__FQDN__ → fqdn).
# Args: fqdn template_path
# Idempotent: skips rewrite when on-disk bytes already match.
_edge_write_domain_front() {
  local fqdn="$1"
  local template_path="$2"
  local dest="${DOMAINS_DIR}/${fqdn}.conf"
  local template desired tmp

  [[ -n "${template_path}" && -f "${template_path}" ]] || {
    echo "_edge_write_domain_front: Domain front template missing: ${template_path:-<unset>}" >&2
    return 1
  }
  template="$(cat "${template_path}")"
  desired="${template//__FQDN__/${fqdn}}"

  if [[ -f "${dest}" ]] && [[ "$(cat "${dest}")" == "${desired}" ]]; then
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/platform-domain-front-XXXXXX.conf")"
  printf '%s\n' "${desired}" >"${tmp}"
  install -m 0644 "${tmp}" "${dest}"
  rm -f "${tmp}"
}

# Reconcile Domain-front drop-ins for the want-list under DOMAINS_DIR (ADR-0028).
# SoT is DOMAIN_FRONT_TEMPLATE (Edge Component); issuer FQDN uses
# IDENTITY_DOMAIN_FRONT_TEMPLATE (ADR-0057). Missing template fails closed.
# Empty nginx wildcard includes are valid (parent dirs exist); no 00-empty stubs.
# Does not prune Domain fronts for names that left the want-list.
# Removes legacy include stubs from earlier Setup generations.
edge_reconcile_domain_fronts() {
  local fqdn issuer_fqdn=""
  local -a names=()

  if [[ -z "${DOMAIN_FRONT_TEMPLATE:-}" || ! -f "${DOMAIN_FRONT_TEMPLATE}" ]]; then
    echo "edge_reconcile_domain_fronts: Domain front template missing: ${DOMAIN_FRONT_TEMPLATE:-<unset>}" >&2
    return 1
  fi
  if [[ -z "${IDENTITY_DOMAIN_FRONT_TEMPLATE:-}" || ! -f "${IDENTITY_DOMAIN_FRONT_TEMPLATE}" ]]; then
    echo "edge_reconcile_domain_fronts: Identity Domain front template missing: ${IDENTITY_DOMAIN_FRONT_TEMPLATE:-<unset>}" >&2
    return 1
  fi

  mkdir -p "${DOMAINS_DIR}" "${ROUTES_DIR}"

  # Drop legacy empty-glob stubs (ADR-0028 attachment cutover).
  rm -f "${DOMAINS_DIR}/00-empty.conf" "${ROUTES_DIR}/00-empty.conf"
  if compgen -G "${ROUTES_DIR}/00-empty--*" >/dev/null; then
    rm -f "${ROUTES_DIR}/00-empty--"*.conf
  fi

  issuer_fqdn="$(edge_identity_issuer_fqdn_from_handoff)" || return 1

  while IFS= read -r fqdn || [[ -n "${fqdn}" ]]; do
    [[ -n "${fqdn}" ]] || continue
    names+=("${fqdn}")
  done < <(edge_want_list_fqdns)

  for fqdn in "${names[@]+"${names[@]}"}"; do
    if [[ "${fqdn}" == "${issuer_fqdn}" ]]; then
      _edge_write_domain_front "${fqdn}" "${IDENTITY_DOMAIN_FRONT_TEMPLATE}"
    else
      _edge_write_domain_front "${fqdn}" "${DOMAIN_FRONT_TEMPLATE}"
    fi
  done

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${DOMAINS_DIR}" "${ROUTES_DIR}" 2>/dev/null || true
  fi
}
