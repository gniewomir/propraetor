#!/usr/bin/env bash
# Host TLS material for the Database Component (ADR-0049 / #188).
# Sourced by Database Setup. Create-if-missing CA + server cert (SAN DNS:database).
# Expects: DATA_ROOT (Host Volume Database interior), USER_NAME (optional chown).

database_tls_ensure() {
  local ca_dir="${DATA_ROOT}/ca"
  local server_dir="${DATA_ROOT}/server"
  local ca_crt="${ca_dir}/ca.crt"
  local ca_key="${ca_dir}/ca.key"
  local server_crt="${server_dir}/server.crt"
  local server_key="${server_dir}/server.key"
  local extfile serial csr
  local tmp

  mkdir -p "${ca_dir}" "${server_dir}"

  if [[ ! -f "${ca_crt}" || ! -f "${ca_key}" ]]; then
    echo "Database TLS: creating CA" >&2
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "${ca_key}" -out "${ca_crt}" \
      -subj "/CN=propraetor-database-ca" \
      || return 1
    chmod 0600 "${ca_key}"
    chmod 0644 "${ca_crt}"
  fi

  if [[ ! -f "${server_crt}" || ! -f "${server_key}" ]]; then
    echo "Database TLS: creating server certificate (SAN DNS:database)" >&2
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/platform-database-tls.XXXXXX")"
    extfile="${tmp}/san.ext"
    serial="${tmp}/ca.srl"
    csr="${tmp}/server.csr"
    printf '%s\n' \
      "basicConstraints=CA:FALSE" \
      "keyUsage=digitalSignature,keyEncipherment" \
      "extendedKeyUsage=serverAuth" \
      "subjectAltName=DNS:database" >"${extfile}"
    openssl req -newkey rsa:4096 -sha256 -nodes \
      -keyout "${server_key}" -out "${csr}" \
      -subj "/CN=database" \
      || {
        rm -rf "${tmp}"
        return 1
      }
    openssl x509 -req -in "${csr}" -CA "${ca_crt}" -CAkey "${ca_key}" \
      -CAserial "${serial}" -CAcreateserial \
      -out "${server_crt}" -days 3650 -sha256 -extfile "${extfile}" \
      || {
        rm -rf "${tmp}"
        return 1
      }
    rm -rf "${tmp}"
    chmod 0600 "${server_key}"
    chmod 0644 "${server_crt}"
  fi

  [[ -f "${ca_crt}" && -f "${ca_key}" && -f "${server_crt}" && -f "${server_key}" ]] || {
    echo "Database TLS: CA/server material missing after ensure" >&2
    return 1
  }

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${ca_dir}" "${server_dir}" 2>/dev/null || true
  fi
}
