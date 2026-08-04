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
| Identity | Amazon Cognito — invite-only signup, standard JWTs so no client type is assumed |
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

There is no packaging or deployment yet; those land with the implementation.

## Prior art

[Outwatch](https://github.com/jluszcz/Outwatch) is a Cloudflare Worker tracking which
seasons of *Survivor* a small group has watched, with per-episode discussion boards. Spoilies
is a fresh application rather than a split of it, but Outwatch's schema — and especially its
migration commentary — is worth reading as a record of decisions already thought through once.

## License

MIT. See [LICENSE](LICENSE).
