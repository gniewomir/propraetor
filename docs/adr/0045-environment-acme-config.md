# Environment ACME config is committed acme.json (directory only)

Edge ACME’s Let’s Encrypt directory (`production` | `staging`) is declared in committed `environments/<cloud-slug>/acme.json`, staged by ensure-components onto the Host as an EnvironmentFile for `edge-acme.service` (same handoff shape as the Domain-derived want-list — ADR-0023). Contact email is **Operator Configuration** (`PROPRAETOR_ACME_EMAIL`, ADR-0038) — required when `acme.json` is present, not at general Operator Configuration load. Missing file means staging with no email line (Host still derives `acme@<apex>` per acme-run). Present file requires key `directory` only (fail closed on any other key, including leftover `email`) and a non-empty Operator Configuration contact at ACME staging. This is the explicit production opt-in ADR-0015 required — not Environment Configuration (ADR-0035; Components do not consume that bag) and not a field on `domains.json`.

**Committed Environment file for directory over putting CA choice in `.env`:** keeps production opt-in as reviewable Environment intent beside Domain assignment.

**Considered:** contact email in the same `acme.json`. Rejected — contact is who operates the machine (Operator Configuration), not what the Environment opts into with Let’s Encrypt; personal addresses do not belong in committed Environment files.
