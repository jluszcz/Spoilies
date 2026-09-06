# Spoilies

Asynchronous, spoiler-gated TV discussion.

Friends watching the same series at different paces each get per-episode discussion boards.
You can always write to a board, but you can only read one once you have deliberately
opened it — so nobody spoils anybody, and nobody has to wait for the group to catch up.

**Status: design.** No code yet. The design is specified in
[`docs/superpowers/specs/2026-08-02-async-tv-discussion-design.md`](docs/superpowers/specs/2026-08-02-async-tv-discussion-design.md),
which records the decisions and the reasoning behind them.

## Shape

A Rust backend on AWS, API-first, with clients (web, native) to follow.

| Concern | Choice |
| --- | --- |
| API | Rust + `axum` in a single Lambda, behind CloudFront via a Function URL |
| Identity | Amazon Cognito — admin-provisioned accounts at first, invite-only group access always, standard JWTs so no client type is assumed |
| Data | Aurora DSQL — serverless Postgres, no VPC, genuinely zero idle cost |
| Catalog | TMDB, cached locally and refreshed on a schedule |

Designed to idle at effectively $0 and stay private by default: no public discussion, no
discovery, and no way to see posts from people you have not explicitly grouped with.

## Development

```sh
cargo build
cargo test
cargo fmt --check
cargo clippy --all-targets -- -D warnings
pre-commit run --all-files    # includes cargo fmt --check
```

CI is a thin caller of `jluszcz/github-utils/.github/workflows/rust-ci.yml`, which runs
build, test, `cargo fmt --check`, and `cargo clippy --all-targets -- -D warnings` on
`ubuntu-24.04-arm` against the `aarch64-unknown-linux-musl` target — the Lambda runtime the
service deploys to. To reproduce a CI failure exactly, append `--target
aarch64-unknown-linux-musl` to the commands above.

The Lambda binary is the `lambda` bin target (`src/main.rs`), named that way because
`github-utils`' `lambda-package.yml` copies `target/<triple>/release/lambda` to `bootstrap` before
zipping. At S0 it is a diagnostic handler that reports which headers reached the origin; S1a
replaces it with the axum router.

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

### Terraform

One flat root module, `spoilies.tf`, applied **from a laptop with an active SSO session, never from
CI** (§9). CI runs only `fmt` and `validate`, offline, with no AWS credentials configured at all.

```sh
# Do NOT have $AWS_REGION set when running init
AWS_PROFILE=spoilies terraform init

# $TF_VAR_alert_email must be set — the budget's notification address is
# deliberately absent from this repository and has no default. `.envrc` is
# gitignored and supplies it through direnv.
AWS_PROFILE=spoilies terraform plan
AWS_PROFILE=spoilies terraform apply

# Offline — what CI and the pre-commit hook run
terraform init -backend=false
terraform fmt -check -recursive -diff
terraform validate
```

The AWS provider is pinned to `~> 6.37` and `.terraform.lock.hcl` is committed, so every clone and
every CI run resolves the same provider build. State lives in `s3://spoilies-tf-state` **in the
Spoilies account**, with `use_lockfile = true` for S3-native locking, so separating the account
carries its state with it.

## Prior art

[Outwatch](https://github.com/jluszcz/Outwatch) is a Cloudflare Worker tracking which
seasons of *Survivor* a small group has watched, with per-episode discussion boards. Spoilies
is a fresh application rather than a split of it, but Outwatch's schema — and especially its
migration commentary — is worth reading as a record of decisions already thought through once.

## License

MIT. See [LICENSE](LICENSE).
