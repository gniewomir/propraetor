#!/usr/bin/env bash
# Host TLS material for the Database Component (ADR-0049 / #188 / #189).
# Sourced by Database Setup. Create-if-missing CA + server cert (SAN DNS:database)
# and per-Workload client certificates (CN = basename).
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

# Create-if-missing client certificate for one Workload basename (CN = basename).
# Writes under DATA_ROOT/clients/<basename>/{client.crt,client.key}.
# Args: basename
database_tls_ensure_client() {
  local basename="${1:?database_tls_ensure_client: basename required}"
  local ca_crt="${DATA_ROOT}/ca/ca.crt"
  local ca_key="${DATA_ROOT}/ca/ca.key"
  local client_dir="${DATA_ROOT}/clients/${basename}"
  local client_crt="${client_dir}/client.crt"
  local client_key="${client_dir}/client.key"
  local tmp extfile serial csr

  [[ -f "${ca_crt}" && -f "${ca_key}" ]] || {
    echo "Database TLS: CA missing; call database_tls_ensure first" >&2
    return 1
  }

  mkdir -p "${client_dir}"
  if [[ -f "${client_crt}" && -f "${client_key}" ]]; then
    if [[ -n "${USER_NAME:-}" ]]; then
      chown -R "${USER_NAME}:${USER_NAME}" "${client_dir}" 2>/dev/null || true
    fi
    return 0
  fi

  echo "Database TLS: creating client certificate CN=${basename}" >&2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/platform-database-client-tls.XXXXXX")"
  extfile="${tmp}/client.ext"
  serial="${tmp}/ca.srl"
  csr="${tmp}/client.csr"
  printf '%s\n' \
    "basicConstraints=CA:FALSE" \
    "keyUsage=digitalSignature" \
    "extendedKeyUsage=clientAuth" >"${extfile}"
  openssl req -newkey rsa:4096 -sha256 -nodes \
    -keyout "${client_key}" -out "${csr}" \
    -subj "/CN=${basename}" \
    || {
      rm -rf "${tmp}"
      return 1
    }
  openssl x509 -req -in "${csr}" -CA "${ca_crt}" -CAkey "${ca_key}" \
    -CAserial "${serial}" -CAcreateserial \
    -out "${client_crt}" -days 3650 -sha256 -extfile "${extfile}" \
    || {
      rm -rf "${tmp}"
      return 1
    }
  rm -rf "${tmp}"
  chmod 0600 "${client_key}"
  chmod 0644 "${client_crt}"

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${client_dir}" 2>/dev/null || true
  fi
}
