#!/usr/bin/env bash
# Shared Component mTLS ensure (ADR-0049 / ADR-0055 / #229).
# Parameterized by Service Network dial name and Component Persist root.
# Cache and Database call the same module with distinct Persist roots — share
# code, never a shared CA.
# Ambient: USER_NAME (optional chown of written leaves).
#
# Public interface:
#   component_tls_ensure DIAL_NAME PERSIST_ROOT
#   component_tls_ensure_client DIAL_NAME PERSIST_ROOT BASENAME
#   component_tls_ensure_admin_client DIAL_NAME PERSIST_ROOT ADMIN_USERNAME
#     (optional adapter branch — Cache Setup; Database does not call)

# Create-if-missing Persist CA + server cert (SAN DNS:<dial>, CN=<dial>).
component_tls_ensure() {
  local dial="${1:?component_tls_ensure: dial name required}"
  local persist_root="${2:?component_tls_ensure: Persist root required}"
  local ca_dir="${persist_root}/ca"
  local server_dir="${persist_root}/server"
  local ca_crt="${ca_dir}/ca.crt"
  local ca_key="${ca_dir}/ca.key"
  local server_crt="${server_dir}/server.crt"
  local server_key="${server_dir}/server.key"
  local extfile serial csr
  local tmp

  if [[ "${dial}" =~ [[:space:]/] ]]; then
    echo "Component TLS: dial name is not a simple CN: '${dial}'" >&2
    return 1
  fi

  mkdir -p "${ca_dir}" "${server_dir}"

  if [[ ! -f "${ca_crt}" || ! -f "${ca_key}" ]]; then
    echo "Component TLS (${dial}): creating CA" >&2
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "${ca_key}" -out "${ca_crt}" \
      -subj "/CN=propraetor-${dial}-ca" \
      || return 1
    chmod 0600 "${ca_key}"
    chmod 0644 "${ca_crt}"
  fi

  if [[ ! -f "${server_crt}" || ! -f "${server_key}" ]]; then
    echo "Component TLS (${dial}): creating server certificate (SAN DNS:${dial})" >&2
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/platform-component-tls.XXXXXX")"
    extfile="${tmp}/san.ext"
    serial="${tmp}/ca.srl"
    csr="${tmp}/server.csr"
    printf '%s\n' \
      "basicConstraints=CA:FALSE" \
      "keyUsage=digitalSignature,keyEncipherment" \
      "extendedKeyUsage=serverAuth" \
      "subjectAltName=DNS:${dial}" >"${extfile}"
    openssl req -newkey rsa:4096 -sha256 -nodes \
      -keyout "${server_key}" -out "${csr}" \
      -subj "/CN=${dial}" \
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
    echo "Component TLS (${dial}): CA/server material missing after ensure" >&2
    return 1
  }

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${ca_dir}" "${server_dir}" 2>/dev/null || true
  fi
}

# Create-if-missing Workload client certificate (CN = basename).
# Writes under PERSIST_ROOT/clients/<basename>/{client.crt,client.key}.
component_tls_ensure_client() {
  local dial="${1:?component_tls_ensure_client: dial name required}"
  local persist_root="${2:?component_tls_ensure_client: Persist root required}"
  local basename="${3:?component_tls_ensure_client: basename required}"
  local ca_crt="${persist_root}/ca/ca.crt"
  local ca_key="${persist_root}/ca/ca.key"
  local client_dir="${persist_root}/clients/${basename}"
  local client_crt="${client_dir}/client.crt"
  local client_key="${client_dir}/client.key"
  local tmp extfile serial csr

  [[ -f "${ca_crt}" && -f "${ca_key}" ]] || {
    echo "Component TLS (${dial}): CA missing; call component_tls_ensure first" >&2
    return 1
  }

  if [[ "${basename}" =~ [[:space:]/] ]]; then
    echo "Component TLS (${dial}): basename is not a simple CN: '${basename}'" >&2
    return 1
  fi

  mkdir -p "${client_dir}"
  if [[ -f "${client_crt}" && -f "${client_key}" ]]; then
    if [[ -n "${USER_NAME:-}" ]]; then
      chown -R "${USER_NAME}:${USER_NAME}" "${client_dir}" 2>/dev/null || true
    fi
    return 0
  fi

  echo "Component TLS (${dial}): creating client certificate CN=${basename}" >&2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/platform-component-client-tls.XXXXXX")"
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

# Create-if-missing admin client certificate (CN = admin username).
# Optional adapter branch: Cache Setup issues this for the operator console;
# Database does not. Writes under PERSIST_ROOT/admin/{client.crt,client.key}.
component_tls_ensure_admin_client() {
  local dial="${1:?component_tls_ensure_admin_client: dial name required}"
  local persist_root="${2:?component_tls_ensure_admin_client: Persist root required}"
  local admin_user="${3:?component_tls_ensure_admin_client: admin username required}"
  local ca_crt="${persist_root}/ca/ca.crt"
  local ca_key="${persist_root}/ca/ca.key"
  local admin_dir="${persist_root}/admin"
  local client_crt="${admin_dir}/client.crt"
  local client_key="${admin_dir}/client.key"
  local tmp extfile serial csr
  local existing_cn

  [[ -f "${ca_crt}" && -f "${ca_key}" ]] || {
    echo "Component TLS (${dial}): CA missing; call component_tls_ensure first" >&2
    return 1
  }

  if [[ "${admin_user}" =~ [[:space:]/] ]]; then
    echo "Component TLS (${dial}): admin username is not a simple CN: '${admin_user}'" >&2
    return 1
  fi

  mkdir -p "${admin_dir}"
  if [[ -f "${client_crt}" && -f "${client_key}" ]]; then
    existing_cn="$(openssl x509 -noout -subject -in "${client_crt}" | sed -n 's/.*CN *= *//p')"
    if [[ "${existing_cn}" != "${admin_user}" ]]; then
      echo "Component TLS (${dial}): admin client CN='${existing_cn}' does not match admin user '${admin_user}'" >&2
      return 1
    fi
    if [[ -n "${USER_NAME:-}" ]]; then
      chown -R "${USER_NAME}:${USER_NAME}" "${admin_dir}" 2>/dev/null || true
    fi
    return 0
  fi

  echo "Component TLS (${dial}): creating admin client certificate CN=${admin_user}" >&2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/platform-component-admin-tls.XXXXXX")"
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
