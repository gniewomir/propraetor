#!/usr/bin/env bash
# Host TLS material for the Cache Component (ADR-0055 / #221).
# Sourced by Cache Setup. Create-if-missing CA + server cert (SAN DNS:cache)
# and admin client certificate (CN = admin ACL username).
# Expects: DATA_ROOT (Host Volume Cache Persist), USER_NAME (optional chown).

cache_tls_ensure() {
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
    echo "Cache TLS: creating CA" >&2
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "${ca_key}" -out "${ca_crt}" \
      -subj "/CN=propraetor-cache-ca" \
      || return 1
    chmod 0600 "${ca_key}"
    chmod 0644 "${ca_crt}"
  fi

  if [[ ! -f "${server_crt}" || ! -f "${server_key}" ]]; then
    echo "Cache TLS: creating server certificate (SAN DNS:cache)" >&2
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/platform-cache-tls.XXXXXX")"
    extfile="${tmp}/san.ext"
    serial="${tmp}/ca.srl"
    csr="${tmp}/server.csr"
    printf '%s\n' \
      "basicConstraints=CA:FALSE" \
      "keyUsage=digitalSignature,keyEncipherment" \
      "extendedKeyUsage=serverAuth" \
      "subjectAltName=DNS:cache" >"${extfile}"
    openssl req -newkey rsa:4096 -sha256 -nodes \
      -keyout "${server_key}" -out "${csr}" \
      -subj "/CN=cache" \
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
    echo "Cache TLS: CA/server material missing after ensure" >&2
    return 1
  }

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${ca_dir}" "${server_dir}" 2>/dev/null || true
  fi
}

# Create-if-missing admin client certificate (CN = admin ACL username).
# Writes under DATA_ROOT/admin/{client.crt,client.key}.
# Args: admin_username
cache_tls_ensure_admin_client() {
  local admin_user="${1:?cache_tls_ensure_admin_client: admin username required}"
  local ca_crt="${DATA_ROOT}/ca/ca.crt"
  local ca_key="${DATA_ROOT}/ca/ca.key"
  local admin_dir="${DATA_ROOT}/admin"
  local client_crt="${admin_dir}/client.crt"
  local client_key="${admin_dir}/client.key"
  local tmp extfile serial csr
  local existing_cn

  [[ -f "${ca_crt}" && -f "${ca_key}" ]] || {
    echo "Cache TLS: CA missing; call cache_tls_ensure first" >&2
    return 1
  }

  if [[ "${admin_user}" =~ [[:space:]/] ]]; then
    echo "Cache TLS: admin username is not a simple CN: '${admin_user}'" >&2
    return 1
  fi

  mkdir -p "${admin_dir}"
  if [[ -f "${client_crt}" && -f "${client_key}" ]]; then
    existing_cn="$(openssl x509 -noout -subject -in "${client_crt}" | sed -n 's/.*CN *= *//p')"
    if [[ "${existing_cn}" != "${admin_user}" ]]; then
      echo "Cache TLS: admin client CN='${existing_cn}' does not match admin user '${admin_user}'" >&2
      return 1
    fi
    if [[ -n "${USER_NAME:-}" ]]; then
      chown -R "${USER_NAME}:${USER_NAME}" "${admin_dir}" 2>/dev/null || true
    fi
    return 0
  fi

  echo "Cache TLS: creating admin client certificate CN=${admin_user}" >&2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/platform-cache-admin-tls.XXXXXX")"
  extfile="${tmp}/client.ext"
  serial="${tmp}/ca.srl"
  csr="${tmp}/client.csr"
  printf '%s\n' \
    "basicConstraints=CA:FALSE" \
    "keyUsage=digitalSignature" \
    "extendedKeyUsage=clientAuth" >"${extfile}"
  openssl req -newkey rsa:4096 -sha256 -nodes \
    -keyout "${client_key}" -out "${csr}" \
    -subj "/CN=${admin_user}" \
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
    chown -R "${USER_NAME}:${USER_NAME}" "${admin_dir}" 2>/dev/null || true
  fi
}
