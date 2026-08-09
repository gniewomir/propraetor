#!/usr/bin/env bash
# Component Setup pre-workloads for the Database (ADR-0049 / #188).
# Standing Component: TLS + admin credentials + idle Postgres on dial name database.
# Runs on the Host only. Invoked by ensure-components with slot pre-workloads.
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
SRC="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../host-scripts/lib/database-setup-host.sh
source /var/lib/host-volume/internals/host-scripts/lib/database-setup-host.sh

database_setup_pre_workloads "${SRC}" /tmp/platform-database-admin.env
