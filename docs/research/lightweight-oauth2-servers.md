# Lightweight OAuth2 / OIDC authorization servers for Propraetor Components

**Researched:** 2026-08-17  
**Question:** Are there lightweight, reputable OAuth2 (and/or OIDC) authorization servers distributed as one binary and/or one container that a solo operator could run as a Propraetor Component (rootless Podman / Quadlet, small Host, Host Volume bind-mount)?  
**Scope:** Self-hosted OAuth 2.0 Authorization Servers and/or OpenID Connect Providers that can run as a single official binary or a single official container image. Managed IdPs (Auth0, Okta, Cognito, Entra ID, Clerk, WorkOS, Ory Network SaaS, Google Identity, …) are out of scope except as non-fits. OAuth **clients** and libraries that are not a runnable server are noted only to dismiss. Reverse-proxy / forward-auth products that consume tokens but are not an AS (oauth2-proxy, vouch-proxy, Pomerium, tinyauth’s original job, Traefik Forward Auth, Caddy security plugins) are mentioned only as “wrong job.” Not a Propraetor design doc. Repo deployment context from [`CONTEXT.md`](../../CONTEXT.md) (Components as rootless Quadlets on a Host Volume) informs operational fit observations only.  
**Method:** Primary sources only — official project docs and READMEs, CNCF project pages, OAuth 2.0 / OIDC specs when needed to classify a product, first-party install/config/deploy guides, and GitHub release metadata. Secondary blogs used only as leads; claims verified against owning sources.

---

## Roles (so the shortlist is not mixing jobs)

RFC 6749 defines an **Authorization Server (AS)** as the party that issues OAuth 2.0 tokens after authenticating the resource owner and obtaining authorization ([RFC 6749](https://www.rfc-editor.org/rfc/rfc6749)). OpenID Connect Core 1.0 defines an **OpenID Provider (OP)** as an OAuth 2.0 AS that also authenticates the End-User and provides Claims to a Relying Party, typically via an ID Token ([OIDC Core](https://openid.net/specs/openid-connect-core-1_0.html)).

This note uses:

| Role | What it does | Component-shaped? |
| --- | --- | --- |
| **Headless AS / OP** | Speaks OAuth2/OIDC on the wire; does **not** store users; login/consent is a separate app (Hydra-style) | Yes as a protocol daemon; user-facing flows need a sibling UI |
| **OIDC IdP** | AS/OP that authenticates users itself or via connectors, and issues ID tokens (Dex, Pocket ID, Authelia-as-OP, Kanidm) | Yes if one process + local store |
| **Login portal / SSO companion** | Session cookie + reverse-proxy authz; may *also* be an OP (Authelia) | Only if the OP path is first-party and usable without the proxy job |
| **Forward-auth / identity-aware proxy** | Consumes an IdP; is not an AS (oauth2-proxy, Pomerium, Traefik Forward Auth) | No |

Nothing below is “just store and serve” in the sense of [CNCF Distribution](lightweight-container-registries.md). An AS always has identity and (for user-facing grants) a login surface.

---

## Verdict

**Qualified yes.** There *are* reputable, actively maintained Go (and one Rust) servers that speak OAuth2/OIDC as a **single official binary or single official container**, with first-party SQLite / filesystem / in-memory stores and no mandatory PostgreSQL/Redis/Elasticsearch stack.

They are not interchangeable:

1. **[Dex](https://github.com/dexidp/dex)** (`ghcr.io/dexidp/dex`) — CNCF Sandbox federated **OIDC identity and OAuth 2.0 provider**. One Go process, one YAML file, pluggable connectors, first-party SQLite (explicitly “stand up quickly,” not “real workloads”). Apps talk OIDC to Dex; users usually live upstream ([docs](https://dexidp.io/docs/), [storage](https://dexidp.io/docs/configuration/storage/), [CNCF](https://www.cncf.io/projects/dex/)).
2. **[Pocket ID](https://github.com/pocket-id/pocket-id)** (`ghcr.io/pocket-id/pocket-id`) — OpenID Certified™ **OIDC / OAuth 2.0 provider** that stores users itself and authenticates with **passkeys only**. Official single binary and single container; default SQLite; first-party **Podman Quadlet** example ([install](https://pocket-id.org/docs/setup/installation), [env](https://pocket-id.org/docs/configuration/environment-variables)).
3. **[Ory Hydra](https://github.com/ory/hydra)** (`oryd/hydra`) — OpenID Certified™ **headless** OAuth 2.0 AS and OIDC OP. One Go binary/container; SQLite and `DSN=memory` are first-party. It does **not** store users. Official user-facing flows require a **login and consent** app ([README](https://github.com/ory/hydra/blob/master/README.md), [configure-deploy](https://www.ory.com/docs/hydra/self-hosted/configure-deploy), [DSN](https://www.ory.com/docs/hydra/self-hosted/dependencies-environment)). Client-credentials-only can skip that sibling.

**Strongest overall for this criteria order:** **Dex** when the Host should expose one OIDC issuer and identity stays in connectors (or a small local password DB). **Pocket ID** when the Host should be a self-contained passkey IdP with one Quadlet and a bind-mounted SQLite file — closest operational analog to `registry:3` / `zot-minimal`. **Hydra** when the job is a headless AS (machine clients, or login UI already exists). None of the three is a full IAM suite; none publishes idle RSS in primary docs.

Full IAM platforms (Keycloak, Authentik, ZITADEL, Logto, Casdoor, FusionAuth, Janssen/Gluu, UAA) can be real ASs, but they fail the footprint / minimal-API / one-container tests. Forward-auth products fail the job test.

---

## Decision criteria

Ordered for this question:

1. **Low resource footprint** on a solo-operator / small Host (idle and light use). Prefer few processes, no mandatory PostgreSQL/Redis/Elasticsearch stack. SQLite or filesystem/in-memory stores are a plus if first-party. Published vendor minima are not observed RSS (same evidence policy as the [registry note](lightweight-container-registries.md)).
2. **Minimal API** — OAuth2 AS and/or OIDC Provider. Prefer not a full IAM suite (user directory, admin UI, MFA product, workflow engine) unless that is the only reputable option.
3. **Simplicity** — official single binary and/or official single container; small config surface; Quadlet-friendly (one long-lived container + Host Volume bind-mount).
4. **Reputable** — CNCF or established org, recent releases (2025–2026 activity verified), clear ownership, OSI license.
5. **Go or Rust** preferred when candidates are otherwise similar.

---

## Shortlist

| Tier | Candidate | Shape | Why it remains / exits |
| --- | --- | --- | --- |
| A | Dex | Single Go OIDC IdP container/binary | CNCF Sandbox; one YAML; SQLite/memory; connectors; apps speak OIDC |
| A | Pocket ID | Single Go OIDC IdP container/binary | Certified OP; SQLite default; passkeys; first-party Quadlet |
| A | Ory Hydra | Single Go headless AS/OP | Certified OP; SQLite/memory; no user store; login/consent is a sibling for user grants |
| B | Authelia (OIDC provider mode) | Single Go portal + OP | Certified OP + SQLite, but primary job is reverse-proxy SSO/MFA portal |
| B | Kanidm | Single Rust IDM container | First-party SQLite KV + OIDC, but full IDM (LDAP, RADIUS, PAM, SSH, portal) |
| Reject (heavy) | Keycloak | JVM IAM (Quarkus) | CNCF Incubating; production wants Postgres; vendor memory floors in the GB class |
| Reject (heavy) | Authentik | Server + worker + Postgres | Official min 2 CPU / 2 GB RAM; compose stack |
| Reject (heavy) | ZITADEL | Go IAM + Postgres (+ login UI image) | Full IAM; Postgres required; compose is a stack |
| Reject (heavy) | Logto | Node/TS IAM + Postgres | Official OSS host floor 8 GiB RAM |
| Reject (heavy) | FusionAuth community | JVM app + Postgres (+ optional OpenSearch) | Full CIAM; not one lightweight daemon |
| Reject (heavy) | Janssen / Gluu Flex | Java IAM bundle | Auth Server plus config/FIDO/SCIM/…; RDBMS |
| Reject (heavy) | Cloud Foundry UAA | Java CF identity | OAuth2/OIDC server, CF-oriented packaging |
| Reject (IAM, not minimal) | Casdoor | Go UI-first IAM | SQLite possible, but full IAM/SSO/MCP console |
| Reject (wrong packaging) | supabase/auth (GoTrue) | Go JWT auth API | User/JWT service; OAuth 2.1 is a Supabase Auth feature, not a standalone AS Component |
| Reject (wrong job) | SuperTokens Core | Java session/auth core | SDK-driven auth; not a dedicated AS; Postgres/MySQL typical |
| Reject (wrong job) | Hanko | Go passkey/CIAM API | Consumes OIDC IdPs; is not itself an AS/OP |
| Reject (wrong job) | HashiCorp Vault / OpenBao | Secrets manager + OIDC feature | Can issue OIDC for Vault identities; the product is secrets, not an AS Component |
| Reject (wrong job) | oauth2-proxy, vouch-proxy, Pomerium, Traefik Forward Auth | Proxy / forward-auth | Consume an IdP; are not an AS |
| Reject (wrong job) | Tinyauth | Forward-auth (+ OIDC since v5.1) | Getting-started is Traefik Forward Auth; OIDC is an add-on role |
| Reject (not a server) | ory/fosite, go-oauth2/oauth2, panva/node-oidc-provider, Spring Authorization Server, OpenIddict, Duende IdentityServer, Authlib | Library / framework | No official one-binary AS image as the product |
| Skip | Cierge (Biarity OIDC) | Abandoned .NET OP | Canonical repo gone; 2018-era forks; homepage discontinued |
| Skip | autentico, sui-id, gtid | New single-binary OIDC | 2025–2026 shape matches the brief; not established enough for “reputable” |
| Skip | Ory Kratos, LLDAP | Identity / LDAP | Not an OAuth2 AS |

---

## Tier A — serious candidates

### 1. Dex (`ghcr.io/dexidp/dex`)

**What it is.** “An identity service that uses OpenID Connect to drive authentication for other apps.” It is a **federated OIDC IdP and OAuth 2.0 provider**: clients speak OIDC to Dex; Dex authenticates users through **connectors** (LDAP, SAML, GitHub, Google, Microsoft, OIDC, local password DB, …) ([README](https://github.com/dexidp/dex/blob/master/README.md), [docs home](https://dexidp.io/docs/)). Language: **Go**. License: Apache-2.0. Ownership: dexidp org; CNCF.

**Maintenance / reputation.** Accepted to CNCF on **June 25, 2020** at **Sandbox** ([CNCF Dex](https://www.cncf.io/projects/dex/)). Recent releases: **v2.45.1** (2026-03-03), **v2.45.0** (2026-02-23), **v2.44.0** (2025-09-01) ([GitHub releases](https://github.com/dexidp/dex/releases)). `main` pushes through 2026-08. Images: GitHub Container Registry is the **primary** image source; Docker Hub is also published ([releases process](https://dexidp.io/docs/development/releases/)). First-party Dockerfile example uses `FROM ghcr.io/dexidp/dex:latest` ([templates](https://dexidp.io/docs/guides/templates/)). Alpine and distroless variants ([getting started](https://dexidp.io/docs/getting-started/)).

**Protocol surface.** OIDC ID Tokens are “dex's primary feature” ([README](https://github.com/dexidp/dex/blob/master/README.md)). Configurable OAuth2 grants ([oauth2 config](https://dexidp.io/docs/configuration/oauth2/)):

| Grant | Dex |
| --- | --- |
| `authorization_code` | Yes |
| `refresh_token` | Yes |
| `password` | Yes, discouraged; needs `passwordConnector` |
| `client_credentials` | Yes; env `DEX_CLIENT_CREDENTIAL_GRANT_ENABLED_BY_DEFAULT=true` |
| Device code (RFC 8628) | Yes |
| Token exchange (RFC 8693) | Yes |
| Implicit | Via `responseTypes`, not `grantTypes` |

PKCE is part of the OIDC/OAuth2 client path Dex implements for public clients (standard OIDC usage; grant table does not call it out as a separate grant).

**How to run.** Official path is the container image, or `make build` then:

```text
./bin/dex serve examples/config-dev.yaml
```

([getting started](https://dexidp.io/docs/getting-started/)). Container command is `dex serve /etc/dex/config.yaml` (image entrypoint can gomplate-template the config). Bind-mount the YAML and, for SQLite, the DB file.

**Persistence.** Dex **requires** storage for refresh tokens, replay protection, and key rotation ([storage](https://dexidp.io/docs/configuration/storage/)). First-party backends: etcd, Kubernetes CRDs, **SQLite3**, Postgres, MySQL. Docs architecture diagram also lists **in-memory** ([docs home](https://dexidp.io/docs/)). SQLite:

```yaml
storage:
  type: sqlite3
  config:
    file: /var/dex/dex.db
```

**First-party warning:** “SQLite3 is the recommended storage for users who want to stand up dex quickly. **It is not appropriate for real workloads.**” `:memory:` disables concurrent queries because of file locks ([storage](https://dexidp.io/docs/configuration/storage/)). For a solo Host with a handful of OIDC clients that warning is about SQLite concurrency/HA, not a second container. Postgres is optional, not mandatory.

**Resource footprint (primary-source only).** No official idle RAM/CPU figures. Positioning: “Lightweight binary … minimal configuration” on the marketing site ([dexidp.io](https://dexidp.io/)); architecture is one process + pluggable storage. Do not treat third-party “Dex uses N MB” posts as evidence.

**Auth / identity.** **Delegates login** in the normal case (connectors). Optional **local** users via `enablePasswordDB: true` (credentials in Dex storage) ([local connector](https://dexidp.io/docs/connectors/local/)). Static clients can live in the YAML; a gRPC API exists for runtime client management ([getting started](https://dexidp.io/docs/getting-started/)).

**Feature surface vs bloat.** Core is OIDC issuance + connectors + storage. No admin UI product, no MFA suite, no workflow engine. Login screens are Dex’s own templates (customizable) ([templates](https://dexidp.io/docs/guides/templates/)). SAML connector is documented as unmaintained / likely vulnerable — avoid that connector ([README](https://github.com/dexidp/dex/blob/master/README.md)).

**Operational fit (Quadlet / Host Volume).** One long-lived container, one config file, optional SQLite file on the Host Volume. No sibling DB required for the SQLite path. Docs are Kubernetes-heavy; the image is a normal OCI image Podman can run. No first-party Quadlet file found (unlike Pocket ID).

**Deal-breakers for this use case.** None for “lightweight OIDC issuer.” Caveats: SQLite is explicitly not “production workload” storage in Dex’s own words; local password DB is a connector, not a full user-admin product; if you need passkeys/MFA as the IdP, Dex is the wrong shape.

---

### 2. Pocket ID (`ghcr.io/pocket-id/pocket-id` / `pocketid/pocket-id`)

**What it is.** “An easy-to-use OpenID Connect Certified™ and OAuth 2.0 provider that lets users sign in to your applications with passkeys.” Goal: simpler than Keycloak or Ory Hydra for simple use cases; **passkey-only** (no passwords) ([README](https://github.com/pocket-id/pocket-id), [site](https://pocket-id.org/)). Language: **Go** (frontend is bundled into the binary). License: **BSD-2-Clause**. Ownership: pocket-id org. Created 2024-08; not CNCF.

**Maintenance / reputation.** Recent releases: **v2.13.0** (2026-08-07), **v2.12.0** (2026-07-29), monthly cadence through 2026 ([GitHub releases](https://github.com/pocket-id/pocket-id/releases)). Active `main` through 2026-08-17. OpenID Certified™ is a first-party claim on the README and site. Reputation is “established homelab/self-host IdP with a clear owner and rapid 2025–2026 releases,” not a CNCF/Linux Foundation project. That is weaker than Dex on criterion 4, stronger than one-maintainer 2026 toys.

**Protocol surface.** OIDC discovery and standard client registration in the admin UI. First-party client-metadata docs list grant types **`authorization_code`**, **`refresh_token`**, and **device code** (`urn:ietf:params:oauth:grant-type:device_code`); PKCE is enabled automatically for public CIMD clients ([client ID metadata documents](https://pocket-id.org/docs/guides/client-id-metadata-documents)). App guides require PKCE for public clients and support confidential clients with a secret (e.g. Harbor) ([Harbor](https://pocket-id.org/docs/client-examples/harbor), [OpenCloud](https://pocket-id.org/docs/client-examples/opencloud)).

**How to run.** Official recommended path is Docker Compose from first-party files ([install](https://pocket-id.org/docs/setup/installation)):

```yaml
services:
  pocket-id:
    image: pocketid/pocket-id:v2  # or ghcr.io/pocket-id/pocket-id:v2
    restart: unless-stopped
    env_file: .env
    ports:
      - 1411:1411
    volumes:
      - "./data:/app/data"
```

([docker-compose.yml](https://raw.githubusercontent.com/pocket-id/pocket-id/main/docker-compose.yml)). Standalone: download `pocket-id-linux-amd64` from GitHub Releases, `./pocket-id` ([install](https://pocket-id.org/docs/setup/installation)). Requires **HTTPS** (WebAuthn) ([install](https://pocket-id.org/docs/setup/installation)). First-party **rootless Podman Quadlet** unit example: `Image=ghcr.io/pocket-id/pocket-id:v2`, `Volume=pocket-id:/app/data:Z`, port 1411 ([install — Podman + Quadlet](https://pocket-id.org/docs/setup/installation)).

**Persistence.** Default **SQLite** at `data/pocket-id.db`; provider inferred from `DB_CONNECTION_STRING`. PostgreSQL is optional. First-party caution: do not put SQLite on NFS/SMB ([environment variables](https://pocket-id.org/docs/configuration/environment-variables)). Bind-mount `/app/data` onto the Host Volume.

**Resource footprint (primary-source only).** No official idle RAM/CPU figures. Site testimonials claiming “few resources” are **not** vendor measurements — ignored here.

**Auth / identity.** **Stores users itself** (admin UI, signup links, open registration, optional LDAP **sync** into Pocket ID) ([site](https://pocket-id.org/docs/setup/introduction)). Login is passkeys; one-time login codes exist for another device without a passkey ([site](https://pocket-id.org/docs/setup/introduction)). This is the opposite of Hydra: identity lives in the Component.

**Feature surface vs bloat.** Admin UI, groups, LDAP sync, REST API, audit logs, mail notifications, i18n. Still a single process. Not a SAML/RADIUS/PAM IDM. Passkey-only is a product constraint, not optional.

**Operational fit.** Strongest Quadlet story in this note: official `.container` snippet, one volume, one image tag `v2`. Edge would terminate TLS in front (WebAuthn needs HTTPS). Rootless: install docs mention PUID/PGID in community compose; official Quadlet example uses a named volume.

**Deal-breakers.** Passwords are not a login method — operators without passkeys cannot use it as intended. Younger than Dex/Hydra; BSD-2-Clause and rapid releases, but not CNCF. SQLite-on-network-fs is unsupported.

---

### 3. Ory Hydra (`oryd/hydra`)

**What it is.** “A hardened, OpenID Certified OAuth 2.0 Server and OpenID Connect Provider” that **connects to your existing identity provider through a login and consent app** ([README](https://github.com/ory/hydra/blob/master/README.md)). Headless AS/OP: it stores OAuth2 clients, consent sessions, and tokens — **not users**. Language: **Go**. License: Apache-2.0. Ownership: Ory Corp. Self-host OSS or Ory Network SaaS (SaaS out of scope).

**Maintenance / reputation.** Created 2015; 17k+ GitHub stars. Recent OSS tags: **v26.2.0** (2026-03-20), **v25.4.0** (2025-11-07), after a jump from **v2.3.0** (2025-01-17) ([GitHub releases](https://github.com/ory/hydra/releases)). `main` pushes through 2026-07. Not CNCF. README claims production use and OpenID Certified™. Binaries on the v26.2.0 release are ~13–16 MB compressed tarballs, including dedicated `*_sqlite_*` and `*_static-nosqlite_*` artifacts ([v26.2.0 assets](https://github.com/ory/hydra/releases/tag/v26.2.0)). README: binaries “small (5-15MB)” with no Java/Node runtime ([README](https://github.com/ory/hydra/blob/master/README.md)).

**Protocol surface.** OAuth2 + OIDC. Official CLI can perform **authorization code**, **client credentials**, and **device code** ([hydra perform](https://www.ory.com/docs/hydra/cli/hydra-perform)). Client-create examples include grant types `authorization_code`, `refresh_token`, `client_credentials`, `implicit` and response types `token,code,id_token`; scopes `openid` / `offline` ([configure-deploy](https://www.ory.com/docs/hydra/self-hosted/configure-deploy), [oauth2-clients](https://www.ory.com/docs/hydra/guides/oauth2-clients)). Public clients use **PKCE** (no secret) ([oauth2-clients](https://www.ory.com/docs/hydra/guides/oauth2-clients)).

**How to run.** Official Docker Hub image `oryd/hydra` ([configure-deploy](https://www.ory.com/docs/hydra/self-hosted/configure-deploy)). Pattern:

```text
docker run … oryd/hydra:<tag> migrate sql --yes $DSN
docker run -p 4444:4444 -p 4445:4445 \
  -e DSN=$DSN -e SECRETS_SYSTEM=$SECRETS_SYSTEM \
  -e URLS_SELF_ISSUER=https://… \
  -e URLS_LOGIN=http://…/login -e URLS_CONSENT=http://…/consent \
  oryd/hydra:<tag> serve all
```

Public API **:4444**, admin API **:4445**. `hydra serve all` is the recommended process ([serve.go](https://github.com/ory/hydra/blob/master/cmd/serve.go)). GitHub Releases ship OS/arch tarballs including SQLite builds ([v26.2.0](https://github.com/ory/hydra/releases/tag/v26.2.0)). Quickstart compose uses SQLite plus a **separate** `oryd/hydra-login-consent-node` container ([quickstart.yml](https://github.com/ory/hydra/blob/master/quickstart.yml)).

**Persistence.** Hydra **requires a database** for clients, consent sessions, and tokens ([dependencies](https://www.ory.com/docs/hydra/self-hosted/dependencies-environment)):

- `DSN=memory` — ephemeral SQLite; data lost on restart; single instance
- SQL: PostgreSQL 12+, MySQL 8+, CockroachDB, **SQLite** (`DSN=sqlite:///path/to/hydra.sqlite?_fk=true`)
- Migrations are mandatory (`hydra migrate sql -e`)

SQLite is first-party. Ory maintainers treat SQLite as **dev-oriented** (CGO images; “doesn't scale and can't handle competing transactions”) ([issue #3918](https://github.com/ory/hydra/issues/3918)) — same class of warning as Dex, not a missing driver.

**Resource footprint (primary-source only).** README: “optimized for low-latency, high throughput, and **low resource consumption**”; binary size 5–15 MB ([README](https://github.com/ory/hydra/blob/master/README.md)). Official [performance benchmarks](https://www.ory.com/docs/performance/hydra) exist; this fetch timed out — not quoted here. No idle RSS in the sources successfully retrieved.

**Auth / identity.** **Does not store users.** Login and consent URLs are **required** for the documented user-facing setup (`URLS_LOGIN`, `URLS_CONSENT`) ([configure-deploy](https://www.ory.com/docs/hydra/self-hosted/configure-deploy)). Reference UI: [ory/hydra-login-consent-node](https://github.com/ory/hydra-login-consent-node). Identity can be Ory Kratos or anything the bridge app calls — that is a **second Component**, not Hydra. **Client credentials** does not need that UI ([README client-credentials demo](https://github.com/ory/hydra/blob/master/README.md)). Admin API is unauthenticated unless you put a gateway in front — first-party warning ([enterprise install page restates the OSS API warning](https://www.ory.com/docs/hydra/self-hosted/install)).

**Feature surface vs bloat.** Protocol AS/OP, client admin API, JWKS, token lifecycle. No user directory, no MFA product, no admin console for humans (CLI/API). That is the point — and the operational cost (you must supply login/consent for authorization-code).

**Operational fit.** One Hydra container + bind-mounted SQLite (or `memory` for throwaway) matches a Quadlet **if** the job is headless tokens. User-facing OIDC login is **two** containers unless the login/consent UI is a Workload. Admin port 4445 must not be on the public Edge.

**Deal-breakers.** “One Component that logs humans in via OIDC” is **not** Hydra alone. Combining Hydra + Kratos + UI is the Ory stack, not a lightweight AS. SQLite/memory are first-party but not what Ory documents as the production DSN. OSS vs Enterprise image tags are easy to mix up — this note is OSS `oryd/hydra` / GitHub binaries, not the private OEL registry.

---

## Side-by-side (Tier A)

| Dimension | Dex | Pocket ID | Ory Hydra |
| --- | --- | --- | --- |
| Language | Go | Go | Go |
| License | Apache-2.0 | BSD-2-Clause | Apache-2.0 |
| CNCF | Sandbox (2020) | No | No |
| Role | Federating OIDC IdP | Passkey OIDC IdP (stores users) | Headless AS/OP |
| Users | Connectors / optional local password DB | Built-in (passkeys) | None (bridge app) |
| Wire | OIDC + OAuth2 grants incl. device + token exchange | OIDC + OAuth2; auth code, refresh, device; PKCE | OIDC + OAuth2; auth code, CC, device, refresh; PKCE |
| Official image | `ghcr.io/dexidp/dex` | `ghcr.io/pocket-id/pocket-id:v2` | `oryd/hydra` |
| Config | One YAML | Env file | YAML / env (`DSN`, `URLS_*`) |
| Persistence | SQLite (quick), memory, etcd, k8s, SQL | SQLite default; optional Postgres | `memory`, SQLite, Postgres/MySQL/CRDB |
| Sibling processes | No | No | Login/consent app for user grants |
| Quadlet docs | No (plain OCI image) | **Yes** (first-party) | No (plain OCI image) |
| Idle RSS | Not published | Not published | Not published (binary size only) |

---

## Tier B — reputable, one-container-ish, not the minimal API

### Authelia (OIDC provider mode)

**What it is.** “The Single Sign-On Multi-Factor portal for web apps, now OpenID Certified™” ([GitHub](https://github.com/authelia/authelia)). Architecture docs: a **companion of reverse proxies** providing authentication; payloads of protected apps never hit Authelia ([architecture](https://www.authelia.com/overview/prologue/architecture/)). Separately, it can act as an **OpenID Connect 1.0 Provider** (docs still call this an **open beta** feature, while also stating OpenID Certified™ for Basic/Implicit/Hybrid/Form Post/Config OP profiles) ([OIDC introduction](https://www.authelia.com/integration/openid-connect/introduction/), [OIDC provider config](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/)). Language: **Go**. License: Apache-2.0.

**Maintenance.** **v4.39.20** (2026-05-26) and frequent 2026 patch releases ([GitHub releases](https://github.com/authelia/authelia/releases)). Images: `authelia/authelia`, `docker.io/authelia/authelia`, `ghcr.io/authelia/authelia` ([Docker](https://www.authelia.com/integration/deployment/docker/)).

**Protocol.** Grants: authorization_code, client_credentials, implicit (deprecated), refresh_token, device_code; **not** password or token-exchange. PKCE enforceable (`enforce_pkce: public_clients_only`) ([OIDC introduction](https://www.authelia.com/integration/openid-connect/introduction/), [provider config](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/)).

**Persistence.** First-party **SQLite** (`storage.local.path`), documented as leaving Authelia stateful and **not** for multi-instance/HA; Postgres/MySQL for that ([SQLite](https://www.authelia.com/configuration/storage/sqlite/)). Official standalone Compose examples in the Docker guide **assume PostgreSQL** ([Docker](https://www.authelia.com/integration/deployment/docker/)).

**Identity.** File user backend (`users.yml`) or LDAP ([file backend](https://www.authelia.com/configuration/first-factor/file/)). Stores users (file) or delegates (LDAP). Plus TOTP, WebAuthn, regulation, password reset — a **portal/MFA product**.

**Why Tier B, not A.** Criterion 2 (minimal API) and 3 (simplicity): the primary job is reverse-proxy SSO ([supported proxies](https://www.authelia.com/overview/prologue/supported-proxies/)). Using it “only as an OP” still ships that portal surface and OIDC-as-beta wording. One container + SQLite *can* work on a Host Volume; it is not the smallest AS.

No official idle RSS.

### Kanidm

**What it is.** “A simple, secure, and fast identity management platform” with **OAuth2/OIDC authentication provider**, application portal, Unix/PAM, SSH keys, RADIUS, read-only LDAPS, CLI, WebUI ([kanidm.com](https://kanidm.com/), [README](https://github.com/kanidm/kanidm)). Language: **Rust**. License: **MPL-2.0**.

**Maintenance.** **v1.11.1** (2026-08-14), **v1.11.0** (2026-08-02) ([GitHub releases](https://github.com/kanidm/kanidm/releases)). Active 2026.

**How to run.** Official evaluation: `docker.io/kanidm/server:latest`, volume `/data`, ports 8443 (HTTPS) and 3636 (LDAPS) ([evaluation quickstart](https://kanidm.github.io/kanidm/stable/evaluation_quickstart.html)):

```text
docker volume create kanidmd
docker create --name kanidmd -p '443:8443' -p '636:3636' -v kanidmd:/data docker.io/kanidm/server:latest
docker cp server.toml kanidmd:/data/server.toml
docker start kanidmd
```

**Persistence.** Own DB on **SQLite as a durable key-value store** (`db_path = "/data/kanidm.db"`). **Cannot** swap in Postgres; doing so would break the cache/replication model ([FAQ](https://kanidm.github.io/kanidm/stable/frequently_asked_questions.html)).

**Protocol.** OAuth2 + OIDC; PKCE S256 required by default; ID tokens ES256; RFC 9068 JWTs; confidential and public clients; device-style native localhost redirects documented ([OAuth2 chapter](https://kanidm.github.io/kanidm/stable/integrations/oauth2.html)).

**Identity.** **Stores users itself** (full IDM). OAuth2 clients configured via `kanidm` CLI.

**Why Tier B.** Criterion 2: this is an IDM suite (LDAP/RADIUS/PAM/SSH/portal), not a minimal AS. Criterion 1/3 still look good: one container, one DB file, Rust. No official idle RSS.

---

## Screened and dismissed

### Keycloak (CNCF Incubating) — too heavy

Open-source IAM; OIDC/SAML ([CNCF Keycloak](https://www.cncf.io/projects/keycloak/), accepted **2023-04-10** Incubating). Image `quay.io/keycloak/keycloak`; `start-dev` for development; production `start` with `--db=postgres` ([containers](https://www.keycloak.org/server/containers)). Production `db` default `dev-file` is **deprecated** — specify a real vendor ([containers — db option](https://www.keycloak.org/server/containers)). Vendor memory: always set a container memory limit; to approach the old 512 MB heap, limit **at least 750 MB**; “smaller production-ready deployments” recommended limit **2 GB**. HA sizing doc: base pod memory **1250 MB** including 10k sessions ([containers](https://www.keycloak.org/server/containers), [CPU/memory sizing](https://www.keycloak.org/high-availability/single-cluster/concepts-memory-and-cpu-sizing)). JVM + production Postgres + admin/realm model = control plane, not a lightweight Component.

### Authentik — compose stack

“The authentication glue you need” ([GitHub](https://github.com/goauthentik/authentik)). Docker Compose install: **at least 2 CPU cores and 2 GB of RAM**; Podman or Compose; Postgres password + `AUTHENTIK_SECRET_KEY` ([Compose install](https://docs.goauthentik.io/install-config/install/docker-compose/)). Worker + Docker socket mount for outposts. Redis **removed** as of 2025.10 (tasks/cache/WebSocket on Postgres) ([release 2025.10](https://docs.goauthentik.io/releases/2025.10/)). Latest non-prerelease observed: **version/2026.5.6** (2026-07-22). Main tree MIT with enterprise/website exceptions ([LICENSE](https://raw.githubusercontent.com/goauthentik/authentik/main/LICENSE)). Full IdP (OIDC, SAML, LDAP, proxy outposts) — fails footprint and minimal API. Official compose.yml fetch from docs.goauthentik.io returned 500 during this research — architecture claims taken from the install page and 2025.10 notes, not from a locally retrieved compose file.

### ZITADEL — IAM + Postgres

Go IAM. Deploy docs: test env “**1 CPU and 512MB memory** are more than enough”; **PostgreSQL instance required** ([deploy overview](https://zitadel.com/docs/self-hosting/deploy/overview)). Compose guide: machine with **at least 2 GB RAM**; stack Traefik → ZITADEL API + **Login (Next.js)** → PostgreSQL ([compose](https://zitadel.com/docs/self-hosting/deploy/compose)). Image `ghcr.io/zitadel/zitadel`; `start-from-init`. License **AGPL-3.0**. Recent **v4.17.1** (2026-08-14). Real AS/OP, wrong weight class.

### Logto — Node IAM, 8 GiB floor

TypeScript IAM on OIDC/OAuth 2.1 ([GitHub](https://github.com/logto-io/logto)). OSS get-started: **minimum recommended hardware vCPU 2, memory 8 GiB, disk 256 GiB**; `DB_URL` Postgres DSN; image `ghcr.io/logto-io/logto` ([get started](https://docs.logto.io/logto-oss/get-started-with-oss), [deploy](https://docs.logto.io/logto-oss/deployment-and-configuration)). Compose quickstart bundles Postgres and is **not** for production. License MPL-2.0. **v1.42.0** (2026-07-30). Fails criterion 1 on vendor floor alone.

### FusionAuth community — JVM CIAM

Requires PostgreSQL 14+ (MySQL possible, not primary-tested) ([system requirements](https://fusionauth.io/docs/get-started/download-and-install/reference/system-requirements)). Image `fusionauth/fusionauth-app` requires PostgreSQL; Elasticsearch/OpenSearch optional ([Docker Hub](https://hub.docker.com/r/fusionauth/fusionauth-app), [docker install](https://fusionauth.io/docs/get-started/download-and-install/docker)). Example env `FUSIONAUTH_APP_MEMORY=512M` is a **JVM heap setting**, not a Host minimum. Full CIAM + optional search = heavy.

### Casdoor — UI-first IAM (SQLite possible, not minimal)

“UI-first identity provider and access management platform” ([README](https://github.com/casdoor/casdoor)). Go + React console. Databases via XORM include **SQLite 3**, MySQL, Postgres, … ([server installation](https://casdoor.github.io/docs/basic/server-installation/)). `docker run -p 8000:8000 casbin/casdoor-all-in-one` is a quick trial. License Apache-2.0. Hyper-frequent tags (e.g. **v3.154.3** 2026-08-16). Fails criterion 2 (IAM/SSO/MCP console), not the “no SQLite” test.

### supabase/auth (GoTrue) — user/JWT API, not a standalone AS

“A JWT based API for managing users and issuing JWT tokens” ([GitHub](https://github.com/supabase/auth)). MIT, Go. Latest non-RC observed **v2.195.0** (2026-08-03). Supabase Auth can act as an **OAuth 2.1 / OIDC identity provider** *inside a Supabase project* (authorization code + PKCE, discovery, JWKS) ([OAuth 2.1 Server](https://supabase.com/docs/guides/auth/oauth-server)). That is a feature of the Auth product + Postgres, plus a custom consent UI the operator must implement ([getting started](https://supabase.com/docs/guides/auth/oauth-server/getting-started)). Not a one-container AS Component.

### Cloud Foundry UAA — Java, CF packaging

“CloudFoundry User Account and Authentication (UAA) Server” — Java OAuth2/OIDC ([GitHub](https://github.com/cloudfoundry/uaa)). Apache-2.0. **v79.5.0** (2026-07-24). Real AS; not a small Host Quadlet.

### Janssen Project / Gluu Flex — Java IAM bundle

Janssen Auth Server is a comprehensive OAuth2/OIDC OP (Java Weld, oxAuth lineage) ([Auth Server overview](https://docs.jans.io/v2.0.0/janssen-server/auth-server/)). **v2.3.0** (2026-07-30). Gluu Flex compose: **monolith image packing auth-server, config-api, fido2, casa, scim, admin UI** plus MySQL/Postgres ([Flex compose](https://docs.gluu.org/stable/install/docker-install/compose/)). Enterprise IAM, not one lightweight AS.

### SuperTokens Core — session/auth service

“Open source alternative to Auth0 / Firebase Auth / AWS Cognito” ([GitHub](https://github.com/supertokens/supertokens-core)). Java. Self-host: Docker `supertokens/supertokens-postgresql`; **PostgreSQL 13+**; in-memory if no DB env ([self-host](https://supertokens.com/docs/deployment/self-host-supertokens), [Docker Hub](https://hub.docker.com/r/supertokens/supertokens-postgresql)). Core is consumed by **backend SDKs**, not presented as a standalone OAuth2 AS for third-party clients. **v12.1.1** (2026-08-13). Wrong job.

### Hanko — passkey CIAM, OIDC *client*

Go backend, AGPL-3.0 ([README](https://github.com/teamhanko/hanko/blob/main/README.md)). OAuth/OIDC support is **third-party provider login** (authorization code to Google/etc., or custom IdPs via discovery) ([backend README](https://github.com/teamhanko/hanko/blob/main/backend/README.md)). Hanko is a **Relying Party / user API**, not an Authorization Server. **backend/v3.0.4** (2026-07-27).

### HashiCorp Vault / OpenBao — secrets product with an OIDC feature

Vault and OpenBao “are an OpenID Connect (OIDC) identity provider” so apps can use **Vault/OpenBao’s identities and auth methods** ([Vault OIDC IdP](https://developer.hashicorp.com/vault/docs/secrets/identity/oidc-provider), [OpenBao OIDC IdP](https://openbao.org/docs/secrets/identity/oidc-provider/)). Flow supported: **authorization code** only. This is a feature of a secrets manager, not an OAuth2 AS Component. Wrong job (and a large operational surface).

### Forward-auth / identity-aware proxies — wrong job

| Product | First-party job |
| --- | --- |
| [oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy) | “A reverse proxy that provides authentication with Google, Azure, OpenID Connect and many more identity providers.” MIT, Go. **v7.15.3** (2026-06-09). |
| [vouch-proxy](https://github.com/vouch/vouch-proxy) | “SSO and OAuth / OIDC login solution for Nginx using the auth_request module.” MIT, Go. |
| [Pomerium](https://github.com/pomerium/pomerium) | “Identity and context-aware access proxy.” Apache-2.0, Go. **v0.33.0** (2026-07-16). |
| Traefik Forward Auth / Caddy security plugins | Proxy middleware; not an AS. |
| [Tinyauth](https://tinyauth.app/) | Getting started is **Traefik `forwardauth`** ([getting started](https://tinyauth.app/docs/getting-started/)). Since **v5.1.0** it is also an **OpenID Connect™ Certified** server with `/data` persistence ([OIDC server](https://tinyauth.app/docs/guides/oidc/)). Image `ghcr.io/tinyauthapp/tinyauth:v5`. Go, **AGPL-3.0**, **v5.1.3** (2026-07-30), [tinyauthapp/tinyauth](https://github.com/tinyauthapp/tinyauth). Dual-role: still the wrong *primary* job for “just an AS”; do not treat the getting-started compose as an AS. |

Ory Oathkeeper is an identity-aware proxy in the Ory ecosystem ([Hydra README ecosystem](https://github.com/ory/hydra/blob/master/README.md)) — same wrong job.

### Libraries — not a server

No official “run this one binary as your AS” product (unless you wrap them yourself — out of scope):

- [ory/fosite](https://github.com/ory/fosite) — “OAuth 2.0 and OpenID Connect SDK for Go.” Hydra is the server built on this family. Latest observed tag **v0.49.0** (2024-12-12).
- [go-oauth2/oauth2](https://github.com/go-oauth2/oauth2) — OAuth 2.0 **library**. **v4.5.4** (2025-08-20).
- [panva/node-oidc-provider](https://github.com/panva/node-oidc-provider) — Certified Node **implementation you embed**. **v9.11.3** (2026-08-08).
- Spring Authorization Server, OpenIddict, Duende IdentityServer — application frameworks, not a Propraetor image.
- Authlib — Python library.

### Cierge — abandoned (name collision)

The OAuth2-relevant **Cierge** was a .NET passwordless OIDC server (OpenIddict, magic links) with homepage `cierge.biarity.me`. LibHunt marks that homepage **discontinued**; GitHub `PwdLess/Cierge` **404**; surviving forks show **~2018** history ([ConceptFirst/Cierge](https://github.com/ConceptFirst/Cierge)). **Not verified as maintained in 2025–2026.** Unrelated: `daylamtayari/Cierge` is a restaurant-booking app, not an OP.

### Other 2025–2026 single-binary OIDC leads (skipped)

GitHub search surfaced **autentico**, **sui-id**, and **gtid**: single binary + SQLite OIDC IdPs. They match the *shape* of Pocket ID/Dex and fail criterion 4 (no CNCF/established org, not used as a comparison baseline here). Tinyauth’s OIDC mode is the only extra 2026 certified OP that is both small and widely starred — still classified as forward-auth-first above.

Ory **Kratos** is identity/user management, not an AS ([Hydra README ecosystem](https://github.com/ory/hydra/blob/master/README.md)). **LLDAP** is an LDAP directory, not OAuth2.

---

## Resource evidence policy (repeat)

- Keycloak’s “750 MB / 2 GB container limit,” Authentik’s “2 GB RAM,” ZITADEL’s “512 MB test / 2 GB compose,” and Logto’s “8 GiB” are **vendor deployment floors**, not idle RSS of Dex/Pocket ID/Hydra.
- Binary or image compressed size ≠ runtime memory. Hydra’s 5–15 MB binary claim is size-on-disk of the artifact.
- SQLite “not for production” warnings (Dex, Hydra, Authelia HA) are **concurrency/HA** statements. A single Quadlet on one Host is the Dex “stand up quickly” case; it is not a license to ignore lock/WAL behavior on a Host Volume.
- Prefer a Propraetor Host experiment (cgroup memory/CPU for `ghcr.io/dexidp/dex` vs `ghcr.io/pocket-id/pocket-id:v2` vs `oryd/hydra` + SQLite, idle + one authorization-code) before ranking Tier A on footprint alone.

---

## Gaps / what primary sources do not say

- **Idle RSS/CPU** for Dex, Pocket ID, Hydra, Authelia, Kanidm: not published in the docs retrieved. Hydra’s [performance](https://www.ory.com/docs/performance/hydra) page timed out in this research pass — do not invent numbers from blogs.
- **OpenID Certification** listings were not re-fetched row-by-row from [openid.net/certification](https://openid.net/certification/); Certified™ claims are taken from first-party project pages (Hydra, Pocket ID, Authelia, Tinyauth). Dex does not lead with a Certified™ badge in the README retrieved.
- **Dex image tag matrix** (alpine vs distroless vs Docker Hub names) is described in getting-started HTML that truncated in fetch; GHCR `ghcr.io/dexidp/dex` is confirmed first-party ([templates](https://dexidp.io/docs/guides/templates/), [releases process](https://dexidp.io/docs/development/releases/)).
- **Authentik official `compose.yml`** could not be retrieved (HTTP 500). Service list inferred from install + 2025.10 notes.
- **Cierge** original canonical repository could not be verified (404). Abandoned conclusion is from forks + discontinued homepage, not from a living first-party tree.
- **Hydra Docker tag vs SQLite**: GitHub ships `*_sqlite_*` binaries; which `oryd/hydra` tags include CGO/SQLite in 2026 was not fully mapped beyond v2.x maintainer comments and v26.2.0 asset names. An operator enabling `DSN=sqlite://…` must use a SQLite-enabled artifact.
- **Pocket ID encryption-key requirement** across v1→v2 is documented in env docs; this note does not reproduce secret values. Confirm current required env from [environment variables](https://pocket-id.org/docs/configuration/environment-variables) at pin time.
- **Rootless Podman** specifics (UID 1000, `:Z` labels) are first-party only for Pocket ID’s Quadlet snippet. Dex/Hydra/Authelia/Kanidm are “plain OCI images” unless the operator writes the Quadlet.

---

## Implications for Propraetor

A Component that wraps an existing OAuth2/OIDC **server** looks **viable in shape**: Dex and Pocket ID are single-container OPs with filesystem/SQLite state that can bind-mount under Host Volume `components/<name>/persist/` and sit on the Service Network, with Edge terminating TLS. Hydra is the same *process* shape for a headless AS, with a second login/consent process if humans use authorization-code.

**Strongest fit for low footprint + minimal API + simplicity + Go + reputation:** **Dex** as the CNCF, one-YAML, connector-style OIDC issuer (SQLite acceptable for a solo Host with eyes open). **Pocket ID** as the peer when the operator wants users and passkeys in-process and a first-party Quadlet. **Hydra** when the Component must be a headless AS and login is already someone else’s problem (or client-credentials only).

This is research, not a decision to add a Component.
