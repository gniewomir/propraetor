# Manifest Source authoring shape

Manifest **Source** is always a JSON object with a `kind` discriminator. String forms (`"internal"`, bare zip path, bare zip URI) are retired — ADR-0058 introduced object kinds for `git` and `local` but left `internal` and zip on legacy strings; this completes discriminated-object authoring for all four kinds.

**Authoring shapes (v1):**

- **`internal`** — `{ "kind": "internal" }`. Environment Workload directory authors the whole Workload; **materials** = that directory excluding `manifest.json` and `binding.json`; inline Artifact contracts allowed. Obtain/peel rules for other kinds unchanged (ADR-0053).
- **`zip`** — `{ "kind": "zip", "path": "<relative.zip>" }` **or** `{ "kind": "zip", "uri": "<http(s) zip URI>" }` (exactly one of `path` | `uri`). Path and URI validation rules are ADR-0053. Prep extract→validate→re-zip; Environment tree is Manifest + Binding only.
- **`git`** — `{ "kind": "git", "url", "commit", "path" }` (ADR-0058).
- **`local`** — `{ "kind": "local", "path" }` (ADR-0058).

**Canonical wire:** compact JSON object for every kind after validation (`artifact_source_validate` / `artifact_source_from_manifest`). **`artifact_source_kind`** returns `internal` | `zip` | `git` | `local` — not legacy `path` / `uri`.

**Amends:** ADR-0053 (Source authoring shape; zip obtain semantics unchanged); ADR-0058 (internal/zip object shape); ADR-0059 (prep-facing kinds list); ADR-0024 (thin Manifest Source pointer).

**Rejected:** dual-read of string and object forms; `path` and `uri` as separate domain kinds (zip is one kind with two obtain fields); a fifth top-level string Source form.

**Tracking:** grilling session 2026-08-31 (internal/zip object parity).
