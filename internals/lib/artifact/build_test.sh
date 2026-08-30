#!/usr/bin/env bash
# Unit tests: Artifact Build validate / outputs / reserved refuse / run
# (ADR-0058 / #259).
# Seam: artifact_build_validate / artifact_build_outputs /
# artifact_build_reserved_output_refuse / artifact_build_run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=build.sh
source "${REPO_ROOT}/internals/lib/artifact/build.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-build.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

BUILD="${TMP}/build.json"

# --- validate: happy paths ---
cat >"${BUILD}" <<'EOF'
{"image":"docker.io/library/alpine:3.20","command":"make","output":"www"}
EOF
artifact_build_validate "${BUILD}" || fail "string command + string output must validate"
pass "validate string command / string output"

cat >"${BUILD}" <<'EOF'
{
  "image": "img:tag",
  "command": ["npm", "run", "build"],
  "output": ["dist", "assets/app.js"]
}
EOF
artifact_build_validate "${BUILD}" || fail "argv command + array output must validate"
pass "validate argv command / array output"

# --- validate: fail closed ---
if artifact_build_validate "${TMP}/missing.json" >/dev/null 2>&1; then
  fail "missing build.json must fail validate"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":"c","output":"o","extra":1}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "unknown key must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"","command":"c","output":"o"}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "empty image must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":"","output":"o"}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "empty command string must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":[],"output":"o"}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "empty command array must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":["ok",""],"output":"o"}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "empty command argv element must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":"c","output":"."}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "sole . output must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":"c","output":"/abs"}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "absolute output must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":"c","output":"../escape"}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail ".. output must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":"c","output":"a/./b"}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "dot-segment output must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":"c","output":[]}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "empty output array must fail closed"
fi

cat >"${BUILD}" <<'EOF'
{"image":"x","command":123,"output":"o"}
EOF
if artifact_build_validate "${BUILD}" >/dev/null 2>&1; then
  fail "wrong-type command must fail closed"
fi
pass "validate fail closed"

# --- outputs ---
cat >"${BUILD}" <<'EOF'
{"image":"img","command":"c","output":["dist","www/app"]}
EOF
got="$(artifact_build_outputs "${BUILD}")"
[[ "${got}" == $'dist\nwww/app' ]] || fail "outputs must print one path per line; got: ${got}"
pass "artifact_build_outputs"

# --- reserved refuse ---
if artifact_build_reserved_output_refuse "provides.json" >/dev/null 2>&1; then
  fail "provides.json must be refused"
fi
if artifact_build_reserved_output_refuse "requires.json" >/dev/null 2>&1; then
  fail "requires.json must be refused"
fi
if artifact_build_reserved_output_refuse "build.json" >/dev/null 2>&1; then
  fail "build.json must be refused"
fi
if artifact_build_reserved_output_refuse "systemd" >/dev/null 2>&1; then
  fail "systemd must be refused"
fi
if artifact_build_reserved_output_refuse "systemd/unit.container" >/dev/null 2>&1; then
  fail "under systemd must be refused"
fi
if artifact_build_reserved_output_refuse "persist/data" >/dev/null 2>&1; then
  fail "under persist must be refused"
fi
if artifact_build_reserved_output_refuse "pkg/provides.json" >/dev/null 2>&1; then
  fail "nested provides.json segment must be refused"
fi
artifact_build_reserved_output_refuse "www" \
  || fail "www must be allowed"
artifact_build_reserved_output_refuse "dist/app.js" \
  || fail "dist/app.js must be allowed"
pass "artifact_build_reserved_output_refuse"

# --- run: missing build.json is no-op ---
MAT="${TMP}/materials"
ART="${MAT}/pkg"
mkdir -p "${ART}"
printf 'provides\n' >"${ART}/provides.json"
artifact_build_run "${MAT}" "${ART}" "${ART}/build.json" \
  || fail "missing build.json must no-op success"
[[ -f "${ART}/provides.json" ]] || fail "no-op must leave Artifact intact"
pass "run missing build.json no-op"

# --- run: stub podman records args and creates output ---
BIN="${TMP}/bin"
mkdir -p "${BIN}"
RECORD="${TMP}/podman-args.txt"
export ARTIFACT_BUILD_TEST_RECORD="${RECORD}"
export ARTIFACT_BUILD_TEST_MATERIALS="${MAT}"

cat >"${BIN}/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"${ARTIFACT_BUILD_TEST_RECORD}"
workdir=""
i=0
args=("$@")
while [[ $i -lt ${#args[@]} ]]; do
  printf '%s\n' "${args[$i]}" >>"${ARTIFACT_BUILD_TEST_RECORD}"
  if [[ "${args[$i]}" == "-w" ]]; then
    i=$((i + 1))
    workdir="${args[$i]}"
    printf '%s\n' "${args[$i]}" >>"${ARTIFACT_BUILD_TEST_RECORD}"
  fi
  i=$((i + 1))
done
# Map container workdir /materials/<rel> onto host materials and create www.
host_root="${ARTIFACT_BUILD_TEST_MATERIALS}"
if [[ "${workdir}" == /materials ]]; then
  host_cwd="${host_root}"
elif [[ "${workdir}" == /materials/* ]]; then
  host_cwd="${host_root}/${workdir#/materials/}"
else
  echo "stub podman: unexpected -w ${workdir}" >&2
  exit 1
fi
mkdir -p "${host_cwd}"
printf 'built\n' >"${host_cwd}/www"
EOF
chmod +x "${BIN}/podman"
export PATH="${BIN}:${PATH}"

mkdir -p "${ART}/systemd"
printf 'unit\n' >"${ART}/systemd/app.container"
printf 'provides\n' >"${ART}/provides.json"
printf 'requires\n' >"${ART}/requires.json"
cat >"${ART}/build.json" <<'EOF'
{
  "image": "docker.io/library/alpine:3.20",
  "command": "make www",
  "output": "www"
}
EOF

artifact_build_run "${MAT}" "${ART}" "${ART}/build.json" \
  || fail "successful build run must succeed"
[[ -f "${ART}/www" ]] || fail "build output www must exist after run"
[[ "$(cat "${ART}/www")" == "built" ]] || fail "www content mismatch"
[[ "$(cat "${ART}/provides.json")" == "provides" ]] || fail "provides.json must be unchanged"
[[ "$(cat "${ART}/requires.json")" == "requires" ]] || fail "requires.json must be unchanged"
[[ "$(cat "${ART}/systemd/app.container")" == "unit" ]] || fail "systemd/ must be unchanged"

grep -Fxq -- 'run' "${RECORD}" || fail "podman must be invoked with run"
grep -Fxq -- '--rm' "${RECORD}" || fail "podman must use --rm"
grep -Fxq -- "${MAT}:/materials:rw" "${RECORD}" || fail "podman must mount materials RW"
grep -Fxq -- '/materials/pkg' "${RECORD}" || fail "podman -w must be /materials/pkg"
grep -Fxq -- 'docker.io/library/alpine:3.20' "${RECORD}" || fail "podman image missing"
grep -Fxq -- 'sh' "${RECORD}" || fail "string command must use sh -c"
grep -Fxq -- 'make www' "${RECORD}" || fail "string command body missing"
pass "run stub podman string command"

# --- run: argv command ---
cat >"${ART}/build.json" <<'EOF'
{
  "image": "img:1",
  "command": ["node", "build.js"],
  "output": ["www"]
}
EOF
rm -f "${ART}/www" "${RECORD}"
artifact_build_run "${MAT}" "${ART}" "${ART}/build.json" \
  || fail "argv build run must succeed"
grep -Fxq -- 'node' "${RECORD}" || fail "argv command must pass node"
grep -Fxq -- 'build.js' "${RECORD}" || fail "argv command must pass build.js"
if grep -Fxq -- 'sh' "${RECORD}"; then
  fail "argv command must not wrap with sh -c"
fi
pass "run stub podman argv command"

# --- run: reserved output refuse ---
cat >"${ART}/build.json" <<'EOF'
{"image":"img","command":"c","output":"provides.json"}
EOF
if artifact_build_run "${MAT}" "${ART}" "${ART}/build.json" >/dev/null 2>&1; then
  fail "reserved output provides.json must refuse run"
fi
pass "run reserved output refuse"

# --- run: contract mutation detected ---
cat >"${BIN}/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Mutate provides.json inside materials Artifact root.
printf 'tampered\n' >"${ARTIFACT_BUILD_TEST_MATERIALS}/pkg/provides.json"
printf 'built\n' >"${ARTIFACT_BUILD_TEST_MATERIALS}/pkg/www"
EOF
chmod +x "${BIN}/podman"
cat >"${ART}/build.json" <<'EOF'
{"image":"img","command":"c","output":"www"}
EOF
printf 'provides\n' >"${ART}/provides.json"
rm -f "${ART}/www"
if artifact_build_run "${MAT}" "${ART}" "${ART}/build.json" >/dev/null 2>&1; then
  fail "mutated provides.json must fail closed"
fi
pass "run contract mutation fail closed"

# --- run: non-output path mutation fail closed ---
cat >"${BIN}/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'built\n' >"${ARTIFACT_BUILD_TEST_MATERIALS}/pkg/www"
printf 'sneaky\n' >"${ARTIFACT_BUILD_TEST_MATERIALS}/pkg/README.md"
EOF
chmod +x "${BIN}/podman"
printf 'provides\n' >"${ART}/provides.json"
printf 'keep\n' >"${ART}/README.md"
rm -f "${ART}/www"
cat >"${ART}/build.json" <<'EOF'
{"image":"img","command":"c","output":"www"}
EOF
if artifact_build_run "${MAT}" "${ART}" "${ART}/build.json" >/dev/null 2>&1; then
  fail "non-output mutation must fail closed"
fi
pass "run non-output mutation fail closed"

echo "All Artifact Build unit tests passed."
