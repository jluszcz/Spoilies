# Spoilies — Async TV Discussion Service Design

**Date:** 2026-08-02
**Status:** Design complete, pending review. Catalog, architecture, data model, API surface,
abuse posture, error handling, and testing are all decided. Phasing is the main open item
before an implementation plan.

> **Spoilies** is a working name, chosen so the project has an identity. Not final.

## 1. Context and Framing

A greenfield service for asynchronous, spoiler-gated TV discussion. Friends watching the
same series at different paces each get per-episode discussion boards they can always
write to, but can only read once they have deliberately opened them.

### Relationship to Outwatch

[Outwatch](../../../../Outwatch) is **prior art, not a source**. It stays exactly as it is:
a Cloudflare Worker + D1 + Cloudflare Access app tracking which *Survivor* seasons a small
group has watched, with per-episode discussion boards bolted on.

This is a **fresh application**. Nothing is split out, migrated, or shared. Outwatch's
schema and its design commentary are worth reading as a reference for decisions already
thought through once — particularly `migrations/0006`, `0007`, and `0008`, which document
the individual-vs-column split, the reactions keying, and why watch offsets are their own
table.

### Constraints

| Constraint | Decision |
| --- | --- |
| Audience | Private now, product-shaped. Multi-tenancy in the schema from day one; no billing, admin console, or moderation tooling yet. |
| Content scope | Any TV series. Not movies. |
| Front ends | API first. Clients (web, native) come later, but the API is designed against a concrete client story rather than speculatively. |
| Cost | Near-zero idle, under ~$5/mo. Everything must scale to zero. Rules out NAT gateways, always-on RDS, ALBs. |
| Cloud | AWS. |
| Privacy | Groups are private. No public discussion, no discovery, no way to see posts from people you have not explicitly grouped with. |

## 2. Catalog: TMDB

### Decision

**TMDB is the catalog of record.** Trakt is a possible *later* integration for importing
existing watch history. TheTVDB is rejected.

### Rationale

**TheTVDB — rejected.** Their v4 API offers two paths: a negotiated commercial license, or
"user-supported" keys requiring *each of your users* to hold a $12/yr TVDB subscription.
Requiring friends to buy a database subscription before joining a discussion group is a
non-starter. Their licensed tier is free under $50k revenue with attribution but requires
negotiating a contract.

One honest point in TVDB's favour: their commercial pricing is *public* and tiered by
revenue (free under $50k; $1,000/yr at $50k–250k; $10,000/yr at $250k–1M), which is more
predictable than TMDB's "email sales". This does not outweigh the per-user subscription
requirement for phase 1.

**Trakt — not a catalog.** Trakt is a tracker. Its API is free with OAuth and it is
genuinely good at watched history, progress, and scrobbling. But Trakt
[switched its TV metadata to TMDB](https://github.com/trakt/trakt-api/discussions/250) and
does not serve artwork itself, so using it as a catalog means depending on TMDB through a
proxy that adds per-user rate limits.

**Trakt's real value is phase 3.** The spoiler gate is driven entirely by watch progress.
A member who already tracks on Trakt could OAuth-link their account and populate the gate
automatically, instead of clicking through 40 episodes by hand. Worth building, later.

**TMDB — chosen.** Free for non-commercial use with attribution. Full search, season and
episode listings, air dates, artwork CDN, and external ID mapping (TVDB/IMDB) so we are
not locked in. It is also what Trakt itself now uses.

### Terms of use — obligations this creates

Verified against <https://www.themoviedb.org/api-terms-of-use>.

**Caching is permitted but capped at six months.** The terms prohibit: *"Cache, for longer
than 6 months, any information obtained through or from TMDB or the TMDB APIs."*

This makes refresh a hard requirement, not an optimisation:

- Every TMDB-derived field must be re-synced at least every six months.
- `title.tmdb_synced_at` tracks staleness; a scheduled sweep re-fetches anything older
  than ~90 days, well inside the limit.
- **The sync job refreshes TMDB fields in place and never deletes-and-recreates rows.**
  An `episode` row is two things fused: a stable internal identity that `post`, `reveal`,
  and `watched_episode` reference, and a mirror of TMDB fields. Only the second is subject
  to the six-month rule. Delete-and-recreate would orphan every post ever written.

**Commercial use requires a written agreement.** *"If Your use (or intended use) is
commercial, You must enter into a written agreement with TMDB that expressly permits Your
commercial use. Any such agreement may be subject to, among other things, payment of
fees."* Contact `sales@themoviedb.org`. No published rates. "Commercial" is defined
broadly: charging users, selling the app, driving traffic or revenue, or training an ML/AI
system on the content. A free private app is squarely non-commercial.

**Attribution is required from day one.** Display the TMDB logo, and the notice: *"This
application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise
approved by TMDB."* The TMDB logo must be less prominent than the application's own marks.

### Design consequences

- **TMDB never sits on the read path.** Ingest a show's season/episode skeleton when a
  group first adds it; refresh on a schedule. Keeps the API fast, independent, and cheap.
- **A catalog swap later is a backfill, not a rewrite**, because internal IDs are ours and
  TMDB IDs are just another column.
- **Episode titles are themselves spoilers.** A real catalog hands you names like "The One
  Where Everyone Finds Out". Controlled by a per-account setting, titles shown by default.

## 3. Architecture

### Shape

```
CloudFront  ──/api/*──>  Lambda Function URL  ──>  Rust/axum (Lambdalith)  ──>  Aurora DSQL
     │                                                      │
     └──/*──> S3 (static client, later)                     └──>  TMDB (ingest + scheduled sync only)

EventBridge Scheduler ──> same Lambda (scheduled entrypoint): TMDB refresh, session/invite pruning

Cognito User Pool ──> JWTs verified in app middleware (jsonwebtoken + cached JWKS)
```

### Decisions and rationale

**Rust, on `provided.al2023` / ARM64.** The deciding factor is cold starts, which are
unusually load-bearing for this app: a private service opened a few times a week means
Lambda's warm container is almost always gone, so cold start is not tail latency — it is
the *median* experience on nearly every session.

| | Rust | Python |
| --- | --- | --- |
| Cold start | ~10–30ms | ~300ms–1s (boto3 import alone ~300ms) |
| + DSQL connect (both) | ~50–150ms | ~50–150ms |
| **Realistic first request** | **~150ms** | **~700ms–1.2s** |
| Iteration speed | Slow (30s–2min builds) | Fast |
| Query safety | `sqlx` checks SQL at compile time | Runtime only |

A second argument beyond speed: the single most important invariant in this system is *a
hidden post never appears in any response*. Rust's type system can make that
**unrepresentable** — a response type constructible only from reveal-filtered rows. Pydantic
gets partway; the compiler gets all the way.

Accepted costs: slower iteration, and Lambda SnapStart (which now supports Python) would
have narrowed the cold-start gap — worth revisiting only if Rust iteration speed becomes
the bottleneck.

**Stack:** `axum` behind `lambda_http`, `sqlx` via the [AWS DSQL connector for Rust
SQLx](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/SECTION_program-with-dsql-connector-for-rust-sqlx.html)
(handles IAM token generation, SSL, and background token refresh — DSQL auth tokens expire
every 15 minutes), `jsonwebtoken` for JWT verification, `cargo test` + testcontainers.

**One Lambda (a "Lambdalith")**, not a function per route. At this scale per-route Lambdas
buy nothing and cost cold starts and deployment complexity.

**CloudFront → Lambda Function URL, not API Gateway.** CloudFront's always-free tier is
1 TB egress + 10M requests/month with no expiry. API Gateway HTTP API is $1/M with only a
12-month free tier. The trade-off is losing API Gateway's built-in JWT authorizer — but
that middleware is being written anyway, and Outwatch's `src/access.js` is a working
reference for the shape (remote JWKS, pinned algorithm, audience check), even though the
implementation language differs. One domain also means no CORS.

**Cognito for identity.** 10,000 MAUs free *permanently* — not a 12-month tier. Managed
login UI, Google/Apple sign-in, standard JWTs. A small middleware layer is the entire user
management story.

**Aurora DSQL for data.** See comparison below.

### Data store comparison

| | DynamoDB | **Aurora DSQL** (chosen) | Aurora Serverless v2 |
| --- | --- | --- | --- |
| Model | Single-table, denormalised | Postgres (distributed) | Postgres (standard) |
| Idle cost | $0 | $0 | ~$3–10/mo |
| Cold start | None | None | **~15s DB resume** |
| VPC needed | No | No | No (via Data API) |
| Free tier | 25 GB, always | 100k DPU + 1 GB, always | None |
| Fit for this schema | Poor | Good | Excellent |

**Why not DynamoDB:** the access patterns are relational — threaded replies, reaction
rollups per post, reveal-filtered reads, cross-member queries. Single-table design handles
this, but the modelling work is real and it locks in query patterns while the product is
still finding its shape.

**Why not Aurora Serverless v2:** auto-pause at min 0 ACU means ~15 seconds before the
first query of a session returns. For an app opened a few times a week, nearly every
session eats that stall. Also lands at $3–10/mo, brushing the cost ceiling.

**Why DSQL:** serverless distributed Postgres on a public IAM-authenticated endpoint — no
VPC, no NAT, no connection pooling infrastructure. Scales to zero with *no* resume penalty.
Free tier is 100k DPUs + 1 GB storage permanently. SQL ergonomics are retained, so the
complex discussion read stays one query.

### DSQL constraints this design must respect

- **No foreign keys.** Referential integrity moves into a validation layer in the app.
- **No triggers, no PL/pgSQL, no temp tables.** Use CTEs; put logic in the app.
- **UUID primary keys throughout.** No sequences; DSQL partitions on key distribution.
- **`CREATE INDEX ASYNC`** for index creation.
- **Optimistic concurrency control.** Conflicting transactions return a serialization error
  rather than blocking. The app needs retry logic around writes.
- **Transactions cap at 3,000 modified rows**, and DDL/DML cannot mix (one DDL statement
  per transaction). This shapes the migration runner and forces bulk progress writes to
  chunk — see §4.
- **No local DSQL.** Develop against stock Postgres and accept some dialect drift.

## 4. Data Model

### Schema

```
account            cognito_sub, email, display_name,
                   show_unrevealed_titles, show_note_counts
group              name, created_by
membership         group_id, account_id, display_name, accent_color, sort_order
watch_party        group_id, name
watch_party_member watch_party_id, membership_id, sharing_enabled
invite             group_id, token, created_by, expires_at, max_uses, uses, revoked_at

title              tmdb_id, name, poster_path, status, tmdb_synced_at
episode            title_id, season_number, episode_number, name, air_date, still_path
group_title        group_id, title_id

post               group_id, episode_id, membership_id, author_account_id,
                   body, created_at, edited_at, offset_secs, reply_to_post_id
reaction           post_id, account_id, emoji
reveal             membership_id, episode_id, mode, created_at
watched_episode    membership_id, episode_id, created_at
watch_session      membership_id, episode_id, elapsed_secs, running_since, last_activity_at
watch_offset       membership_id, episode_id, adjust_secs
```

All tables carry a UUID primary key. `group_id` is denormalised onto `post` so the hot read
is a single indexed scan rather than a join through `episode → title → group_title`.

### Membership, and the watch party

`account` is a login. `membership` is that account's presence in one group, and is the home
of **all per-group preferences** (display name override, accent colour, sort order).

A `watch_party` is a persistent set of memberships who watch together on the same screen —
couples, roommates, families. **Up to 10 members**, enforced in the app layer.

**Progress is always per-membership.** Sharing is a *write-time fan-out*, not a shared row:

> A write from membership X propagates to the other members of X's watch party **only if X
> is sharing**, and **only to members who are themselves sharing**.

`watch_party_member.sharing_enabled` defaults to true. Flipping it off is symmetric — the
traveller stops broadcasting and stops receiving in one action, and everyone else stays in
sync with each other.

**Why per-member and not per-party:** at size 2 a party-level toggle would be correct. At
size 9, one roommate on a business trip flipping a party-level switch would desync the
other eight.

**Why fan-out and not a read-time union:** a union cannot represent divergence at all.
Fan-out makes divergence natural and keeps every read per-membership and simple.

A watch party renders in a grid as one column with three states — all watched, some
watched, none — rather than a single checkbox.

### Reveal is a mode, not a boolean

```
reveal   membership_id, episode_id, mode, created_at
         mode ∈ 'open' | 'synced'          -- absence of row = hidden
```

A binary reveal flag would have precluded planned future behaviour: **posts appearing in
sync with the watch timer, auto-revealing as you watch**. Synced reveal is not "open", it
is "open up to where I am".

- `open` — every post on the board is visible. Marking an episode watched writes this.
- `synced` — visible posts are those whose *corrected* offset (`post.offset_secs` plus the
  reader's `watch_offset`) is at or behind the reader's current timer position.

**Only `open` ships in v1.** `synced` slots in as a new enum value, not a migration of
meaning.

Two questions deferred until `synced` is built:

- Posts written with **no timer running** have `offset_secs = NULL` and cannot be placed on
  a timeline. Current intent: hold them until the board is fully open.
- In synced mode the visible set changes second by second, which has an API shape
  implication — see §5.

### Progress is per-episode

Outwatch tracked seasons and derived episode reveals. With arbitrary shows — including ones
airing week to week — episode-level is the honest unit. "Watched through episode N" becomes
a bulk write; a season grid derives from it.

**`reveal` and `watched_episode` stay separate tables** even though marking watched implies
revealing. They mean different things: one is "I've seen the episode", the other is "I've
read the board". Watching writes both; revealing writes only the reveal. Collapsing them
would lose the distinction between a board opened out of impatience and an episode actually
watched.

### Bulk writes must chunk

"Mark this whole series watched" on a 250-episode show, for a 10-member watch party, across
`watched_episode` + `reveal`, is 5,000 rows — over DSQL's 3,000-row transaction cap. Bulk
progress writes batch by episode range and commit per chunk.

### Growth and pruning

`watch_session` is prunable, and the reason is a property worth preserving deliberately:
**`post.offset_secs` is frozen at write time and never recomputed**, and `watch_offset`
lives in its own table specifically so corrections outlive the session that produced them.
A session row therefore has no downstream dependents.

Prune on **deadness, not age**. A *paused* session is resumable indefinitely — watch 20
minutes, pause, come back Thursday, and the timer must resume at 20:00, not zero. Outwatch's
three-hour expiry was reasonable for a group binge-watching one show; for arbitrary series
it would silently destroy real state.

- **Session's episode is marked watched** → the timer's job is done; drop the row. This
  reclaims almost everything.
- **Inactive beyond ~90 days** → backstop for episodes started and abandoned.

Separately, a **correctness bug** rather than a storage one: a session left *running* accumulates
elapsed time forever, so someone falling asleep gets their next post stamped at 9:41:00.
A running session needs a cap — if `now - running_since` exceeds a sane episode length
(~4 hours), treat it as ended at the cap rather than banking wall-clock. This is read-path
logic and belongs in the shared session helper, not in a pruning job.

Cleanup runs lazily when a membership's sessions are touched, plus a sweep in the scheduled
Lambda that already runs for the TMDB refresh. No new infrastructure.

| Table | Growth | Prunable? |
| --- | --- | --- |
| `watch_session` | Unbounded, worthless when dead | **Yes** — as above |
| `invite` | Grows per invite issued | **Yes** — drop expired/revoked after a grace period |
| `reveal`, `watched_episode` | members × episodes-in-catalog | No, but bounded and meaningful |
| `watch_offset` | Same bound, sparse — only actual corrections | No, but tiny |
| `post`, `reaction` | Grows with use — but that is the product | User-deletable; reactions capped per post |
| `title`, `episode` | Bounded by what groups actually discuss | Droppable with `group_title` |

Everything else is bounded by catalog size times party size, far inside DSQL's 1 GB free
storage tier.

## 5. API Surface

### Authentication is client-agnostic

`Authorization: Bearer <cognito-jwt>`, verified in middleware with `jsonwebtoken` — remote
JWKS (cached, refetched on unknown `kid`), pinned RS256, audience checked. Same shape as
Outwatch's `src/access.js`, minus the Access-specific issuer handling.

**Bearer tokens rather than cookies specifically so no client type is assumed.** The API
sees a string and never learns what produced it. Cookie sessions would have been the
browser-assuming choice.

What differs per client is the login flow, not the token:

- **Web** — Authorization Code + PKCE, redirect to Cognito managed login.
- **iOS** — the same Authorization Code + PKCE flow via `ASWebAuthenticationSession`,
  tokens stored in Keychain.

Native-specific decisions to lock in early:

- **Register as a public client with no secret.** A client secret shipped in an iOS binary
  is extractable; PKCE exists so one is not needed.
- **Enable Sign in with Apple as a Cognito IdP now.** App Store review effectively requires
  it once any other social login is offered, and adding an IdP after accounts exist means
  account-linking work.

Middleware resolves the token to an `account`; a second layer resolves
`(account, group) → membership` on every group-scoped route.

### Privacy invariant, enforced structurally

Every route touching group data carries `:group_id` in the path, so no handler can
accidentally read across groups. There are no discovery endpoints, no user search, and no
way to enumerate groups. **Unauthorized and nonexistent both return 404** — carrying over
Outwatch's principle that an error code must not become an oracle for which ids exist.

### Routes

| Route | Purpose |
| --- | --- |
| `GET /api/me` | Account + the groups I am in |
| `PATCH /api/me` | `display_name`, `show_unrevealed_titles`, `show_note_counts` |
| `POST /api/groups` | Create a group |
| `GET /api/groups/:g` | Members, watch parties, titles |
| `PATCH /api/groups/:g/me` | My membership: `display_name`, `accent_color` |
| `POST /api/groups/:g/invites` / `DELETE /api/invites/:token` | Issue / revoke |
| `POST /api/invites/:token/accept` | Join — the only way in |
| `POST /api/groups/:g/watch-parties` | Create |
| `PATCH /api/watch-parties/:w/members/me` | `sharing_enabled` — the business-trip toggle |
| `GET /api/catalog/search?q=` | Server-side TMDB proxy |
| `POST /api/groups/:g/titles` `{tmdb_id}` | Ingest skeleton + attach |
| `GET /api/groups/:g/titles/:t` | Season grid: my progress, reveal state, all columns |
| `GET /api/groups/:g/episodes/:e/posts` | The board — reveal-filtered |
| `POST /api/groups/:g/episodes/:e/posts` | `{body, reply_to_post_id}` |
| `PATCH` / `DELETE /api/posts/:p` | Edit / delete own |
| `PUT /api/posts/:p/reactions` | `{emoji, on}` — emoji in body, not path (astral chars) |
| `PUT /api/groups/:g/episodes/:e/watched` | Mark one |
| `POST /api/groups/:g/titles/:t/watched-through` | Bulk, chunked per §4 |
| `POST /api/groups/:g/episodes/:e/reveal` | `{mode}` |
| `POST /api/groups/:g/episodes/:e/timer` | `{action: start\|pause\|resume}` |
| `PUT /api/groups/:g/episodes/:e/offset` | `{adjust_secs}` |

### The read endpoint, and what synced reveal requires

Designed now even though `synced` ships later, because getting it wrong would mean
rebuilding the read path.

In synced mode the visible post set changes continuously as the timer advances. **Streaming
is the wrong reach.** WebSockets would mean API Gateway WebSocket APIs (priced per
connection-minute, no meaningful free tier) or a persistent connection Lambda cannot hold
cheaply. It breaks the cost model for a feature needing at most second-level freshness.

**Polling wins, and the client never tells the server where it is.** The server computes the
caller's position from `watch_session` (`elapsed_secs` plus `now - running_since`, clamped
by the 4-hour cap from §4), adds their `watch_offset` correction, and returns only posts at
or behind it.

> A client cannot spoof its position to bypass the gate, because there is no position
> parameter to spoof. If the position came from the request, the spoiler gate would be
> client-enforced — which is no gate at all.

Two refinements:

- **ETag on responses** so unchanged polls return 304. A 45-minute episode is ~180 polls per
  person at 15s intervals — trivially inside free tier, and 304s make it near-free in DSQL
  reads too.
- **~5 second lookahead** so the client displays posts on time rather than up to a poll
  interval late. Sending the *whole* future timeline with timestamps would not be safe —
  "a post lands at 12:30" is itself a spoiler.

### Note counts

A note count is a mild spoiler: eleven notes on episode 7 of thirteen says something
happened, before anything is revealed.

- **Floor, always visible, not configurable** — a boolean: does this episode have any notes.
  Needed to decide what to watch next, and a much weaker signal than a count.
- **Preference** — exact counts, default on, `account.show_note_counts`.

## 6. Abuse and Cost Protection

### Framing: private-by-default already did most of the work

There is no public surface. No open discussion, no discovery, no user search, groups
reachable only by invite. This eliminates spam, stranger harassment, and scraping **by
construction rather than by controls**. What remains is an insider problem — someone you
invited behaving badly — which is solved socially, by removing them.

Most conventional abuse tooling is therefore genuinely deferrable. Four things are not.

### 1. Denial of wallet is the real risk

Serverless does not degrade under abuse; it bills. Two controls, both free:

- **Lambda reserved concurrency cap** (~10). Hard-caps maximum burn rate regardless of
  inbound volume. Highest-value control in the design.
- **AWS Budgets alarm.**

**Explicitly not recommended: AWS WAF.** Rate-based rules are the textbook answer, but WAF
costs ~$5/mo before a single request — doubling the entire infrastructure bill to solve a
problem that does not exist yet. Application-level limits cost nothing.

### 2. Cognito self-signup posture — the one structural choice

If the user pool allows open self-registration, unbounded account and group creation is
live and quotas become necessary. If account creation requires a valid invite, that surface
collapses to zero: an attacker needs someone to invite them first.

**Decision: a pre-signup Lambda trigger rejecting registration without a valid invite
token.** Keeps self-service invite links working with no admin toil, while making "anyone
can create an account" false. Relaxing this later is a config change; tightening it later
means auditing accounts that already exist.

### 3. Invite tokens must be right the first time

Cryptographically random, ≥128 bits, never sequential, constant-time comparison, redemption
attempts rate-limited per IP. A guessable or enumerable token is a total bypass of the
privacy model.

### 4. TMDB search proxy rate limit — not for attackers

The key is *ours*. A search-as-you-type box will hammer it accidentally, TMDB throttles the
key, and every user is affected. Debounce client-side, cap per-account server-side.

### Deferred

Group-count and post-rate quotas (a `COUNT(*)` at write time when needed — no schema prep
required), content moderation, CAPTCHA, WAF, email-verification hardening.

## 7. Error Handling and Testing

### Optimistic concurrency is the genuinely new failure mode

Outwatch on D1 had none of this. A conflicting DSQL transaction returns a serialization
error (SQLSTATE `40001`) rather than blocking, so writes need bounded retry with backoff —
three attempts, then a 409.

That is only safe on idempotent transactions, which sorts the write paths in two:

- **Naturally idempotent, retry freely** — reveals, `watched`, reactions, watch-party
  fan-out. (Outwatch's choice to make `PUT .../reactions` take an explicit `on` rather than
  toggling pays off directly here.)
- **Not idempotent** — timer actions (`start` zeroes the session) and post creation. Retry
  after a *failed* transaction is still safe, since nothing committed. The risk is only
  retry after an **ambiguous** failure such as a network timeout after commit.
  **Decision for v1: accept it.** A duplicate note is a minor annoyance the author can
  delete. If it bites, a client-supplied idempotency key fixes it with no schema change.

Conflict-prone paths to watch: fan-out to a 10-member watch party, reactions on a busy post,
and simultaneous timer ticks.

### Status conventions

| Status | Meaning |
| --- | --- |
| 400 | Validation failure |
| 401 | Missing or invalid token |
| **404** | **Both unauthorized and nonexistent** — never an oracle for which ids exist |
| 409 | Retries exhausted on a serialization conflict |
| 429 | Rate limited |
| 503 | JWKS fetch failure — *never* fall through to treating the caller as anonymous |

**TMDB failures:** ingest is user-initiated, so surface it plainly. Scheduled sync failures
log and alarm, but must never partial-write a title — a half-ingested season shows phantom
episode gaps.

### Local testing target: stock Postgres, not MySQL

MySQL was considered and **rejected**. The two gaps are different kinds of problem:

- **Postgres → DSQL is a *subset* gap.** DSQL speaks the Postgres wire protocol and removes
  features (foreign keys, triggers, sequences, PL/pgSQL, temp tables). Anything that works
  on DSQL also works on stock Postgres, so a **migration lint can mechanically catch the
  entire divergence** — reject the forbidden syntax in CI and local tests become trustworthy.
- **MySQL → DSQL is a *translation* gap.** Different protocol and dialect
  (`ON DUPLICATE KEY UPDATE` vs `ON CONFLICT`, different `RETURNING`, UUID storage, JSON
  functions, collation and NULL semantics), no subset relationship, and nothing can lint for
  it. You would write SQL twice and test neither.

This resolves the local-development open question.

### Test strategy

- **Unit, no database** — the highest-value tier. Session offset computation including the
  4-hour running cap, reveal filtering, fan-out target selection under `sharing_enabled`,
  and bulk chunking are all pure functions, and all are logic where a bug is a spoiler leak.
- **Integration against stock Postgres** via testcontainers, paired with the migration lint
  above so dialect drift fails in CI rather than at deploy.
- **Smoke suite against a real dev DSQL cluster in CI**, catching what the lint cannot.
  `sqlx`'s compile-time query checking runs against Postgres, so it complements rather than
  replaces this.

**The test that matters most:** assert a hidden post never appears in *any* response shape —
board read, note counts, search, error messages. That invariant is what the product rests on.

## 8. Cost Model

At the stated scale, essentially just a Route 53 hosted zone at $0.50/mo:

| Service | Free allowance | Expiry |
| --- | --- | --- |
| CloudFront | 1 TB egress, 10M requests/mo | Always |
| Lambda | 1M requests, 400k GB-s/mo | Always |
| Aurora DSQL | 100k DPU, 1 GB storage/mo | Always |
| Cognito | 10,000 MAU/mo | Always |
| Lambda Function URLs | No per-request charge | n/a |
| Route 53 hosted zone | — | $0.50/mo |

Beyond free tier: DSQL is $8.00/M DPU and $0.33/GB-month (us-east-1/us-east-2). This holds
until well past a few hundred users.

## 9. Open Questions

- Final product name — "Spoilies" is a working name.
- Whether `post.membership_id` and `post.author_account_id` should collapse into one column.
  Both are kept for now: `membership_id` is what group-scoped queries index on,
  `author_account_id` is what survives if someone leaves a group.
- Migration runner shape, given one DDL statement per transaction and no DDL/DML mixing.
- **Phasing.** As specified this is a large first build. A plausible phase 1 is accounts +
  one group + titles + boards + `open`-mode reveal, deferring watch parties, timers, watch
  offsets, and `synced` reveal. Needs deciding before an implementation plan is written.
