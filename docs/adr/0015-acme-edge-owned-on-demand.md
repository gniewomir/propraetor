# ACME is Edge-owned and on-demand

**Historical post-issue Route reprojection slice superseded by [ADR-0022](0022-operator-owned-routes.md)**. Body below is the rewritten current contract — not a dead ADR.

Certificate issuance and renewal are owned by the **Edge** Component, not by Workloads. ACME is **on-demand**, not a standing sidecar: Edge Component Setup always installs the ACME capability (oneshot unit, systemd user timer, Host Volume paths, HTTP-01 webroot shared with the Edge front door) even when the want-list is empty. A **systemd user timer** (Platform User, linger) runs renewals periodically; Edge Setup triggers an immediate oneshot after installing the Domain-derived want-list and **waits for that oneshot to finish** before Setup succeeds — the oneshot reloads the Edge front door, so returning early races :80/:443. CA/DNS failures still soft-succeed (oneshot exit 0; Setup does not require usable PEMs — ADR-0012). Renewal applies to every name on that want-list. After issue/renew (and after oneshot runs that skip CA contact for fixtures), ACME **reloads** the Edge front door and does **not** generate or rewrite Workload Routes (ADR-0022). The Edge remains the sole publisher of :80/:443 — ACME writes challenge tokens and PEMs on the Host Volume for the front door to serve; it does not bind those ports itself. Automated paths default to the Let’s Encrypt **staging** directory when `environments/<slug>/acme.json` is absent; production directory and contact email are declared there ([ADR-0045](0045-environment-acme-config.md)). Want-list source of truth: [ADR-0023](0023-acme-want-list-from-domains.md).

**On-demand over a standing ACME sidecar in the Edge Pod:** matches idle cost and HTTP-01 webroot; refines ADR-0007’s reserved sidecar slot into a scheduled Edge job sharing volumes with nginx rather than an always-on Pod mate.

**Always-installed ACME capability over install-on-first-hostname:** keeps Edge Component shape complete; the want-list may be empty.

**systemd user timer over cron(8):** same Platform User Quadlet path as the rest of the Edge; OnCalendar is a superset of typical cron schedules; Persistent/RandomizedDelay fit renewal; on-demand `systemctl --user start` shares the oneshot unit.

**Edge-owned ACME over Workload-owned ACME:** one issuer per Host; certificate material is Domain-scoped; want-list input is Domain assignment (ADR-0023), not Workload claims.
