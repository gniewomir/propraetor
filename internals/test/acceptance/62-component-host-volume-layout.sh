#!/usr/bin/env bash
# Acceptance Test: Host Volume internals/ + data/ layout and ownership (ADR-0010 / ADR-0041 / #154)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

USER_NAME="${PLATFORM_USER:-platform}"
INTERNALS_ROOT=/var/lib/host-volume/internals
FABRIC_ROOT="${INTERNALS_ROOT}/fabric"
COMPONENTS_ROOT="${INTERNALS_ROOT}/components"
WORKLOADS_SOT_ROOT="${INTERNALS_ROOT}/workloads"
HOST_SCRIPTS_ROOT="${INTERNALS_ROOT}/host-scripts"
DATA_ROOT=/var/lib/host-volume/data
EDGE_DATA="${DATA_ROOT}/components/edge"
DB_DATA="${DATA_ROOT}/components/database"

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

mount_owner="$(owner_of /var/lib/host-volume)"
if [[ "${mount_owner}" != "root:root" ]]; then
  fail "/var/lib/host-volume owner expected root:root, got '${mount_owner}'"
fi

must_be_dir "${FABRIC_ROOT}"
must_be_dir "${COMPONENTS_ROOT}/edge"
must_be_dir "${COMPONENTS_ROOT}/database"
must_be_dir "${WORKLOADS_SOT_ROOT}"
must_be_dir "${HOST_SCRIPTS_ROOT}/lib"
must_be_dir "${FABRIC_ROOT}/quadlets"
must_be_dir "${COMPONENTS_ROOT}/edge/quadlets"
must_be_dir "${COMPONENTS_ROOT}/edge/systemd"
must_be_dir "${COMPONENTS_ROOT}/database/quadlets"
must_be_file "${COMPONENTS_ROOT}/edge/nginx.conf"
must_be_file "${COMPONENTS_ROOT}/edge/domain-template.conf"
must_be_file "${FABRIC_ROOT}/setup.sh"
must_be_file "${COMPONENTS_ROOT}/edge/pre-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/edge/post-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/database/pre-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/database/post-workloads.sh"
must_be_file "${COMPONENTS_ROOT}/database/entrypoint.sh"
must_not_exist "${COMPONENTS_ROOT}/edge/setup.sh"
must_not_exist "${COMPONENTS_ROOT}/database/setup.sh"
must_be_file "${FABRIC_ROOT}/quadlets/service-network.network"
must_be_file "${COMPONENTS_ROOT}/edge/quadlets/edge.pod"
must_be_file "${COMPONENTS_ROOT}/edge/quadlets/edge-nginx.container"
must_be_file "${COMPONENTS_ROOT}/edge/systemd/edge-acme.service"
must_be_file "${COMPONENTS_ROOT}/edge/systemd/edge-acme.timer"
must_be_file "${COMPONENTS_ROOT}/database/quadlets/database.pod"
must_be_file "${COMPONENTS_ROOT}/database/quadlets/database-postgres.container"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/quadlet-user-session.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/edge-routes-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/edge-want-list-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/edge-domain-fronts-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/edge-front-door-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/database-setup-host.sh"
must_be_file "${HOST_SCRIPTS_ROOT}/lib/database-tls-host.sh"
must_not_exist "${COMPONENTS_ROOT}/lib"
must_not_exist "${COMPONENTS_ROOT}/edge/certs"
must_not_exist /var/lib/host-volume/components
must_not_exist /var/lib/host-volume/components_data

must_be_dir "${DATA_ROOT}/fabric"
must_be_dir "${DATA_ROOT}/components"
must_be_dir "${DATA_ROOT}/workloads"
must_be_dir "${EDGE_DATA}/routes"
must_be_dir "${EDGE_DATA}/domains"
must_be_dir "${EDGE_DATA}/certs"
must_be_dir "${EDGE_DATA}/acme-www"
must_be_dir "${EDGE_DATA}/acme"
must_be_dir "${DB_DATA}/ca"
must_be_dir "${DB_DATA}/server"
must_be_dir "${DB_DATA}/pgdata"
must_be_dir "${DB_DATA}/clients"
must_be_dir "${DB_DATA}/conf"
must_be_file "${DB_DATA}/ca/ca.crt"
must_be_file "${DB_DATA}/server/server.crt"
must_be_file "${DB_DATA}/admin/environment"
must_not_exist "${EDGE_DATA}/routes/00-empty.conf"
must_not_exist "${EDGE_DATA}/domains/00-empty.conf"
must_be_file "${EDGE_DATA}/acme/want-list"
must_not_exist "${COMPONENTS_ROOT}/edge/acme-www"
must_not_exist "${COMPONENTS_ROOT}/edge/acme"

for path in \
  "${INTERNALS_ROOT}" \
  "${FABRIC_ROOT}" \
  "${FABRIC_ROOT}/quadlets" \
  "${COMPONENTS_ROOT}" \
  "${COMPONENTS_ROOT}/edge" \
  "${COMPONENTS_ROOT}/edge/quadlets" \
  "${COMPONENTS_ROOT}/edge/systemd" \
  "${COMPONENTS_ROOT}/database" \
  "${COMPONENTS_ROOT}/database/quadlets" \
  "${WORKLOADS_SOT_ROOT}" \
  "${HOST_SCRIPTS_ROOT}" \
  "${HOST_SCRIPTS_ROOT}/lib" \
  "${DATA_ROOT}" \
  "${DATA_ROOT}/fabric" \
  "${DATA_ROOT}/components" \
  "${DATA_ROOT}/workloads" \
  "${EDGE_DATA}" \
  "${EDGE_DATA}/routes" \
  "${EDGE_DATA}/domains" \
  "${EDGE_DATA}/certs" \
  "${EDGE_DATA}/acme-www" \
  "${EDGE_DATA}/acme" \
  "${DB_DATA}" \
  "${DB_DATA}/ca" \
  "${DB_DATA}/server" \
  "${DB_DATA}/pgdata" \
  "${DB_DATA}/clients" \
  "${DB_DATA}/conf"
do
  o="$(owner_of "${path}")"
  if [[ "${o}" != "${USER_NAME}:${USER_NAME}" ]]; then
    fail "${path} owner expected ${USER_NAME}:${USER_NAME}, got '${o}'"
  fi
done

pass "Host Volume internals/ + data/ layout and ownership"
