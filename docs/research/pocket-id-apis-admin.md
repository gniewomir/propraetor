# Pocket ID admin API: OAuth resource servers (“APIs”) and permissions

**Researched:** 2026-08-17  
**Question:** How does a Propraetor Component Setup script authenticate to Pocket ID and then **gather/fulfill** OAuth resource servers (“APIs”) and their permissions?  
**Scope:** Pocket ID’s **admin** HTTP API for custom OAuth resource servers (the Settings → APIs feature), plus the minimum adjacent facts needed to upsert by `resource`, replace permissions by `key`, and decide delete vs leave. Not a Propraetor schema. Not Setup code. Not an OIDC client allow-list design. The built-in Pocket ID REST API and its API keys are in scope only as the **auth** mechanism for calling this admin surface. Token *issuance* to apps (authorization-code / client-credentials `resource=` + `scope=`) is cited only where it affects leftover tokens after API delete.  
**Method:** Primary sources only — official docs ([APIs and Permissions](https://pocket-id.org/docs/guides/apis), [API Reference](https://pocket-id.org/docs/api), [environment variables](https://pocket-id.org/docs/configuration/environment-variables)), first-party OpenAPI ([swagger.yaml](https://pocket-id.org/swagger.yaml)), GitHub source of [pocket-id/pocket-id](https://github.com/pocket-id/pocket-id) pinned to tag **v2.13.0** (`f39f59e9e0dcf0957c83872e60093cebb90ca596`, 2026-08-07), and the feature PR [#1542](https://github.com/pocket-id/pocket-id/pull/1542) (merged 2026-07-06, merge commit `09d196f7c52a00ba89266ea5df8cdad1137ee070`; shipped in [v2.10.0](https://github.com/pocket-id/pocket-id/blob/v2.13.0/CHANGELOG.md)). Website markdown from [pocket-id/website](https://github.com/pocket-id/website). Secondary blogs unused.

Source pin for code citations below: [`v2.13.0`](https://github.com/pocket-id/pocket-id/tree/v2.13.0) = `f39f59e9e0dcf0957c83872e60093cebb90ca596`. Line links use that tag.

---

## Verdict

A Setup script authenticates as an **admin user** with header **`X-API-Key`** (docs write `X-API-KEY`; HTTP header names are case-insensitive). There is **no get-by-resource** endpoint: gather is **list + client-side exact match** on `resource` (optional `search` is a SQL `LIKE`, not a unique lookup). Create is `POST /api/apis` with `{name, resource}`; `resource` is **unique** and **immutable**. Duplicate `resource` is **HTTP 409**. Update is name-only (`PUT /api/apis/{id}`). Permissions are a **full replace** on `PUT /api/apis/{id}/permissions` matching existing rows **by `key`**: same key keeps its UUID; omitted keys are deleted (and their client grants go with them). There is **no PATCH / no per-permission DELETE / no archive**. Delete is hard-delete (`204`). Outstanding **RFC 9068 JWT** access tokens with `aud` = that resource are **not revoked** by API delete; local JWT validation (the documented resource-server path) still succeeds until `exp`. Refresh of such a grant **does** re-check that the API still exists. Client allow-list `PUT /api/api-access/{clientId}` takes **permission UUIDs, not keys** — delete/recreate of an API (or dropping a key and adding it back) churns those IDs.

---

## What an “API” is (so the admin surface is not confused with API keys)

Official guide: an **API** here is a service the operator built; it is **not** the built-in Pocket ID REST API and its API keys ([guide](https://pocket-id.org/docs/guides/apis), [website source](https://github.com/pocket-id/website/blob/main/docs/guides/apis.md)).

Internally the row is stored with column **`audience`**; JSON always exposes it as **`resource`**. The list/get/create handlers copy `api.Audience` → `resource` on the way out ([`handler.go` list + `respond`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/handler.go)). Create writes `Audience: input.Resource` ([`service.go` Create](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)). SQLite/Postgres migrations: `audience TEXT NOT NULL UNIQUE` ([sqlite](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/resources/migrations/sqlite/20260707170000_oauth_apis.up.sql), [postgres](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/resources/migrations/postgres/20260707170000_oauth_apis.up.sql)).

Feature origin: PR [#1542](https://github.com/pocket-id/pocket-id/pull/1542) “add OAuth APIs with scoped permissions” (Auth0-style API/permissions; clients request scopes for a specific audience). Changelog: shipped in **v2.10.0**.

Admin UI lives at Settings → Administration → APIs (`/settings/admin/apis`); nav is admin-only ([`+layout.svelte`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/+layout.svelte)).

---

## 1. Auth

### Header

Code reads **`X-API-Key`** via `c.GetHeader("X-API-Key")` then `ValidateApiKey` ([`api_key_auth.go` `Verify`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/middleware/api_key_auth.go)).

Official API reference: “All endpoints should have the **`X-API-KEY`** header with the content being the API Key” ([docs/api](https://pocket-id.org/docs/api), [website `docs/api.md`](https://github.com/pocket-id/website/blob/main/docs/api.md)). Gin’s `GetHeader` is canonical-MIME / case-insensitive, so `X-API-KEY` and `X-API-Key` are the same header.

Missing or invalid key: `ValidateApiKey` returns `NoAPIKeyProvided` / `InvalidAPIKey`, but `Verify` maps any failure to `NotSignedIn` **401** “You are not signed in” ([`api_key_auth.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/middleware/api_key_auth.go), [`ValidateApiKey`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apikey/service.go), [`NotSignedIn`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apperror/constructors.go)). Disabled user → `UserDisabled` **403**.

The SPA does **not** send this header: `APIService` is axios to `/api` with cookies / JWT ([`api-service.ts`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/lib/services/api-service.ts)). `AuthMiddleware` tries JWT first, then API key ([`auth_middleware.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/middleware/auth_middleware.go)). A Setup script is the API-key path.

### Where the key is created

UI (admin): `https://id.example.com/settings/admin/api-keys` → Add API Key → name, expires-at, description → Generate. The plaintext is shown **once** ([docs/api](https://pocket-id.org/docs/api)). Nav puts API Keys under Administration, so only admins see that screen ([`+layout.svelte`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/+layout.svelte)).

HTTP: `POST /api/api-keys` creates a key **for the current user**; `GET /api/api-keys` lists **that user’s** keys ([`apikey/handler.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apikey/handler.go), OpenAPI [`/api/api-keys`](https://pocket-id.org/swagger.yaml)). Create and renew **reject API-key auth** (`WithApiKeyAuthDisabled`) so a key cannot mint or renew further keys ([`apikey/module.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apikey/module.go), wired in [`router_bootstrap.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/bootstrap/router_bootstrap.go)).

Alternative for declarative installs: env **`STATIC_API_KEY`** — “a static API key that grants **admin** access”; creates an admin account named “Static API User”. Docs: “If possible prefer regular API Keys” ([environment variables](https://pocket-id.org/docs/configuration/environment-variables)). Code: compared in plaintext against the env value; user `IsAdmin: true`, fixed ID `00000000-0000-0000-0000-000000000000` ([`ValidateApiKey` / `initStaticApiKeyUser`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apikey/service.go), [`StaticApiKeyUserID`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/common/reserved.go)). When set, must be at least 16 characters ([`env_config.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/common/env_config.go)).

### Admin-only for resource-server CRUD

Default `AuthMiddleware` has `AdminRequired: true` ([`auth_middleware.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/middleware/auth_middleware.go)). The APIs module mounts **all** `/apis` and `/api-access` routes with that `adminAuth` ([`api/module.go` `RegisterRoutes`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/module.go)). Router passes `authMiddleware.Add()` (admin required, API key allowed) ([`router_bootstrap.go` line 176](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/bootstrap/router_bootstrap.go)).

If the authenticated user is not admin: `MissingPermission` **403** “You don't have permission to perform this action” ([`api_key_auth.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/middleware/api_key_auth.go), [`MissingPermission`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apperror/constructors.go)). A non-admin’s API key therefore cannot gather/fulfill APIs.

JSON write bodies must be `Content-Type: application/json` ([`httpserver.BindJSON`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/httpserver/binding.go)).

---

## 2. List APIs (gather)

| | |
| --- | --- |
| Method / path | `GET /api/apis` ([handler `list`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/handler.go), [OpenAPI](https://pocket-id.org/swagger.yaml)) |
| Query | `search` (optional string); `pagination[page]` default 1; `pagination[limit]` default 20; `sort[column]`; `sort[direction]` default `asc` |
| Lookup by `resource` URI? | **No dedicated query or path.** `search` is `name LIKE ? OR audience LIKE ?` with `%term%` ([`Service.List`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)). Exact gather = list (or search-narrow) then **filter client-side** on `resource === uri`. The `API` model is `sortable` on `Name`/`Audience`, **not** `filterable`, so `filters[audience]=` is ignored ([`models.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/models.go), [`list_request_util.go` `applyFilters`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/utils/list_request_util.go)). |
| Pagination | Yes. Page &lt; 1 → 1; limit &lt; 1 → **20**; limit **capped at 100** ([`Paginate`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/utils/list_request_util.go)). Response: `{ "data": [...], "pagination": { "totalPages", "totalItems", "currentPage", "itemsPerPage" } }` ([`dto.Paginated`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/pagination_dto.go)). |
| Payload | Each item is `apiResponseDto`: `id`, `name`, `resource`, `createdAt`, `permissions[]` (`id`, `key`, `name`, `description?`). List **preloads** permissions ([`Service.List`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)). |

Frontend `listAll` requests `pagination.limit: 1000` ([`apis-service.ts`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/lib/services/apis-service.ts)); the server still caps at **100**. A Setup gather that assumes one page is incomplete once there are more than 100 APIs.

`sort[column]=resource` is remapped to DB column `audience` ([`Service.List`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)).

There is **no** `GET /api/apis?resource=` and **no** `GET /api/apis/by-resource/...`.

---

## 3. Create API

| | |
| --- | --- |
| Method / path | `POST /api/apis` |
| Success | **201** `{object} apiResponseDto` ([handler `create`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/handler.go), [OpenAPI](https://pocket-id.org/swagger.yaml)) |
| Body (`apiCreateDto`) | **Required:** `name` (min 1, max 50, NFC), `resource` (required, `resource_uri`, max 350, NFC) ([`dto.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/dto.go)). OpenAPI `required: [name, resource]` ([swagger.yaml](https://pocket-id.org/swagger.yaml)). Permissions are **not** in the create body; they are a later PUT. |

`resource_uri` is RFC 8707 via `fosite.IsValidResourceIndicatorURI`, plus rejection of `javascript:` / `data:` schemes ([`ValidateResourceURI`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/dto/validations.go)). Validation failure message: “must be an absolute URI without whitespace or a fragment” ([`error_handler.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/middleware/error_handler.go)). Unit tests accept `https://api.orders.example.com`, `api://PocketID`, `urn:my-app` ([`service_test.go` `TestCreateAcceptsAbsoluteResourceURIs`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service_test.go)).

**Reserved:** `resource` must not be the Pocket ID issuer (exact, trailing-slash, or case-insensitive match). That is `400` validation `resource` / `reserved` ([`isIssuerAudience` + `Create`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go), [`TestCreateRejectsIssuerResource`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service_test.go)).

### Is `resource` unique? Duplicate HTTP status?

Yes. DB `UNIQUE` on `audience`. `Create` maps `gorm.ErrDuplicatedKey` → `apperror.AlreadyInUse("resource")` ([`service.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)). `AlreadyInUse` is **HTTP 409** Conflict, message `"{property} is already in use"`, detail `property: resource` ([`constructors.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/apperror/constructors.go)). Test: second create with the same resource yields `CodeAlreadyInUse` ([`TestAPICrudAndPermissionDiff`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service_test.go)).

Uniqueness is the DB constraint (exact string). Issuer reservation is a separate, case-insensitive check. Nothing in source folds `https://API.example.com` and `https://api.example.com` into one API unless they hit the issuer rule.

IDs are UUIDs assigned in `Base.BeforeCreate` if empty ([`model/base.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/model/base.go)).

---

## 4. Get / Update / Delete a single API; `resource` immutability

| Verb | Path | Body | Success |
| --- | --- | --- | --- |
| GET | `/api/apis/{id}` | — | **200** `apiResponseDto` including `permissions` ([handler `get`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/handler.go)) |
| PUT | `/api/apis/{id}` | `apiUpdateDto`: **`name` only** (required, 1–50) | **200** |
| DELETE | `/api/apis/{id}` | — | **204** No Content |
| PATCH | — | — | **No PATCH route** ([`RegisterRoutes`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/module.go), [OpenAPI](https://pocket-id.org/swagger.yaml)) |

Unknown id → `NotFound("API")` **404** ([`Service.Get`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)).

### `resource` is immutable after create

Docs: “The resource is the permanent identifier for your API. … Choose it carefully because it **cannot be changed later**” ([guide](https://pocket-id.org/docs/guides/apis)). UI copy: “It can't be changed later.” ([`en.json` `api_resource_description`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/messages/en.json)). Edit form sets the resource input **`readonly`** when `existingApi` is set ([`api-form.svelte`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/admin/apis/api-form.svelte)). Edit save sends **`{ name }` only** ([`[id]/+page.svelte`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/admin/apis/%5Bid%5D/+page.svelte)).

DTO comment: “The resource identifier is only accepted here [create] because changing it later would invalidate every token already minted for the API”; `apiUpdateDto` “intentionally not updatable” ([`dto.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/dto.go)). Handler update binds `apiUpdateDto` (name only) ([`handler.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/handler.go)). `Service.Update` writes `Name` and `UpdatedAt` only ([`service.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)).

**FQDN / URI rename = a new API.** There is no rename-in-place. Creating the new URI while the old row exists is **409**. Operators delete the old API (or leave it) and `POST` a new one. Tokens minted for the old `aud` stay bound to the old URI (see §6).

---

## 5. Permissions

### `PUT /api/apis/{id}/permissions` — full replace

OpenAPI and godoc: “**Replace the full set** of permissions for an API” ([handler `updatePermissions`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/handler.go), [swagger.yaml](https://pocket-id.org/swagger.yaml)). Success **200** with the full `apiResponseDto`.

Body (`apiPermissionsUpdateDto`):

```json
{ "permissions": [ { "key": "...", "name": "...", "description": "..." } ] }
```

| Field | Binding | Notes |
| --- | --- | --- |
| `key` | required, min 1, max 128, NFC | RFC 6749 scope-token characters (`fosite.IsValidScopeToken`). Must not be reserved: `openid`, `profile`, `email`, `email_verified`, `groups`, `offline_access` (case-insensitive). Must be unique **within the request**. ([`dto.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/dto.go), [`UpdatePermissions`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)) |
| `name` | required, min 1, max 50, NFC | Display name (consent UI) |
| `description` | optional, max 200 | Pointer; omitted from JSON response when empty (`omitempty`) |

**No `id` in the input DTO.** The server matches existing rows **by `key`**, not by UUID ([`dto.go` `apiPermissionInputDto`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/dto.go)).

Service comment: “matching existing permissions by key. Unchanged keys keep their grants, removed keys and their client grants are deleted, and new keys are inserted” ([`UpdatePermissions`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)). Implementation: build `existing[key]`; keys not in the request are `deletePermissions` (also deletes `oidc_clients_allowed_api_permissions` rows); keys already present get `Updates` of `name`/`description` **where id = cur.ID**; new keys `Create` (new UUID). Unique `(api_id, key)` in SQL ([migration](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/resources/migrations/sqlite/20260707170000_oauth_apis.up.sql)).

Empty `{ "permissions": [] }` or omitted `permissions` (nil slice, `binding:"omitempty"`) means **wanted is empty** → **every** existing permission is deleted. That is a wipe, not a no-op.

Frontend always PUTs the whole editor list `{ permissions }` ([`apis-service.ts` `updatePermissions`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/lib/services/apis-service.ts), [`[id]/+page.svelte`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/admin/apis/%5Bid%5D/+page.svelte)). UI editor has no per-row API; minus-button only mutates local state, then one Save PUT. UI caps the editor at 100 rows ([`api-permissions-input.svelte`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/admin/apis/%5Bid%5D/api-permissions-input.svelte)); the backend has no matching 100 cap in `UpdatePermissions`.

### PATCH one permission? DELETE one? GET current set?

| Operation | Exists? |
| --- | --- |
| PATCH one permission | **No** route |
| DELETE `/api/apis/{id}/permissions/{permId}` | **No** route |
| GET current set | **Yes, as part of the API:** `GET /api/apis/{id}` (and list items) include `permissions[]`. No standalone GET `/permissions`. |

Removing one permission = PUT the remaining set.

### Are permission UUIDs stable across replace-all when the same `key` is sent again?

**Yes, if the key stays in the replacement set.** Existing row is updated in place by id; `Create` is skipped ([`UpdatePermissions` loop](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)). Client grants that reference that id therefore survive a name/description edit.

They are **not** stable if:

- the key is omitted then added back (delete + insert → new UUID; grants for the old id are deleted — tested for `read:orders` in [`TestAPICrudAndPermissionDiff`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service_test.go));
- the whole API is deleted and recreated (new API id + new permission ids; `UNIQUE` on audience requires the old row gone first).

Changing the **key** string is a new permission, not a rename of the old UUID.

---

## 6. Disable / archive vs delete; leftover tokens

**No disable/archive column or endpoint.** Migration table `apis` is `id, created_at, updated_at, name, audience` only. UI action is Delete ([`api-list.svelte`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/routes/settings/admin/apis/api-list.svelte)). `Service.Delete` loads the API, deletes its permissions (and client grants), then `DELETE FROM apis` ([`service.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go)). SQL also has `ON DELETE CASCADE` from permissions → APIs ([migration](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/resources/migrations/sqlite/20260707170000_oauth_apis.up.sql)). **No call into OAuth2 session revocation.**

### Outstanding access tokens (`aud` = resource)

Access tokens are **RFC 9068 JWTs** (fosite `RFC9068JWTStrategy`, changelog v2.13.0 “make oauth access tokens RFC 9068 compliant”; [`provider.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/provider.go)). Default access-token lifetime is **60 minutes** per client (`DefaultAccessTokenDurationMinutes`) ([`model/oidc.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/model/oidc.go)).

Official resource-server instructions: verify **signature** (Pocket ID JWKS), **`iss`**, **`aud` contains the API’s resource**, **not expired**, and the **permission** in the token. They do **not** say to call Pocket ID to check the API still exists ([guide “Validate the token in your API”](https://pocket-id.org/docs/guides/apis)). That local-JWT path therefore **still accepts** a token after the API row is gone, until `exp`.

Permissions appear in the JWT as RFC 9068 `scp` and space-delimited `scope` (`JWTScopeFieldBoth`) ([`provider.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/provider.go)).

**Issuance after delete:** `resolveResource` looks up the API by `audience`; if `!apiExists` → `fosite.ErrInvalidTarget` (“requested resource … invalid, missing, unknown, or malformed”) ([`api_resource.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/api_resource.go)). New authorization-code / client-credentials grants for that `resource` fail.

**Refresh after delete:** `validateRefreshAPIGrant` re-runs `resolveResource` against the granted API audience ([`token_handler.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/token_handler.go)). Changelog v2.10.0: “re-check api permissions on access token refresh” (`e8cb0c8`). A refresh targeting a deleted API fails the same missing-resource path. (Refresh is user-delegated `SubjectTypeUser` in that helper.)

### Introspection

`POST /api/oidc/introspect` ([`introspection_handler.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/introspection_handler.go), OpenAPI). It asks fosite to introspect the token and checks the **caller client** owns it. It does **not** look up the `apis` table. Access-token sessions are stored separately (`CreateAccessTokenSession` / `GetAccessTokenSession` on `OAuth2Session`) ([`store.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/oidc/store.go)). API delete does not delete those sessions.

**Gap:** no first-party test titled “introspection / JWT still active after API delete.” The conclusion is composed from Delete’s lack of revocation + documented JWT validation + introspection not consulting `apis`.

---

## 7. `PUT /api/api-access/{clientId}` (UUID, not key)

Enough for the gather/fulfill ID-churn warning; not an allow-list design.

- `GET` / `PUT` `/api/api-access/{clientId}` ([handler](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/handler.go), [OpenAPI](https://pocket-id.org/swagger.yaml)).
- Body / response: `userDelegatedPermissionIds` and `clientPermissionIds` — arrays of **permission id strings** ([`clientApiAccessDto`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/dto.go), frontend [`ClientApiAccess`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/lib/types/api.type.ts)).
- OpenAPI description of the PUT body: “Allowed **permission IDs** per subject type.”
- `SetClientAPIAccess` stores `APIPermissionID` FKs; unknown IDs are **dropped**, not rejected ([`filterAssignablePermissionIDs`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service.go), [`TestClientApiAccessAllowList`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/service_test.go)).
- Full replace of both lists each PUT (empty array clears that subject type).

Because grants hang off **permission UUIDs**, delete/recreate of an API (or drop-and-readd of a key) makes previous allow-list IDs invalid; they are ignored on the next PUT.

---

## Frontend client and handlers (as requested)

| Piece | Path at v2.13.0 |
| --- | --- |
| Frontend service | [`frontend/src/lib/services/apis-service.ts`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/lib/services/apis-service.ts) — `GET/POST /apis`, `GET/PUT/DELETE /apis/{id}`, `PUT /apis/{id}/permissions` with `{ permissions }`, `GET/PUT /api-access/{clientId}` |
| Types | [`frontend/src/lib/types/api.type.ts`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/frontend/src/lib/types/api.type.ts) — `ApiCreate { name, resource }`, `ApiUpdate { name }`, `ApiPermissionInput { key, name, description }` (no id) |
| Handlers | [`backend/internal/api/handler.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/handler.go) |
| DTOs | [`backend/internal/api/dto.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/dto.go) |
| Routes | [`backend/internal/api/module.go`](https://github.com/pocket-id/pocket-id/blob/v2.13.0/backend/internal/api/module.go) |

---

## Endpoint map (admin)

All under `/api`, `adminAuth`, JSON in/out except DELETE 204.

| Method | Path | Role |
| --- | --- | --- |
| GET | `/apis` | Paginated list + permissions |
| POST | `/apis` | Create (`name`, `resource`) → 201 |
| GET | `/apis/{id}` | One API + permissions |
| PUT | `/apis/{id}` | Rename (`name`) |
| DELETE | `/apis/{id}` | Hard delete → 204 |
| PUT | `/apis/{id}/permissions` | Replace permission set by key |
| GET | `/api-access/{clientId}` | Permission UUIDs allowed for client |
| PUT | `/api-access/{clientId}` | Replace those UUID lists |

---

## Gaps / what primary sources do not say

- No first-party test that a JWT access token (or introspect `active: true`) survives API delete until `exp`. Composed from Delete + JWT validation docs + introspection not reading `apis`.
- `LIKE` case-sensitivity is SQLite- vs Postgres-dependent; uniqueness is exact `UNIQUE(audience)`.
- OpenAPI on [pocket-id.org/swagger.yaml](https://pocket-id.org/swagger.yaml) is generated from the same godoc as v2.13.0 handlers; it does **not** document 409-on-duplicate (that is only in `Create` + `AlreadyInUse`).
- Website OpenAPI UI defaults to `/swagger.yaml` ([`openapi-spec.svelte`](https://github.com/pocket-id/website/blob/main/src/lib/components/openapi-spec.svelte)); there is no separate published “get by resource” operation there either.
- Exact HTTP JSON error envelope for 409 (`error`, `code`, `details.property`) is from the shared error middleware, not from the APIs guide.
