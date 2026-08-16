# S0 — Account, Terraform, and the Two Spikes: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended)
> or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** Stand up everything that must be true before application code can deploy — the AWS
account, the Terraform estate, and a CI pipeline that puts a Rust binary behind CloudFront — and
answer both open verifications in §11 before anything depends on them.

**Architecture:** One AWS account in the existing organization, us-east-2, holding a flat Terraform
root module applied from a laptop under SSO. A single ARM64 `provided.al2023` Lambda sits behind an
`AWS_IAM` Function URL, reachable only through a CloudFront distribution with origin access control;
a viewer-request CloudFront Function moves the viewer's `Authorization` header aside so OAC can claim
it for SigV4. GitHub Actions deploys the zip through OIDC. Nothing user-facing ships: the Lambda
serves a diagnostic handler whose whole job is to report what reached it, which is also the
instrument Spike B reads.

**Tech Stack:** Terraform ≥ 1.10 with `hashicorp/aws ~> 6.37`; Rust 2024 on
`aarch64-unknown-linux-musl` with `lambda_http`; `sqlx` + `aurora-dsql-sqlx-connector` (spike only);
GitHub Actions via `jluszcz/github-utils@v2`; AWS Lambda, CloudFront, Aurora DSQL, S3, IAM, Budgets.

**Spec:** [`docs/superpowers/specs/2026-08-02-async-tv-discussion-design.md`](../specs/2026-08-02-async-tv-discussion-design.md)

**Staging:** [`docs/superpowers/plans/2026-08-16-implementation-staging.md`](2026-08-16-implementation-staging.md) — S0

---

## Global Constraints

Every task's requirements implicitly include this section.

**Account and region**

- Spoilies lives in **its own AWS account**, inside the existing organization, in **us-east-2**. (§9)
- The account must **never be a delegated administrator** for any org-enabled service — that is one
  of the three requirements for `RemoveAccountFromOrganization`. (§9)
- **Four days must pass** between account creation and any possible removal from the organization,
  which is why the account is created first. (§9, §10 P0)
- A **dedicated root email alias**, not a personal address. (§9)
- **Never IAM Identity Center for workload identity.** It is org-level and dies at separation. Fine
  for human console access; never for anything the application depends on. (§9)
- **No org CloudTrail trail, Config aggregator, or RAM share** in the dependency path. (§9)

**Terraform**

- **Applied from a laptop with an active SSO session, never from CI.** (§9)
- CI's Terraform job runs `init -backend=false`, `fmt -check`, and `validate` — **offline, with no
  AWS credentials configured at all**. (§9)
- **Terraform state lives in a bucket in this account**, never `jluszcz-tf-state`. The bucket cannot
  be a resource in the configuration it stores, so it is created by a hand-run script. (§9)
- **The code bucket, GitHub OIDC provider, and deploy roles are `resource`s here, not `data`
  sources.** This is a deliberate departure from the JakeSky pattern. (§9)
- `required_version = ">= 1.10"` (the floor for `use_lockfile`), `aws ~> 6.37`, and
  `.terraform.lock.hcl` committed — matching `AmazonWebServices`.

**Runtime and deploy**

- Rust on **`provided.al2023` / ARM64**. (§3)
- Target triple **`aarch64-unknown-linux-musl`**. (README, `.github/workflows/ci.yml`)
- `github-utils`' `lambda-package.yml` copies `target/<triple>/release/lambda` to `bootstrap`, so
  **the binary must be named `lambda`**.
- `deploy-lambda.yml` hardcodes the code bucket as `code-<account-id>-<region>-an`, so **the code
  bucket name is not a free choice**.
- Deploy flow: GitHub OIDC → assume the deploy role → `PutObject` the zip →
  `lambda:UpdateFunctionCode` → `aws lambda wait function-updated-v2`. **LambdUpdate is not part of
  this.** (§9)
- Role names `spoilies.github-deploy` and `spoilies.github-migrate`; single-region, so
  `regional: false` and **no suffix**. (§9)

**Security posture**

- Function URL is **`AWS_IAM`, never `NONE`**, fronted by CloudFront OAC. Direct calls get 403. (§3)
- **Lambda reserved concurrency cap of 10** — §6 names it the highest-value control in the design,
  and §6.4 leans on it to make per-instance rate limiting a provable global bound.
- **An AWS Budgets alarm.** (§6)
- **Explicitly not AWS WAF** — ~$5/mo before a single request. (§6)
- The deploy role is trusted broadly across the repo; the migrate role is trusted **from `main`
  only**, because `dsql:DbConnectAdmin` is the strongest permission in the design and cannot be
  scoped below the cluster. (§7, §9)

**Two spec corrections established while writing this plan** — both verified, both load-bearing:

1. **The GitHub OIDC subject prefix for this repository is not the form §9 names.** §9 writes the
   trust conditions as `repo:jluszcz/Spoilies:*` and
   `repo:jluszcz/Spoilies:ref:refs/heads/main`. Repositories created after 2026-07-15 use GitHub's
   immutable subject format, which embeds owner and repository IDs. Spoilies was created
   2026-08-02, and the live API confirms it:

   ```console
   $ gh api repos/jluszcz/Spoilies/actions/oidc/customization/sub
   {"use_default":true,"use_immutable_subject":false,"sub_claim_prefix":"repo:jluszcz@4526414/Spoilies@1320196357"}

   $ gh api repos/jluszcz/JakeSky-rs/actions/oidc/customization/sub   # pre-cutoff control
   {"use_default":true,"use_immutable_subject":false,"sub_claim_prefix":"repo:jluszcz/JakeSky-rs"}
   ```

   **The effective prefix is `repo:jluszcz@4526414/Spoilies@1320196357`.** Copying JakeSky's
   name-only condition would produce a trust policy that never matches, surfacing as an opaque
   `AssumeRoleWithWebIdentity` denial on the first deploy. Task 6 carries it in a variable so the
   value is checkable against the API rather than buried in a policy document.

2. **§7's "trusted only from `main`" and "behind a GitHub Environment" cannot both live in one
   `sub` condition.** AWS IAM honours only `aud` and `sub` from a GitHub OIDC token — the `ref`,
   `environment`, and `job_workflow_ref` claims are ignored — and a job declaring `environment:`
   gets `…:environment:NAME` as its `sub` *instead of* `…:ref:refs/heads/main`, not in addition to
   it. S0 therefore implements the branch restriction, which is the security boundary, and Task 6
   records the choice S1b must make if the approval gate is ever wanted.

**Repository conventions to follow** (from `AmazonWebServices`, `JakeSky-rs`, and this repo)

- One flat Terraform root module named after the project: `spoilies.tf`.
- `default_tags` on the provider (`ManagedBy`, `Repo`), so spend can be attributed.
- Every S3 bucket: public access fully blocked, KMS encryption with `bucket_key_enabled`, an
  `abort-mpu` lifecycle rule at 7 days, and `filter {}` declared explicitly on every lifecycle rule.
- Every lifecycle rule carries an empty `filter {}`; omitting it relies on provider-version-specific
  leniency and is a recurring source of `MalformedXML` breakage on upgrades.
- Commits go on a branch, never straight to `main`, via the `jluszcz:commit` skill.
- `.gitignore` is kept sorted — the `file-contents-sorter` pre-commit hook rewrites it otherwise.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/bootstrap-tf-state.sh` | **Create** — hand-run, idempotent creation of the Terraform state bucket. The one thing that cannot be a Terraform resource. |
| `spoilies.tf` | **Create** — the entire Terraform root module. Flat by choice, matching `AmazonWebServices`: one bucket, one function, one distribution, and a handful of IAM resources do not need a `modules/` tree. |
| `cloudfront/forward-authorization.js` | **Create** — the viewer-request CloudFront Function. Its own file so `terraform fmt` never touches JavaScript and the function is reviewable as code. |
| `.terraform.lock.hcl` | **Create** (generated, committed) — pins the provider build for every clone and CI run. |
| `Cargo.toml` | **Modify** — add the `lambda` bin target and the `lambda_http` dependencies. |
| `src/main.rs` | **Modify** — replace the placeholder with the S0 diagnostic handler. Replaced again by S1a's axum router. |
| `.github/workflows/ci.yml` | **Modify** — add the `terraform` job, then the `package` and `deploy` jobs. |
| `.pre-commit-config.yaml` | **Modify** — add a `terraform fmt` hook alongside `cargo fmt`. |
| `.gitignore` | **Modify** — ignore `.terraform/` and state files while keeping `.terraform.lock.hcl`. |
| `docs/superpowers/spikes/2026-08-16-sqlx-offline-musl-arm.md` | **Create** — Spike A's written answer. |
| `docs/superpowers/spikes/2026-08-16-cloudfront-oac-auth-transport.md` | **Create** — Spike B's written answer. |
| `CLAUDE.md` | **Create** — repository guidance, written once the shape is real rather than guessed. |
| `README.md` | **Modify** — bootstrap, Terraform, and deploy sections. |

Both spike write-ups are permanent; the code the spikes produce is not. §S0 of the staging document:
*"Whatever they prove gets written down; whatever code they produce gets deleted or reduced to the
one working configuration."*

---

## Task 1: The AWS account and the Terraform state bucket

**Files:**
- Create: `scripts/bootstrap-tf-state.sh`
- Modify: `README.md`
- Modify (outside the repo): `~/.aws/config`

**Interfaces:**
- Produces: an AWS account id (referred to below as `$SPOILIES_ACCOUNT_ID`); an
  `aws` CLI profile named `spoilies`; an S3 bucket `spoilies-tf-state` in us-east-2 that Task 3's
  `backend "s3"` block points at.

**Why first:** Principle 1 of the staging document. The account has a four-day clock on it (§9), it
costs nothing to create early, and it cannot be accelerated later.

- [ ] **Step 1: Create the working branch**

Per the repository rules, branch before the first commit and give it an upstream.

```bash
git fetch origin
git switch -c s0-account-and-spikes --track origin/main
git status -sb   # must print: ## s0-account-and-spikes...origin/main
```

- [ ] **Step 2: Choose the root email address**

§9 requires *"a dedicated root email that can be handed to a company later — an alias, not a personal
address."* This value is deliberately not written into the repository. Before running Step 3, decide
the address and hold it in a shell variable:

```bash
read -r "SPOILIES_ROOT_EMAIL?Root email for the Spoilies AWS account: "
```

Two facts to weigh, both already established: §8 registers no domain, so no genuinely transferable
address exists yet; and AWS supports changing an account's root email later, so this is reversible
if the project ever acquires one.

- [ ] **Step 3: Create the account in the organization**

Run from the management account (`386619136577`) with an active SSO session.

```bash
aws sso login --profile default

aws organizations create-account \
  --profile default \
  --email "$SPOILIES_ROOT_EMAIL" \
  --account-name Spoilies \
  --role-name OrganizationAccountAccessRole \
  --iam-user-access-to-billing ALLOW
```

Capture the `CreateAccountStatus.Id` from the output, then poll until it succeeds:

```bash
aws organizations describe-create-account-status \
  --profile default \
  --create-account-request-id <car-XXXXXXXX>
```

Expected: `"State": "SUCCEEDED"` and an `AccountId`. Export it:

```bash
export SPOILIES_ACCOUNT_ID=<the 12-digit account id>
```

**Do not** register this account as a delegated administrator for any service. Doing so blocks
`RemoveAccountFromOrganization` permanently, which is the one thing the separate-account topology
exists to keep available (§9).

- [ ] **Step 4: Record the four-day clock**

Note the creation date in the branch's first commit message. §9: removal from the organization
requires four days since creation, and that clock starts now.

- [ ] **Step 5: Add the `spoilies` CLI profile**

§9 is explicit that the first apply *"necessarily runs through `OrganizationAccountAccessRole`
assumed from the management account"*, because an org-created account has no other credential path
initially. Append to `~/.aws/config`, substituting the account id:

```ini
[profile spoilies]
region = us-east-2
role_arn = arn:aws:iam::<SPOILIES_ACCOUNT_ID>:role/OrganizationAccountAccessRole
source_profile = default
cli_pager =
```

Verify:

```bash
aws sts get-caller-identity --profile spoilies
```

Expected: an `Arn` of the form
`arn:aws:sts::<SPOILIES_ACCOUNT_ID>:assumed-role/OrganizationAccountAccessRole/...` and an `Account`
matching `$SPOILIES_ACCOUNT_ID`.

- [ ] **Step 6: Write the state bucket bootstrap script**

The bucket holding Terraform state cannot be a resource in the configuration it stores, so it is
scripted (§9). Create `scripts/bootstrap-tf-state.sh`:

```bash
#!/usr/bin/env bash
#
# Creates the Terraform state bucket for Spoilies.
#
# This is the one piece of the estate that cannot be a Terraform resource: it is
# where Terraform's own state lives, so the configuration that stores state there
# cannot also create it. Everything else in the account is in spoilies.tf.
#
# Idempotent — safe to re-run. Settings match the conventions in the
# AmazonWebServices repo: versioning, public access fully blocked, KMS at rest
# with a bucket key, incomplete uploads aborted after 7 days, and superseded
# versions expired after 30 days.

set -euo pipefail

BUCKET="${BUCKET:-spoilies-tf-state}"
REGION="${REGION:-us-east-2}"
PROFILE="${AWS_PROFILE:-spoilies}"

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "Bucket $BUCKET already exists; reconciling settings."
else
    echo "Creating $BUCKET in $REGION."
    aws s3api create-bucket \
        --bucket "$BUCKET" \
        --create-bucket-configuration "LocationConstraint=$REGION"
fi

# Versioning first: it is what makes a corrupted or truncated state file
# recoverable, and the lifecycle rule below assumes it is on.
aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"},
            "BucketKeyEnabled": true
        }]
    }'

aws s3api put-bucket-lifecycle-configuration \
    --bucket "$BUCKET" \
    --lifecycle-configuration '{
        "Rules": [
            {
                "ID": "delete-old-versions-rule",
                "Status": "Enabled",
                "Filter": {},
                "NoncurrentVersionExpiration": {"NoncurrentDays": 30}
            },
            {
                "ID": "abort-mpu",
                "Status": "Enabled",
                "Filter": {},
                "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
            }
        ]
    }'

echo "Done. Terraform backend bucket: s3://$BUCKET (region $REGION)."
```

```bash
chmod +x scripts/bootstrap-tf-state.sh
```

- [ ] **Step 7: Run it, and run it again**

```bash
./scripts/bootstrap-tf-state.sh
./scripts/bootstrap-tf-state.sh
```

Expected: the first run prints `Creating spoilies-tf-state in us-east-2.`; the second prints
`Bucket spoilies-tf-state already exists; reconciling settings.` Both exit 0.

- [ ] **Step 8: Verify the bucket's settings**

```bash
aws s3api get-bucket-versioning --profile spoilies --bucket spoilies-tf-state
aws s3api get-public-access-block --profile spoilies --bucket spoilies-tf-state
aws s3api get-bucket-encryption --profile spoilies --bucket spoilies-tf-state
aws s3api get-bucket-lifecycle-configuration --profile spoilies --bucket spoilies-tf-state
```

Expected, in order: `"Status": "Enabled"`; all four public-access flags `true`; an
`"SSEAlgorithm": "aws:kms"` rule with `"BucketKeyEnabled": true`; and two rules with ids
`delete-old-versions-rule` and `abort-mpu`.

- [ ] **Step 9: Document the bootstrap in the README**

Add this section to `README.md`, immediately before `## Prior art`:

````markdown
## Infrastructure

Spoilies lives in its own AWS account in `us-east-2`, inside the existing organization, so it can be
separated later without untangling anything. The account topology and its reasoning are in §9 of the
design spec.

### Bootstrap (once per account)

Terraform's state bucket cannot be a resource in the configuration it stores, so it is created by a
script rather than by Terraform:

```sh
./scripts/bootstrap-tf-state.sh
```

Idempotent, and safe to re-run to reconcile the bucket's settings. It expects an `AWS_PROFILE` that
can administer the Spoilies account; it defaults to a profile named `spoilies`.
````

- [ ] **Step 10: Commit**

```bash
git add scripts/bootstrap-tf-state.sh README.md
git commit
```

Use the `jluszcz:commit` skill. The message should record the account creation date, since Step 4's
four-day clock is otherwise written down nowhere.

---

## Task 2: Spike A — `sqlx` offline mode and the DSQL connector on musl/ARM

**Files:**
- Create: `docs/superpowers/spikes/2026-08-16-sqlx-offline-musl-arm.md`
- Temporary (deleted in Step 9): `Cargo.toml` dependency block, `src/main.rs` probe, `.sqlx/`,
  `migrations/0001_spike.sql`

**Interfaces:**
- Produces: a written verdict, and the exact `Cargo.toml` dependency stanza S1b copies. If the
  verdict is negative, it produces instead the decision to drop the `sqlx::query!` macros — which
  forfeits the compile-time checking §3 lists as a deciding advantage of Rust, and is a design-level
  answer that belongs before S1b rather than during it.

**Why here:** Principle 2. This has **no dependency on Tasks 3–9** — it touches only the repository —
so it runs at the earliest point after the account clock starts. Its answer changes how S1b is built.

**The question, stated precisely (§11):** `sqlx`'s compile-time query checking needs either a live
Postgres at build time or a committed `.sqlx` cache, and CI cross-compiles to
`aarch64-unknown-linux-musl` with no database. Verify in the same spike that the AWS DSQL SQLx
connector's TLS stack builds and links on that target.

**What the dependency graph says before the spike runs** — established while writing this plan, so
the spike confirms or refutes something concrete rather than exploring:

- `aurora-dsql-sqlx-connector` is at **0.2.2**, not the 0.1.2 the AWS documentation shows.
- It requires `sqlx ^0.9` with features `runtime-tokio`, `postgres`, **`tls-rustls-ring`**. A pure-Rust
  TLS stack is exactly what makes musl linking plausible, so `sqlx` itself is the low-risk half.
- **The risk sits in `aws-config ^1.8`**, which the connector pulls in non-optionally for credentials.
  The AWS SDK's Smithy runtime brings its own crypto provider, and `aws-lc-rs` needs a C toolchain and
  does not cross-compile to musl as reliably as `ring`. That is the specific link failure to watch for.
- Its own features are `pool` (background token refresh) and `occ` (`retry_on_occ`, `is_occ_error`).
- Its MSRV is **1.94**; the local toolchain is 1.97.

- [ ] **Step 1: Install a local Postgres**

`cargo sqlx prepare` needs a live database once, to generate the cache. There is no container runtime
on this machine, so Homebrew is the shortest path:

```bash
brew install postgresql@18
brew services start postgresql@18
export PATH="$(brew --prefix postgresql@18)/bin:$PATH"
psql --version
```

Expected: `psql (PostgreSQL) 18.x`.

*(S1a's testcontainers harness will need a real container runtime — Colima or Docker Desktop. That is
an S1a prerequisite, noted in Task 10, not something this spike needs.)*

- [ ] **Step 2: Install the sqlx CLI**

```bash
cargo install sqlx-cli --no-default-features --features postgres,rustls
cargo sqlx --version
```

- [ ] **Step 3: Create the spike branch**

Branch from `origin/main`, not from the working branch: this is throwaway code that opens its own
draft PR, and it should not drag Task 1's commits through that PR.

```bash
git fetch origin
git switch -c spike/sqlx-offline-musl --track origin/main
```

- [ ] **Step 4: Add the dependencies under test**

Append to `Cargo.toml`'s `[dependencies]`:

```toml
sqlx = { version = "0.9", default-features = false, features = [
    "runtime-tokio",
    "tls-rustls-ring",
    "postgres",
    "uuid",
    "chrono",
    "macros",
] }
aurora-dsql-sqlx-connector = { version = "0.2.2", features = ["pool", "occ"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
```

- [ ] **Step 5: Write the probe**

The probe has to contain a real `sqlx::query!` macro invocation, because the macro is the thing under
test — a plain `sqlx::query` would compile whether or not offline mode works. Replace `src/main.rs`:

```rust
//! Spike A probe. Deleted in Task 2, Step 9 — see
//! `docs/superpowers/spikes/2026-08-16-sqlx-offline-musl-arm.md`.

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Referenced so the connector is linked rather than merely resolved: a
    // dependency that is never called can be dropped before the linker sees it,
    // which would make this spike pass for the wrong reason.
    let opts = aurora_dsql_sqlx_connector::DsqlConnectOptions::from_connection_string(
        "postgres://admin@example.dsql.us-east-2.on.aws/postgres",
    )?;
    println!("connector parsed options: {opts:?}");

    let url = std::env::var("DATABASE_URL")?;
    let pool = sqlx::PgPool::connect(&url).await?;

    // The macro under test: checked against the schema at compile time.
    let row = sqlx::query!("SELECT name FROM spike WHERE id = $1", 1_i32)
        .fetch_one(&pool)
        .await?;
    println!("spike row: {}", row.name);

    Ok(())
}
```

- [ ] **Step 6: Create the schema and generate the cache**

```bash
mkdir -p migrations
cat > migrations/0001_spike.sql <<'SQL'
CREATE TABLE spike (id INT PRIMARY KEY, name TEXT NOT NULL);
SQL

export DATABASE_URL="postgres://$USER@localhost/spoilies_spike"
cargo sqlx database create
cargo sqlx migrate run
cargo sqlx prepare
```

Expected: a `.sqlx/` directory containing one `query-*.json` file.

- [ ] **Step 7: Prove the cache builds with no database in reach**

```bash
unset DATABASE_URL
SQLX_OFFLINE=true cargo build
```

Expected: PASS. `SQLX_OFFLINE=true` matters specifically because *"the presence of a `DATABASE_URL`
environment variable will take precedence over the presence of `.sqlx`"* — without it, a build that
happens to have `DATABASE_URL` set would prove nothing.

Then confirm the CI guard works, since S1b's CI will depend on it:

```bash
SQLX_OFFLINE=true cargo sqlx prepare --check
```

Expected: PASS. This is what stops the cache silently drifting from the queries.

- [ ] **Step 8: Prove it links on musl/ARM — in CI, not locally**

Cross-compiling to `aarch64-unknown-linux-musl` from macOS needs a musl cross-linker that is not
installed and is fiddly to get right. The repository's existing CI job already builds that target on
`ubuntu-24.04-arm` with `musl-tools`, which is the environment the answer is actually about. Use it:

```bash
git add Cargo.toml Cargo.lock src/main.rs migrations/ .sqlx/
git commit -m "spike: sqlx offline mode and DSQL connector on musl/ARM"
git push -u origin spike/sqlx-offline-musl
gh pr create --draft --title "Spike A: sqlx offline mode on musl/ARM" \
  --body "Throwaway. Verifying §11's sqlx offline question and the DSQL connector's TLS stack on aarch64-unknown-linux-musl. Not for merge."
gh run watch
```

Expected on success: the `Build, Test & Lint` job passes, meaning
`cargo build --target aarch64-unknown-linux-musl` linked with both `sqlx` and
`aurora-dsql-sqlx-connector` present.

If it fails, capture the failing linker output verbatim — it is the finding — and check whether the
cause is the crypto provider:

```bash
cargo tree --target aarch64-unknown-linux-musl -i aws-lc-rs
cargo tree --target aarch64-unknown-linux-musl -i ring
cargo tree --target aarch64-unknown-linux-musl -i openssl-sys
```

Expected on a clean result: `ring` present, `aws-lc-sys`/`openssl-sys` absent. If `aws-lc-sys` is
present, the remedy to try is forcing the SDK onto `ring` via a `[patch]` or an explicit
`aws-smithy-runtime` feature selection — and whether that works is itself part of the finding.

- [ ] **Step 9: Write the answer, then delete the code**

Create `docs/superpowers/spikes/2026-08-16-sqlx-offline-musl-arm.md`:

```markdown
# Spike A — `sqlx` offline mode and the DSQL connector on musl/ARM

**Date:** 2026-08-16
**Question (§11):** Compile-time query checking needs a live Postgres at build time or a committed
`.sqlx` cache, and CI cross-compiles to `aarch64-unknown-linux-musl` with no database. Does offline
mode work there, and does the AWS DSQL SQLx connector's TLS stack build and link on that target?
**Stage:** S0. Consumed by S1b.

## Verdict

<!-- One of: "Offline mode works and the connector links." / "Offline mode works; the connector
does not link, because …" / "Neither works, because …" — followed by the consequence for S1b. -->

## What was run

<!-- Toolchain versions, the exact commands from Task 2, and the CI run URL. -->

## Findings

<!-- Resolved versions. Whether `.sqlx` alone sufficed. Whether `SQLX_OFFLINE=true` was required.
What `cargo tree -i aws-lc-rs` / `-i ring` / `-i openssl-sys` reported. The linker output if it
failed. -->

## The configuration S1b should use

<!-- The exact Cargo.toml stanza that worked, verbatim, and the CI steps that go with it:
where `SQLX_OFFLINE=true` is set and where `cargo sqlx prepare --check` runs. -->

## If the verdict is negative

The fallback is `sqlx::query` without the macros, which forfeits the compile-time checking §3 lists
as a deciding advantage of Rust. That is a design-level change and it is recorded here rather than
discovered during S1b.

## Carried forward beyond the question asked

`aurora-dsql-sqlx-connector` ships `retry_on_occ` and `OCCRetryConfig` behind its `occ` feature —
three attempts with exponential backoff and jitter. S1b's `db::retry` (§7: three attempts on
SQLSTATE `40001`, then 409) may be able to wrap this rather than reimplement it. S1b's plan should
decide deliberately, because §7's contract adds a specific status mapping the connector does not
have.
```

Fill in every section from what actually happened. Then reduce the code to nothing:

```bash
git checkout origin/main -- Cargo.toml Cargo.lock src/main.rs
rm -rf .sqlx migrations
git add -A
git commit -m "docs: record Spike A's answer and delete the probe"
```

- [ ] **Step 10: Land the write-up on the working branch**

```bash
git switch s0-account-and-spikes
git checkout spike/sqlx-offline-musl -- docs/superpowers/spikes/2026-08-16-sqlx-offline-musl-arm.md
git add docs/superpowers/spikes/
git commit
gh pr close --delete-branch spike/sqlx-offline-musl
```

Verify the working tree is clean of spike residue before continuing:

```bash
git status --short          # expected: empty
cargo build                 # expected: PASS, with the placeholder main.rs
```

---

## Task 3: Terraform root — backend, provider, code bucket, and the budget

**Files:**
- Create: `spoilies.tf`
- Create (generated, committed): `.terraform.lock.hcl`
- Modify: `.github/workflows/ci.yml`
- Modify: `.pre-commit-config.yaml`
- Modify: `.gitignore`
- Modify: `README.md`

**Interfaces:**
- Consumes: `spoilies-tf-state` and the `spoilies` profile from Task 1.
- Produces: `aws_s3_bucket.code` (named `code-<account-id>-us-east-2-an`, which `deploy-lambda.yml`
  hardcodes); `data.aws_caller_identity.current`; `var.aws_region`; `local.default_tags`. Tasks 5, 6,
  and 7 append to this same file.

- [ ] **Step 1: Write the root module**

Create `spoilies.tf`. This is the whole file at this point; later tasks append to it.

```hcl
terraform {
  # 1.10 is the floor for use_lockfile below.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.37"
    }
  }

  # The bucket is created by scripts/bootstrap-tf-state.sh, not by this
  # configuration: it holds this configuration's own state. It lives in the
  # Spoilies account rather than jluszcz-tf-state, so spinning the account out
  # of the organization never drags a state migration along with it (§9).
  backend "s3" {
    bucket = "spoilies-tf-state"
    key    = "spoilies"
    region = "us-east-2"

    # S3-native locking; no DynamoDB table required.
    use_lockfile = true
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "alert_email" {
  # No default: like the root address (Task 2, Step 2), a real address is never
  # written into the repository. Supply it as $TF_VAR_alert_email.
  type        = string
  description = "Address that receives budget notifications."
}

locals {
  # Without tags the cost budget can only report one undifferentiated number,
  # and the free tier is shared across the organization (§8) — so Spoilies'
  # own spend has to be separable from everything else in the family.
  default_tags = {
    ManagedBy = "terraform"
    Repo      = "Spoilies"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.default_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

/**************************************
* Code Bucket
**************************************/

# The name is not a free choice: github-utils' deploy-lambda.yml computes it as
# code-${account-id}-${region}-an and uploads there. Unlike the other projects,
# this is a `resource` rather than a `data` source — the AmazonWebServices repo
# does not reach into this account, and extending it to would recreate exactly
# the cross-account state dependency §9 exists to avoid.

resource "aws_s3_bucket" "code" {
  bucket           = format("code-%s-%s-an", data.aws_caller_identity.current.account_id, data.aws_region.current.region)
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket = aws_s3_bucket.code.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "code" {
  bucket = aws_s3_bucket.code.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true

    # Declared to match what S3 already enforces. Leaving it out makes the
    # provider plan it away on every run, which would silently permit
    # customer-provided-key uploads that the bucket currently rejects.
    blocked_encryption_types = ["SSE-C"]
  }
}

# Every lifecycle rule carries an empty `filter {}`: that is the explicit way to
# say "apply to all objects". Omitting both filter and prefix relies on
# provider-version-specific leniency and is a recurring source of MalformedXML
# breakage on provider upgrades.
resource "aws_s3_bucket_lifecycle_configuration" "code" {
  bucket = aws_s3_bucket.code.id

  rule {
    id     = "delete-old-versions-rule"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-mpu"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_versioning" "code" {
  bucket = aws_s3_bucket.code.id

  versioning_configuration {
    status = "Enabled"
  }
}

/**************************************
* Budget
**************************************/

# §6 pairs this with the reserved concurrency cap as the two controls against
# denial of wallet, and both are free.
#
# A fixed limit rather than the HISTORICAL auto-adjustment the AmazonWebServices
# repo uses: this account is days old and has no spend history, so a 3-month
# lookback would adjust to $0 and alarm on the first cent. §1's ceiling is a real
# number, so it serves directly as the limit.
resource "aws_budgets_budget" "monthly" {
  name              = "monthly"
  budget_type       = "COST"
  limit_amount      = "5"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-08-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 110
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  # Forecasts are suppressed until AWS has enough history and can swing wildly,
  # so an overrun that arrives late in the month may never trigger the one above.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "code_bucket" {
  value = aws_s3_bucket.code.bucket
}
```

- [ ] **Step 2: Teach git which Terraform files to track**

Replace `.gitignore` with the following. The `file-contents-sorter` pre-commit hook keeps this file
sorted, so the order matters — and note that `.terraform/` carries a trailing slash specifically so it
does not also match `.terraform.lock.hcl`, which **must** be committed.

```
**/*.rs.bk
**/mutants.out*/
*.tfstate
*.tfstate.*
.terraform.tfstate.lock.info
.terraform/
/.claude
/.idea
/target
```

- [ ] **Step 3: Verify the configuration offline, exactly as CI will**

```bash
terraform init -backend=false
terraform fmt -check -recursive -diff
terraform validate
```

Expected: all three PASS. `init -backend=false` is what keeps this offline — no S3 backend, no AWS
credentials. Running `terraform fmt` (without `-check`) first is fine if the diff is non-empty.

- [ ] **Step 4: Add the CI job**

`github-utils` has no Terraform workflow, so this job is inline, mirroring `AmazonWebServices`'
`ci.yml` step for step. Add it to `.github/workflows/ci.yml` as a sibling of the existing `ci` job,
and extend the push `paths` filter so Terraform-only changes still trigger a run:

```yaml
on:
  push:
    branches:
      - main

    paths:
      - '.github/workflows/**'
      - 'Cargo**'
      - 'src/**/*.rs'
      - '**.tf'
      - '.terraform.lock.hcl'
      - 'cloudfront/**'
```

```yaml
  terraform:
    name: Terraform
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v7

      - uses: hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1
        with:
          terraform_wrapper: false

      # -backend=false keeps this offline: no S3 backend, no AWS credentials.
      # The provider version comes from the committed .terraform.lock.hcl.
      - name: Init
        run: terraform init -backend=false

      - name: Format
        run: terraform fmt -check -recursive -diff

      - name: Validate
        run: terraform validate
```

§9 is emphatic that this job has **no AWS credentials configured at all**. Do not add
`configure-aws-credentials` here, and do not give the job `id-token: write`.

- [ ] **Step 5: Add the pre-commit hook**

Add to the `local` repo's hooks in `.pre-commit-config.yaml`, after the `cargo-fmt` hook:

```yaml
        - id: terraform-fmt
          name: terraform fmt
          entry: terraform fmt -check -recursive -diff
          language: system
          pass_filenames: false
          files: \.tf$
```

Verify:

```bash
pre-commit run --all-files
```

Expected: PASS, including `terraform fmt`.

- [ ] **Step 6: Initialize the real backend and apply**

```bash
export AWS_PROFILE=spoilies
unset AWS_REGION        # having it set breaks `terraform init` in this estate

# Budget notification address — not stored in the repo, same rule as the root address
read -r "TF_VAR_alert_email?Address for budget alerts: "
export TF_VAR_alert_email

terraform init
terraform plan
terraform apply
```

Expected from `plan`: creation of the code bucket and its four sub-resources, plus the budget. Nothing
else. Review it before applying — this is the first apply into a brand-new account.

- [ ] **Step 7: Prove the apply is convergent**

```bash
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

This is the check that catches the class of bug the `blocked_encryption_types` and `filter {}` comments
above describe — a resource that plans a change on every run.

- [ ] **Step 8: Confirm the code bucket has the name the deploy workflow expects**

```bash
terraform output code_bucket
aws s3api head-bucket --profile spoilies --bucket "$(terraform output -raw code_bucket)"
```

Expected: `code-<SPOILIES_ACCOUNT_ID>-us-east-2-an`, and `head-bucket` exits 0. If the name differs by
even a character, `deploy-lambda.yml` will fail at upload time, because it computes the name rather
than reading it.

- [ ] **Step 9: Document the Terraform workflow in the README**

Append to the `## Infrastructure` section added in Task 1:

````markdown
### Terraform

One flat root module, `spoilies.tf`, applied **from a laptop with an active SSO session, never from
CI** (§9). CI runs only `fmt` and `validate`, offline, with no AWS credentials configured at all.

```sh
# Do NOT have $AWS_REGION set when running init
AWS_PROFILE=spoilies terraform init

# $TF_VAR_alert_email must be set — the budget's notification address is
# deliberately absent from this repository and has no default
AWS_PROFILE=spoilies terraform plan
AWS_PROFILE=spoilies terraform apply

# Offline — what CI and the pre-commit hook run
terraform init -backend=false
terraform fmt -check -recursive -diff
terraform validate
```

The AWS provider is pinned to `~> 6.37` and `.terraform.lock.hcl` is committed, so every clone and
every CI run resolves the same provider build. State lives in `s3://spoilies-tf-state` **in the
Spoilies account** — not in `jluszcz-tf-state` — with `use_lockfile = true` for S3-native locking.
````

- [ ] **Step 10: Commit**

```bash
git add spoilies.tf .terraform.lock.hcl .gitignore .github/workflows/ci.yml .pre-commit-config.yaml README.md
git commit
```

---

## Task 4: The `lambda` binary and a placeholder artifact

**Files:**
- Modify: `Cargo.toml`
- Modify: `src/main.rs`
- Modify: `README.md`

**Interfaces:**
- Consumes: `aws_s3_bucket.code` from Task 3.
- Produces: `s3://code-<account-id>-us-east-2-an/spoilies.zip`, which Task 5's
  `aws_lambda_function` reads at create time; and `fn header_report(&HeaderMap) -> serde_json::Value`,
  the diagnostic Spike B reads in Task 9.

**Why before the Lambda resource:** `aws_lambda_function` with `s3_bucket`/`s3_key` requires the
object to already exist. This task puts it there.

**Why a diagnostic handler rather than a bare 200:** S0's exit criteria need a 200 through CloudFront,
and Spike B needs to see *which headers actually arrived* at the origin. One handler serves both, so
the spike needs no throwaway deployment of its own. S1a replaces this file with the axum router.

- [ ] **Step 1: Declare the bin target and dependencies**

Replace `Cargo.toml`:

```toml
[package]
name = "spoilies"
authors = ["Jacob Luszcz"]
version = "0.1.0"
edition = "2024"

# github-utils' lambda-package.yml copies target/<triple>/release/lambda to
# `bootstrap` before zipping, so the binary has to be named `lambda` regardless
# of which file defines it.
[[bin]]
name = "lambda"
path = "src/main.rs"

[dependencies]
lambda_http = "1.3"
serde_json = "1.0"
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["fmt"] }
```

Resolve and record the exact versions:

```bash
cargo build
git diff --stat Cargo.lock
```

- [ ] **Step 2: Write the failing tests**

Replace `src/main.rs` with the tests plus a stub `main`, so they fail for the right reason. The stub
matters: `cargo test` builds the bin target as well as the test harness, so a file with no `main`
fails with *"main function not found"* — which would look like a passing red step while testing
nothing.

```rust
//! Spoilies — asynchronous, spoiler-gated TV discussion.

fn main() {
    println!("spoilies: not implemented");
}

#[cfg(test)]
mod tests {
    use super::*;
    use lambda_http::http::{HeaderMap, HeaderName, HeaderValue};

    fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.insert(
                HeaderName::from_bytes(name.as_bytes()).unwrap(),
                HeaderValue::from_str(value).unwrap(),
            );
        }
        map
    }

    #[test]
    fn echoes_the_body_hash_header() {
        let report = header_report(&headers(&[("x-amz-content-sha256", "abc123")]));
        assert_eq!(report["x-amz-content-sha256"], "abc123");
    }

    #[test]
    fn withholds_the_forwarded_bearer_token() {
        let report = header_report(&headers(&[("x-forwarded-authorization", "Bearer s3cret")]));
        assert_eq!(report["x-forwarded-authorization"], "<present>");
    }

    #[test]
    fn omits_a_header_that_did_not_arrive() {
        let report = header_report(&headers(&[("content-type", "application/json")]));
        assert!(report.get("x-forwarded-authorization").is_none());
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cargo test
```

Expected: FAIL, with `cannot find function 'header_report' in this scope`.

- [ ] **Step 4: Write the handler**

Replace the stub `main` and prepend the handler, leaving the `mod tests` block untouched:

```rust
//! S0 ships a diagnostic handler rather than a route: it reports what actually
//! reached the Lambda through CloudFront, which is the instrument Spike B reads
//! to settle the OAC auth-transport question in §11. S1a replaces it with the
//! axum router.

use lambda_http::http::HeaderMap;
use lambda_http::{Body, Error, Request, Response, run, service_fn};
use serde_json::{Value, json};

/// Header names whose values may be echoed.
///
/// Everything else is reported by name only. `authorization` carries
/// CloudFront's own SigV4 signature and `x-forwarded-authorization` carries the
/// viewer's bearer token, so echoing values wholesale would publish credentials
/// to anyone who can reach the distribution — and the distribution is public.
const ECHOED_HEADERS: &[&str] = &["content-length", "content-type", "x-amz-content-sha256"];

/// Reports which headers arrived, with values only for [`ECHOED_HEADERS`].
///
/// A header that arrived but whose value is withheld reads as `"<present>"`, so
/// "the header never got here" and "the header got here and I am not printing
/// it" stay distinguishable — which is the entire question Spike B is asking.
fn header_report(headers: &HeaderMap) -> Value {
    let mut report = serde_json::Map::new();

    for name in headers.keys() {
        let key = name.as_str().to_ascii_lowercase();

        let value = if ECHOED_HEADERS.contains(&key.as_str()) {
            match headers.get(name).and_then(|v| v.to_str().ok()) {
                Some(v) => Value::String(v.to_string()),
                None => Value::String("<unreadable>".to_string()),
            }
        } else {
            Value::String("<present>".to_string())
        };

        report.insert(key, value);
    }

    Value::Object(report)
}

async fn handler(request: Request) -> Result<Response<Body>, Error> {
    let body = json!({
        "service": "spoilies",
        "stage": "S0",
        "method": request.method().as_str(),
        "path": request.uri().path(),
        "headers": header_report(request.headers()),
    });

    Ok(Response::builder()
        .status(200)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))?)
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .with_target(false)
        .without_time()
        .init();

    run(service_fn(handler)).await
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cargo test
cargo fmt --check
cargo clippy --all-targets -- -D warnings
```

Expected: 3 tests PASS; `fmt` and `clippy` clean.

- [ ] **Step 6: Build the release artifact the way CI does**

CI builds on `ubuntu-24.04-arm` with `musl-tools`; that toolchain is not on this machine, so build the
zip in CI rather than locally. Push the branch and let the `ci` job prove the target compiles:

```bash
git add Cargo.toml Cargo.lock src/main.rs
git commit -m "feat: add the S0 diagnostic Lambda handler"
git push -u origin s0-account-and-spikes
gh pr create --draft --title "S0: account, Terraform, and the two spikes" \
  --body "Staged per docs/superpowers/plans/2026-08-16-implementation-staging.md."
gh run watch
```

Expected: `Build, Test & Lint` PASSES against `aarch64-unknown-linux-musl`.

- [ ] **Step 7: Get a placeholder zip into the code bucket, once**

There is a circle here, and it is broken exactly once, by hand. Task 5's `aws_lambda_function` cannot
be created without an object at `spoilies.zip`; CI's `package` job does not exist until Task 8; and
CI's `deploy` job cannot run until Task 5 has created the function it updates.

So the object that unblocks Task 5 is a **placeholder**, not the real binary. Task 8's first deploy
overwrites it minutes later.

```bash
cd "$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > bootstrap
chmod +x bootstrap
zip -j spoilies.zip bootstrap
```

Upload:

```bash
aws s3 cp spoilies.zip \
  "s3://code-${SPOILIES_ACCOUNT_ID}-us-east-2-an/spoilies.zip" \
  --profile spoilies
```

Verify:

```bash
aws s3api head-object --profile spoilies \
  --bucket "code-${SPOILIES_ACCOUNT_ID}-us-east-2-an" --key spoilies.zip
```

Expected: a `ContentLength` and an `ETag`.

Because this object is a placeholder, **every invocation check between here and Task 8 will fail at
the runtime**, not at the edge. Tasks 5 and 7 say so where it applies, and Task 8 Step 6 re-runs both
against the real artifact.

- [ ] **Step 8: Update the README's development section**

In `README.md`, replace the sentence *"There is no packaging or deployment yet; those land with the
implementation."* with:

```markdown
The Lambda binary is the `lambda` bin target (`src/main.rs`), named that way because
`github-utils`' `lambda-package.yml` copies `target/<triple>/release/lambda` to `bootstrap` before
zipping. At S0 it is a diagnostic handler that reports which headers reached the origin; S1a
replaces it with the axum router.
```

- [ ] **Step 9: Commit**

```bash
git add README.md
git commit
```

---

## Task 5: Lambda infrastructure — role, log group, function, Function URL

**Files:**
- Modify: `spoilies.tf`

**Interfaces:**
- Consumes: `aws_s3_bucket.code` (Task 3); the `spoilies.zip` object (Task 4).
- Produces: `aws_lambda_function.spoilies` (ARN needed by Task 6's deploy policy and Task 7's
  permissions) and `aws_lambda_function_url.spoilies` (`function_url` needed by Task 7's origin).

- [ ] **Step 1: Append the Lambda resources to `spoilies.tf`**

```hcl
/**************************************
* Lambda
**************************************/

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda" {
  name               = "spoilies.lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Declared rather than left to Lambda's implicit creation, so retention is
# bounded. Without this the group is created on first invocation and keeps logs
# forever.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/spoilies"
  retention_in_days = 7
}

resource "aws_lambda_function" "spoilies" {
  function_name = "spoilies"
  s3_bucket     = aws_s3_bucket.code.bucket
  s3_key        = "spoilies.zip"
  role          = aws_iam_role.lambda.arn
  architectures = ["arm64"]
  runtime       = "provided.al2023"
  handler       = "ignored"
  publish       = false
  description   = "Spoilies API"
  timeout       = 10
  memory_size   = 128

  # §6 calls this the highest-value control in the design: serverless does not
  # degrade under abuse, it bills, and this hard-caps the burn rate regardless of
  # inbound volume. §6.4 also leans on it — with concurrency pinned at 10, a
  # per-instance rate limit of L is a provable global ceiling of 10L rather than
  # an approximation.
  reserved_concurrent_executions = 10

  # No source_code_hash: CI owns the code through lambda:UpdateFunctionCode, so
  # Terraform deliberately does not track the artifact and will not fight the
  # deploy pipeline over it.
}

# AWS_IAM, never NONE. With NONE the *.lambda-url.us-east-2.on.aws hostname is
# world-callable and it leaks eventually — headers, error pages, a scanner —
# and anyone holding it then bypasses CloudFront entirely, which is precisely
# the denial-of-wallet exposure §6 names as the real risk (§3).
resource "aws_lambda_function_url" "spoilies" {
  function_name      = aws_lambda_function.spoilies.function_name
  authorization_type = "AWS_IAM"
}

output "lambda_function_url" {
  value = aws_lambda_function_url.spoilies.function_url
}
```

- [ ] **Step 2: Verify offline, then apply**

```bash
terraform fmt -recursive
terraform validate
AWS_PROFILE=spoilies terraform apply
```

Expected: creation of the role, the attachment, the log group, the function, and the function URL.

- [ ] **Step 3: Verify the reserved concurrency actually landed**

```bash
aws lambda get-function-concurrency --profile spoilies --function-name spoilies
```

Expected: `{"ReservedConcurrentExecutions": 10}`.

This gets its own check because it is the single control §6 leans on hardest, and because a reserved
concurrency that silently failed to apply looks identical to one that worked until the bill arrives.

- [ ] **Step 4: Verify the Function URL rejects unsigned callers**

```bash
FURL=$(terraform output -raw lambda_function_url)
curl -s -o /dev/null -w '%{http_code}\n' "$FURL"
```

Expected: `403`.

This is one of S0's four exit criteria — *"a direct call to the `*.lambda-url.us-east-2.on.aws`
hostname returns 403"* — and it is worth confirming here, before CloudFront exists, so a later 403
cannot be mistaken for a CloudFront misconfiguration.

- [ ] **Step 5: Verify the invocation path, knowing the code is a placeholder**

Invoke with a Function URL v2.0 event:

```bash
cat > /tmp/furl-event.json <<'JSON'
{
  "version": "2.0",
  "routeKey": "$default",
  "rawPath": "/api/health",
  "rawQueryString": "",
  "headers": {"content-type": "application/json", "x-forwarded-authorization": "Bearer probe"},
  "requestContext": {
    "http": {"method": "GET", "path": "/api/health", "protocol": "HTTP/1.1", "sourceIp": "127.0.0.1"}
  },
  "isBase64Encoded": false
}
JSON

aws lambda invoke --profile spoilies \
  --function-name spoilies \
  --cli-binary-format raw-in-base64-out \
  --payload file:///tmp/furl-event.json \
  /tmp/furl-response.json

cat /tmp/furl-response.json
```

Expected **now**: a `Runtime.InvalidEntrypoint` or similar runtime error from the placeholder
`bootstrap`. That is the correct result at this point, and it is still informative — it proves the
role, the log group, and the S3-sourced code path all work, and that the failure is the placeholder
rather than the plumbing.

Check that the failure was logged, which is what confirms the log group is wired:

```bash
aws logs tail /aws/lambda/spoilies --profile spoilies --since 5m
```

Expected **after Task 8's first real deploy**: a `"statusCode": 200` whose body reports
`"x-forwarded-authorization": "<present>"`. Task 8 Step 6 re-runs this.

- [ ] **Step 6: Commit**

```bash
git add spoilies.tf
git commit
```

---

## Task 6: GitHub OIDC provider, the DSQL cluster, and the two CI roles

**Files:**
- Modify: `spoilies.tf`
- Modify: `README.md`

**Interfaces:**
- Consumes: `aws_s3_bucket.code` (Task 3); `aws_lambda_function.spoilies` (Task 5).
- Produces: `aws_iam_role.github_deploy` (assumed by `deploy-lambda.yml` in Task 8);
  `aws_iam_role.github_migrate` and `aws_dsql_cluster.main` (both consumed by S1b);
  `var.github_sub_prefix`.

**Why the DSQL cluster is here:** `spoilies.github-migrate` grants `dsql:DbConnectAdmin` and §7 is
explicit that the permission *"cannot be scoped below the cluster"* — so the role cannot be written
without a cluster ARN to point at. The cluster is one resource, costs $0 at idle, and S0 wires
nothing in application code to it (which is what the staging document excludes). S1b inherits a
cluster instead of opening with Terraform work.

- [ ] **Step 1: Confirm the OIDC subject prefix against the live API**

Do not skip this. It is the correction described in Global Constraints, and it is the difference
between a deploy that works and an opaque `AssumeRoleWithWebIdentity` denial.

```bash
gh api repos/jluszcz/Spoilies/actions/oidc/customization/sub
```

Expected: `"sub_claim_prefix": "repo:jluszcz@4526414/Spoilies@1320196357"`.

If the value differs from the default in Step 2, use what the API reports — it is authoritative, and
this plan's default is a snapshot of it.

- [ ] **Step 2: Append the OIDC provider, cluster, and roles to `spoilies.tf`**

```hcl
/**************************************
* GitHub OIDC
**************************************/

variable "github_sub_prefix" {
  type        = string
  description = <<-EOT
    The effective GitHub OIDC `sub` claim prefix for this repository.

    Repositories created after 2026-07-15 use GitHub's immutable subject format,
    which embeds the owner and repository IDs — so the name-only form the other
    projects use (repo:jluszcz/JakeSky-rs) does not match here, and §9's
    `repo:jluszcz/Spoilies:*` would silently never match. Read the live value:

      gh api repos/jluszcz/Spoilies/actions/oidc/customization/sub
  EOT
  default     = "repo:jluszcz@4526414/Spoilies@1320196357"
}

# A `resource`, not a `data` source: the AmazonWebServices repo's provider lives
# in the main account behind jluszcz-tf-state, and reaching for it would recreate
# exactly the cross-account state dependency this topology exists to avoid (§9).
#
# No thumbprint_list: since 2023 IAM validates token.actions.githubusercontent.com
# against its own trusted CA store and ignores any thumbprint supplied here.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]
}

/**************************************
* Aurora DSQL
**************************************/

# Created in S0 because spoilies.github-migrate below has to name a cluster ARN:
# dsql:DbConnectAdmin cannot be scoped below the cluster (§7). Nothing in the
# application touches it until S1b. $0 at idle.
resource "aws_dsql_cluster" "main" {
  # The first migration in S1b is the point at which losing this would matter,
  # and turning it on costs nothing before then. `terraform destroy` needs
  # force_destroy = true while this is set.
  deletion_protection_enabled = true

  tags = {
    Name = "spoilies"
  }
}

/**************************************
* GitHub Deploy Role
**************************************/

data "aws_iam_policy_document" "github_deploy" {
  statement {
    # GetObject too: update-function-code makes Lambda fetch the artifact with
    # the caller's credentials, not the function's execution role.
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.code.arn}/spoilies.zip"]
  }

  # GetFunction backs the `aws lambda wait function-updated-v2` in deploy-lambda.yml.
  statement {
    actions   = ["lambda:UpdateFunctionCode", "lambda:GetFunction"]
    resources = [aws_lambda_function.spoilies.arn]
  }
}

resource "aws_iam_policy" "github_deploy" {
  name   = "spoilies.github-deploy"
  policy = data.aws_iam_policy_document.github_deploy.json
}

# Trusted across the whole repository, because deploys have to work from any
# branch. That breadth is exactly why DDL rights are not on this role (§7).
resource "aws_iam_role" "github_deploy" {
  name = "spoilies.github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" : "${var.github_sub_prefix}:*"
          },
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.github_deploy.arn
}

/**************************************
* GitHub Migrate Role
**************************************/

# dsql:DbConnectAdmin is the strongest permission in the design: it cannot be
# scoped below the cluster, and it is admin on the database — read everything,
# drop anything. lambda:UpdateFunctionCode already lets CI run code as the
# function, but that reaches the data only through reviewed, merged code.
# Database admin is an independent path, so it gets its own role (§7).
data "aws_iam_policy_document" "github_migrate" {
  statement {
    actions   = ["dsql:DbConnectAdmin"]
    resources = [aws_dsql_cluster.main.arn]
  }
}

resource "aws_iam_policy" "github_migrate" {
  name   = "spoilies.github-migrate"
  policy = data.aws_iam_policy_document.github_migrate.json
}

# StringEquals on the exact main-branch subject, not StringLike: a pull-request
# branch must not be able to assume this at all.
#
# §7 also wants this behind a GitHub Environment, and the two cannot both live in
# one condition. AWS IAM honours only `aud` and `sub` from a GitHub OIDC token —
# the `ref`, `environment`, and `job_workflow_ref` claims are ignored — and a job
# declaring `environment:` gets `<prefix>:environment:NAME` as its subject
# *instead of* `<prefix>:ref:refs/heads/main`. S0 implements the branch
# restriction, which is the security boundary. If S1b wants the approval gate,
# it must move this condition to the environment form and restore the
# main-branch guarantee with a GitHub Environment deployment-branch rule.
resource "aws_iam_role" "github_migrate" {
  name = "spoilies.github-migrate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" : "${var.github_sub_prefix}:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_migrate" {
  role       = aws_iam_role.github_migrate.name
  policy_arn = aws_iam_policy.github_migrate.arn
}

output "dsql_cluster_identifier" {
  value = aws_dsql_cluster.main.identifier
}

output "dsql_cluster_endpoint" {
  value = "${aws_dsql_cluster.main.identifier}.dsql.${data.aws_region.current.region}.on.aws"
}
```

- [ ] **Step 3: Verify offline, then apply**

```bash
terraform fmt -recursive
terraform validate
AWS_PROFILE=spoilies terraform apply
```

- [ ] **Step 4: Verify the trust policies contain the immutable subject form**

```bash
aws iam get-role --profile spoilies --role-name spoilies.github-deploy \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
aws iam get-role --profile spoilies --role-name spoilies.github-migrate \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```

Expected: the deploy role's `StringLike` sub is `repo:jluszcz@4526414/Spoilies@1320196357:*`; the
migrate role's `StringEquals` sub is
`repo:jluszcz@4526414/Spoilies@1320196357:ref:refs/heads/main`. Neither contains the name-only form.

- [ ] **Step 5: Verify the migrate role is scoped to exactly one cluster**

```bash
aws iam get-policy-version --profile spoilies \
  --policy-arn "arn:aws:iam::${SPOILIES_ACCOUNT_ID}:policy/spoilies.github-migrate" \
  --version-id v1 --query 'PolicyVersion.Document'
```

Expected: one statement, action `dsql:DbConnectAdmin`, resource a concrete
`arn:aws:dsql:us-east-2:<account>:cluster/<identifier>` — **not** a wildcard.

- [ ] **Step 6: Verify the DSQL cluster is reachable**

```bash
aws dsql get-cluster --profile spoilies --region us-east-2 \
  --identifier "$(terraform output -raw dsql_cluster_identifier)"
```

Expected: `"status": "ACTIVE"`.

- [ ] **Step 7: Set the `AWS_ACCOUNT_ID` repository secret**

`deploy-lambda.yml` takes the account id as a secret and builds both the role ARN and the bucket name
from it.

```bash
gh secret set AWS_ACCOUNT_ID --repo jluszcz/Spoilies --body "$SPOILIES_ACCOUNT_ID"
gh secret list --repo jluszcz/Spoilies
```

Expected: `AWS_ACCOUNT_ID` listed.

- [ ] **Step 8: Record the roles in the README**

Append to `## Infrastructure`:

```markdown
### CI roles

Two roles, deliberately split, because `dsql:DbConnectAdmin` cannot be scoped below the cluster and
is an independent path to the data that `lambda:UpdateFunctionCode` is not (§7):

| Role | Trusted from | Grants |
| --- | --- | --- |
| `spoilies.github-deploy` | any ref in this repo | `s3:PutObject`/`s3:GetObject` on `.../spoilies.zip`, `lambda:UpdateFunctionCode`, `lambda:GetFunction` |
| `spoilies.github-migrate` | `main` only | `dsql:DbConnectAdmin` on the cluster |

Both trust conditions use GitHub's **immutable** subject format
(`repo:jluszcz@<owner-id>/Spoilies@<repo-id>:…`), which repositories created after 2026-07-15 carry.
The name-only form the older projects use does not match here. Check the live value with
`gh api repos/jluszcz/Spoilies/actions/oidc/customization/sub`.
```

- [ ] **Step 9: Commit**

```bash
git add spoilies.tf README.md
git commit
```

---

## Task 7: CloudFront — OAC, the viewer-request function, and the distribution

**Files:**
- Create: `cloudfront/forward-authorization.js`
- Modify: `spoilies.tf`

**Interfaces:**
- Consumes: `aws_lambda_function.spoilies` and `aws_lambda_function_url.spoilies` (Task 5).
- Produces: `aws_cloudfront_distribution.spoilies` and the `cloudfront_domain_name` output, which
  Task 8 deploys against and Task 9 probes.

**What CloudFront is actually for** (§3, worth keeping in view while building it): somewhere to attach
OAC — sufficient on its own; one origin for `/api/*` and the S3 client later, therefore no CORS; and
the option of a custom domain. **It buys no caching.** Responses vary by `Authorization` and the
ETag/304 path revalidates at the origin, so Lambda runs either way.

**No S3 origin behaviour**, per the staging document: no client exists, so the default behaviour is
the only one and the second origin is added when a client is. A second behaviour with no origin behind
it is configuration waiting to rot.

- [ ] **Step 1: Write the viewer-request function**

Create `cloudfront/forward-authorization.js`:

```javascript
// OAC signs every origin request with SigV4, and SigV4 puts its signature in the
// Authorization header — the same header §5 uses for the Cognito bearer token.
// They cannot coexist on one request, so the viewer's token travels under
// another name and the auth middleware reads that name when running behind
// CloudFront. Clients still send Authorization and never learn about this.
function handler(event) {
    var request = event.request;
    var headers = request.headers;

    if (headers.authorization) {
        headers['x-forwarded-authorization'] = headers.authorization;

        // Removed rather than left for CloudFront to overwrite. With
        // signing_behavior = "always" it would be replaced anyway, but relying on
        // that makes the token's fate a property of the OAC's configuration
        // rather than of this function.
        delete headers.authorization;
    }

    return request;
}
```

- [ ] **Step 2: Append the CloudFront resources to `spoilies.tf`**

```hcl
/**************************************
* CloudFront
**************************************/

resource "aws_cloudfront_function" "forward_authorization" {
  name    = "spoilies-forward-authorization"
  runtime = "cloudfront-js-2.0"
  comment = "Move the viewer's Authorization aside so OAC can claim it for SigV4"
  publish = true
  code    = file("${path.module}/cloudfront/forward-authorization.js")
}

resource "aws_cloudfront_origin_access_control" "lambda" {
  name                              = "spoilies-lambda"
  description                       = "Signs CloudFront's requests to the Spoilies Function URL"
  origin_access_control_origin_type = "lambda"

  # "always", not "no-override". The no-override setting passes the viewer's own
  # Authorization header through, which would require the *client* to SigV4-sign
  # against the Lambda URL's hostname — turning every client into an IAM
  # principal. "always" is what makes the CloudFront Function above the whole of
  # the auth transport story.
  signing_behavior = "always"
  signing_protocol = "sigv4"
}

resource "aws_cloudfront_distribution" "spoilies" {
  enabled      = true
  comment      = "Spoilies API"
  price_class  = "PriceClass_100"
  http_version = "http2and3"

  origin {
    # aws_lambda_function_url returns a full URL; CloudFront wants a bare hostname.
    domain_name              = replace(replace(aws_lambda_function_url.spoilies.function_url, "https://", ""), "/", "")
    origin_id                = "lambda"
    origin_access_control_id = aws_cloudfront_origin_access_control.lambda.id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # One behaviour, deliberately. No client exists, so there is no S3 origin to
  # route /* to yet, and a second behaviour with nothing behind it is
  # configuration waiting to rot. It gains an S3 origin when a client is built.
  default_cache_behavior {
    target_origin_id       = "lambda"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    # Managed-CachingDisabled. CloudFront buys no caching here: responses vary by
    # Authorization and the ETag/304 path revalidates at the origin, so Lambda
    # runs either way (§3).
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    # Managed-AllViewerExceptHostHeader. Forwards every viewer header except
    # Host, which is exactly right for a Function URL origin: Lambda expects Host
    # to be its own hostname, and CloudFront substitutes it. This is also what
    # carries x-forwarded-authorization (added by the function below) and
    # x-amz-content-sha256 (sent by the client for POST/PUT) to the origin.
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.forward_authorization.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # No custom domain (§8), so the default *.cloudfront.net certificate. Adding a
  # domain later is additive: an alias plus a us-east-1 ACM certificate on this
  # same distribution, with nothing else moving.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Both statements are required, and the AWS documentation is explicit about it:
# InvokeFunctionUrl authorises the URL, InvokeFunction authorises the invocation
# behind it. The source_arn condition is what keeps this from granting the
# CloudFront service principal at large — only this distribution.
resource "aws_lambda_permission" "cloudfront_invoke_function_url" {
  statement_id           = "AllowCloudFrontServicePrincipal"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.spoilies.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.spoilies.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "cloudfront_invoke_function" {
  statement_id  = "AllowCloudFrontServicePrincipalInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.spoilies.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.spoilies.arn
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.spoilies.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.spoilies.id
}
```

- [ ] **Step 3: Verify offline, then apply**

```bash
terraform fmt -recursive
terraform validate
AWS_PROFILE=spoilies terraform apply
```

Expected: the distribution takes several minutes to deploy. Wait for it:

```bash
aws cloudfront wait distribution-deployed --profile spoilies \
  --id "$(terraform output -raw cloudfront_distribution_id)"
```

- [ ] **Step 4: Verify a request reaches the origin through CloudFront**

```bash
CF=$(terraform output -raw cloudfront_domain_name)
curl -s -i "https://$CF/api/health"
```

Expected **now**, with the placeholder zip still in place: a **502**. That is the right result and
the informative one — a 502 means CloudFront signed the request, Lambda accepted the signature, and
the *code* failed. A 403 here would mean the opposite: OAC or the resource policy is wrong.

Distinguishing those two is the whole point of running this step before the real deploy. Do not move
on from a 403.

Expected **after Task 8's first real deploy**: a 200 whose body reports `"service": "spoilies"`,
`"stage": "S0"`, `"path": "/api/health"`, and a `headers` object. Task 8 Step 6 re-runs this.

- [ ] **Step 5: Verify the direct hostname is still shut**

```bash
FURL=$(terraform output -raw lambda_function_url)
curl -s -o /dev/null -w '%{http_code}\n' "$FURL"
curl -s -o /dev/null -w '%{http_code}\n' "https://$CF/api/health"
```

Expected: `403` for the Function URL, and not-403 for the distribution. Both matter — the pair is
what demonstrates OAC is the only path in.

- [ ] **Step 6: Commit**

```bash
git add cloudfront/forward-authorization.js spoilies.tf
git commit
```

---

## Task 8: The CI package and deploy pipeline

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `aws_iam_role.github_deploy`, the code bucket, and `aws_lambda_function.spoilies`
  (Tasks 3, 5, 6); the `AWS_ACCOUNT_ID` secret (Task 6).
- Produces: a push to `main` that deploys, which is one of S0's exit criteria and the mechanism every
  later stage relies on.

- [ ] **Step 1: Add the package and deploy jobs**

Append to `.github/workflows/ci.yml`, after the `terraform` job:

```yaml
  package:
    needs: [ci, terraform]
    if: github.event_name == 'push'
    uses: jluszcz/github-utils/.github/workflows/lambda-package.yml@v2
    with:
      project: spoilies

  deploy:
    needs: package
    if: github.event_name == 'push'
    permissions:
      id-token: write
      contents: read
    uses: jluszcz/github-utils/.github/workflows/deploy-lambda.yml@v2
    with:
      aws-region: us-east-2
      project: spoilies
    secrets:
      aws-account-id: ${{ secrets.AWS_ACCOUNT_ID }}
```

`regional` is deliberately omitted, so it defaults to `false` and the role name carries no region
suffix — matching §9's *"Single-region, so `regional: false` and no suffix on the role names."*

`package` needs `terraform` as well as `ci`: a Terraform change that fails validation should not
produce a deploy, since Terraform and the binary describe the same estate.

- [ ] **Step 2: Verify the workflow parses before pushing**

```bash
gh workflow view CI --repo jluszcz/Spoilies --yaml >/dev/null && echo "workflow readable"
```

If `actionlint` is available, run it — `github-utils` gates its own workflows on it:

```bash
command -v actionlint >/dev/null && actionlint .github/workflows/ci.yml || echo "actionlint not installed; skipping"
```

- [ ] **Step 3: Commit and merge the branch**

The deploy job runs only on a push to `main`, so it cannot be exercised from the branch. Land the PR:

```bash
git add .github/workflows/ci.yml
git commit
git push
gh pr ready
gh pr merge --squash --delete-branch
```

- [ ] **Step 4: Watch the deploy run**

```bash
gh run watch --repo jluszcz/Spoilies
```

Expected: `Build, Test & Lint` → `Terraform` → `Package` → `Deploy`, all green. `Deploy` should show
the OIDC role assumption, the `s3 cp`, `update-function-code`, and `wait function-updated-v2`.

If the role assumption fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, the
subject prefix is the first thing to check — see Task 6 Step 1.

- [ ] **Step 5: Verify the deployed code is the code that was pushed**

```bash
CF=$(AWS_PROFILE=spoilies terraform output -raw cloudfront_domain_name)
curl -s "https://$CF/api/health" | jq .
```

Expected: HTTP 200 and a body of the shape

```json
{
  "service": "spoilies",
  "stage": "S0",
  "method": "GET",
  "path": "/api/health",
  "headers": { "...": "..." }
}
```

This is S0's second exit criterion — *"a push to `main` deploys a zip and the function serves a 200
through the CloudFront hostname."*

- [ ] **Step 6: Re-run the two checks the placeholder zip deferred**

Task 5 Step 5 (direct `aws lambda invoke`) and Task 7 Step 4 (`curl` through CloudFront) both ran
against the placeholder. Run them again now, against the real artifact.

Expected this time: `"statusCode": 200` from the direct invoke, and HTTP 200 from CloudFront.

- [ ] **Step 7: Start the next branch before editing anything**

`gh pr merge --delete-branch` leaves the checkout on `main`, which is protected. Branch before making
the README edit below, so no change is ever staged against `main`.

```bash
git fetch origin
git switch -c s0-spike-b --track origin/main
git status -sb   # must print: ## s0-spike-b...origin/main
```

- [ ] **Step 8: Document the pipeline in the README**

Replace the README's *"There is no packaging or deployment yet"* remnant, if any survives, and append
to `## Infrastructure`:

```markdown
### Deploy

A push to `main` runs build/test/lint, Terraform `fmt`/`validate`, then packages and deploys:
GitHub OIDC → assume `spoilies.github-deploy` → `PutObject` the zip to the account's code bucket →
`lambda:UpdateFunctionCode` → `aws lambda wait function-updated-v2`. No S3 event and no LambdUpdate —
`github-utils` retired it in v2.

Infrastructure is **not** deployed by CI. `terraform apply` is a laptop operation (see above).
```

- [ ] **Step 9: Commit**

```bash
git add README.md
git commit
```

---

## Task 9: Spike B — the CloudFront OAC auth transport

**Files:**
- Create: `docs/superpowers/spikes/2026-08-16-cloudfront-oac-auth-transport.md`

**Interfaces:**
- Consumes: the deployed distribution (Task 7) and the diagnostic handler (Task 4, Task 8).
- Produces: **the exact header name S1a's middleware reads**, and the exact contract every client must
  satisfy for POST/PUT. S0's fourth exit criterion requires that the answer name the header
  explicitly.

**The question (§3, §11):** confirm the `Authorization` forwarding function works, and specifically
**how request bodies are signed for POST/PUT**. If it fails, the auth transport changes for every
route, so it must be answered before S1a writes middleware against it.

**What the documentation already says**, so the spike confirms rather than explores — from AWS's
*Restrict access to an AWS Lambda function URL origin*:

> If you use `PUT` or `POST` methods with your Lambda function URL, your users must compute the
> SHA256 of the body and include the payload hash value of the request body in the
> `x-amz-content-sha256` header when sending the request to CloudFront. Lambda doesn't support
> unsigned payloads.

That is a **client-side obligation**, not a server-side one, and it is the single most consequential
thing this spike settles: every client this project ever ships must hash its request bodies. The
spike's job is to confirm it empirically and pin down what happens when a client does not.

- [ ] **Step 1: Confirm the bearer token survives the rename on a GET**

```bash
CF=$(AWS_PROFILE=spoilies terraform output -raw cloudfront_domain_name)

curl -s -H 'Authorization: Bearer probe-token-value' "https://$CF/api/health" | jq .headers
```

Expected: `"x-forwarded-authorization": "<present>"`, and **no** `"authorization"` key — the function
deleted it and OAC's own signature is applied after the viewer-request stage.

Record whether `authorization` appears. If it does, the function's `delete` did not take effect at the
origin, which matters for S1a: the middleware would need to disambiguate two headers rather than one.

- [ ] **Step 2: Confirm the header does not arrive when the viewer sends none**

```bash
curl -s "https://$CF/api/health" | jq .headers
```

Expected: no `x-forwarded-authorization` key. §7 requires that a missing token produce a 401 and
*never* a fall-through to anonymous, so S1a's middleware needs "absent" to be unambiguous.

- [ ] **Step 3: POST with the body hash — the documented happy path**

```bash
BODY='{"probe":"post-with-hash"}'
HASH=$(printf '%s' "$BODY" | shasum -a 256 | cut -d' ' -f1)

curl -s -i -X POST "https://$CF/api/health" \
  -H 'Authorization: Bearer probe-token-value' \
  -H 'Content-Type: application/json' \
  -H "x-amz-content-sha256: $HASH" \
  --data "$BODY"
```

Expected: HTTP 200, with the body reporting `"method": "POST"`,
`"x-amz-content-sha256": "<the hash>"`, and `"x-forwarded-authorization": "<present>"`.

- [ ] **Step 4: POST without the body hash — establish the failure mode**

```bash
curl -s -i -X POST "https://$CF/api/health" \
  -H 'Authorization: Bearer probe-token-value' \
  -H 'Content-Type: application/json' \
  --data '{"probe":"post-without-hash"}'
```

Expected: a 4xx from Lambda's signature validation rather than a 200. Record the **exact status and
body** — this is what a client that forgets the hash will see, and S1a has to be able to recognise
it. Note in particular whether the error is distinguishable from an application-level 400, because if
it is not, a client bug will be misdiagnosed as a validation failure.

- [ ] **Step 5: POST with a wrong body hash**

```bash
curl -s -i -X POST "https://$CF/api/health" \
  -H 'Content-Type: application/json' \
  -H "x-amz-content-sha256: $(printf 'not-the-body' | shasum -a 256 | cut -d' ' -f1)" \
  --data '{"probe":"post-with-wrong-hash"}'
```

Expected: rejected. This distinguishes "the header is required" from "the header's *value* is
verified" — if a wrong hash passes, the header is theatre and the finding changes.

- [ ] **Step 6: Repeat Steps 3 and 4 for PUT**

```bash
BODY='{"probe":"put-with-hash"}'
HASH=$(printf '%s' "$BODY" | shasum -a 256 | cut -d' ' -f1)

curl -s -i -X PUT "https://$CF/api/health" \
  -H "x-amz-content-sha256: $HASH" -H 'Content-Type: application/json' --data "$BODY"

curl -s -i -X PUT "https://$CF/api/health" \
  -H 'Content-Type: application/json' --data "$BODY"
```

Expected: the same pattern as POST. §5's API surface uses `PUT` for every progress write —
`/api/episodes/:e/watched`, `/api/episodes/:e/reveal`, `/api/groups/:g/posts/:p/reactions` — so PUT is
not an afterthought here; it is the majority of the write surface.

- [ ] **Step 7: Check an empty-bodied POST**

```bash
EMPTY_HASH=$(printf '' | shasum -a 256 | cut -d' ' -f1)   # e3b0c442...

curl -s -i -X POST "https://$CF/api/health" -H "x-amz-content-sha256: $EMPTY_HASH"
curl -s -i -X POST "https://$CF/api/health"
```

`POST /api/titles/:t/watched-through` and `POST /api/invites/:token/accept` may well carry no body, so
whether an empty body still needs the hash of the empty string is a real question rather than an edge
case.

- [ ] **Step 8: Confirm the direct hostname is still closed**

```bash
FURL=$(AWS_PROFILE=spoilies terraform output -raw lambda_function_url)
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$FURL" --data '{}'
```

Expected: `403`. A POST path that accidentally bypassed OAC would be worse than a GET one.

- [ ] **Step 9: Write the answer**

Create `docs/superpowers/spikes/2026-08-16-cloudfront-oac-auth-transport.md`:

```markdown
# Spike B — CloudFront OAC to a Lambda Function URL

**Date:** 2026-08-16
**Question (§3, §11):** Does the `Authorization` forwarding function work, and how are request
bodies signed for POST/PUT?
**Stage:** S0. Consumed by S1a's auth middleware and by every client this project ships.

## The contract

**The header S1a's middleware reads is `X-Forwarded-Authorization`.**

<!-- State it flatly and without qualification — S0's exit criteria require this document to name
the exact header. Then: is `Authorization` also present at the origin? If so, what does it contain,
and what must the middleware do about it? -->

**Every client must send `x-amz-content-sha256` on POST and PUT**, containing the hex SHA-256 of the
request body.

<!-- Confirmed or refuted by Steps 3-7. Include the empty-body answer. -->

## What was run

<!-- The distribution's domain, and the exact curl invocations from Steps 1-8 with their responses. -->

## Findings

| Request | Result |
| --- | --- |
| GET with `Authorization` | |
| GET without `Authorization` | |
| POST with correct `x-amz-content-sha256` | |
| POST with no `x-amz-content-sha256` | |
| POST with wrong `x-amz-content-sha256` | |
| PUT with / without the hash | |
| POST with empty body, with / without the hash | |
| Direct Function URL POST | |

## Consequences for S1a

<!-- Concretely: which header the middleware reads; whether it must also handle a present
`Authorization`; what it does when neither is present (§7 requires 401, never anonymous). -->

## Consequences for every client

<!-- The body-hashing obligation, in the terms a client author needs: hex-encoded SHA-256 of the
exact bytes sent, on the request that goes to CloudFront. Note that the failure mode from Step 4 is
what a client that forgets it will see, and whether that is distinguishable from an application
400 — because if it is not, this is the paragraph that saves a debugging session. -->

## What was not settled

<!-- Anything that stayed ambiguous, and where it gets picked up. -->
```

Fill in every section from what actually happened. Where an expectation in Steps 1–8 did not hold,
the *observed* behaviour is the finding — do not write down the expectation.

- [ ] **Step 10: Commit**

```bash
git add docs/superpowers/spikes/2026-08-16-cloudfront-oac-auth-transport.md
git commit
```

---

## Task 10: S0 close-out

**Files:**
- Create: `CLAUDE.md`
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-08-16-implementation-staging.md`

**Why a task rather than a step:** the repository guidance is written *after* the estate exists, so it
describes what is there rather than what was planned. Writing it earlier would make it a forecast.

- [ ] **Step 1: Verify all four exit criteria, together**

The staging document's S0 exit criteria, checked in one pass so the result is a single statement
rather than four scattered ones:

```bash
export AWS_PROFILE=spoilies
CF=$(terraform output -raw cloudfront_domain_name)
FURL=$(terraform output -raw lambda_function_url)

echo "1. terraform plan is clean on rerun:"
terraform plan -detailed-exitcode >/dev/null 2>&1; echo "   exit=$? (2 means drift; 0 means clean)"

echo "2. push to main deploys and CloudFront serves 200:"
curl -s -o /dev/null -w '   %{http_code}\n' "https://$CF/api/health"

echo "3. direct Function URL is 403:"
curl -s -o /dev/null -w '   %{http_code}\n' "$FURL"

echo "4. both spikes have written answers:"
ls -1 docs/superpowers/spikes/
```

Expected: `exit=0`; `200`; `403`; and both spike files listed. Criterion 4 also requires that the
OAC write-up **names the exact header the middleware will read for POST/PUT bodies** — confirm that
by reading it, not by its existence.

Do not proceed past this step with any criterion unmet. Record the actual output.

- [ ] **Step 2: Write `CLAUDE.md`**

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## Project Overview

Spoilies is an asynchronous, spoiler-gated TV discussion service: per-episode discussion boards you
can always write to, but can only read once you have deliberately opened them.

The design is specified in `docs/superpowers/specs/2026-08-02-async-tv-discussion-design.md` and is
the authority on **what** the product is. `docs/superpowers/plans/2026-08-16-implementation-staging.md`
decides **what ships in what order**. Per-stage plans live alongside it and are written one stage at
a time, immediately before that stage is built.

## Common Commands

### Rust

- `cargo build` / `cargo test` / `cargo fmt --check`
- `cargo clippy --all-targets -- -D warnings`
- `pre-commit run --all-files` — includes `cargo fmt --check` and `terraform fmt`

CI is a thin caller of `jluszcz/github-utils/.github/workflows/rust-ci.yml@v2`, which runs build,
test, `fmt`, and `clippy` on `ubuntu-24.04-arm` against `aarch64-unknown-linux-musl`. To reproduce a
CI failure exactly, append `--target aarch64-unknown-linux-musl`.

### Terraform

- `AWS_PROFILE=spoilies terraform plan` / `apply` — **from a laptop under SSO, never from CI**,
  with `$TF_VAR_alert_email` set (no real address lives in this repo)
- `terraform init -backend=false && terraform fmt -check -recursive -diff && terraform validate` —
  what CI runs, offline, with no AWS credentials

Do NOT have `$AWS_REGION` set when running `terraform init`.

## Architecture

CloudFront → OAC → Lambda Function URL (`AWS_IAM`) → Rust/axum in one Lambda → Aurora DSQL. Cognito
issues JWTs verified in application middleware. Everything scales to zero; the design targets $0/mo.

`src/main.rs` is the `lambda` bin target — named `lambda` because `github-utils`' packaging workflow
copies `target/<triple>/release/lambda` to `bootstrap`.

`spoilies.tf` is the whole Terraform estate, one flat root module by choice.

## Constraints that are easy to violate by accident

- **Aurora DSQL is not Postgres.** No foreign keys, no triggers, no PL/pgSQL, no temp tables. UUID
  primary keys throughout. `CREATE INDEX ASYNC` is the only index form. Transactions cap at 3,000
  modified rows and cannot mix DDL with DML. Writes need bounded retry on SQLSTATE `40001`. See §3
  and §7 of the spec.
- **Every uniqueness constraint is declared inline on `CREATE TABLE`**, which keeps it out of the
  async index path entirely (§4).
- **Migrations run from CI before the code deploy**, one statement per file, never at cold start.
  Expand/contract is a standing rule: no migration may break the currently-deployed binary (§7).
- **`post.created_at` and `membership.left_at` are server clock, never client-supplied.**
  `members_at` turns `created_at` into a security boundary rather than an audit column (§5).
- **404 for both unauthorized and nonexistent.** An error code must never become an oracle for which
  ids exist (§5, §7).
- **JWKS failure returns 503**, never a fall-through to treating the caller as anonymous (§7).
- **Behind CloudFront the bearer token arrives as `X-Forwarded-Authorization`**, because OAC claims
  `Authorization` for its SigV4 signature. Clients still send `Authorization` and never learn about
  it (§3, §5). See `docs/superpowers/spikes/2026-08-16-cloudfront-oac-auth-transport.md`.
- **Clients must send `x-amz-content-sha256` on POST and PUT** — the hex SHA-256 of the request body.
  Lambda does not accept unsigned payloads behind OAC. Same spike document.
- **GitHub OIDC trust policies use the immutable subject format**
  (`repo:jluszcz@<owner-id>/Spoilies@<repo-id>:…`). The name-only form the older `jluszcz` projects
  use does not match this repository.
- **Terraform is never applied from CI**, and CI's Terraform job has no AWS credentials at all (§9).
- **Do not make this account a delegated administrator for anything** — it would permanently block
  removing it from the organization (§9).

## The invariant the product rests on

A post the caller may not see must never appear in any response shape — board read, note counts,
search, or error messages. State it as "may not see" rather than "is hidden": a locked board is not
empty, because the caller's own posts and the list of other authors both survive it by design (§5).
Those two exceptions are exactly where a leak would hide, so each needs its own test case (§7).
```

- [ ] **Step 3: Update the README's status**

Replace the README's `**Status: design.** No code yet.` paragraph with:

```markdown
**Status: S0 complete.** The AWS account, the Terraform estate, and the deploy pipeline exist; a push
to `main` puts a Rust binary behind CloudFront. No product behaviour has shipped yet. The design is
specified in
[`docs/superpowers/specs/2026-08-02-async-tv-discussion-design.md`](docs/superpowers/specs/2026-08-02-async-tv-discussion-design.md),
and the build order in
[`docs/superpowers/plans/2026-08-16-implementation-staging.md`](docs/superpowers/plans/2026-08-16-implementation-staging.md).
```

- [ ] **Step 4: Update the staging document**

In `docs/superpowers/plans/2026-08-16-implementation-staging.md`:

Change the `**Status:**` line to:

```markdown
**Status:** Roadmap. S0 is complete; S1a is the next stage to plan.
```

Replace the `## What to plan next` section with:

```markdown
## What to plan next

**S1a**, at task level, as `docs/superpowers/plans/<date>-s1a-auth-and-deploy.md`. S0 is complete —
its plan is [`2026-08-16-s0-account-and-spikes.md`](2026-08-16-s0-account-and-spikes.md) and both
spikes have written answers in `docs/superpowers/spikes/`.

Three things S0 established that the S1a plan must build on rather than rediscover:

- **The auth transport is settled.** The middleware reads `X-Forwarded-Authorization`, and clients
  must send `x-amz-content-sha256` on POST and PUT. See
  [the OAC spike](../spikes/2026-08-16-cloudfront-oac-auth-transport.md).
- **`sqlx` offline mode has a verdict.** See
  [the sqlx spike](../spikes/2026-08-16-sqlx-offline-musl-arm.md). If it is negative, S1b's plan
  inherits a design change rather than a surprise.
- **A container runtime is an unmet S1a prerequisite.** S1a stands up a testcontainers Postgres
  harness (unused, so S1b adds queries rather than infrastructure), and this machine has neither
  Docker nor Podman installed. Colima or Docker Desktop is the first task of that plan, not a
  detail inside one.
```

- [ ] **Step 5: Verify the repository is clean**

```bash
cargo test
cargo clippy --all-targets -- -D warnings
pre-commit run --all-files
terraform fmt -check -recursive -diff
terraform validate
```

Expected: all PASS.

- [ ] **Step 6: Commit and merge**

```bash
git add CLAUDE.md README.md docs/superpowers/plans/2026-08-16-implementation-staging.md
git commit
git push -u origin s0-spike-b
gh pr create --title "S0: spike answers, close-out, and repository guidance" \
  --body "Completes S0 per docs/superpowers/plans/2026-08-16-s0-account-and-spikes.md."
gh pr merge --squash --delete-branch
```

---

## What S0 deliberately does not contain

Restated from the staging document so no task quietly grows into the next stage:

- **DSQL wiring in application code.** The cluster exists because the migrate role needs an ARN;
  nothing connects to it.
- **Cognito.** The user pool, the JWKS middleware, and `GET /api/me` are S1a.
- **Any schema, and the migration runner.** S1b.
- **Any route beyond the diagnostic handler.** The handler is an instrument, not an API.
- **CloudFront's S3 origin behaviour.** §10's P0 does not require it, and a second origin behaviour
  with no origin behind it is configuration waiting to rot. It arrives with the client.
