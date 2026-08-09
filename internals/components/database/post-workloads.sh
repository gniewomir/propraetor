#!/usr/bin/env bash
# Component Setup post-workloads for the Database (ADR-0049 / #188 / #191).
# Standing ensure + drop role/db/client material for Purge/Orphan-absent basenames.
# Runs on the Host only. Invoked by ensure-components with slot post-workloads.
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
SRC="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../host-scripts/lib/database-setup-host.sh
source /var/lib/host-volume/internals/host-scripts/lib/database-setup-host.sh

database_setup_post_workloads "${SRC}" /tmp/platform-database-admin.env
