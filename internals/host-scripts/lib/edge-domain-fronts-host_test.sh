#!/usr/bin/env bash
# Unit tests: placeholder PEM create-if-missing (ADR-0029 / #78).
# No cloud Apply — temp dirs only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=edge-domain-fronts-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/edge-domain-fronts-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/edge-domain-fronts.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

CERTS_DIR="${TMP}/certs"
WANT_LIST="${TMP}/want-list"
mkdir -p "${CERTS_DIR}"

# --- create-if-missing: both absent → plant pair with CN+SAN = FQDN ---
printf '%s\n' 'alpha.example.test' >"${WANT_LIST}"
edge_plant_placeholder_pems
[[ -f "${CERTS_DIR}/alpha.example.test/fullchain.pem" ]] \
  || fail "expected fullchain.pem after plant"
[[ -f "${CERTS_DIR}/alpha.example.test/privkey.pem" ]] \
  || fail "expected privkey.pem after plant"
subj="$(openssl x509 -in "${CERTS_DIR}/alpha.example.test/fullchain.pem" -noout -subject)"
echo "${subj}" | grep -q 'CN[[:space:]]*=[[:space:]]*alpha.example.test' \
  || fail "CN expected alpha.example.test, got '${subj}'"
san="$(openssl x509 -in "${CERTS_DIR}/alpha.example.test/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)"
echo "${san}" | grep -Fq 'DNS:alpha.example.test' \
  || fail "SAN expected DNS:alpha.example.test, got '${san}'"
pass "plants self-signed pair with CN+SAN = FQDN when both missing"

# --- complete pair never touched ---
full_before="$(cat "${CERTS_DIR}/alpha.example.test/fullchain.pem")"
key_before="$(cat "${CERTS_DIR}/alpha.example.test/privkey.pem")"
edge_plant_placeholder_pems
full_after="$(cat "${CERTS_DIR}/alpha.example.test/fullchain.pem")"
key_after="$(cat "${CERTS_DIR}/alpha.example.test/privkey.pem")"
[[ "${full_before}" == "${full_after}" ]] || fail "complete fullchain.pem must not be overwritten"
[[ "${key_before}" == "${key_after}" ]] || fail "complete privkey.pem must not be overwritten"
pass "never overwrites a complete fullchain+privkey pair"

# --- incomplete pair (privkey missing) → fresh pair ---
rm -f "${CERTS_DIR}/alpha.example.test/privkey.pem"
printf 'stale-fullchain\n' >"${CERTS_DIR}/alpha.example.test/fullchain.pem"
edge_plant_placeholder_pems
[[ -f "${CERTS_DIR}/alpha.example.test/privkey.pem" ]] \
  || fail "expected privkey after incomplete rewrite"
grep -q 'BEGIN CERTIFICATE' "${CERTS_DIR}/alpha.example.test/fullchain.pem" \
  || fail "incomplete rewrite should replace stale fullchain with a real cert"
pass "rewrites incomplete pair (missing privkey) as a fresh pair"

# --- incomplete pair (fullchain missing) → fresh pair ---
rm -f "${CERTS_DIR}/alpha.example.test/fullchain.pem"
edge_plant_placeholder_pems
[[ -f "${CERTS_DIR}/alpha.example.test/fullchain.pem" ]] \
  || fail "expected fullchain after incomplete rewrite"
[[ -f "${CERTS_DIR}/alpha.example.test/privkey.pem" ]] \
  || fail "expected privkey after incomplete rewrite"
pass "rewrites incomplete pair (missing fullchain) as a fresh pair"

# --- names leaving want-list are not pruned ---
printf '%s\n' 'beta.example.test' >"${WANT_LIST}"
edge_plant_placeholder_pems
[[ -f "${CERTS_DIR}/alpha.example.test/fullchain.pem" ]] \
  || fail "alpha PEMs must remain after leaving want-list"
[[ -f "${CERTS_DIR}/beta.example.test/fullchain.pem" ]] \
  || fail "beta PEMs expected for new want-list name"
pass "does not prune PEMs when a name leaves the want-list"

# --- Domain fronts: reconcile drop-ins for want-list (no empty-glob stubs) ---
DOMAINS_DIR="${TMP}/domains"
ROUTES_DIR="${TMP}/routes"
DOMAIN_FRONT_TEMPLATE="${REPO_ROOT}/internals/components/edge/domain-template.conf"
IDENTITY_DOMAIN_FRONT_TEMPLATE="${REPO_ROOT}/internals/components/edge/identity-domain-template.conf"
HANDOFF_ROOT="${TMP}/handoff-root"
mkdir -p "${HANDOFF_ROOT}" "${DOMAINS_DIR}" "${ROUTES_DIR}"
printf '%s\n' '{"fqdn":"gamma.example.test"}' >"${HANDOFF_ROOT}/identity.json"
export HV_ROOT="${TMP}/hv"
mkdir -p "${HV_ROOT}/components/handoff"
cp "${HANDOFF_ROOT}/identity.json" "${HV_ROOT}/components/handoff/identity.json"
printf '%s\n' 'alpha.example.test' 'gamma.example.test' >"${WANT_LIST}"

# Legacy stubs must be cleared on reconcile.
printf '%s\n' '# legacy' >"${DOMAINS_DIR}/00-empty.conf"
printf '%s\n' '# legacy' >"${ROUTES_DIR}/00-empty.conf"
printf '%s\n' '# legacy' >"${ROUTES_DIR}/00-empty--alpha.example.test.conf"

edge_reconcile_domain_fronts

[[ ! -f "${DOMAINS_DIR}/00-empty.conf" ]] \
  || fail "domains/00-empty.conf stub must be removed"
[[ ! -f "${ROUTES_DIR}/00-empty.conf" ]] \
  || fail "routes/00-empty.conf stub must be removed"
[[ ! -f "${ROUTES_DIR}/00-empty--alpha.example.test.conf" ]] \
  || fail "per-FQDN route stub must be removed"
[[ -f "${DOMAINS_DIR}/alpha.example.test.conf" ]] \
  || fail "expected Domain front for alpha.example.test"
[[ -f "${DOMAINS_DIR}/gamma.example.test.conf" ]] \
  || fail "expected Domain front for gamma.example.test"

front="$(cat "${DOMAINS_DIR}/alpha.example.test.conf")"
echo "${front}" | grep -Fq 'server_name alpha.example.test;' \
  || fail "Domain front must set server_name to FQDN"
echo "${front}" | grep -Fq 'ssl_certificate     /etc/nginx/certs/alpha.example.test/fullchain.pem;' \
  || fail "Domain front must pin stable fullchain path"
echo "${front}" | grep -Fq 'ssl_certificate_key /etc/nginx/certs/alpha.example.test/privkey.pem;' \
  || fail "Domain front must pin stable privkey path"
echo "${front}" | grep -Fq 'location = /healthcheck' \
  || fail "Domain front must publish /healthcheck"
echo "${front}" | grep -Fq "include /etc/nginx/edge-routes/*--alpha.example.test.conf;" \
  || fail "Domain front must include Workload Route fragments by FQDN"
echo "${front}" | grep -E -q 'return 301 https://\$host\$request_uri;' \
  || fail "Domain front :80 must redirect non-ACME to HTTPS"
echo "${front}" | grep -Fq 'location ^~ /.well-known/acme-challenge/' \
  || fail "Domain front :80 must keep ACME HTTP-01"
echo "${front}" | grep -Fq '__FQDN__' \
  && fail "Domain front must not leave __FQDN__ unsubstituted"
pass "reconciles Domain fronts with TLS paths, /healthcheck, redirect, ACME, and Route includes"

issuer_front="$(cat "${DOMAINS_DIR}/gamma.example.test.conf")"
echo "${issuer_front}" | grep -Fq 'proxy_pass http://identity:1411;' \
  || fail "Identity issuer Domain front must proxy to Identity dial name"
if echo "${issuer_front}" | grep -Fq 'edge-routes/*--gamma.example.test.conf'; then
  fail "Identity issuer Domain front must not include Workload Route fragments"
fi
pass "issuer FQDN Domain front proxies to Identity; no Workload Routes"

# --- Domain-front bytes stay stable across re-reconcile (ACME must not churn drop-ins either) ---
before="$(cat "${DOMAINS_DIR}/alpha.example.test.conf")"
edge_reconcile_domain_fronts
after="$(cat "${DOMAINS_DIR}/alpha.example.test.conf")"
[[ "${before}" == "${after}" ]] || fail "re-reconcile must not churn Domain-front bytes"
pass "Domain-front drop-ins are byte-stable across re-reconcile"

# --- Missing Domain front template fails closed ---
DOMAIN_FRONT_TEMPLATE="${REPO_ROOT}/internals/components/edge/domain-template.conf"
unset IDENTITY_DOMAIN_FRONT_TEMPLATE
if edge_reconcile_domain_fronts 2>"${TMP}/missing-identity-template.err"; then
  fail "reconcile must fail when IDENTITY_DOMAIN_FRONT_TEMPLATE is unset"
fi
grep -Fq 'Identity Domain front template missing' "${TMP}/missing-identity-template.err" \
  || fail "missing Identity template error must name the template"
IDENTITY_DOMAIN_FRONT_TEMPLATE="${REPO_ROOT}/internals/components/edge/identity-domain-template.conf"
unset DOMAIN_FRONT_TEMPLATE
if edge_reconcile_domain_fronts 2>"${TMP}/missing-template.err"; then
  fail "reconcile must fail when DOMAIN_FRONT_TEMPLATE is unset"
fi
grep -Fq 'Domain front template missing' "${TMP}/missing-template.err" \
  || fail "missing-template error must name the template"
DOMAIN_FRONT_TEMPLATE="${TMP}/no-such-domain-template.conf"
if edge_reconcile_domain_fronts 2>"${TMP}/missing-template2.err"; then
  fail "reconcile must fail when DOMAIN_FRONT_TEMPLATE path is absent"
fi
grep -Fq 'Domain front template missing' "${TMP}/missing-template2.err" \
  || fail "absent-template error must name the template"
DOMAIN_FRONT_TEMPLATE="${REPO_ROOT}/internals/components/edge/domain-template.conf"
pass "fails closed when Domain front template is missing"

echo "All Domain front helper checks passed."
