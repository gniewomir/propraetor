#!/usr/bin/env bash
# Unit tests: Mirror Host half — materialize regardless of Source (#204 / ADR-0053).
# Seam: ensure-mirror-host.sh (Environment upsert + Source resolve + Provides directories).
# Offline: temp Host Volume + staged Workload trees. No SSH / live Host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-mirror-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ensure-mirror.XXXXXX")"
HTTP_PID=""
cleanup() {
  if [[ -n "${HTTP_PID}" ]]; then
    kill "${HTTP_PID}" 2>/dev/null || true
    wait "${HTTP_PID}" 2>/dev/null || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

HV="${TMP}/host-volume"
STAGE="${TMP}/stage"
mkdir -p "${HV}" "${STAGE}/lib"
cp "${REPO_ROOT}/internals/host-scripts/lib/sync-tree-host.sh" "${STAGE}/lib/sync-tree-host.sh"
cp "${REPO_ROOT}/internals/host-scripts/lib/workload-materialize-host.sh" \
  "${STAGE}/lib/workload-materialize-host.sh"
cp "${REPO_ROOT}/internals/host-scripts/lib/unit-consumers-host.sh" \
  "${STAGE}/lib/unit-consumers-host.sh"
cp "${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh" \
  "${STAGE}/lib/host-volume-paths-host.sh"
cp "${REPO_ROOT}/internals/lib/artifact/source.sh" "${STAGE}/lib/source.sh"
cp "${REPO_ROOT}/internals/lib/artifact/provides.sh" "${STAGE}/lib/provides.sh"

cp "${HOST_SCRIPT}" "${TMP}/mirror-run.sh"
chmod +x "${TMP}/mirror-run.sh"
export HV_ROOT="${HV}"

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP}/bin/chown"
export PATH="${TMP}/bin:${PATH}"

USER_NAME="$(id -un)"

write_internal_stubs() {
  local tree="$1"
  mkdir -p "${tree}/systemd"
  printf '{}\n' >"${tree}/provides.json"
  printf '{ "database": false, "cache": false }\n' >"${tree}/requires.json"
  printf '{}\n' >"${tree}/binding.json"
  printf '[Container]\nImage=localhost/stub\n' >"${tree}/systemd/stub.container"
}

# Seed an orphan on the Host that must survive Mirror
mkdir -p "${HV}/workloads/orphan-left/routes" "${HV}/workloads/orphan-left/persist"
printf '{"intent":"run","source":"internal"}\n' >"${HV}/workloads/orphan-left/manifest.json"
printf 'keep-orphan\n' >"${HV}/workloads/orphan-left/routes/orphan.conf"
printf 'durable\n' >"${HV}/workloads/orphan-left/persist/state.bin"

# --- internal Source: Environment bag + Provides directories ---
mkdir -p "${STAGE}/workloads/alpha/routes" \
  "${STAGE}/workloads/alpha/www/usage" \
  "${STAGE}/workloads/alpha/scripts"
write_internal_stubs "${STAGE}/workloads/alpha"
cat >"${STAGE}/workloads/alpha/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal"
}
EOF
cat >"${STAGE}/workloads/alpha/provides.json" <<'EOF'
{
  "directories": {
    "www": "static site",
    "scripts": "job scripts",
    "routes": "edge fragments"
  }
}
EOF
printf 'route-a\n' >"${STAGE}/workloads/alpha/routes/a.conf"
printf 'home\n' >"${STAGE}/workloads/alpha/www/index.html"
printf 'nested\n' >"${STAGE}/workloads/alpha/www/usage/index.html"
printf '#!/bin/bash\necho ok\n' >"${STAGE}/workloads/alpha/scripts/alpha-job.sh"

# Manifest-less staged Workload must still be upserted (ADR-0047)
mkdir -p "${STAGE}/workloads/gamma/notes"
printf 'draft\n' >"${STAGE}/workloads/gamma/notes/idea.md"
printf 'secret-link-target\n' >"${STAGE}/workloads/gamma/target.txt"
ln -s target.txt "${STAGE}/workloads/gamma/link-to-target"
mkdir -p "${STAGE}/workloads/gamma/www/.well-known"
printf 'acme\n' >"${STAGE}/workloads/gamma/www/.well-known/probe"

# Pre-existing Host tree for alpha that Mirror must update (upsert)
mkdir -p "${HV}/workloads/alpha/routes"
printf '{"intent":"stop","source":"internal"}\n' >"${HV}/workloads/alpha/manifest.json"
printf 'stale\n' >"${HV}/workloads/alpha/routes/stale.conf"
printf 'old-a\n' >"${HV}/workloads/alpha/routes/a.conf"

cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" \
  || fail "ensure-mirror-host failed for internal Workloads"

python3 - "${HV}/workloads/alpha/manifest.json" <<'PY' || fail "alpha Manifest not upserted"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m.get("intent") == "run" and m.get("source") == "internal", m
PY
grep -Fxq 'route-a' "${HV}/workloads/alpha/routes/a.conf" \
  || fail "alpha route not materialized"
grep -Fxq 'home' "${HV}/workloads/alpha/www/index.html" \
  || fail "alpha www root not materialized"
grep -Fxq 'nested' "${HV}/workloads/alpha/www/usage/index.html" \
  || fail "alpha nested www not materialized"
grep -Fq 'echo ok' "${HV}/workloads/alpha/scripts/alpha-job.sh" \
  || fail "alpha scripts not materialized"
[[ ! -e "${HV}/workloads/alpha/routes/stale.conf" ]] \
  || fail "stale authored file must be pruned within Mirrored tree"
grep -Fq 'static site' "${HV}/workloads/alpha/provides.json" \
  || fail "alpha Provides must land on Host"
pass "Mirror materializes internal Source + Provides directories"

# Leaves orphans alone (definition tree + durable data)
[[ -f "${HV}/workloads/orphan-left/manifest.json" ]] \
  || fail "Mirror must leave orphan definition tree"
grep -Fxq 'keep-orphan' "${HV}/workloads/orphan-left/routes/orphan.conf" \
  || fail "orphan routes must be untouched"
grep -Fxq 'durable' "${HV}/workloads/orphan-left/persist/state.bin" \
  || fail "orphan durable data must be untouched"
[[ -d "${HV}/workloads/alpha/persist" ]] \
  || fail "Mirror must auto-create empty Persist for Environment Workloads"
[[ -d "${HV}/workloads/gamma/persist" ]] \
  || fail "Mirror must auto-create Persist for Manifest-less bags"
pass "Mirror leaves orphan Host trees alone"

# Manifest-less bag, hidden paths, and preserved symlinks
[[ ! -f "${HV}/workloads/gamma/manifest.json" ]] \
  || fail "gamma must remain Manifest-less"
grep -Fxq 'draft' "${HV}/workloads/gamma/notes/idea.md" \
  || fail "opaque bag extras must be mirrored"
grep -Fxq 'acme' "${HV}/workloads/gamma/www/.well-known/probe" \
  || fail "in-tree hidden paths must be mirrored"
[[ -L "${HV}/workloads/gamma/link-to-target" ]] \
  || fail "symlinks must be preserved as links"
pass "Mirror upserts Manifest-less bags; preserves hidden paths and symlinks"

# Invalid Manifest present → Source resolution fails closed
rm -rf "${STAGE}/workloads"
mkdir -p "${STAGE}/workloads/bad"
printf 'not-even-json\n' >"${STAGE}/workloads/bad/manifest.json"
cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
if bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" >/dev/null 2>&1; then
  fail "invalid Manifest must fail closed at Source resolution"
fi
pass "Mirror fails closed on invalid Manifest Source resolution"

# Reserved collision: root Provides pull onto dest with Manifest/Binding
rm -rf "${STAGE}/workloads"
mkdir -p "${STAGE}/workloads/collide/extra"
write_internal_stubs "${STAGE}/workloads/collide"
cat >"${STAGE}/workloads/collide/manifest.json" <<'EOF'
{ "intent": "stop", "source": "internal" }
EOF
cat >"${STAGE}/workloads/collide/provides.json" <<'EOF'
{ "directories": { ".": "entire artifact root" } }
EOF
printf 'payload\n' >"${STAGE}/workloads/collide/extra/file.txt"
cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
if bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" >/dev/null 2>&1; then
  fail "root Provides directories onto reserved Host files must fail closed"
fi
pass "Mirror fails closed on reserved Provides destination collision"

# --- zip Source: Environment holds Manifest+Binding; Artifact content from zip ---
rm -rf "${STAGE}/workloads"
ZIP_ROOT="${TMP}/zip-artifact"
ZIP_DIR="${TMP}/zip-http"
mkdir -p "${ZIP_ROOT}/systemd" "${ZIP_ROOT}/www" "${ZIP_DIR}"
cat >"${ZIP_ROOT}/provides.json" <<'EOF'
{
  "directories": {
    "systemd": "units",
    "www": "static"
  }
}
EOF
printf '{ "database": false, "cache": false }\n' >"${ZIP_ROOT}/requires.json"
printf 'from-zip-unit\n' >"${ZIP_ROOT}/systemd/zippy.container"
printf 'from-zip-www\n' >"${ZIP_ROOT}/www/index.html"
(cd "${ZIP_ROOT}" && zip -qr "${ZIP_DIR}/artifact.zip" .)

# Bind HTTP server to a free port
PORT_FILE="${TMP}/http-port"
python3 - "${ZIP_DIR}" "${PORT_FILE}" <<'PY' &
import http.server, socketserver, sys, pathlib
directory, port_file = sys.argv[1], sys.argv[2]
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)
    def log_message(self, fmt, *args):
        pass
with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    port = httpd.server_address[1]
    pathlib.Path(port_file).write_text(str(port), encoding="utf-8")
    httpd.serve_forever()
PY
HTTP_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "${PORT_FILE}" ]] && break
  sleep 0.1
done
[[ -f "${PORT_FILE}" ]] || fail "HTTP server did not publish port"
HTTP_PORT="$(cat "${PORT_FILE}")"
ZIP_URI="http://127.0.0.1:${HTTP_PORT}/artifact.zip"

mkdir -p "${STAGE}/workloads/zippy"
printf '{}\n' >"${STAGE}/workloads/zippy/binding.json"
cat >"${STAGE}/workloads/zippy/manifest.json" <<EOF
{
  "intent": "run",
  "source": "${ZIP_URI}"
}
EOF

cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" \
  || fail "ensure-mirror-host failed for zip Source"

grep -Fxq 'from-zip-unit' \
  "${HV}/workloads/zippy/systemd/zippy.container" \
  || fail "zip Provides directories must materialize systemd"
grep -Fxq 'from-zip-www' "${HV}/workloads/zippy/www/index.html" \
  || fail "zip Provides directories must materialize www"
grep -Fq 'units' "${HV}/workloads/zippy/provides.json" \
  || fail "zip Artifact Provides must land on Host"
grep -Fq 'database' "${HV}/workloads/zippy/requires.json" \
  || fail "zip Artifact Requires must land on Host"
python3 - "${HV}/workloads/zippy/manifest.json" <<'PY' || fail "zip Manifest must remain Environment SoT"
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m.get("intent") == "run"
assert str(m.get("source", "")).endswith(".zip")
PY
[[ -f "${HV}/workloads/zippy/binding.json" ]] \
  || fail "zip Environment Binding must remain on Host"
pass "Mirror materializes zip URI Source via Provides directories"

# --- path zip Source: same Artifact, local file, zip remains on Host ---
rm -rf "${STAGE}/workloads"
mkdir -p "${STAGE}/workloads/zippath"
printf '{}\n' >"${STAGE}/workloads/zippath/binding.json"
cp "${ZIP_DIR}/artifact.zip" "${STAGE}/workloads/zippath/artifact.zip"
cat >"${STAGE}/workloads/zippath/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "artifact.zip"
}
EOF
cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" \
  || fail "ensure-mirror-host failed for path zip Source"
grep -Fxq 'from-zip-www' "${HV}/workloads/zippath/www/index.html" \
  || fail "path zip Provides directories must materialize www"
[[ -f "${HV}/workloads/zippath/artifact.zip" ]] \
  || fail "path zip must remain on Host as Environment bag"
pass "Mirror materializes path zip Source via Provides directories"

echo "All ensure-mirror-host offline tests passed."
