#!/usr/bin/env bash
# Unit Test: authored Quadlet Volume=/EnvironmentFile= use Host-relative paths (ADR-0054 / #218).
# Seam: committed Component + example/prod Workload systemd/ bags — portable ../persist authorship.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

trees=(
  "${REPO_ROOT}/internals/components/edge/systemd"
  "${REPO_ROOT}/internals/components/database/systemd"
  "${REPO_ROOT}/internals/components/cache/systemd"
  "${REPO_ROOT}/environments/example/hello-service/systemd"
  "${REPO_ROOT}/environments/example/static-site/systemd"
  "${REPO_ROOT}/environments/example/env-config/systemd"
  "${REPO_ROOT}/environments/example/web-api-with-db/systemd"
  "${REPO_ROOT}/environments/prod/panel/systemd"
)

found_abs_vol=0
found_rel_vol=0
while IFS= read -r -d '' f; do
  [[ "${f}" == *.container ]] || continue
  if grep -Eq '^Volume=/host-volume/' "${f}"; then
    echo "absolute Host Volume Volume= in ${f}" >&2
    found_abs_vol=1
  fi
  if grep -Eq '^Volume=\.\./' "${f}"; then
    found_rel_vol=1
  fi
  # EnvironmentFile= is not covered by the Volume= relative spike — keep absolute.
  if grep -Eq '^EnvironmentFile=\.\./' "${f}"; then
    echo "relative EnvironmentFile= in ${f} (use absolute /host-volume/…)" >&2
    found_abs_vol=1
  fi
done < <(find "${trees[@]}" -type f -name '*.container' -print0 2>/dev/null)

[[ "${found_abs_vol}" -eq 0 ]] \
  || fail "authored .container Volume= must be ../…; EnvironmentFile= must stay absolute"
[[ "${found_rel_vol}" -eq 1 ]] \
  || fail "expected at least one Volume=../… bind in authored .container units"
pass "authored Quadlet containers use relative Volume= binds"

# Soft Persist scaffold habit on teaching examples that mount /var/lib/workload.
for wl in hello-service static-site env-config web-api-with-db; do
  example_dir="${REPO_ROOT}/environments/example/${wl}/systemd"
  [[ -d "${example_dir}" ]] || fail "missing example systemd/ for ${wl}"
  if grep -Eq '^Volume=.+:/var/lib/workload' "${example_dir}/"*.container 2>/dev/null; then
    grep -Eq '^Volume=\.\./persist' "${example_dir}/"*.container \
      || fail "example ${wl}: /var/lib/workload mounts must use Volume=../persist…"
  fi
done
pass "example soft Persist scaffolds use Volume=../persist"

# EnvironmentFile= stays absolute on both Quadlet containers and native units.
grep -Eq '^EnvironmentFile=/host-volume/components/database/persist/admin/environment$' \
  "${REPO_ROOT}/internals/components/database/systemd/database-postgres.container" \
  || fail "database-postgres EnvironmentFile must stay absolute on Host Volume"
grep -Eq '^EnvironmentFile=/host-volume/components/edge/persist/acme/environment$' \
  "${REPO_ROOT}/internals/components/edge/systemd/edge-acme.service" \
  || fail "native edge-acme.service EnvironmentFile must stay absolute on Host Volume"
# Cache admin EnvironmentFile lives on Persist for Setup/operator use; Valkey unit
# does not mount it (ACL file is the engine contract).
if grep -Eq '^EnvironmentFile=' \
  "${REPO_ROOT}/internals/components/cache/systemd/cache-valkey.container"; then
  fail "cache-valkey must not EnvironmentFile= admin credentials into the engine"
fi
pass "EnvironmentFile= stays absolute on Host Volume"
