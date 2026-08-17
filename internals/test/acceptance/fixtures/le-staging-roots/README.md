# Let’s Encrypt staging root trust bundle

Official **self-signed** Let’s Encrypt staging roots for Acceptance Tier B
(`test/2000-domain-front-healthcheck.sh`). Concatenated as `le-staging-roots.pem`
for OpenSSL `-CAfile`. Do **not** pin intermediates. Do **not** install into
ordinary OS trust stores.

Sources (from [LE Staging Environment](https://letsencrypt.org/docs/staging-environment/)):

- https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem
- https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x2.pem
- https://letsencrypt.org/certs/staging/gen-y/root-ye.pem
- https://letsencrypt.org/certs/staging/gen-y/root-yr.pem

Vendored for #79 (2026-07-29). Re-fetch from those URLs if LE rotates staging roots.
