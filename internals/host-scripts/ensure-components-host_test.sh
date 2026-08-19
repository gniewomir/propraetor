#!/usr/bin/env bash
# Unit tests: ensure-components Host half — slotted Component Setup (ADR-0043 / #181).
# Offline: temp Host Volume roots + stub pre/post scripts. No SSH / live Host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-components-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

inode_of() {
  local path="$1"
  if stat -f %i "${path}" >/dev/null 2>&1; then
    stat -f %i "${path}"
  else
    stat -c %i "${path}"
  fi
}

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ensure-components.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
HV="${TMP}/host-volume"
mkdir -p "${HV}" "${TMP}/lib"
cp "${REPO_ROOT}/internals/host-scripts/lib/sync-tree-host.sh" "${TMP}/lib/sync-tree-host.sh"
cp "${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh" \
  "${TMP}/lib/host-volume-paths-host.sh"
cp "${REPO_ROOT}/internals/host-scripts/lib/component-handoff-host.sh" \
  "${TMP}/lib/component-handoff-host.sh"
printf '# ensure unit stub lib\n' >"${TMP}/lib/stub.sh"
printf '%s\n' 'alpha.example.test' >"${TMP}/platform-acme-want-list"
printf '%s\n' 'EDGE_ACME_DIRECTORY=staging' >"${TMP}/platform-acme.env"
printf '%s\n' '{"fqdn":"auth.alpha.example.test"}' >"${TMP}/platform-identity.json"
printf '%s\n' 'test' >"${TMP}/platform-environment-slug"
printf '%s\n' \
  'STATIC_API_KEY=0123456789abcdef' \
  'ENCRYPTION_KEY=enckey' \
  'IDENTITY_ADMIN_EMAIL=ops@example.com' \
  'APP_URL=https://auth.alpha.example.test' \
  >"${TMP}/platform-identity-admin.env"

# Runnable copy; Host Volume via ambient HV_ROOT (#214 path vocabulary).
cp "${HOST_SCRIPT}" "${TMP}/ensure-run.sh"
chmod +x "${TMP}/ensure-run.sh"
export HV_ROOT="${HV}"

mkdir -p "${TMP}/edge" "${TMP}/fabric"
cat >"${TMP}/edge/pre-workloads.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "edge-pre" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/edge/pre-workloads.sh"
cat >"${TMP}/edge/post-workloads.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "edge-post" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/edge/post-workloads.sh"
printf 'edge-nginx\n' >"${TMP}/edge/nginx.conf"
printf '# Domain front for __FQDN__\n' >"${TMP}/edge/domain-template.conf"
printf '# Identity issuer Domain front for __FQDN__\nlocation / { proxy_pass http://identity:1411; }\n' \
  >"${TMP}/edge/identity-domain-template.conf"
# Staged Fabric must be ignored by ensure-components.
cat >"${TMP}/fabric/setup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "fabric" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/fabric/setup.sh"

USER_NAME="$(id -un)"

# Offline macOS: Platform User group may not equal login name; Host uses user:user.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP}/bin/chown"
export PATH="${TMP}/bin:${PATH}"

# --- missing slot fails closed ---
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" --component edge 2>"${TMP}/stderr-slot"; then
  fail "ensure-components-host must require a Setup slot"
fi
grep -Eqi 'pre-workloads|post-workloads|slot' "${TMP}/stderr-slot" \
  || fail "missing-slot rejection unclear: $(cat "${TMP}/stderr-slot")"
pass "missing Setup slot fails closed"

# --- unknown slot fails closed ---
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" full --component edge 2>"${TMP}/stderr-full"; then
  fail "ensure-components-host must reject unknown slot 'full'"
fi
grep -Eqi 'unknown|pre-workloads|post-workloads|slot' "${TMP}/stderr-full" \
  || fail "unknown-slot rejection unclear: $(cat "${TMP}/stderr-full")"
pass "unknown Setup slot fails closed"

# --- pre-workloads: installs Edge, runs only that slot, ignores staged Fabric ---
: >"${TMP}/setup.order"
mkdir -p "${HV}/internals/legacy" "${HV}/data/legacy" "${HV}/components_data/legacy"
bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component edge 2>"${TMP}/stderr" \
  || fail "ensure-run pre-workloads failed: $(cat "${TMP}/stderr")"

grep -Fq 'Running Component Setup: edge (pre-workloads)' "${TMP}/stderr" \
  || fail "expected pre-workloads Component Setup log, got: $(cat "${TMP}/stderr")"
if grep -Fq 'Running Fabric Setup' "${TMP}/stderr"; then
  fail "ensure-components must not run Fabric Setup"
fi
order="$(cat "${TMP}/setup.order")"
printf '%s\n' "${order}" | grep -Fxq 'edge-pre' || fail "pre-workloads script did not run, got: ${order}"
if printf '%s\n' "${order}" | grep -Fxq 'edge-post'; then
  fail "pre-workloads must not run post-workloads script"
fi
if printf '%s\n' "${order}" | grep -Fxq 'fabric'; then
  fail "ensure-components must not run staged Fabric Setup"
fi
[[ -f "${HV}/components/edge/pre-workloads.sh" ]] \
  || fail "edge pre-workloads.sh not installed on Host Volume"
[[ -f "${HV}/components/edge/post-workloads.sh" ]] \
  || fail "edge post-workloads.sh not installed on Host Volume"
[[ ! -e "${HV}/components/edge/setup.sh" ]] \
  || fail "monolithic setup.sh must not be shipped"
[[ -f "${HV}/components/edge/nginx.conf" ]] || fail "edge nginx.conf not installed"
[[ -f "${HV}/components/edge/domain-template.conf" ]] \
  || fail "edge domain-template.conf not installed"
[[ -f "${HV}/components/edge/identity-domain-template.conf" ]] \
  || fail "edge identity-domain-template.conf not installed"
[[ ! -e "${HV}/fabric/setup.sh" ]] || fail "ensure-components must not install Fabric"
[[ -d "${HV}/host-scripts/lib" ]] || fail "host-scripts lib not installed on Host Volume"
[[ -d "${HV}/workloads" ]] || fail "workloads SoT root missing on Host Volume"
[[ -d "${HV}/components" ]] || fail "components SoT root missing on Host Volume"
[[ -d "${HV}/components/edge/persist" ]] || fail "Edge Persist not auto-created"
[[ -f "${HV}/components/handoff/acme-want-list" ]] \
  || fail "ACME want-list handoff missing under Host Volume"
[[ -f "${HV}/components/handoff/acme.env" ]] \
  || fail "ACME env handoff missing under Host Volume"
[[ -f "${HV}/components/handoff/identity.json" ]] \
  || fail "Identity config handoff missing under Host Volume"
[[ -f "${HV}/components/handoff/identity-admin.env" ]] \
  || fail "Identity admin handoff missing under Host Volume"
grep -Fxq 'alpha.example.test' "${HV}/components/handoff/acme-want-list" \
  || fail "ACME want-list handoff content wrong"
[[ ! -e "${HV}/internals" ]] || fail "retired internals/ must not exist after ensure"
[[ ! -e "${HV}/data" ]] || fail "retired data/ must not exist after ensure"
[[ ! -e "${HV}/components_data" ]] || fail "retired components_data/ must not exist after ensure"
pass "ensure-components pre-workloads installs Components and runs only that slot"

# --- missing staged ACME EnvironmentFile fails closed ---
mv "${TMP}/platform-acme.env" "${TMP}/platform-acme.env.bak"
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component edge 2>"${TMP}/stderr-acme-env"; then
  fail "missing platform-acme.env must fail closed"
fi
grep -Eqi 'ACME EnvironmentFile|platform-acme\.env' "${TMP}/stderr-acme-env" \
  || fail "missing ACME env rejection unclear: $(cat "${TMP}/stderr-acme-env")"
mv "${TMP}/platform-acme.env.bak" "${TMP}/platform-acme.env"
pass "missing staged ACME EnvironmentFile fails closed"

# --- missing staged Identity config fails closed ---
mv "${TMP}/platform-identity.json" "${TMP}/platform-identity.json.bak"
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component edge 2>"${TMP}/stderr-id-config"; then
  fail "missing platform-identity.json must fail closed"
fi
grep -Eqi 'identity\.json|Identity config|platform-identity' "${TMP}/stderr-id-config" \
  || fail "missing Identity config rejection unclear: $(cat "${TMP}/stderr-id-config")"
mv "${TMP}/platform-identity.json.bak" "${TMP}/platform-identity.json"
pass "missing staged identity.json fails closed"

# --- missing staged Identity admin EnvironmentFile fails closed ---
mv "${TMP}/platform-identity-admin.env" "${TMP}/platform-identity-admin.env.bak"
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component edge 2>"${TMP}/stderr-id-admin"; then
  fail "missing platform-identity-admin.env must fail closed"
fi
grep -Eqi 'Identity admin|platform-identity-admin' "${TMP}/stderr-id-admin" \
  || fail "missing Identity admin rejection unclear: $(cat "${TMP}/stderr-id-admin")"
mv "${TMP}/platform-identity-admin.env.bak" "${TMP}/platform-identity-admin.env"
pass "missing staged Identity admin EnvironmentFile fails closed"

# --- missing staged Database admin EnvironmentFile fails closed when Database selected ---
printf '%s\n' 'POSTGRES_USER=dbadmin' 'POSTGRES_PASSWORD=secret' >"${TMP}/platform-database-admin.env"
mkdir -p "${TMP}/database"
cat >"${TMP}/database/pre-workloads.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "database-pre" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/database/pre-workloads.sh"
cat >"${TMP}/database/post-workloads.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "database-post" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/database/post-workloads.sh"
mv "${TMP}/platform-database-admin.env" "${TMP}/platform-database-admin.env.bak"
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component database 2>"${TMP}/stderr-db-admin"; then
  fail "missing platform-database-admin.env must fail closed when Database is selected"
fi
grep -Eqi 'Database admin|platform-database-admin' "${TMP}/stderr-db-admin" \
  || fail "missing Database admin rejection unclear: $(cat "${TMP}/stderr-db-admin")"
mv "${TMP}/platform-database-admin.env.bak" "${TMP}/platform-database-admin.env"
pass "missing staged Database admin EnvironmentFile fails closed"

# --- Database Component runs beside Edge when both selected ---
: >"${TMP}/setup.order"
bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component edge --component database \
  2>"${TMP}/stderr-both" \
  || fail "ensure-run with edge+database failed: $(cat "${TMP}/stderr-both")"
order="$(cat "${TMP}/setup.order")"
printf '%s\n' "${order}" | grep -Fxq 'edge-pre' || fail "edge-pre missing in dual run: ${order}"
printf '%s\n' "${order}" | grep -Fxq 'database-pre' || fail "database-pre missing in dual run: ${order}"
[[ -f "${HV}/components/database/pre-workloads.sh" ]] \
  || fail "database pre-workloads.sh not installed"
[[ -f "${HV}/components/handoff/database-admin.env" ]] \
  || fail "Database admin handoff missing when Database selected"
pass "ensure-components runs Edge and Database Setup in one slot"

# --- missing staged Cache admin EnvironmentFile fails closed when Cache selected ---
printf '%s\n' 'CACHE_ADMIN_USER=cacheadmin' 'CACHE_ADMIN_PASSWORD=secret' >"${TMP}/platform-cache-admin.env"
mkdir -p "${TMP}/cache"
cat >"${TMP}/cache/pre-workloads.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "cache-pre" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/cache/pre-workloads.sh"
cat >"${TMP}/cache/post-workloads.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "cache-post" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/cache/post-workloads.sh"
mv "${TMP}/platform-cache-admin.env" "${TMP}/platform-cache-admin.env.bak"
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component cache 2>"${TMP}/stderr-cache-admin"; then
  fail "missing platform-cache-admin.env must fail closed when Cache is selected"
fi
grep -Eqi 'Cache admin|platform-cache-admin' "${TMP}/stderr-cache-admin" \
  || fail "missing Cache admin rejection unclear: $(cat "${TMP}/stderr-cache-admin")"
mv "${TMP}/platform-cache-admin.env.bak" "${TMP}/platform-cache-admin.env"
pass "missing staged Cache admin EnvironmentFile fails closed"

# --- Cache Component runs beside Edge when both selected ---
: >"${TMP}/setup.order"
bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component edge --component cache \
  2>"${TMP}/stderr-edge-cache" \
  || fail "ensure-run with edge+cache failed: $(cat "${TMP}/stderr-edge-cache")"
order="$(cat "${TMP}/setup.order")"
printf '%s\n' "${order}" | grep -Fxq 'edge-pre' || fail "edge-pre missing in edge+cache run: ${order}"
printf '%s\n' "${order}" | grep -Fxq 'cache-pre' || fail "cache-pre missing in edge+cache run: ${order}"
[[ -f "${HV}/components/cache/pre-workloads.sh" ]] \
  || fail "cache pre-workloads.sh not installed"
[[ -f "${HV}/components/handoff/cache-admin.env" ]] \
  || fail "Cache admin handoff missing when Cache selected"
pass "ensure-components runs Edge and Cache Setup in one slot"

# --- post-workloads runs the post script only ---
: >"${TMP}/setup.order"
bash "${TMP}/ensure-run.sh" "${USER_NAME}" post-workloads --component edge 2>"${TMP}/stderr-post" \
  || fail "ensure-run post-workloads failed: $(cat "${TMP}/stderr-post")"
grep -Fq 'Running Component Setup: edge (post-workloads)' "${TMP}/stderr-post" \
  || fail "expected post-workloads log, got: $(cat "${TMP}/stderr-post")"
order="$(cat "${TMP}/setup.order")"
printf '%s\n' "${order}" | grep -Fxq 'edge-post' || fail "post-workloads script did not run, got: ${order}"
if printf '%s\n' "${order}" | grep -Fxq 'edge-pre'; then
  fail "post-workloads must not run pre-workloads script"
fi
pass "ensure-components post-workloads runs only that slot"

# --- missing slot script fails closed ---
rm -f "${TMP}/edge/post-workloads.sh"
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" post-workloads --component edge 2>"${TMP}/stderr-miss"; then
  fail "missing post-workloads.sh must fail closed"
fi
grep -Eqi 'post-workloads|missing|Setup' "${TMP}/stderr-miss" \
  || fail "missing-script rejection unclear: $(cat "${TMP}/stderr-miss")"
# Restore for later cases.
cat >"${TMP}/edge/post-workloads.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "edge-post" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/edge/post-workloads.sh"
pass "missing Component Setup slot script fails closed"

# --- rejects --fabric (Fabric is a different cog; no combined ship) ---
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --fabric fabric 2>"${TMP}/stderr2"; then
  fail "expected failure for --fabric on ensure-components"
fi
grep -Eqi 'unknown argument|--component' "${TMP}/stderr2" \
  || fail "ensure-components --fabric rejection unclear: $(cat "${TMP}/stderr2")"
pass "ensure-components rejects --fabric (combined ship gone)"

# --- rejects bare Component name as slot ---
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" edge --component edge 2>"${TMP}/stderr3"; then
  fail "expected failure for Component name used as slot"
fi
grep -Eqi 'unknown|pre-workloads|post-workloads|slot' "${TMP}/stderr3" \
  || fail "bad-slot rejection unclear: $(cat "${TMP}/stderr3")"
pass "Component name is not a valid Setup slot"

# --- non-breaking ship: update Edge tree without replacing directory/file inodes ---
mkdir -p "${HV}/components/edge"
printf 'old-nginx\n' >"${HV}/components/edge/nginx.conf"
dir_ino="$(inode_of "${HV}/components/edge")"
file_ino="$(inode_of "${HV}/components/edge/nginx.conf")"
: >"${TMP}/setup.order"
bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component edge 2>"${TMP}/stderr4" \
  || fail "re-ensure-components failed: $(cat "${TMP}/stderr4")"
[[ "$(inode_of "${HV}/components/edge")" == "${dir_ino}" ]] \
  || fail "edge directory inode changed (breaking ship for bind mounts)"
[[ "$(inode_of "${HV}/components/edge/nginx.conf")" == "${file_ino}" ]] \
  || fail "nginx.conf inode changed (file was unlinked instead of overwritten)"
grep -Fxq 'edge-nginx' "${HV}/components/edge/nginx.conf" \
  || fail "nginx.conf content not updated in place"
pass "ensure-components updates Edge tree without replacing directory/file inodes"

# --- both cogs in order: Fabric then Components leave both installed ---
FABRIC_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-fabric-host.sh"
cp "${FABRIC_SCRIPT}" "${TMP}/ensure-fabric-run.sh"
chmod +x "${TMP}/ensure-fabric-run.sh"
rm -rf "${HV}"
mkdir -p "${HV}"
export HV_ROOT="${HV}"
: >"${TMP}/setup.order"
bash "${TMP}/ensure-fabric-run.sh" "${USER_NAME}" --fabric fabric 2>"${TMP}/stderr5" \
  || fail "ordered ensure-fabric failed: $(cat "${TMP}/stderr5")"
bash "${TMP}/ensure-run.sh" "${USER_NAME}" pre-workloads --component edge 2>"${TMP}/stderr6" \
  || fail "ordered ensure-components failed: $(cat "${TMP}/stderr6")"
order="$(cat "${TMP}/setup.order")"
printf '%s\n' "${order}" | head -1 | grep -Fxq 'fabric' \
  || fail "Fabric Setup must run first when both cogs run in order, got: ${order}"
printf '%s\n' "${order}" | tail -1 | grep -Fxq 'edge-pre' \
  || fail "Component Setup must run after Fabric when both cogs run in order, got: ${order}"
[[ -f "${HV}/fabric/setup.sh" ]] || fail "fabric missing after ordered ensure"
[[ -f "${HV}/components/edge/pre-workloads.sh" ]] \
  || fail "edge pre-workloads missing after ordered ensure"
pass "ensure-fabric then ensure-components leaves Fabric and Edge installed in order"

echo "All ensure-components-host offline tests passed."
