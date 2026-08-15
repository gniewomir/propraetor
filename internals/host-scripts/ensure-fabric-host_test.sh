#!/usr/bin/env bash
# Unit tests: ensure-fabric Host half — Fabric Setup only (ADR-0041 / #155).
# Offline: temp Host Volume roots + stub setup.sh scripts. No SSH / live Host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-fabric-host.sh"

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

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ensure-fabric.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
HV="${TMP}/host-volume"
mkdir -p "${HV}" "${TMP}/lib"
cp "${REPO_ROOT}/internals/host-scripts/lib/sync-tree-host.sh" "${TMP}/lib/sync-tree-host.sh"
cp "${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh" \
  "${TMP}/lib/host-volume-paths-host.sh"
printf '# ensure-fabric unit stub lib\n' >"${TMP}/lib/stub.sh"

# Runnable copy; Host Volume via ambient HV_ROOT (#214 path vocabulary).
cp "${HOST_SCRIPT}" "${TMP}/ensure-run.sh"
chmod +x "${TMP}/ensure-run.sh"
export HV_ROOT="${HV}"

mkdir -p "${TMP}/fabric" "${TMP}/edge"
cat >"${TMP}/fabric/setup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "fabric" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/fabric/setup.sh"
# Staged Edge must be ignored by ensure-fabric.
cat >"${TMP}/edge/setup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "edge" >>"${TMP}/setup.order"
EOF
chmod +x "${TMP}/edge/setup.sh"
printf 'fabric-marker\n' >"${TMP}/fabric/marker.txt"

USER_NAME="$(id -un)"

# Offline macOS: Platform User group may not equal login name; Host uses user:user.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP}/bin/chown"
export PATH="${TMP}/bin:${PATH}"

# --- Fabric only: installs fabric, runs Fabric Setup, ignores staged Edge ---
: >"${TMP}/setup.order"
mkdir -p "${HV}/internals/legacy" "${HV}/data/legacy" "${HV}/components_data/legacy"
bash "${TMP}/ensure-run.sh" "${USER_NAME}" --fabric fabric 2>"${TMP}/stderr" \
  || fail "ensure-fabric-run failed: $(cat "${TMP}/stderr")"

grep -Fq 'Running Fabric Setup: fabric' "${TMP}/stderr" \
  || fail "expected Fabric Setup log for fabric, got: $(cat "${TMP}/stderr")"
if grep -Fq 'Running Component Setup' "${TMP}/stderr"; then
  fail "ensure-fabric must not run Component Setup"
fi
order="$(cat "${TMP}/setup.order")"
printf '%s\n' "${order}" | grep -Fxq 'fabric' || fail "Fabric Setup did not run, got: ${order}"
if printf '%s\n' "${order}" | grep -Fxq 'edge'; then
  fail "ensure-fabric must not run staged Edge Setup"
fi
[[ -f "${HV}/fabric/setup.sh" ]] || fail "fabric tree not installed on Host Volume"
[[ -f "${HV}/fabric/marker.txt" ]] || fail "fabric marker not installed"
[[ ! -e "${HV}/components/edge" ]] || fail "ensure-fabric must not install Edge"
[[ -d "${HV}/host-scripts/lib" ]] || fail "host-scripts lib not installed"
[[ -d "${HV}/fabric" ]] || fail "fabric SoT missing"
[[ ! -e "${HV}/fabric/persist" ]] || fail "Fabric must not get Persist"
[[ ! -e "${HV}/internals" ]] || fail "retired internals/ must not exist after ensure-fabric"
[[ ! -e "${HV}/data" ]] || fail "retired data/ must not exist after ensure-fabric"
[[ ! -e "${HV}/components_data" ]] || fail "retired components_data/ must not exist after ensure-fabric"
pass "ensure-fabric installs Fabric only and runs Fabric Setup"

# --- rejects --component (Components are a different cog) ---
if bash "${TMP}/ensure-run.sh" "${USER_NAME}" --component edge 2>"${TMP}/stderr2"; then
  fail "expected failure for --component on ensure-fabric"
fi
grep -Eqi 'unknown argument|--fabric' "${TMP}/stderr2" \
  || fail "ensure-fabric --component rejection unclear: $(cat "${TMP}/stderr2")"
pass "ensure-fabric rejects --component"

# --- non-breaking ship: update fabric tree without replacing directory inode ---
mkdir -p "${HV}/fabric"
printf 'old\n' >"${HV}/fabric/marker.txt"
dir_ino="$(inode_of "${HV}/fabric")"
file_ino="$(inode_of "${HV}/fabric/marker.txt")"
: >"${TMP}/setup.order"
bash "${TMP}/ensure-run.sh" "${USER_NAME}" --fabric fabric 2>"${TMP}/stderr3" \
  || fail "re-ensure-fabric failed: $(cat "${TMP}/stderr3")"
[[ "$(inode_of "${HV}/fabric")" == "${dir_ino}" ]] \
  || fail "fabric directory inode changed (breaking ship for bind mounts)"
[[ "$(inode_of "${HV}/fabric/marker.txt")" == "${file_ino}" ]] \
  || fail "fabric marker inode changed (file was unlinked instead of overwritten)"
grep -Fxq 'fabric-marker' "${HV}/fabric/marker.txt" \
  || fail "fabric marker content not updated in place"
pass "ensure-fabric updates Fabric tree without replacing directory/file inodes"

echo "All ensure-fabric-host offline tests passed."
