# Pocket ID admin API: OIDC client CRUD

**Researched:** 2026-08-19  
**Question:** How does a Propraetor Component Setup script authenticate to Pocket ID and then **create, update, list, get, and delete OIDC clients** via the admin HTTP API?  
**Scope:** Pocket ID's **admin** HTTP API for OIDC client management — create, read, update, delete clients, set callback URLs, configure PKCE/public flags, group restriction, token lifetimes, and allowed scopes. Auth mechanism is cited only to the extent needed. OAuth resource-server ("APIs") management is covered separately in `pocket-id-apis-admin.md`.  
**Method:** Primary sources only — official docs ([API Reference](https://pocket-id.org/docs/api), [environment variables](https://pocket-id.org/docs/configuration/environment-variables)), first-party OpenAPI ([swagger.yaml](https://pocket-id.org/swagger.yaml)), GitHub source of [pocket-id/pocket-id](https://github.com/pocket-id/pocket-id) pinned to tag **v2.13.0** (`f39f59e9e0dcf0957c83872e60093cebb90ca596`, 2026-08-07), and PR [#864](https://github.com/pocket-id/pocket-id/pull/864) for custom client IDs. Website markdown from [pocket-id/website](https://github.com/pocket-id/website). Secondary blogs unused.

Source pin for code citations below: [`v2.13.0`](https://github.com/pocket-id/pocket-id/tree/v2.13.0) = `f39f59e9e0dcf0957c83872e60093cebb90ca596`. Line links use that tag.

---

## Verdict

A Setup script authenticates as an **admin user** with header **`X-API-Key`** (same mechanism as the APIs surface; see `pocket-id-apis-admin.md` §1). All OIDC client routes use the default `authMiddleware.Add()` which requires admin + allows API key auth ([`oidc_controller.go` route registration](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/controller/oidc_controller.go)).

**1 — Client ID charset:** Custom client IDs are validated by regex `^[a-zA-Z0-9._-]+$`, min 2, max 128 characters ([`validations.go` `validateClientIDRegex`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/validations.go), [`oidc_dto.go` `OidcClientCreateDto.ID`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/oidc_dto.go)). **Dots (`.`) are accepted.** Alphanumerics, dots, underscores, and hyphens only. The frontend Zod schema is stricter (`^[a-zA-Z0-9_-]+$`, excludes dots) — this is a frontend-only discrepancy; the backend is authoritative. Workload basenames using `.` will pass backend validation. If the ID field is omitted or empty, a UUID is auto-assigned by `Base.BeforeCreate` ([`model/base.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/model/base.go)). Duplicate client ID on create → `ClientIDAlreadyExists()` → **HTTP 409** Conflict ([`oidc_service.go` `CreateClient`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go), [`constructors.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apperror/constructors.go)).

**2 — Group restriction default:** The `IsGroupRestricted` field is a plain `bool` on the model, defaulting to Go's zero value **`false`** ([`model/oidc.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/model/oidc.go)). The **API** therefore defaults to **not group-restricted** when the field is omitted from the create body. The frontend UI form hard-codes `isGroupRestricted: existingClient?.isGroupRestricted ?? true` — so UI-created clients default to restricted, but API-created clients with `isGroupRestricted` omitted or `false` are **unrestricted** ([`oidc-client-form.svelte` `onSubmit`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/admin/oidc-clients/oidc-client-form.svelte)). A Setup script that omits `isGroupRestricted` gets an **unrestricted** client — no hidden human gate.

**3 — Upsert/list/delete semantics:** There is **no upsert** endpoint. There is **no get-by-name**. `GET /api/oidc/clients/:id` looks up by the client's primary key ID (which is the custom client ID if one was supplied at create time) ([`oidc_service.go` `getClientInternal`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)). Gather pattern: if the Setup script assigned a known custom client ID, it can **GET by that ID directly** — no list+filter needed. List is `GET /api/oidc/clients` with `search` (name `LIKE`), paginated (limit capped at 100). Delete is hard-delete (`DELETE /api/oidc/clients/:id` → 204); cascading deletes OAuth2 sessions ([`oidc_service_test.go` `TestOidcService_DeleteClientDeletesOAuth2Sessions`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service_test.go)). Not-found → 404.

**4 — Callback URL handling:** Callback URLs (`callbackURLs`, `logoutCallbackURLs`) are **full replace** arrays on every `PUT`. Validation: `callback_url_pattern` — `ValidateCallbackURLPattern` rejects `javascript:` and `data:` schemes but otherwise accepts any URL including wildcards ([`validations.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/validations.go)). There is no append-only mode. An update with an empty array clears all callback URLs.

**5 — PKCE / public client flags:** Both `isPublic` and `pkceEnabled` are fields on the create/update DTO. Service logic: `client.PkceEnabled = input.IsPublic || input.PkceEnabled` — **PKCE is forced on for public clients** ([`oidc_service.go` `updateOIDCClientModelFromDto`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)). A client can be created as public + PKCE-required (the combination is enforced). Defaults when omitted: both `false` (Go zero values). `PkceSupported` is a read-only diagnostic flag, not settable via create.

**6 — Client scope / allowed scopes:** There is **no per-client scope allow-list field** in the OIDC client CRUD API. Every client gets the fixed set `openid, profile, email, groups, offline_access` plus any scopes from OAuth API access grants ([`oidc/client.go` `GetScopes`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/client.go)). API-level scope grants are managed separately via `PUT /api/api-access/{clientId}` (see `pocket-id-apis-admin.md`).

**7 — Access token duration:** Per-client `accessTokenDurationMinutes` and `refreshTokenDurationMinutes` are settable on create/update. Default 60 min (access) / 43200 min = 30 days (refresh). Range: 1–525600 min (1 year). Zero or omitted → falls back to default. Validation: `token_duration` custom validator using `model.IsValidTokenDurationMinutes` ([`oidc_dto.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/oidc_dto.go), [`model/oidc.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/model/oidc.go), [`oidc_service.go` `updateOIDCClientModelFromDto`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)). These durations are consumed by `Client.GetEffectiveLifespan` on token issuance ([`oidc/client.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/client.go)).

**8 — Other relevant fields:** `description` (optional, max 150, NFC), `skipConsent` (bool, skip user consent screen), `requiresReauthentication` (bool), `requiresPushedAuthorizationRequests` (bool, PAR), `launchURL` (optional URL, app launcher), `credentials.federatedIdentities` (array of issuer/subject/audience/jwks for federated client auth), `logoUrl`/`darkLogoUrl` (download-on-create logo from URL). Client secret: generated via separate `POST /api/oidc/clients/:id/secret` endpoint, not part of create/update body. Allowed user groups: separate `PUT /api/oidc/clients/:id/allowed-user-groups` endpoint.

---

## 1. Auth

Same `X-API-Key` header mechanism documented in `pocket-id-apis-admin.md` §1. All OIDC client routes use `authMiddleware.Add()` — admin required, API key allowed ([`oidc_controller.go` `NewOidcController`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/controller/oidc_controller.go)). Exception: `GET /api/oidc/clients/:id/meta` has **no** auth middleware (public metadata endpoint). Exception: `GET /api/oidc/users/me/*` and `DELETE /api/oidc/users/me/*` use `WithAdminNotRequired()`.

---

## 2. Client ID: charset, length, uniqueness

### Custom client IDs (PR #864)

`OidcClientCreateDto` has an optional `ID` field: `binding:"omitempty,client_id,min=2,max=128"` ([`oidc_dto.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/oidc_dto.go)).

`client_id` validator calls `ValidateClientID` which checks against `validateClientIDRegex` = `^[a-zA-Z0-9._-]+$` ([`validations.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/validations.go)).

| Constraint | Value |
| --- | --- |
| Allowed characters | `a-z A-Z 0-9 . _ -` |
| Min length | 2 |
| Max length | 128 |
| Omitted/empty | UUID auto-assigned ([`model/base.go` `BeforeCreate`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/model/base.go)) |

**Frontend discrepancy:** The Svelte form Zod regex is `^[a-zA-Z0-9_-]+$` — excludes dots. The backend accepts dots. This means the API accepts dot-containing IDs that the UI cannot create ([`oidc-client-form.svelte`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/admin/oidc-clients/oidc-client-form.svelte)).

### Uniqueness and duplicate handling

The `ID` column is the primary key (`gorm:"primaryKey;not null"`) ([`model/base.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/model/base.go)). `CreateClient` catches `gorm.ErrDuplicatedKey` → `ClientIDAlreadyExists()` → **HTTP 409** `"Client ID is already in use"` ([`oidc_service.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go), [`constructors.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apperror/constructors.go)).

### Client ID as path parameter

All routes use `:id` which is the client ID itself. CIMD clients (whose IDs are full `https://` URLs) use a `~base64url` encoding in the path — the `ClientIDParamMiddleware` decodes them. Plain client IDs pass through unchanged ([`client_id_param.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/middleware/client_id_param.go)).

---

## 3. Create client

| | |
| --- | --- |
| Method / path | `POST /api/oidc/clients` |
| Success | **201** `OidcClientWithAllowedUserGroupsDto` |
| Body (`OidcClientCreateDto`) | Embeds `OidcClientUpdateDto` + optional `id` (see §2) |

`OidcClientUpdateDto` fields ([`oidc_dto.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/oidc_dto.go)):

| Field | Type | Binding | Default (Go zero) |
| --- | --- | --- | --- |
| `name` | string | required, max 50, NFC | — (required) |
| `description` | string | omitempty, max 150, NFC | `""` |
| `callbackURLs` | `[]string` | omitempty, `callback_url_pattern` | `[]` |
| `logoutCallbackURLs` | `[]string` | omitempty, `callback_url_pattern` | `[]` |
| `isPublic` | bool | — | `false` |
| `pkceEnabled` | bool | — | `false` |
| `requiresReauthentication` | bool | — | `false` |
| `requiresPushedAuthorizationRequests` | bool | — | `false` |
| `skipConsent` | bool | — | `false` |
| `credentials` | object | — | `{ federatedIdentities: [] }` |
| `launchURL` | `*string` | omitempty, url | `null` |
| `isGroupRestricted` | bool | — | `false` |
| `accessTokenDurationMinutes` | int64 | omitempty, `token_duration` | 0 → default 60 |
| `refreshTokenDurationMinutes` | int64 | omitempty, `token_duration` | 0 → default 43200 |
| `logoUrl` | `*string` | omitempty, url | `null` |
| `darkLogoUrl` | `*string` | omitempty, url | `null` |
| `hasLogo` | bool | — | `false` |
| `hasDarkLogo` | bool | — | `false` |

`CreateClient` sets `CreatedByID` to the authenticated user ID. The service copies DTO → model via `updateOIDCClientModelFromDto` ([`oidc_service.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)). No client secret is generated at creation time — a separate `POST /api/oidc/clients/:id/secret` call is needed.

### Token lifetime fallback

`cmp.Or(input.AccessTokenDurationMinutes, model.DefaultAccessTokenDurationMinutes)` — zero is treated as "use default" ([`oidc_service.go` `updateOIDCClientModelFromDto`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)). Tests confirm this ([`oidc_service_test.go` `TestOidcService_CreateClient_tokenLifetimes`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service_test.go)).

### PKCE enforcement for public clients

`client.PkceEnabled = input.IsPublic || input.PkceEnabled` — setting `isPublic: true` forces `pkceEnabled: true` regardless of what was sent ([`oidc_service.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)).

---

## 4. Get / Update / Delete

| Verb | Path | Body | Success |
| --- | --- | --- | --- |
| GET | `/api/oidc/clients/:id` | — | **200** `OidcClientWithAllowedUserGroupsDto` |
| PUT | `/api/oidc/clients/:id` | `OidcClientUpdateDto` (full replace of all fields) | **200** `OidcClientWithAllowedUserGroupsDto` |
| DELETE | `/api/oidc/clients/:id` | — | **204** No Content |
| PATCH | — | — | **No PATCH route** |

Unknown id → `NotFound("OIDC client")` **404** ([`oidc_service.go` `getClientInternal`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)).

### Update is full replace

`PUT` replaces **all** fields in `OidcClientUpdateDto`. There is no partial update. Omitting `callbackURLs` from the update body clears them. The update uses `Save` (full row write) for standard clients ([`oidc_service.go` `UpdateClient`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)).

### Client ID is immutable after create

The `OidcClientUpdateDto` does **not** include an `id` field — only `OidcClientCreateDto` adds it ([`oidc_dto.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/oidc_dto.go)). The client ID cannot be changed after creation.

### IsGroupRestricted on update

If `isGroupRestricted` is set to `false` in the update body, the service **clears all allowed user groups** for that client ([`oidc_service.go` `UpdateClient`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)).

### Delete cascades

Delete uses `DELETE FROM oidc_clients WHERE id = ?` with `clause.Returning`. OAuth2 sessions referencing the client are cascade-deleted by foreign key. Client images are deleted from storage. Tests confirm session cleanup ([`oidc_service_test.go` `TestOidcService_DeleteClientDeletesOAuth2Sessions`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service_test.go)).

---

## 5. List clients (gather)

| | |
| --- | --- |
| Method / path | `GET /api/oidc/clients` |
| Query | `search` (optional, name `LIKE %term%`); `pagination[page]` default 1; `pagination[limit]` default 20 (capped at 100); `sort[column]`; `sort[direction]` default `asc`; filter/sort on `pkceEnabled`, `isGroupRestricted`, `skipConsent`, `requiresReauthentication`, `requiresPushedAuthorizationRequests`, `pkceSupported`, `clientType` |
| Response | `{ data: [...], pagination: { totalPages, totalItems, currentPage, itemsPerPage } }` |

Search is **name only** (`name LIKE ?`), not client ID ([`oidc_service.go` `ListClients`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)). No `search` on `id`.

If the script knows the custom client ID, it should use `GET /api/oidc/clients/:id` directly instead of listing.

---

## 6. Client secret

| | |
| --- | --- |
| Method / path | `POST /api/oidc/clients/:id/secret` |
| Body | Optional `{ "secret": "..." }` — min 16 chars, printascii. Omit to auto-generate a 32-char alphanumeric secret. |
| Success | **200** `{ "secret": "plaintext" }` |
| Public client? | Rejected: `"Cannot create a secret for a public client"` 400 |

Secret is bcrypt-hashed before storage. The plaintext is returned once ([`oidc_service.go` `CreateClientSecret`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)). Each call **replaces** the previous secret. Custom secrets: useful for declarative setups where the secret is pre-generated ([`oidc_dto.go` `OidcClientSecretDto`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/oidc_dto.go)).

---

## 7. Allowed user groups

| | |
| --- | --- |
| Method / path | `PUT /api/oidc/clients/:id/allowed-user-groups` |
| Body | `{ "userGroupIds": ["uuid1", "uuid2"] }` — required field |
| Success | **200** `OidcClientDto` |

This is a **full replace** of the allowed groups list. Unknown group IDs are silently looked up and only existing ones are associated ([`oidc_service.go` `UpdateAllowedUserGroups`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)). This endpoint only matters when `isGroupRestricted: true`.

---

## 8. Callback URL validation

`callback_url_pattern` validator calls `ValidateCallbackURLPattern` which delegates to `utils.ValidateCallbackURLPattern`. The basic `callback_url` validator (`ValidateCallbackURL`) rejects `javascript:` and `data:` schemes but otherwise accepts any parseable URL — `http://localhost:8080/callback`, `https://app.example.com/oauth/callback`, and `myapp://callback` are all valid ([`validations.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/validations.go)). Wildcards in patterns are supported for the pattern variant.

Redirect URI matching at authorization time is handled by fosite's `GetRedirectURIs()` which returns the stored `CallbackURLs` array ([`oidc/client.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/client.go)).

---

## 9. CIMD clients (metadata document clients)

CIMD clients (`clientType: "cimd"`) are registered via OAuth Client ID Metadata Documents. Admin update of a CIMD client is restricted: `updateOIDCClientModelFromDto` returns early for CIMD clients after setting only locally-managed fields (`Description`, `RequiresReauthentication`, `RequiresPushedAuthorizationRequests`, `SkipConsent`, `LaunchURL`, `IsGroupRestricted`, token lifetimes). Name, callback URLs, `isPublic`, `pkceEnabled`, and credentials are **owned by the metadata document** and cannot be overridden via the admin API ([`oidc_service.go` `updateOIDCClientModelFromDto` + `UpdateClient`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/service/oidc_service.go)).

Refresh: `POST /api/oidc/clients/:id/refresh` forces a re-fetch of the metadata document ([`oidc_controller.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/controller/oidc_controller.go)).

Not relevant for Setup-managed standard clients — documented for completeness.

---

## Endpoint map (admin OIDC client management)

All under `/api`, `adminAuth` (except `/meta` which is public), JSON in/out except DELETE 204.

| Method | Path | Role |
| --- | --- | --- |
| GET | `/oidc/clients` | Paginated list (search by name) |
| POST | `/oidc/clients` | Create client → 201 |
| GET | `/oidc/clients/:id` | Get client by ID |
| GET | `/oidc/clients/:id/meta` | Get client metadata (public, no auth) |
| PUT | `/oidc/clients/:id` | Full replace update |
| DELETE | `/oidc/clients/:id` | Hard delete → 204 |
| POST | `/oidc/clients/:id/secret` | Create/replace secret → 200 |
| PUT | `/oidc/clients/:id/allowed-user-groups` | Replace allowed groups |
| POST | `/oidc/clients/:id/logo` | Upload logo |
| GET | `/oidc/clients/:id/logo` | Get logo (public-ish, no auth middleware visible) |
| DELETE | `/oidc/clients/:id/logo` | Delete logo |
| POST | `/oidc/clients/:id/refresh` | Force CIMD metadata refresh |
| GET | `/oidc/clients/:id/preview/:userId` | Preview token data for user |
| GET | `/oidc/clients/:id/scim-service-provider` | Get SCIM config |

---

## Gaps / what primary sources do not say

- No first-party documentation of the `client_id` custom validator regex or its charset. The regex `^[a-zA-Z0-9._-]+$` is only in source code. Swagger shows `minLength: 2, maxLength: 128` but not the character constraint.
- Frontend/backend charset discrepancy for custom client IDs (frontend Zod excludes dots, backend regex includes them) is not documented.
- The `isGroupRestricted` default difference between UI (true) and API (false/omitted) is not documented — an operator switching from UI to API creation may be surprised.
- No documentation of the `logoUrl`/`darkLogoUrl` download-on-create feature or its SSRF protections (private IP rejection).
- No documentation of `PUT` being full-replace (not partial) — omitting `callbackURLs` from the update body will clear them.
- The `callback_url_pattern` wildcard support rules are in `utils.ValidateCallbackURLPattern` which was not fully inspected; the exact wildcard syntax is undocumented in the research scope.
- There is no endpoint to list or query by custom client ID substring — `search` on list is name-only.
- OpenAPI does not document the 409 status for duplicate client ID (only `201` and default error).
- `hasLogo` / `hasDarkLogo` fields in `OidcClientUpdateDto` appear unused by the backend `updateOIDCClientModelFromDto` — they seem to be frontend-only state. Not confirmed.
