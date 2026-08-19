#!/usr/bin/env bash
# Unit tests: Binding × Provides Route gather, want-list fail-closed (ADR-0028 / ADR-0053 / #203).
# No cloud Apply — temp dirs only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=edge-routes-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/edge-routes-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/edge-routes.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

ROUTES_DIR="${TMP}/routes"
WANT_LIST="${TMP}/want-list"
mkdir -p "${ROUTES_DIR}"
printf '%s\n' 'alpha.example.test' 'beta.example.test' >"${WANT_LIST}"

export HV_ROOT="${TMP}/hv"
mkdir -p "${HV_ROOT}/components/handoff"
printf '%s\n' '{"fqdn":"issuer.example.test"}' >"${HV_ROOT}/components/handoff/identity.json"

# Plant Binding×Provides Route offer (stable fragment path; FQDN is Binding-only).
plant_bound_route() {
  local wl_dir="$1" fqdn="$2" body="$3"
  local rel="${4:-routes/fragment.conf}"
  mkdir -p "${wl_dir}/$(dirname "${rel}")"
  [[ -f "${wl_dir}/manifest.json" ]] || printf '%s\n' '{"intent":"run"}' >"${wl_dir}/manifest.json"
  printf '%s\n' '{ "database": false, "cache": false }' >"${wl_dir}/requires.json"
  printf '%s\n' "${body}" >"${wl_dir}/${rel}"
  cat >"${wl_dir}/provides.json" <<EOF
{ "routes": { "${rel}": "test fragment" } }
EOF
  cat >"${wl_dir}/binding.json" <<EOF
{ "domains": { "${fqdn}": ["${rel}"] } }
EOF
}

plant_zero_routes() {
  local wl_dir="$1"
  mkdir -p "${wl_dir}"
  [[ -f "${wl_dir}/manifest.json" ]] || printf '%s\n' '{"intent":"run"}' >"${wl_dir}/manifest.json"
  printf '%s\n' '{ "database": false, "cache": false }' >"${wl_dir}/requires.json"
  printf '%s\n' '{}' >"${wl_dir}/provides.json"
  printf '%s\n' '{}' >"${wl_dir}/binding.json"
}

WL="${TMP}/wl"
plant_bound_route "${WL}" "not-on-list.example.test" 'location / { return 200 "x"; }'

# --- Intent run fails closed when Binding FQDN is not on the want-list ---
if edge_reconcile_workload_routes "wl" "run" "${WL}" 2>/dev/null; then
  fail "expected fail-closed for Binding FQDN not on want-list"
fi
[[ ! -f "${ROUTES_DIR}/wl--not-on-list.example.test.conf" ]] \
  || fail "fail-closed must not install off-want-list Route"
pass "Intent run fails closed when Binding FQDN is not on the want-list"

# --- Intent run installs Binding-attached fragment when FQDN is on the want-list ---
rm -rf "${WL}"
plant_bound_route "${WL}" "alpha.example.test" 'location /probe { return 200 "ok"; }'
edge_reconcile_workload_routes "wl" "run" "${WL}"
[[ -f "${ROUTES_DIR}/wl--alpha.example.test.conf" ]] \
  || fail "expected installed wl--alpha.example.test.conf"
grep -Fq 'location /probe' "${ROUTES_DIR}/wl--alpha.example.test.conf" \
  || fail "installed Route must keep Provides fragment bytes"
pass "Intent run installs Binding-attached fragment when FQDN is on the want-list"

# --- Fail-closed leaves a prior good install untouched ---
cat >"${WL}/binding.json" <<'EOF'
{
  "domains": {
    "alpha.example.test": ["routes/fragment.conf"],
    "off.example.test": ["routes/fragment.conf"]
  }
}
EOF
if edge_reconcile_workload_routes "wl" "run" "${WL}" 2>/dev/null; then
  fail "expected fail-closed when Binding mixes on- and off-want-list FQDNs"
fi
[[ -f "${ROUTES_DIR}/wl--alpha.example.test.conf" ]] \
  || fail "prior good install must remain after fail-closed"
[[ ! -f "${ROUTES_DIR}/wl--off.example.test.conf" ]] \
  || fail "off-want-list Route must not be installed"
pass "fail-closed leaves a prior good install untouched"

# --- Binding FQDN that is not a single path segment fails closed ---
printf '%s\n' 'alpha.example.test' 'nested/name.example.test' >"${WANT_LIST}"
rm -rf "${WL}"
plant_bound_route "${WL}" "nested/name.example.test" 'location /x { return 200 "x"; }'
if edge_reconcile_workload_routes "wl" "run" "${WL}" 2>/dev/null; then
  fail "expected fail-closed for Binding FQDN that is not a single path segment"
fi
[[ -f "${ROUTES_DIR}/wl--alpha.example.test.conf" ]] \
  || fail "nested FQDN fail-closed must leave prior good install"
[[ ! -e "${ROUTES_DIR}/nested" ]] \
  || fail "nested Binding FQDN must not create Edge interior subdirectories"
printf '%s\n' 'alpha.example.test' 'beta.example.test' >"${WANT_LIST}"
pass "Binding FQDN must be a single path segment"

# --- Intent stop removes that Workload's installed Routes ---
edge_reconcile_workload_routes "wl" "stop" "${WL}"
[[ ! -f "${ROUTES_DIR}/wl--alpha.example.test.conf" ]] \
  || fail "Intent stop must remove installed Routes"
pass "Intent stop removes that Workload's installed Routes"

# --- Zero Routes (missing/empty Binding×Provides) is valid for Intent run ---
EMPTY="${TMP}/empty"
rm -rf "${EMPTY}"
edge_reconcile_workload_routes "empty" "run" "${EMPTY}"
plant_zero_routes "${EMPTY}"
edge_reconcile_workload_routes "empty" "run" "${EMPTY}"
edge_reconcile_workload_routes "empty" "run" ""
pass "zero Routes is valid for Intent run"

# --- Other Workloads' installs are not removed on stop ---
printf '%s\n' '# other' >"${ROUTES_DIR}/other--alpha.example.test.conf"
rm -rf "${WL}"
plant_bound_route "${WL}" "alpha.example.test" 'location /a { return 200 "a"; }'
edge_reconcile_workload_routes "wl" "run" "${WL}"
edge_reconcile_workload_routes "wl" "stop" "${WL}"
[[ -f "${ROUTES_DIR}/other--alpha.example.test.conf" ]] \
  || fail "stop must not remove another Workload's Routes"
pass "stop does not remove another Workload's installed Routes"

# --- gather-all: Intent-run Binding×Provides across Workloads ---
WL_ROOT="${TMP}/workloads-gather"
rm -rf "${WL_ROOT}" "${ROUTES_DIR}"
mkdir -p "${ROUTES_DIR}"
plant_bound_route "${WL_ROOT}/alpha" "alpha.example.test" 'location /a { return 200 "a"; }'
plant_bound_route "${WL_ROOT}/beta" "alpha.example.test" 'location /b { return 200 "b"; }'
edge_gather_workload_routes "${WL_ROOT}"
[[ -f "${ROUTES_DIR}/alpha--alpha.example.test.conf" ]] \
  || fail "gather must fulfill alpha's Intent-run Route"
[[ -f "${ROUTES_DIR}/beta--alpha.example.test.conf" ]] \
  || fail "gather must fulfill beta's Intent-run Route"
grep -Fq 'location /a' "${ROUTES_DIR}/alpha--alpha.example.test.conf" \
  || fail "alpha fulfilled Route must keep Provides fragment bytes"
grep -Fq 'location /b' "${ROUTES_DIR}/beta--alpha.example.test.conf" \
  || fail "beta fulfilled Route must keep Provides fragment bytes"
pass "gather-all fulfills Intent-run Binding×Provides Routes across Workloads"

# --- gather Intent filter: stop drops fulfillment ---
printf '%s\n' '{"intent":"stop"}' >"${WL_ROOT}/alpha/manifest.json"
printf '%s\n' '{"intent":"run"}' >"${WL_ROOT}/beta/manifest.json"
edge_gather_workload_routes "${WL_ROOT}"
[[ ! -f "${ROUTES_DIR}/alpha--alpha.example.test.conf" ]] \
  || fail "gather must drop fulfillment for Intent stop"
[[ -f "${ROUTES_DIR}/beta--alpha.example.test.conf" ]] \
  || fail "gather must keep fulfillment for Intent run"
pass "gather drops fulfillment for Intent stop; keeps run"

# --- gather restores run and removes orphan Edge installs (SoT gone) ---
printf '%s\n' '{"intent":"run"}' >"${WL_ROOT}/alpha/manifest.json"
rm -rf "${WL_ROOT}/beta"
printf '%s\n' '# orphan' >"${ROUTES_DIR}/gone--alpha.example.test.conf"
edge_gather_workload_routes "${WL_ROOT}"
[[ -f "${ROUTES_DIR}/alpha--alpha.example.test.conf" ]] \
  || fail "gather must fulfill remaining Intent-run Workload"
[[ ! -f "${ROUTES_DIR}/gone--alpha.example.test.conf" ]] \
  || fail "gather must remove fulfilled Routes when Workload SoT is gone"
[[ ! -f "${ROUTES_DIR}/beta--alpha.example.test.conf" ]] \
  || fail "gather must not leave Routes for removed Workload SoT"
pass "gather removes orphan Edge installs when Workload SoT is gone"

# --- gather fail-closed preserves prior good fulfillments ---
plant_bound_route "${WL_ROOT}/beta" "alpha.example.test" 'location /b { return 200 "b"; }'
edge_gather_workload_routes "${WL_ROOT}"
[[ -f "${ROUTES_DIR}/alpha--alpha.example.test.conf" ]] \
  || fail "precondition: alpha fulfilled before fail-closed gather"
[[ -f "${ROUTES_DIR}/beta--alpha.example.test.conf" ]] \
  || fail "precondition: beta fulfilled before fail-closed gather"
cat >"${WL_ROOT}/alpha/binding.json" <<'EOF'
{
  "domains": {
    "alpha.example.test": ["routes/fragment.conf"],
    "off.example.test": ["routes/fragment.conf"]
  }
}
EOF
if edge_gather_workload_routes "${WL_ROOT}" 2>/dev/null; then
  fail "expected gather fail-closed when a Binding FQDN is not on the want-list"
fi
[[ -f "${ROUTES_DIR}/alpha--alpha.example.test.conf" ]] \
  || fail "gather fail-closed must leave prior good alpha fulfillment"
[[ ! -f "${ROUTES_DIR}/alpha--off.example.test.conf" ]] \
  || fail "gather fail-closed must not install off-want-list Route"
[[ -f "${ROUTES_DIR}/beta--alpha.example.test.conf" ]] \
  || fail "gather fail-closed must leave other Workloads' fulfillments"
pass "gather fail-closed preserves prior good fulfillments"

# --- gather fail-closed preserves prior good fulfillments ---
plant_bound_route "${WL_ROOT}/alpha" "alpha.example.test" 'location /a { return 200 "a"; }'
edge_gather_workload_routes "${WL_ROOT}"
[[ -f "${ROUTES_DIR}/alpha--alpha.example.test.conf" ]] \
  || fail "precondition: alpha fulfilled after restoring on-want-list Binding"
[[ -f "${ROUTES_DIR}/beta--alpha.example.test.conf" ]] \
  || fail "precondition: beta fulfilled after restoring on-want-list Binding"
EDGE_ROUTES_CHANGED=1
edge_gather_workload_routes "${WL_ROOT}"
[[ "${EDGE_ROUTES_CHANGED}" == "0" ]] \
  || fail "unchanged gather inputs must set EDGE_ROUTES_CHANGED=0 (noop)"
pass "gather is a noop when inputs are unchanged"

# --- issuer FQDN route collision fails closed during gather ---
ISSUER="${TMP}/issuer-collision"
mkdir -p "${ISSUER}/handoff" "${ISSUER}/workloads/offender/routes" "${ISSUER}/routes"
printf '%s\n' '{"fqdn":"auth.example.test"}' >"${ISSUER}/handoff/identity.json"
HV_ROOT_SAVE="${HV_ROOT-}"
export HV_ROOT="${ISSUER}/hv"
mkdir -p "${HV_ROOT}/components/handoff"
cp "${ISSUER}/handoff/identity.json" "${HV_ROOT}/components/handoff/identity.json"
ROUTES_DIR_SAVE="${ROUTES_DIR}"
WANT_LIST_SAVE="${WANT_LIST}"
ROUTES_DIR="${ISSUER}/routes"
WANT_LIST="${ISSUER}/want-list"
printf '%s\n' 'alpha.example.test' 'auth.example.test' >"${WANT_LIST}"
printf '%s\n' '{"intent":"run"}' >"${ISSUER}/workloads/offender/manifest.json"
printf '%s\n' '{ "database": false, "cache": false }' >"${ISSUER}/workloads/offender/requires.json"
printf '%s\n' 'location / { return 200 "x"; }' >"${ISSUER}/workloads/offender/routes/fragment.conf"
printf '%s\n' '{"routes":{"routes/fragment.conf":"test"}}' >"${ISSUER}/workloads/offender/provides.json"
printf '%s\n' '{"domains":{"auth.example.test":["routes/fragment.conf"]}}' >"${ISSUER}/workloads/offender/binding.json"
if edge_gather_workload_routes "${ISSUER}/workloads" 2>/dev/null; then
  fail "gather must fail closed when Binding attaches Routes to issuer FQDN"
fi
pass "gather fails closed on issuer FQDN route collision"
export HV_ROOT="${HV_ROOT_SAVE}"
ROUTES_DIR="${ROUTES_DIR_SAVE}"
WANT_LIST="${WANT_LIST_SAVE}"
unset HV_ROOT_SAVE ROUTES_DIR_SAVE WANT_LIST_SAVE

# --- ordered Binding array concatenates Provides fragments onto one FQDN ---
ORD="${WL_ROOT}/ordered"
rm -rf "${ORD}"
mkdir -p "${ORD}/routes"
printf '%s\n' '{"intent":"run"}' >"${ORD}/manifest.json"
printf '%s\n' '{ "database": false, "cache": false }' >"${ORD}/requires.json"
printf '%s\n' 'location /first { return 200 "1"; }' >"${ORD}/routes/first.conf"
printf '%s\n' 'location /second { return 200 "2"; }' >"${ORD}/routes/second.conf"
cat >"${ORD}/provides.json" <<'EOF'
{
  "routes": {
    "routes/first.conf": "first",
    "routes/second.conf": "second"
  }
}
EOF
cat >"${ORD}/binding.json" <<'EOF'
{ "domains": { "alpha.example.test": ["routes/first.conf", "routes/second.conf"] } }
EOF
edge_gather_workload_routes "${WL_ROOT}"
got="$(cat "${ROUTES_DIR}/ordered--alpha.example.test.conf")"
printf '%s\n' "${got}" | grep -Fq 'location /first' \
  || fail "ordered concat must include first fragment"
printf '%s\n' "${got}" | grep -Fq 'location /second' \
  || fail "ordered concat must include second fragment"
first_line="$(printf '%s\n' "${got}" | grep -n 'location /first' | head -1 | cut -d: -f1)"
second_line="$(printf '%s\n' "${got}" | grep -n 'location /second' | head -1 | cut -d: -f1)"
[[ "${first_line}" -lt "${second_line}" ]] \
  || fail "Binding array order must be preserved in fulfilled concat"
pass "ordered Binding array concatenates Provides fragments"

# --- one Provides fragment attached to two FQDNs ---
TWO="${WL_ROOT}/twofqdn"
rm -rf "${TWO}"
plant_bound_route "${TWO}" "alpha.example.test" 'location /shared { return 200 "s"; }'
cat >"${TWO}/binding.json" <<'EOF'
{
  "domains": {
    "alpha.example.test": ["routes/fragment.conf"],
    "beta.example.test": ["routes/fragment.conf"]
  }
}
EOF
edge_gather_workload_routes "${WL_ROOT}"
grep -Fq 'location /shared' "${ROUTES_DIR}/twofqdn--alpha.example.test.conf" \
  || fail "shared fragment must fulfill onto first FQDN"
grep -Fq 'location /shared' "${ROUTES_DIR}/twofqdn--beta.example.test.conf" \
  || fail "shared fragment must fulfill onto second FQDN"
pass "one Provides fragment attaches to two Binding FQDNs"

# --- leftover FQDN-as-filename under routes/ is not dual-read ---
LEFTOVER="${WL_ROOT}/leftover"
rm -rf "${LEFTOVER}"
plant_bound_route "${LEFTOVER}" "alpha.example.test" 'location /from-binding { return 200 "b"; }'
printf '%s\n' 'location /from-filename { return 200 "f"; }' \
  >"${LEFTOVER}/routes/alpha.example.test.conf"
edge_gather_workload_routes "${WL_ROOT}"
grep -Fq 'location /from-binding' "${ROUTES_DIR}/leftover--alpha.example.test.conf" \
  || fail "gather must fulfill Binding-attached fragment"
if grep -Fq 'location /from-filename' "${ROUTES_DIR}/leftover--alpha.example.test.conf"; then
  fail "gather must not dual-read FQDN-as-filename Workload-tree routes/"
fi
pass "gather does not dual-read FQDN-as-filename Route SoT"

# --- missing Binding/Provides means Edge does not fulfill ---
MISS="${WL_ROOT}/missing"
rm -rf "${MISS}"
mkdir -p "${MISS}/routes"
printf '%s\n' '{"intent":"run"}' >"${MISS}/manifest.json"
printf '%s\n' 'location /orphan-sot { return 200 "o"; }' \
  >"${MISS}/routes/alpha.example.test.conf"
printf '%s\n' '# prior' >"${ROUTES_DIR}/missing--alpha.example.test.conf"
edge_gather_workload_routes "${WL_ROOT}"
[[ ! -f "${ROUTES_DIR}/missing--alpha.example.test.conf" ]] \
  || fail "missing Binding/Provides must drop (not offer) Edge fulfillment"
pass "missing Binding/Provides does not fulfill Routes"

# --- missing Provides fragment file fails closed ---
rm -f "${WL_ROOT}/alpha/routes/fragment.conf"
if edge_gather_workload_routes "${WL_ROOT}" 2>/dev/null; then
  fail "expected fail-closed when Binding path has no fragment file"
fi
pass "missing Provides fragment file fails closed"

# --- clear fulfilled Routes empties ROUTES_DIR (Domain fronts are elsewhere) ---
printf '%s\n' '# a' >"${ROUTES_DIR}/wl--alpha.example.test.conf"
printf '%s\n' '# legacy' >"${ROUTES_DIR}/legacy.conf"
edge_clear_fulfilled_routes
[[ -z "$(find "${ROUTES_DIR}" -maxdepth 1 -type f 2>/dev/null)" ]] \
  || fail "edge_clear_fulfilled_routes must remove all files under ROUTES_DIR"
pass "edge_clear_fulfilled_routes clears fulfilled Workload Routes under Edge data"

# --- gather lib does not scan Workload-tree routes/ as FQDN SoT ---
if grep -E 'sot_dir="\$\{wl_dir\}/routes"|wl_dir\}/routes"' \
    "${REPO_ROOT}/internals/host-scripts/lib/edge-routes-host.sh"; then
  fail "edge-routes-host must not treat Workload-tree routes/ as FQDN-as-filename SoT"
fi
pass "gather lib has no FQDN-as-filename Route SoT scan"

# --- Host delivery ships Binding/Provides/Requires beside Edge gather ---
for ship in \
  "${REPO_ROOT}/internals/ensure-components.sh" \
  "${REPO_ROOT}/internals/ensure-fabric.sh"; do
  for lib in binding.sh provides.sh requires.sh; do
    grep -Fq "lib/artifact/${lib}" "${ship}" \
      || fail "${ship} must stage artifact ${lib} beside Host helpers"
  done
done
pass "ensure-components and ensure-fabric stage Binding/Provides/Requires"

# --- prod panel Routes are Binding-attached Provides fragments ---
PANEL="${REPO_ROOT}/environments/prod/panel"
[[ -f "${PANEL}/routes/panel.conf" ]] \
  || fail "prod panel must offer a stable Provides fragment routes/panel.conf"
[[ ! -e "${PANEL}/routes/www.propreator.gniewomir.pl.conf" ]] \
  || fail "prod panel must not author FQDN-as-filename Route SoT"
[[ ! -e "${PANEL}/routes/propreator.gniewomir.pl.conf" ]] \
  || fail "prod panel must not author FQDN-as-filename Route SoT"
grep -Fq 'www.propreator.gniewomir.pl' "${PANEL}/binding.json" \
  || fail "prod panel Binding must attach www.propreator.gniewomir.pl"
grep -Fq 'propreator.gniewomir.pl' "${PANEL}/binding.json" \
  || fail "prod panel Binding must attach propreator.gniewomir.pl"
grep -Fq 'routes/panel.conf' "${PANEL}/provides.json" \
  || fail "prod panel Provides must list routes/panel.conf"
pass "prod panel Routes are Binding-attached Provides fragments"

echo "All Edge Route helper checks passed."
