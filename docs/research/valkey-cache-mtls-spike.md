# Spike: Valkey mTLS CN auth for Cache Component (ADR-0055)

**Researched:** 2026-08-15  
**Question:** Does official Valkey container TLS + `tls-auth-clients-user CN` support the ADR-0055 Cache design (cert-only Workloads, `default` off, prefix ACL, command whitelist)?  
**Scope:** Local Podman spike against `docker.io/valkey/valkey` alpine tags; not a Host/Acceptance run.  
**Method:** Generated CA/server/client certs; ran Valkey with `port 0`, `tls-port 6379`, `tls-auth-clients yes`, `tls-auth-clients-user CN`, `aclfile`; exercised clients via `valkey-cli --tls` inside the container.

---

## Verdict

**Go for implementation** on **`valkey/valkey:9.1-alpine` (or any ≥ 9.0 with TLS)**.

| Check | Result |
| --- | --- |
| Official alpine image has TLS | Pass — `Ready to accept connections tls` on 9.1.1 |
| `tls-auth-clients-user CN` | Pass on **9.0.5** and **9.1.1**; **fail on 8.1.9** (unknown directive) |
| CN auto-auth, no Workload `AUTH` | Pass — `PING`/`SET` as CN user without password |
| Cert-only (`resetpass`, no `nopass`) | Pass — `AUTH <user> <password>` → `WRONGPASS` |
| `default off` + unknown CN | Pass — `NOAUTH Authentication required` |
| No client cert | Pass — connection closed |
| Prefix `~alpha:*` blocks cross-tenant keys | Pass — `NOPERM No permissions to access a key` |
| Type-category whitelist blocks SCAN/KEYS/FLUSH/SELECT | Pass |
| Type categories alone enough for cache DX | **Fail** — `DEL`/`EXISTS`/`TYPE`/`EXPIRE`/`TTL` are `@keyspace`, not `@string` |
| Deny `AUTH` to block admin escalation | **Fail** — `AUTH` stays usable (`no_auth`); stolen admin password + any CA-signed client cert escalates |

**Image pin recommendation:** `docker.io/valkey/valkey:9.1-alpine` (spike used **9.1.1**). Floor: **Valkey ≥ 9.0** (CN directive absent on 8.1.9).

---

## Observed behaviors (detail)

### Auth

1. Client cert `CN=alpha` + ACL user `alpha` → session is `alpha` after TLS handshake; no `AUTH` required for allowed commands.
2. Client cert `CN=unknown` with no ACL user and `default off` → TCP/TLS up but commands return `NOAUTH`.
3. `tls-auth-clients yes` without a client cert → server closes the connection.
4. Workload user with `resetpass` and empty password list cannot `AUTH` as themselves with a password (`WRONGPASS`).
5. After connecting with a Workload (or unknown) client cert, `AUTH cache-admin <password>` **succeeds**. `-auth` on the Workload ACL does not stop this. Admin access = **any CA-signed client cert + Cache admin password**. Same class as Database: keep `ROOT_CACHE_*` out of Workload bindings (already required).

### Isolation

1. `SET beta:foo` as `alpha` → `NOPERM No permissions to access a key`.
2. `COPY` / `RENAME` / `MOVE` are not in the type-category allowlist → `NOPERM` on the command (defense in depth beyond key-pattern checks).

### Whitelist (ADR Q14 A refined)

**Insufficient alone:**

```text
-@all +@string +@hash +@list +@set +@sortedset +ping
```

Apps cannot `DEL`, `EXISTS`, `TYPE`, `EXPIRE`, `TTL` (those live under `@keyspace` with `SCAN`/`KEYS`/`FLUSHALL`/`DBSIZE`).

**Sufficient for v1 spike (do not grant `+@keyspace`):**

```text
user <basename> on resetpass ~<basename>:* resetchannels -@all
  +@string +@hash +@list +@set +@sortedset +ping
  +del +unlink +exists +type
  +expire +expireat +pexpire +pexpireat +ttl +pttl +persist +touch
```

Verified still denied: `SCAN`, `KEYS`, `FLUSHALL`, `SELECT`, `COPY`, `DBSIZE`, `RANDOMKEY`, `MOVE`, `RENAME`, `CONFIG`.

---

## Config sketch used

```conf
port 0
tls-port 6379
tls-cert-file …
tls-key-file …
tls-ca-cert-file …
tls-auth-clients yes
tls-auth-clients-user CN
aclfile …
save ""
appendonly no
maxmemory 64mb
maxmemory-policy allkeys-lru
```

```acl
user default off
user cache-admin on ><password> ~* &* +@all
user alpha on resetpass ~alpha:* resetchannels -@all +@string … +del …
```

---

## Implementation notes for Propraetor

1. Pin **Valkey ≥ 9.0**; prefer current 9.1.x alpine.
2. Encode the **refined ACL template** (type categories + explicit keyspace verbs), not bare type categories.
3. Document admin-password blast radius: any issued client cert + admin secret = admin (rotate admin secret seriously; never Binding-remap).
4. Publish `CACHE_KEY_PREFIX=<basename>:`; bare keys fail closed under ACL.
5. Operator `cache.sh` / `valkey-cli --tls` with admin user+password (and a client cert — e.g. dedicated admin cert or any valid cert plus `--user`/`-a`).

---

## Artifacts

Local only (not committed): `.tmp/valkey-spike/` certs + conf used for this run. Container `valkey-spike` removed after the run.

## Sources

- Spike runtime: `docker.io/valkey/valkey:8-alpine` (8.1.9), `:9.0-alpine` (9.0.5), `:9.1-alpine` (9.1.1)
- [Valkey TLS docs](https://valkey.io/topics/tls/) (`tls-auth-clients-user`)
- [Valkey ACL docs](https://valkey.io/topics/acl/) (cert-only / `resetpass`)
- ADR-0055
