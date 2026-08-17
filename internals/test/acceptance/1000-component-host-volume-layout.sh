#!/usr/bin/env bash
# Acceptance Test: Host Volume owner-tree layout + nested Persist (ADR-0054 / #215)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

USER_NAME="${PLATFORM_USER:-platform}"
HV_ROOT=/host-volume
FABRIC_ROOT="${HV_ROOT}/fabric"
COMPONENTS_ROOT="${HV_ROOT}/components"
WORKLOADS_SOT_ROOT="${HV_ROOT}/workloads"
HOST_SCRIPTS_ROOT="${HV_ROOT}/host-scripts"
EDGE_PERSIST="${COMPONENTS_ROOT}/edge/persist"
DB_PERSIST="${COMPONENTS_ROOT}/database/persist"
CACHE_PERSIST="${COMPONENTS_ROOT}/cache/persist"

owner_of() {
  host_ssh "stat -c '%U:%G' '$1'" 2>/dev/null || true
}

must_be_dir() {
  local path="$1"
  if ! host_ssh "test -d '${path}'"; then
    fail "expected directory missing: ${path}"
  fi
}

must_be_file() {
  local path="$1"
  if ! host_ssh "test -f '${path}'"; then
    fail "expected file missing: ${path}"
  fi
}

must_not_exist() {
  local path="$1"
  if host_ssh "test -e '${path}'"; then
    fail "path must not exist: ${path}"
  fi
}

mount_owner="$(owner_of "${HV_ROOT}")"
if [[ "${mount_owner}" != "root:root" ]]; then
  fail "/host-volume owner expected root:root, got '${mount_owner}'"
fi

must_be_dir "${FABRIC_ROOT}"
must_be_dir "${COMPONENTS_ROOT}/edge"
must_be_dir "${COMPONENTS_ROOT}/database"
must_be_dir "${COMPONENTS_ROOT}/cache"
must_be_dir "${WORKLOADS_SOT_ROOT}"
must_be_dir "${HOST_SCRIPTS_ROOT}/lib"
must_be_dir "${FABRIC_ROOT}/systemd"
must_be_dir "${COMPONENTS_ROOT}/edge/systemd"
must_be_dir "${COMPONENTS_ROOT}/database/systemd"
must_be_dir "${COMPONENTS_ROOT}/cache/systemd"
must_be_file "${COMPONENTS_ROOT}/edge/nginx.conf"
must_be_file "${COMPONENTS_ROOT}/edge/domain-template.conf"
must_be_file "${FABRIC_ROOT}/setup.sh"
must_be_file "${COMPONENTS_ROOT}/edge/pre-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/edge/post-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/database/pre-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/database/post-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/database/entrypoint.sh"
must_be_file "${COMPONENTS_ROOT}/cache/pre-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/cache/post-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/cache/entrypoint.sh"
must_not_exist "${COMPONENTS_ROOT}/edge/setup.sh"
must_not_exist "${COMPONENTS_ROOT}/database/setup.sh"
must_not_exist "${COMPONENTS_ROOT}/cache/setup.sh"
must_be_file "${FABRIC_ROOT}/systemd/service-network.network"
must_be_file "${COMPONENTS_ROOT}/edge/systemd/edge.pod"
must_be_file "${COMPONENTS_ROOT}/edge/systemd/edge-nginx.container"
must_be_file "${COMPONENTS_ROOT}/edge/systemd/edge-acme.service"
must_be_file "${COMPONENTS_ROOT}/edge/systemd/edge-acme.timer"
must_be_file "${COMPONENTS_ROOT}/database/systemd/database.pod"
must_be_file "${COMPONENTS_ROOT}/database/systemd/database-postgres.container"
must_be_file "${COMPONENTS_ROOT}/cache/systemd/cache.pod"
must_be_file "${COMPONENTS_ROOT}/cache/systemd/cache-valkey.container"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/quadlet-user-session.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/edge-routes-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/edge-want-list-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/edge-domain-fronts-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/edge-front-door-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/database-setup-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/cache-setup-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/component-tls-host.sh"
must_not_exist "${COMPONENTS_ROOT}/lib"
must_not_exist "${COMPONENTS_ROOT}/edge/certs"
# Retired ADR-0041 parents / mount contract
must_not_exist "${HV_ROOT}/internals"
must_not_exist "${HV_ROOT}/data"
must_not_exist "${HV_ROOT}/components_data"
# Fabric has no Persist contract
must_not_exist "${FABRIC_ROOT}/persist"

# Nested Persist interiors (auto-created + Component Setup)
must_be_dir "${EDGE_PERSIST}"
must_be_dir "${DB_PERSIST}"
must_be_dir "${EDGE_PERSIST}/routes"
must_be_dir "${EDGE_PERSIST}/domains"
must_be_dir "${EDGE_PERSIST}/certs"
must_be_dir "${EDGE_PERSIST}/acme-www"
must_be_dir "${EDGE_PERSIST}/acme"
must_be_dir "${DB_PERSIST}/ca"
must_be_dir "${DB_PERSIST}/server"
must_be_dir "${DB_PERSIST}/pgdata"
must_be_dir "${DB_PERSIST}/clients"
must_be_dir "${DB_PERSIST}/conf"
must_be_file "${DB_PERSIST}/ca/ca.crt"
must_be_file "${DB_PERSIST}/server/server.crt"
must_be_file "${DB_PERSIST}/admin/environment"
must_be_dir "${CACHE_PERSIST}"
must_be_dir "${CACHE_PERSIST}/ca"
must_be_dir "${CACHE_PERSIST}/server"
must_be_dir "${CACHE_PERSIST}/admin"
must_be_dir "${CACHE_PERSIST}/conf"
must_be_dir "${CACHE_PERSIST}/clients"
must_be_file "${CACHE_PERSIST}/ca/ca.crt"
must_be_file "${CACHE_PERSIST}/server/server.crt"
must_be_file "${CACHE_PERSIST}/admin/environment"
must_be_file "${CACHE_PERSIST}/admin/client.crt"
must_be_file "${CACHE_PERSIST}/conf/valkey.conf"
must_be_file "${CACHE_PERSIST}/conf/users.acl"
must_not_exist "${EDGE_PERSIST}/routes/00-empty.conf"
must_not_exist "${EDGE_PERSIST}/domains/00-empty.conf"
must_be_file "${EDGE_PERSIST}/acme/want-list"
must_not_exist "${COMPONENTS_ROOT}/edge/acme-www"
must_not_exist "${COMPONENTS_ROOT}/edge/acme"

for path in \
  "${FABRIC_ROOT}" \
  "${FABRIC_ROOT}/systemd" \
  "${COMPONENTS_ROOT}" \
  "${COMPONENTS_ROOT}/edge" \
  "${COMPONENTS_ROOT}/edge/systemd" \
  "${COMPONENTS_ROOT}/database" \
  "${COMPONENTS_ROOT}/database/systemd" \
  "${COMPONENTS_ROOT}/cache" \
  "${COMPONENTS_ROOT}/cache/systemd" \
  "${WORKLOADS_SOT_ROOT}" \
  "${HOST_SCRIPTS_ROOT}" \
  "${HOST_SCRIPTS_ROOT}/lib" \
  "${EDGE_PERSIST}" \
  "${EDGE_PERSIST}/routes" \
  "${EDGE_PERSIST}/domains" \
  "${EDGE_PERSIST}/certs" \
  "${EDGE_PERSIST}/acme-www" \
  "${EDGE_PERSIST}/acme" \
  "${DB_PERSIST}" \
  "${DB_PERSIST}/ca" \
  "${DB_PERSIST}/server" \
  "${DB_PERSIST}/pgdata" \
  "${DB_PERSIST}/clients" \
  "${DB_PERSIST}/conf" \
  "${CACHE_PERSIST}" \
  "${CACHE_PERSIST}/ca" \
  "${CACHE_PERSIST}/server" \
  "${CACHE_PERSIST}/admin" \
  "${CACHE_PERSIST}/conf" \
  "${CACHE_PERSIST}/clients"
do
  o="$(owner_of "${path}")"
  if [[ "${o}" != "${USER_NAME}:${USER_NAME}" ]]; then
    fail "${path} owner expected ${USER_NAME}:${USER_NAME}, got '${o}'"
  fi
done

pass "Host Volume owner-tree layout and nested Persist ownership"
