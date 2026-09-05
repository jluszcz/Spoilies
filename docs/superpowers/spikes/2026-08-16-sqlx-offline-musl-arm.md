# Spike A — `sqlx` offline mode and the DSQL connector on musl/ARM

**Date:** 2026-09-05
**Question (§11):** Compile-time query checking needs a live Postgres at build time or a committed
`.sqlx` cache, and CI cross-compiles to `aarch64-unknown-linux-musl` with no database. Does offline
mode work there, and does the AWS DSQL SQLx connector's TLS stack build and link on that target?
**Stage:** S0. Consumed by S1b.

## Verdict

**Offline mode works and the connector links.** A committed `.sqlx` cache satisfies `sqlx::query!`
on `aarch64-unknown-linux-musl` with no database in reach, and `aurora-dsql-sqlx-connector` 0.2.2
builds, links, and runs on that target in CI. S1b keeps the `sqlx::query!` macros and the
compile-time checking §3 counts as a deciding advantage of Rust.

One consequence S1b must plan around: **`cargo sqlx prepare --check` cannot run in an offline job.**
See [Findings](#findings).

## What was run

Toolchains — local: `rustc 1.98.0`, `cargo 1.98.0`, `sqlx-cli 0.9.0`, PostgreSQL 18.6 (Homebrew).
CI: `rustc 1.98.1`, `cargo 1.98.1` on `ubuntu-24.04-arm` with `musl-tools 1.2.4-2`.

```sh
# Cache generation, against a local Postgres
export DATABASE_URL="postgres://$USER@localhost/spoilies_spike"
cargo sqlx database create
cargo sqlx migrate run            # CREATE TABLE spike (id INT PRIMARY KEY, name TEXT NOT NULL)
cargo sqlx prepare                # -> .sqlx/query-376c76ee…json

# Offline build, DATABASE_URL unset
env -u DATABASE_URL SQLX_OFFLINE=true cargo build

# Drift guard
cargo sqlx prepare --check
```

The musl/ARM half ran in CI rather than locally, because cross-compiling to musl from macOS needs a
cross-linker the repository does not configure, and CI is the environment the answer is about:
[run 33967796396](https://github.com/jluszcz/Spoilies/actions/runs/33967796396), draft PR #10.

## Findings

**Resolved versions.** `sqlx` 0.9.0, `aurora-dsql-sqlx-connector` 0.2.2, `aws-config` 1.12.0,
`aws-sdk-dsql` 1.69.0, `rustls` 0.23.43. The connector's requirement of `sqlx ^0.9` with
`runtime-tokio`, `postgres`, and `tls-rustls-ring` resolves cleanly against the feature set below.

**`.sqlx` alone sufficed.** CI never sets `SQLX_OFFLINE` and has no `DATABASE_URL`; the committed
cache was used automatically. `SQLX_OFFLINE=true` matters only as a guarantee — a `DATABASE_URL`
present in the environment takes precedence over `.sqlx`, so a build that happens to have one set
proves nothing about offline mode. Set it explicitly in CI so the guarantee does not depend on the
environment staying empty.

**`cargo sqlx prepare --check` requires a database.** With `DATABASE_URL` unset it fails before
doing any work, even with `SQLX_OFFLINE=true`:

```
error: `--database-url` or `DATABASE_URL` must be set
```

The check regenerates the cache and compares, so it needs the schema. It cannot be a step in an
offline build job. S1b's CI has to either run it in a job with a Postgres service container, or
accept that cache drift is caught by the build failing rather than by a dedicated guard.

**The crypto provider is `aws-lc-rs`, and it builds anyway.** This was the specific risk the plan
named, and it is real — `aws-lc-sys` **is** in the tree — but it is not fatal:

| Crate | Present | Path |
| --- | --- | --- |
| `ring` 0.17.14 | yes | `rustls` ← `sqlx-core` |
| `aws-lc-rs` 1.18.1 / `aws-lc-sys` 0.45.0 | yes | `rustls` ← `aws-smithy-http-client` ← `aws-smithy-runtime` ← `aws-config` ← the connector |
| `openssl-sys` | no | — |

Both providers end up linked: `sqlx` on `ring`, the AWS SDK on `aws-lc-rs`. `aws-lc-sys` compiled
from source on `ubuntu-24.04-arm` in about 66 seconds, and `cargo build`, `cargo test`, and
`cargo clippy --all-targets -- -D warnings` all passed against
`--target aarch64-unknown-linux-musl`. No `[patch]` or feature override was needed.

The `ubuntu-24.04-arm` runner builds natively for ARM and targets musl, rather than cross-compiling
architectures — that is what makes `aws-lc-sys`' C build tractable here. The result holds for this
CI configuration; it is not a claim about cross-compiling musl/ARM from a different host
architecture.

Two costs worth knowing rather than rediscovering: `aws-lc-sys` dominates a cold build, and its C
toolchain requirement means `musl-tools` is load-bearing in CI, not incidental.

## The configuration S1b should use

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
```

CI steps that go with it:

- Commit `.sqlx/` and set `SQLX_OFFLINE: true` on the build job's environment, so the cache is used
  regardless of what else is set.
- Keep `musl-tools` installed — `aws-lc-sys` needs the C toolchain.
- Run `cargo sqlx prepare --check` in a separate job with a Postgres service container and
  `DATABASE_URL` pointed at it, or omit the guard deliberately. It cannot live in the offline build.
- Regenerating the cache after a query changes is a local step against a real Postgres:
  `cargo sqlx prepare`, with the result committed.

## If the verdict is negative

Not applicable — the verdict is positive. Recorded for completeness: the fallback would have been
`sqlx::query` without the macros, forfeiting the compile-time checking §3 lists as a deciding
advantage of Rust.

## Carried forward beyond the question asked

`aurora-dsql-sqlx-connector` ships `retry_on_occ` and `OCCRetryConfig` behind its `occ` feature —
three attempts with exponential backoff and jitter. S1b's `db::retry` (§7: three attempts on
SQLSTATE `40001`, then 409) may be able to wrap this rather than reimplement it. S1b's plan should
decide deliberately, because §7's contract adds a specific status mapping the connector does not
have.

The connector's MSRV is 1.94; local and CI toolchains are 1.98.x.
