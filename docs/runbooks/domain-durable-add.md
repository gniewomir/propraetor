# Domain Durable — add a new Domain

ADR-0020 / ADR-0021 / issue #50. Use this when the apex is **not** already a zone on the provider. Ordinary Apply creates the Domain Durable (zone + Stack-authored A records → Reserved IP). Registrar purchase and NS → provider stay out of band.

If the zone already exists on the provider (“name already exists”) and the apex is declared in Environment config, ordinary **Apply** **Adopts** it ([ADR-0026](../adr/0026-adopt-into-state.md) / [#66](https://github.com/gniewomir/prefect/issues/66)). Use [domain Durable import](domain-durable-import.md) only for non-allowlisted surgery or cases Adopt refuses.

## Before you start

1. Own the apex at a registrar (purchase / transfer is out of band).
2. Credentials set (`DIGITALOCEAN_TOKEN`; Apply also needs Operator Configuration key paths — see root `.env.example`).
3. Select the Environment (`./apply.sh` defaults to **test**; pass `--env <slug>` for others).
4. Reserved IP should already be in State for that Environment (or the same Apply that adds the Domain will create both — A records always target that Environment’s Reserved IP).

## Configure the Domain

Edit the Environment’s Domain file (cloud slug — `test`, not workspace `default`):

```text
environments/<slug>/domains.json
```

Example for **test**:

```json
{
  "example.com": {
    "names": ["@", "www"]
  }
}
```

- Key = apex FQDN (one map entry per Domain; Environments may have zero or more).
- `names` = Stack-authored A labels (`@` for apex, `www`, …). At least one required; each A → Reserved IP.
- Missing file = zero Domains for that Environment.
- An apex belongs in **at most one** Environment’s file (provider zones are account-global).

To add another Domain or more labels later, widen the JSON and Apply again. **Narrowing** (removing an apex or a label) does **not** destroy on Apply — Durable `prevent_destroy` fails closed; dropping managed DNS is Teardown (or future specialist surgery), not an ordinary config edit.

## Apply

```bash
./apply.sh
# or: ./apply.sh --env prod
```

Bare `terraform` in `internals/terraform/` is fine too once the correct workspace is selected — no `-var-file` / `TF_VAR_domains`; the workspace slug selects the file.

Expect creation under `module.durables`: one `digitalocean_domain.this["example.com"]` and one `digitalocean_record.a` per declared name. **Do not Apply** if the plan wants to destroy or replace an unexpected existing Domain.

After Apply, Park keeps the Domain; Teardown removes it with other Durables.

## Delegate NS at the registrar (out of band)

The Stack owns the zone on the provider; public resolution still needs the registrar to point NS at DigitalOcean.

1. Read the provider NS for the zone (Control Panel, or):

```bash
doctl compute domain get example.com
# or: dig NS example.com @ns1.digitalocean.com +short  # after the zone exists
```

Typical DigitalOcean nameservers: `ns1.digitalocean.com`, `ns2.digitalocean.com`, `ns3.digitalocean.com`.

2. At the registrar, set the domain’s nameservers to those values. Wait for delegation / TTL to settle, then confirm:

```bash
dig NS example.com +short
dig A example.com +short
dig A www.example.com +short
```

A answers should match the Environment Reserved IP (`terraform output -raw reserved_ip` from the Stack directory, with the correct workspace selected).

## Scope notes

- A Domain does not assign names to Workloads (Binding × Provides Routes + Domain-scoped ACME — ADR-0022 / ADR-0023 / ADR-0053).
- Unmanaged records you add in the same zone by hand are invisible to Terraform until Teardown deletes the zone (and everything under it).
