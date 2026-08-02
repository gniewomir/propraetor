# AWS authentication, IAM, and S3 scaffolding for Propraetor

**Researched:** 2026-08-02  
**Question:** How does AWS separate identity from permission; what is the minimal vs recommended scaffolding before a Terraform-managed S3 bucket is useful; and where does that collide with Propraetor’s Stack / Environment / Provider Credential / Durable model (#148: DO Hosts + AWS S3 in one root)?  
**Scope:** Primary docs only — IAM / Account Management / S3 User Guides, AWS Organizations where relevant, HashiCorp Terraform AWS provider authentication docs. Propraetor glossary + ADR-0019 / ADR-0025 / ADR-0038 for tension mapping. Not: Spaces pricing, remote State backends, community blogs.

**Repo constraint:** Do not invent AWS facts from secondary write-ups. Prefer current `docs.aws.amazon.com` over older guidance when they conflict.

---

## Verdict

| Finding | Implication for #148 / Propraetor |
| --- | --- |
| Root user = full-account identity; AWS **strongly** recommends no day-to-day root use and **don’t create root access keys** | Documenting only “put `AWS_*` in `.env`” without naming *which* principal pushes operators toward root keys — **strong** product/docs risk |
| Authn (who) ≠ authz (what): IAM users/roles/groups + identity-based vs resource-based (bucket) policies | Managing the bucket and granting Workloads object access are **two credential bags** even inside one AWS account |
| Temporary credentials (STS / Identity Center / AssumeRole) preferred over long-term IAM user keys; long-term keys are an acknowledged niche | Solo-operator Terraform with static keys is common but is the **discouraged** path; prefer IAM user/role with MFA or Identity Center → temporary session into Terraform |
| Hard prerequisites for first S3 API: AWS account + payment method + principal that can call S3 (not VPC, not CloudTrail) | S3 scaffolding is thin compared to DO Hosts; AWS **account** existence + IAM identity are the real gates |
| Buckets are regional; names in the **global** namespace (per partition) must be unique; BPA + Bucket-owner-enforced ACLs are **defaults** for new buckets (since Apr 2023) | Environment-prefixed names help; Teardown/delete frees names for *others*; keep BPA on for private Workload storage |
| Terraform AWS provider auth: env `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` / `AWS_PROFILE` / shared config — same precedence as AWS SDK/CLI | ADR-0038 must grow beyond `DIGITALOCEAN_TOKEN`; profile/session-token patterns matter for non-root IAM |
| Multi-provider one Stack vs glossary “one provider”; Environment = namespace under **one** provider account | One AWS account + name-prefixed buckets can mirror DO Environments (**moderate**); multi-account AWS is optional governance, not required for S3 |
| Cloud Project has **no** AWS analogue for S3 | Asymmetry is expected — don’t force-fit; billing tags optional |
| IAM users/keys in State as Durables conflict with Park (keys keep billing/risk) and Teardown (wipe secrets) vs Workload Environment Configuration | **Strong** design fork: Stack-managed IAM material vs operator-supplied object-store secrets in Environment Configuration |
| Acceptance/Lifecycle evidence needs a second live credential matrix | Same bar as ADR-0025’s live test matrix — **moderate** cost/ops burden before merge |

---

## Authoritative sources ranked

| Rank | Source | Owns |
| --- | --- | --- |
| 1 | [IAM — What is IAM?](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html); [Identity-based vs resource-based policies](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_identity-vs-resource.html) | Authn vs authz; policy attachment model |
| 2 | [AWS account root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html); [Root user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html); [Tasks that require root user credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html#root-user-tasks) | Root definition, discouragement, root-only tasks |
| 3 | [Security best practices in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html); [IAM users](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users.html); [IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html); [IAM user groups](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_groups.html); [Access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html); [Programmatic access](https://docs.aws.amazon.com/IAM/latest/UserGuide/security-creds-programmatic-access.html) | Principals, long-term vs temporary credentials, federation guidance |
| 4 | [Getting started with an AWS account](https://docs.aws.amazon.com/accounts/latest/reference/getting-started.html); [Setting up your AWS account (IAM)](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started-account-iam.html); [Setting up Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/creating-bucket.html) | Account signup, payment method, S3 auto-enrollment |
| 5 | [Bucket naming rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html); [Object Ownership](https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html); [Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html); [Required permissions for S3 API operations](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html); [Identity-based policy examples](https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-policies-s3.html); [AmazonS3FullAccess](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonS3FullAccess.html) | Bucket region/name/defaults; CreateBucket permissions; managed policy starting point |
| 6 | [Terraform AWS Provider — Authentication and Configuration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs) (source: HashiCorp `terraform-provider-aws` docs index) | How credentials reach Terraform (`AWS_*`, profile, assume_role, etc.) |
| 7 | Propraetor: `CONTEXT.md`; [ADR-0019](../adr/0019-environments.md); [ADR-0025](../adr/0025-lifecycle-convergence-by-structural-class.md); [ADR-0038](../adr/0038-repo-root-operator-dotenv.md); issue #148 | Domain terms and current credential / Environment contracts |

---

## 1. AWS authentication / authorization model

### Separation of identity and permission

**High.** IAM distinguishes *authentication* (matching credentials to a principal) from *authorization* (whether that principal may perform an action on a resource). From [What is IAM?](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html):

> You use IAM to control who is authenticated (signed in) and authorized (has permissions) to use resources. … Authentication is provided by matching the sign-in credentials to a principal (an IAM user, AWS STS federated principal, IAM role, or application) trusted by the AWS account. Next, a request is made to grant the principal access to resources.

Permissions are expressed as policies. [Identity-based vs resource-based](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_identity-vs-resource.html):

| Policy kind | Attached to | Says |
| --- | --- | --- |
| **Identity-based** | IAM user, group, or role | What *this identity* can do |
| **Resource-based** | Resource (e.g. S3 bucket policy) | Who can access *this resource* and what they can do |

Same-account evaluation: Deny wins; otherwise Allow from either identity-based or resource-based is enough. Cross-account needs Allow on **both** sides.

---

### 1a — Root (main) account credentials (discouraged)

#### What is the AWS account root user?

**High.** When you create an AWS account you get one identity with complete access to all services and resources in that account: the **root user**. Sign-in is the signup email + password ([root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html)).

#### How does root access-key / console auth work?

**High.**

- **Console:** email + password (+ MFA). MFA is required for root; registration must complete within a grace period after first console sign-in ([root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html), [root best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)).
- **Programmatic:** root can have long-term **access keys** (access key ID + secret), same shape as IAM user keys ([Manage access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)). Access key IDs starting with `AKIA` are long-term (user or root); `ASIA` are temporary STS ([Programmatic access](https://docs.aws.amazon.com/IAM/latest/UserGuide/security-creds-programmatic-access.html)).

Standalone accounts: changing root email, root password, and **root access keys** requires root credentials ([root-user tasks](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html#root-user-tasks)).

#### Why AWS discourages root access keys and day-to-day root use

**High.** Official quotes:

From [root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html):

> We strongly recommend that you don't use the root user for your everyday tasks … Safeguard your root user credentials and use them to perform the tasks that only the root user can perform.

From [Don’t create access keys for the root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html#ru-bp-access):

> We strongly recommend that you do not create access keys for your root user because the root user has full access to all AWS services and resources in the account, including billing information.

From [Manage access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html):

> **Do NOT** use your account's root credentials to create access keys.

Preferred path for daily work: administrative user via **IAM Identity Center**, or (standalone) an admin IAM role/user — not root ([root best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html); [Setting up your AWS account](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started-account-iam.html)).

#### What can ONLY root do (account-level operations)?

**High** (summary of current root-tasks list; Organizations can centralize some member-account privileged actions). Standalone / classic root-only examples from [Tasks that require root user credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html#root-user-tasks):

| Category | Examples |
| --- | --- |
| Account management | Change root email / root password / root access keys (standalone); close standalone account; restore IAM admin if locked out |
| Billing | Activate IAM access to Billing console; some billing/tax tasks |
| Break-glass S3/SQS | Edit/delete a bucket (or SQS) policy that denies **all** principals; S3 MFA Delete configuration |
| Other | GovCloud signup; some KMS Support authorization; RI Marketplace seller registration; MTurk account linking |

**Creating and using ordinary S3 buckets does *not* require root.** Root is only special for misconfigured “deny everyone” bucket policies and MFA Delete.

#### Blast radius of root keys with Terraform / S3

**High / Inference.**

| Fact | Blast radius |
| --- | --- |
| Root has complete access to all services and resources, including billing ([root user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html)) | Compromised `AWS_*` = entire account + billing surface |
| Terraform provider uses whatever credentials it finds ([TF AWS auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)) | A Stack Apply with root keys can create/destroy anything the plan touches — and any leaked State/process env inherits that |
| S3 alone does not need root | Using root for `aws_s3_bucket` is pure over-privilege |

**Inference (High confidence of risk, Medium on “typical leak path”):** Repo-root `.env` holding root `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` combines long-lived god-mode secrets with a file operators already treat as Provider Credential baseline (ADR-0038).

---

### 1b — Proper IAM (good practices)

#### Principals: users, roles, groups, policies

**High.**

| Principal / construct | Role | Long-term credentials? |
| --- | --- | --- |
| **IAM user** | Named identity for a person or workload; starts with **no** permissions ([IAM users](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users.html)) | Optional password and/or access keys |
| **IAM user group** | Collection of users; attach policies to the group ([IAM groups](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_groups.html)); **cannot** be a `Principal` in resource-based policies | N/A (not an auth principal) |
| **IAM role** | Assumable identity with permissions; **no** standing password/access keys; assumption yields temporary credentials ([IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)) | Session only |
| **Root** | Account owner identity | Password; optional access keys (discouraged) |

Policies: identity-based (on user/group/role) vs resource-based (e.g. bucket policy) — see §1 above.

#### Long-term access keys vs temporary credentials

**High.** [Security best practices in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html):

- Human users: federation / Identity Center → temporary credentials; prefer **not** IAM users with long-term keys.
- Workloads: temporary credentials via **IAM roles** (on AWS compute) or STS / Roles Anywhere / OIDC / SAML for off-AWS.
- Long-term IAM user keys: only for niches (tools that can’t use Identity Center, some off-AWS plugins, emergency access, etc.) ([When to create an IAM user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html#id_which-to-choose); [Programmatic access](https://docs.aws.amazon.com/IAM/latest/UserGuide/security-creds-programmatic-access.html)).

STS `AssumeRole` (and provider `assume_role` blocks) mint short-lived keys + session token (`ASIA…` + `AWS_SESSION_TOKEN`).

#### Least privilege for managing S3 via Terraform

**High** for required actions; **Medium** for a complete Terraform “bucket + settings” policy (depends on which companion resources you manage).

From [Required permissions for Amazon S3 API operations](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html) and [Creating a bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/creating-bucket.html):

| Goal | Permissions |
| --- | --- |
| Create bucket (defaults: BPA on, ACLs disabled) | `s3:CreateBucket` only |
| Change Object Ownership away from default | also `s3:PutBucketOwnershipControls` |
| Turn off any Block Public Access setting | also `s3:PutBucketPublicAccessBlock` |
| Delete bucket | `s3:DeleteBucket` (bucket must be empty unless tool empties it) |
| Typical companion config (versioning, encryption, policy, tagging, …) | matching `s3:Put*` / `Get*` / `Delete*` per API — see same permissions table |

Official policy example: allow `s3:CreateBucket` on `arn:aws:s3:::*` with `s3:LocationConstraint` condition ([Restricting bucket creation to one Region](https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-policies-s3.html)).

**Starting managed policies** (broad → tighten later, per [IAM best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html#bp-use-aws-defined-policies)):

| Policy | Scope |
| --- | --- |
| [AdministratorAccess](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_job-functions.html) | All actions/resources — admin bootstrap only |
| [AmazonS3FullAccess](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonS3FullAccess.html) | `s3:*` and `s3-object-lambda:*` on `*` — convenient for early Terraform S3 work; not least privilege |
| Customer managed | Prefer: `CreateBucket`/`DeleteBucket` + needed Put/Get for settings, optionally scoped by bucket name prefix / Region condition |

If the Stack also creates IAM users/keys for Workloads, the **operator** principal additionally needs IAM APIs (`iam:CreateUser`, `iam:CreateAccessKey`, `iam:PutUserPolicy` / attach policies, etc.) — separate from S3 actions.

#### Recommended solo-operator / small-team patterns (from AWS docs)

**High.**

1. Secure root: MFA; **no root access keys**; use root only for root-only tasks ([root best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)).
2. Prefer **IAM Identity Center** for human admin access with temporary credentials ([IAM best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html); [Setting up your AWS account](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started-account-iam.html)).
3. If IAM users are used: MFA; avoid embedding keys in app/repo; rotate; prefer roles for workloads ([IAM users](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users.html); [Access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)).
4. Organizations + SCPs/RCPs when scaling to many accounts ([IAM best practices — guardrails](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html#bp-permissions-guardrails)) — optional for a single solo account.

#### Credentials supplied to Terraform AWS provider

**High.** From HashiCorp [AWS Provider — Authentication and Configuration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs) (precedence matches AWS CLI / SDK Go v2):

1. Parameters in the `provider` block (`access_key`, `secret_key`, `token`, `profile`, …) — hard-coding **not recommended**
2. Environment variables
3. Shared credentials file
4. Shared config file
5. Container credentials
6. Instance profile / IMDS

Relevant env vars documented by the provider:

| Variable | Role |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | Access key ID |
| `AWS_SECRET_ACCESS_KEY` | Secret |
| `AWS_SESSION_TOKEN` | Required for temporary (STS / Identity Center) sessions |
| `AWS_PROFILE` | Named profile |
| `AWS_REGION` / `AWS_DEFAULT_REGION` | Region |
| `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` | Alternate file paths |

Also supported: `assume_role` / `assume_role_with_web_identity` in the provider block; `credential_process` via named profile.

#### Two bags: manage-bucket vs Workload object I/O

**High.**

| Bag | Who | Typical material | Lives where (Propraetor terms) |
| --- | --- | --- | --- |
| **Stack / operator** | Terraform process on operator machine | IAM principal that can Create/configure/delete buckets (and maybe IAM) | **Provider Credential** (repo-root `.env` / process env) |
| **Workload** | App on Host reading/writing objects | Separate IAM user keys, or role assumption, and/or bucket policy principals | **Environment Configuration** (or Stack outputs copied into that bag) — *not* the same as Provider Credential |

AWS docs push temporary credentials for workloads; Propraetor Hosts are off-AWS (DigitalOcean), so realistic options are: IAM user long-term keys (acknowledged niche), STS with an external IdP / Roles Anywhere, or operator-rotated keys in Environment Configuration ([IAM best practices — workloads outside AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html#bp-workloads-use-roles)).

---

## 2. Scaffolding before a useful `aws_s3_bucket` Apply

Classify each item:

| Class | Meaning |
| --- | --- |
| **Hard prerequisite** | Without it, signup or first S3/Terraform call fails |
| **Good practice scaffolding** | Strongly recommended by AWS before daily use |
| **Optional governance** | Useful at scale; not required to create a private bucket |

### Account and billing

| Item | Class | Source |
| --- | --- | --- |
| AWS account (email, password, account name, phone verification) | Hard | [Getting started with an AWS account](https://docs.aws.amazon.com/accounts/latest/reference/getting-started.html) |
| Valid **payment method** before signup completes | Hard | Same page: *“You can't proceed with the sign-up process until you add a valid payment method.”* |
| Account activation email (minutes–24h) | Hard (gate) | Same |
| S3 service signup | Automatic with account | [Setting up Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/creating-bucket.html): signing up for AWS signs you up for S3; pay only for use |
| Tax / invoice settings | Optional / as needed | Billing User Guide (not a CreateBucket gate) |

### Identity for APIs (not root-as-daily)

| Item | Class | Source |
| --- | --- | --- |
| Non-root principal that can call S3 (and IAM if managing users) | Hard for *safe* ops; root can call APIs but is discouraged | [IAM intro](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html); [root best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html) |
| Root MFA | Good practice (enforced for console) | [Root MFA](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html#ru-bp-mfa) |
| Identity Center or admin IAM user/role | Good practice | [Setting up your AWS account](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started-account-iam.html) |
| Activate IAM access to Billing console | Good practice if IAM should see bills | Same; root-only activation step |

### Region

| Item | Class | Notes |
| --- | --- | --- |
| Choose Region at bucket create | Hard (immutable after create) | [Creating a bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/creating-bucket.html): can’t change Region later; objects stay in Region unless you move them |
| Provider `region` / `AWS_REGION` for Terraform | Hard for Apply | [TF AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs) |

S3 general-purpose buckets are **regional** resources with names in a **partition-global** namespace ([naming rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html)).

### What is *not* required for S3

| Item | Class | Notes |
| --- | --- | --- |
| Default VPC / any VPC | Not required | S3 is a regional HTTPS API; no VPC dependency in setup docs |
| CloudTrail | Optional governance | Recommended for auditing access keys ([access keys monitoring](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)) |
| AWS Config | Optional governance | e.g. root access-key Config rules referenced from root best practices |
| AWS Organizations | Optional governance | Multi-account guardrails / centralized root; not needed for one solo account + one bucket |
| EC2, IAM Identity Center “org” features | Optional | Identity Center is recommended for humans but S3 works with IAM users/roles alone |

### Terraform-side scaffolding

| Item | Class | Source |
| --- | --- | --- |
| `provider "aws" { region = … }` (or env Region) | Hard | TF AWS docs |
| Credentials available to the operator process | Hard | Env / profile / shared config — see §1b |
| `required_providers` version constraint | Good practice | TF AWS example uses version pins; Propraetor ADR-0025 requires **exact** provider versions for lifecycle correctness on the DO side — same discipline should apply to `hashicorp/aws` |
| Separate resources for BPA, versioning, encryption, etc. | Good practice (current provider) | Modern `aws_s3_bucket` is stripped; companion resources manage settings ([`aws_s3_bucket` docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket)) |

### Bucket naming, ownership, Block Public Access

| Item | Class | Source |
| --- | --- | --- |
| Globally unique name (shared global namespace) **or** account-regional namespace form `…-accountId-region-an` | Hard | [Bucket naming rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html) |
| DNS-compatible length/charset rules | Hard | Same |
| Default **Block Public Access** all four settings ON for new buckets | Current default (since 2023-04) | [Creating a bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/creating-bucket.html); [Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html); S3 What’s New 2023-04-27 |
| Default **Object Ownership = Bucket owner enforced** (ACLs disabled) | Current default | [Object Ownership](https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html) |
| After delete in global namespace, another account may claim the name | Operational risk | [Naming rules — Important](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html) |

For private Workload storage: keep BPA enabled (**good practice**). Turning BPA off requires extra permission (`s3:PutBucketPublicAccessBlock`).

### Chicken-egg: IAM users/keys *inside* the same Stack as the bucket

**High.**

- The Terraform **provider** must already authenticate as a principal that can create S3 (and IAM, if creating users/keys). That principal is **out-of-band** relative to Stack-managed IAM resources — classic Bootstrap: credentials before resources.
- Creating `aws_iam_user` + `aws_iam_access_key` + `aws_s3_bucket` in one root is fine **once** the operator Provider Credential can call both APIs; there is no AWS requirement to create the bucket before the user or vice versa for a greenfield account.
- Sensitive: access key secret appears in Terraform State → State protection becomes part of Durable risk (see §3).

### Operators often forget

| Gotcha | Class |
| --- | --- |
| Payment method required at signup | Hard |
| Waiting for account activation | Hard |
| Assuming “S3 needs a VPC” | Myth |
| Using root keys because they’re the only keys that exist after signup | Anti-pattern (good practice: create admin identity first) |
| Bucket name collision in global namespace / Environment naming | Hard / good practice |
| Emptying bucket before destroy (`force_destroy` semantics in TF) | Operational |
| Confusing Provider Credential (manage) with Environment Configuration (Workload I/O) | Product |

---

## 3. Tensions with Propraetor’s current model

Acknowledged without belaboring: one Terraform root with `digitalocean` + `aws` already stretches the glossary **Stack** gloss (“one provider or concern”). #148 prefers one cohesive lifecycle slice; that fight is known. Below are **additional** tensions from AWS auth/scaffolding reality.

Severity: **strong** = blocks or forces glossary/ADR change before a stable product shape; **moderate** = explicit design decision; **weak** = docs / allowlist extension.

| # | Tension | Severity | Mapping |
| --- | --- | --- | --- |
| T1 | **Two Provider Credential bags** (DO token vs AWS key/role/session) vs ADR-0038 allowlist (`DIGITALOCEAN_TOKEN` only) and “one account” mental model | **Strong** (contract) / **Weak** (mechanics) | Extending allowlist is a small ADR-0038 change; documenting *which* AWS principal and forbidding root is the strong part. Temporary sessions need `AWS_SESSION_TOKEN` (and often `AWS_PROFILE`) — not a single static secret like DO. |
| T2 | **Environment = namespace under one provider account** (ADR-0019) vs AWS **account** as separate tenancy | **Moderate** | One AWS account + Environment-prefixed bucket names mirrors DO naming (`propraetor-<slug>-…`) and keeps one Provider Credential. Multiple AWS accounts per Environment is optional Organizations governance — not required by S3. Does **not** map 1:1 to “one DO token isolates nothing; Environment isolates names.” AWS account *can* isolate blast radius in a way DO token cannot — tempting but heavier than ADR-0019’s rejected “separate accounts for isolation.” |
| T3 | **Cloud Project** has no S3 analogue | **Weak** | CONTEXT: Cloud Project is DO UI/billing folder. S3 won’t join it. Cost allocation **tags** on buckets are optional AWS-side scaffolding — don’t invent a fake Cloud Project. |
| T4 | **IAM material as Durable** (users/access keys in State) | **Strong** | Park preserves Durables → keys remain live attack surface while Hosts are gone. Teardown wipes Durables → destroys keys+bucket together (good for cleanup, bad if Workloads still need objects). Secrets in State conflict with “Provider Credential never committed” discipline. Prefer: bucket Durable; Workload secrets via **Environment Configuration** (rotation = re-Setup); or Escape Hatch (operator-owned bucket+keys, unsupported). |
| T5 | Docs that only say “put `AWS_*` in `.env`” → **root key footgun** | **Strong** | After signup, root is the only ready identity. AWS: don’t create root access keys. Propraetor Bootstrap/docs must say: create IAM (or Identity Center) admin first; put *those* credentials in Provider Credential; never root. |
| T6 | Acceptance / Lifecycle Tests need a **second live credential matrix** | **Moderate** | ADR-0025 already requires live test-Environment matrix for lifecycle/provider changes. Adding AWS means CI/operator must hold DO **and** AWS credentials, and Park/Apply/Teardown must no-op correctly with S3 Durable present. Cost is usage-based but operational complexity doubles. |
| T7 | **Workload wiring**: Environment Configuration vs Stack-managed IAM | **Moderate** / **Strong** if wrong default | CONTEXT: Environment Configuration is the bag Workloads receive; Provider Credential must not be listed in Manifest `environment`. Object-store endpoint + keys belong in Environment Configuration (or generated into it). Stack-managed keys blur Provider Credential vs Environment Configuration and put secrets in State. |
| T8 | **Park semantics** for IAM users/keys created for Workloads | **Strong** | Bucket as Durable fits Park (keep data, drop Hosts). IAM user+key: Durable ⇒ survives Park (ongoing credential risk); Recreatable ⇒ Park deletes keys (Workloads break until Apply — odd for “cost convenience”); Escape Hatch ⇒ Propraetor doesn’t own them. Needs an explicit class decision before implementation. |
| T9 | **Bootstrap** today is DO-complete; AWS provider wiring is new Bootstrap surface | **Moderate** | CONTEXT Bootstrap = provider config, version pins, auth wiring, state backend — *without* managed resources. Adding `hashicorp/aws` + auth wiring is Bootstrap work **even with zero AWS Hosts**. Bucket resources are post-Bootstrap Durables. Remote State on S3 remains out of scope for #148 (chicken-egg if same Stack creates the backend bucket). |
| T10 | Glossary “one provider account” for Environment vs multi-provider Apply | **Moderate** | Literal reading breaks. Product fix options: (a) redefine Environment as one lifecycle namespace spanning N provider accounts/credentials; (b) keep Environment DO-centric and treat AWS as an attached Durable under the same slug; (c) split Stacks (rejected by #148 preferred path). Triage must pick before coding. |

### Credential bag summary (Propraetor vocabulary)

```text
Provider Credential (repo-root .env / process)
  DIGITALOCEAN_TOKEN          → manage DO Hosts / Durables
  AWS_*  (or profile/session) → manage AWS bucket (+ optional IAM)
        ≠ Workload object I/O secrets

Environment Configuration (environments/<slug>/.env)
  e.g. S3_BUCKET / AWS_ACCESS_KEY_ID / … for Workloads
  Manifest environment: lists keys Workloads receive
  Must not reuse Provider Credential names casually (CONTEXT guidance)
```

### Alignment with #148 open questions

| #148 question | Research pointer |
| --- | --- |
| Platform Durable vs Escape Hatch? | Scaffolding cost is low; **auth/credential bag** design is the hard part. Escape Hatch avoids ADR-0038/IAM/Park complexity. |
| One bucket per Environment? | Fits ADR-0019 naming; global uniqueness → include account id or GUID/suffix ([naming best practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html)). |
| How Workloads get creds? | Prefer Environment Configuration; avoid State-held access keys if possible. |
| IAM managed vs operator-supplied? | AWS prefers temporary; Propraetor off-AWS Hosts make long-term keys the pragmatic path — own them in Environment Configuration, not as silent root Provider Credential. |
| Second live credential matrix? | Yes before merge if AWS is in the Stack (ADR-0025 spirit). |

---

## Open questions / implications for Propraetor

1. **ADR-0038 shape:** allowlist `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, and/or `AWS_PROFILE`? Fail closed if only root keys are detectable? (Detection is imperfect — documentation + operator checklist may be enough.)
2. **Bootstrap definition:** when is AWS “Bootstrapped” — provider block only, or first successful authenticated plan against S3?
3. **Durable set:** bucket (+ encryption/versioning/BPA resources) only, or also IAM user/policy/key? If IAM is in-Stack, what is its Park class?
4. **Teardown UX:** destroying a globally named bucket frees the name for other accounts — confirm copy in Teardown messaging ([naming rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html)).
5. **Least-privilege operator policy:** ship a documented customer-managed policy example (CreateBucket + configure + DeleteBucket, optional IAM subset) rather than implying AdministratorAccess / root.
6. **Glossary edits** for multi-provider Environment / Stack — product shape first (#148), then CONTEXT/ADR-0019 wording.

---

## Confidence legend

| Label | Meaning |
| --- | --- |
| **High** | Stated directly on current AWS or HashiCorp primary docs |
| **Medium** | Combined from multiple official pages or depends on exact Terraform resource set |
| **Inference** | Logical consequence for Propraetor; not an AWS normative claim |
