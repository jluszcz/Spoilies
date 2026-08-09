# Spoilies — Async TV Discussion Service Design

**Date:** 2026-08-02
**Status:** Design complete. Catalog, architecture, data model, API surface, abuse posture,
error handling, testing, account topology, and phasing are all decided, including exactly what
the spoiler gate returns on a locked board. **P0 and P1 are both ready to plan.** The remaining
items in §11 are product decisions that later phases need, not blockers.

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
- **`episode` carries its own `tmdb_id`**, so sync matches on a stable identifier rather than
  on `(season_number, episode_number)`. Position is not identity: TMDB renumbers, inserts
  recaps, and reassigns specials, and a positional match would silently rewrite one episode's
  row with another's data — carrying every post attached to it to the wrong episode. That is
  the same orphaning hazard as delete-and-recreate, arriving through a quieter door.

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
  Where Everyone Finds Out". Controlled by `account.show_unrevealed_episode_titles`, shown by
  default. The setting is named for *episode* titles specifically: `title` is also the name of
  the table holding a series, and a setting called `show_unrevealed_titles` reads as though it
  governs which series you can see.

## 3. Architecture

### Shape

```
CloudFront  ──/api/*──>  Lambda Function URL  ──>  Rust/axum (Lambdalith)  ──>  Aurora DSQL
     │        (OAC, AuthType=AWS_IAM)                       │
     │                                                      └──>  TMDB (ingest + scheduled sync only)
     ├── CloudFront Function (viewer request):
     │     Authorization ──> X-Forwarded-Authorization
     │     (SigV4 needs Authorization for itself)
     │
     └──/*──> S3 (static client, later)

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

**Region: us-east-2**, matching the existing estate. The one exception is the ACM certificate
for CloudFront, which must live in **us-east-1** regardless.

**Not API Gateway.** CloudFront's always-free tier is 1 TB egress + 10M requests/month with no
expiry; API Gateway HTTP API is $1/M with only a 12-month free tier. The trade-off is losing
API Gateway's built-in JWT authorizer — but that middleware is being written anyway, and
Outwatch's `src/access.js` is a working reference for the shape (remote JWKS, pinned
algorithm, audience check), even though the implementation language differs.

**What CloudFront is actually for.** The cost argument above rules out API Gateway; it does
*not* justify CloudFront, because a Lambda Function URL has no per-request charge and calling
it directly is already free. Three things earn its place, and none of them is speed:

1. **A custom domain.** A Function URL is `https://<id>.lambda-url.us-east-2.on.aws` and
   nothing can be aliased onto it. `api.<domain>` requires a distribution in front.
2. **One origin for `/api/*` and the S3 client later** — one domain, therefore no CORS.
3. **Somewhere to attach OAC**, which is what makes the Function URL non-public at all.

It buys no caching. Responses vary by `Authorization`, and the ETag/304 path below revalidates
at the origin, so Lambda runs either way. CloudFront here is a pass-through with a real
hostname, and that is worth being honest about — if the client were ever native-only and an
`on.aws` hostname acceptable, it could be dropped.

**The Function URL is `AWS_IAM`, never `NONE`, fronted by CloudFront OAC.** With `NONE` the
`*.lambda-url.us-east-2.on.aws` hostname is world-callable, and it leaks eventually — headers,
error pages, a scanner. Anyone holding it then bypasses CloudFront entirely and invokes Lambda
directly, which is precisely the denial-of-wallet exposure §6 names as the real risk. `AWS_IAM`
plus OAC has CloudFront SigV4-sign every origin request; direct calls get 403.

**This collides with bearer-token auth, and the collision has to be designed around.** SigV4
puts its signature in the `Authorization` header — the same header §5 uses for the Cognito JWT.
They cannot coexist on one request. The resolution is a CloudFront Function on viewer-request
that copies `Authorization` into `X-Forwarded-Authorization`, with the middleware reading that
header when running behind CloudFront. CloudFront Functions are ~$0.10/M, so the cost is
nothing, but it is a component in the auth path and it belongs on the diagram. Confirm the
current OAC behaviour — including how request bodies are signed for POST/PUT — before P1
depends on it.

**Cognito for identity.** 10,000 MAUs free *permanently* — not a 12-month tier. Managed login
UI, standard JWTs, and Google/Apple available when wanted, though **phase 1 is email-only with
no federated IdPs** (§5, §6). A small middleware layer is the entire user management story.
Confirm which pricing tier carries both the free MAU allowance and the managed login UI before
the cost model in §8 leans on it.

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
                   show_unrevealed_episode_titles, show_note_counts
group              name, created_by
membership         group_id, account_id, display_name, accent_color, sort_order, left_at
watch_party        name
watch_party_member watch_party_id, account_id, sharing_enabled
invite             group_id, token, created_by, expires_at, max_uses, uses, revoked_at

title              tmdb_id, name, poster_path, status, tmdb_synced_at
episode            title_id, tmdb_id, season_number, episode_number, name, air_date, still_path
group_title        group_id, title_id

post               episode_id, author_account_id, group_id (nullable),
                   body, created_at, edited_at, offset_secs, reply_to_post_id
reaction           post_id, group_id, account_id, emoji
reveal             account_id, episode_id, mode, created_at
watched_episode    account_id, episode_id, created_at
watch_session      account_id, episode_id, elapsed_secs, running_since, last_activity_at
watch_offset       account_id, episode_id, adjust_secs
```

All tables carry a UUID primary key.

### Uniqueness constraints

DSQL has no foreign keys, so these unique indexes are the *only* integrity the database
enforces. Everything else — does this `account_id` exist, is this `episode_id` real — is
app-layer validation. That makes the list worth stating in full rather than leaving to the
migrations:

| Table | Unique on |
| --- | --- |
| `account` | `(cognito_sub)`; `(email)`, lowercased — see §6 |
| `membership` | `(group_id, account_id)` |
| `watch_party_member` | `(watch_party_id, account_id)` |
| `invite` | `(token)` |
| `title` | `(tmdb_id)` |
| `episode` | `(tmdb_id)` only — position is indexed, not unique |
| `group_title` | `(group_id, title_id)` |
| `reaction` | `(post_id, group_id, account_id, emoji)` |
| `reveal` | `(account_id, episode_id)` |
| `watched_episode` | `(account_id, episode_id)` |
| `watch_session` | `(account_id, episode_id)` |
| `watch_offset` | `(account_id, episode_id)` |
| `group`, `watch_party`, `post` | Primary key only — no natural key |

`account.email` is unique and lowercased from the first migration because it is the account
*linking* key: it is what lets a federated identity added later attach to an existing native
user rather than forking into a second account (§6). Outwatch learned the case-sensitivity
half of this the hard way — see its `migrations/0004_email_nocase.sql`.

**`(title_id, season_number, episode_number)` is an index, not a unique constraint**, and that
is deliberate. Making it unique would fight the renumbering `episode.tmdb_id` exists to survive:
a sync that permutes numbering has to pass through intermediate states where two rows briefly
claim one slot, and a non-deferrable unique constraint rejects that per row — so an `UPDATE`
whose final state is perfectly valid fails depending on row order. `DEFERRABLE INITIALLY
DEFERRED` is the usual escape, but it needs a unique *constraint* rather than a unique index,
which sits badly with the `CREATE INDEX ASYNC` rule in §7. Position is TMDB's to get right;
identity is `tmdb_id`. The index is still wanted, because the season grid reads by it.

Creating these interacts with the `CREATE INDEX ASYNC` rule in §7; confirm whether DSQL wants
each one inline on `CREATE TABLE` or as a separate async unique index before writing the
migrations.

### The layering rule

Every table sits at exactly one of two layers, and the layer follows from a single question:
**does this describe the person, or the person's presence in one group?**

| Layer | Keyed on | Holds |
| --- | --- | --- |
| **Account** | `account_id` | Everything about watching: progress, reveals, timers, offsets. Authored posts. Spoiler-display preferences. Watch parties. |
| **Membership** | `group_id` + `account_id` | Presentation only: display name, accent colour, sort order. Plus group-scoped conversation — replies and reactions. |

You watch an episode once, so watching is account-level. You may present differently to your
roommates than to your coworkers, so presentation is membership-level.

**Mismatched layers are what produced the redundancy this design originally had.** Keying
progress on `membership_id` meant somebody in three *Star Trek* groups marked each episode
watched three times, and could hold "revealed" in one group and "hidden" in another for an
episode they had watched exactly once. When adding a layer, check it against the question above.

### Membership, and the watch party

`account` is a login. `membership` is that account's presence in one group, and holds only
presentation: display name override, accent colour, sort order.

A `watch_party` is a persistent set of accounts who watch together on the same screen —
couples, roommates, families. **Up to 10 members**, enforced in the app layer.

**A watch party is account-level, not group-scoped.** Your household is your household
regardless of which group you are looking at. Scoping parties to groups would break under
account-level progress: somebody in a roommate party in one group and a partner party in
another would have a single solo viewing fan out to both, claiming two households watched
an episode when one person did. A party renders inside any group's grid as one column
merging whichever of its members belong to that group.

**Progress is always per-account.** Sharing is a *write-time fan-out*, not a shared row:

> A write from account X propagates to the other members of X's watch party **only if X is
> sharing**, and **only to members who are themselves sharing**.

`watch_party_member.sharing_enabled` defaults to true. Flipping it off is symmetric — the
traveller stops broadcasting and stops receiving in one action, and everyone else stays in
sync with each other.

**Why per-member and not per-party:** at size 2 a party-level toggle would be correct. At
size 9, one roommate on a business trip flipping a party-level switch would desync the
other eight.

**Why fan-out and not a read-time union:** a union cannot represent divergence at all.
Fan-out makes divergence natural and keeps every read per-account and simple.

A watch party renders in a grid as one column with three states — all watched, some
watched, none — rather than a single checkbox.

### Leaving a group is a soft delete

`membership.left_at` marks departure rather than deleting the row. Post visibility and
display-name resolution both run through `membership`, so a hard delete would retroactively
erase a departed member's notes from a board and leave replies to them dangling.

**`left_at` gates participation, not provenance.** The distinction is the whole point, and
getting it backwards reintroduces the erasure the column exists to prevent:

| Gated by `left_at` | Not gated by `left_at` |
| --- | --- |
| Reading the group | Whether your existing posts still render |
| Writing to the group | Display name and accent colour resolution |
| Appearing as a grid column | Replies already written under your posts |

**A portable post is visible in group `g` if its author's membership in `g` had not ended
when the post was written** — `left_at IS NULL OR post.created_at < left_at`. So `left_at` is
an *upper* bound only. There is deliberately no lower bound, which is what makes joining
backfill your whole back catalogue.

That rule gives the three behaviours that matter:

- Notes written **before** leaving stay visible forever, so replies under them never dangle.
- Notes written **after** leaving, in some other group, do not appear — departing stops you
  broadcasting into a group you left.
- **Rejoining clears `left_at`** on the existing row rather than inserting a second one.
  `(group_id, account_id)` is unique. Display name, accent colour, and identity survive, and
  everything written while away becomes visible — consistent with joining always backfilling.

### Reveal is a mode, not a boolean

```
reveal   account_id, episode_id, mode, created_at
         mode ∈ 'open' | 'synced'          -- absence of row = hidden
```

A binary reveal flag would have precluded planned future behaviour: **posts appearing in
sync with the watch timer, auto-revealing as you watch**. Synced reveal is not "open", it
is "open up to where I am".

- `open` — every post on the board is visible. Marking an episode watched writes this.
- `synced` — visible posts are those whose *corrected* offset is at or behind the reader's
  own corrected position. **A post is shifted by the correction of whoever wrote it, not by
  the reader's:**

  ```
  post.offset_secs + adjust(post.author, e)  <=  reader_elapsed + adjust(reader, e)
  ```

  `offset_secs` is frozen in the *author's* frame (see §4, growth and pruning), so the
  reader's own correction cannot undo the author's skew — only the author's can. The reader's
  correction moves the reader's position, and the two are independent terms on opposite sides.
  Outwatch reached the same conclusion and its read path is the reference implementation:
  `p.offset_secs + adjustFor(p.user_id, episode)`, over *every* member's corrections rather
  than just the caller's.

**Only `open` ships in v1.** `synced` slots in as a new enum value, not a migration of
meaning.

Two questions deferred until `synced` is built:

- Posts written with **no timer running** have `offset_secs = NULL` and cannot be placed on
  a timeline. Current intent: hold them until the board is fully open.
- In synced mode the visible set changes second by second, which has an API shape
  implication — see §5.

### Posts are portable across groups; replies and reactions are not

You watch a series once, but you may be in several overlapping groups discussing it. A note
you write on an episode should reach all of them without being retyped.

So a post belongs to an **account** and an **episode**. Where it is visible is derived:

- **`post.group_id IS NULL`** — portable. Visible in every group where the author is a
  member and the group is discussing that title.
- **`post.group_id` set** — scoped to that one group.

Two invariants, enforced in the app layer:

1. A reply always has `group_id` set. **Replies never travel.**
2. A reply's `group_id` matches the group it was written in, and its parent must be visible
   there.

**The nullable column earns its keep twice.** It makes replies group-scoped, and it gives
group-private top-level notes for free — "I want to say this only to the coworkers group" is
just a scoped post. Portable is the default for a top-level note.

**Reactions are keyed on `(post_id, group_id, account_id, emoji)`.** The same portable note
accumulates separate reactions in each group, and one group's reactions never surface in
another.

**Display name and accent colour resolve through the *viewing* group's `membership`.** A
portable note appears under whatever name and colour its author uses in the group reading it,
with no extra work.

**Visibility is derived at read time, not materialised.** Joining a fourth group therefore
surfaces your existing notes there automatically, with no backfill, and the derivation cannot
go stale. The trade-off is deliberate and worth stating: **joining a group exposes your back
catalogue for any title that group discusses.**

Two alternatives were considered and rejected: asking at join time (needs `joined_at` plus a
visibility floor on `post.created_at`, and bakes in a choice made once with no way to revisit)
and flooring at `joined_at` always (most private, but a new group sees an empty board from you
even on episodes you have written about extensively). Always-backfill matches the premise —
you watched the series once, and the notes are about the episode, not about the room.

**The cost.** An earlier draft denormalised `group_id` onto `post` so the board read was a
single indexed scan. Portability ends that — visibility now requires a join through
`membership` to resolve whose posts the caller can see. Still one query; no longer one index
lookup.

The residual leak is content, not structure: a portable note whose body references another
group's conversation ("I agree with what Sarah said") carries that across. Nothing structural
can prevent it, and the words are the author's own.

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

Account-level progress helps here rather than hurting: the row count no longer multiplies by
how many groups discuss the title. Somebody in three *Star Trek* groups writes one set of
rows, not three.

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

Cleanup runs lazily when an account's sessions are touched, plus a sweep in the scheduled
Lambda that already runs for the TMDB refresh. No new infrastructure.

| Table | Growth | Prunable? |
| --- | --- | --- |
| `watch_session` | Unbounded, worthless when dead | **Yes** — as above |
| `invite` | Grows per invite issued | **Yes** — drop expired/revoked after a grace period |
| `reveal`, `watched_episode` | accounts × episodes-in-catalog | No, but bounded and meaningful |
| `watch_offset` | Same bound, sparse — only actual corrections | No, but tiny |
| `post`, `reaction` | Grows with use — but that is the product | User-deletable; reactions capped per post |
| `title`, `episode` | Bounded by what groups actually discuss | **No — append-only once referenced** |

**`title` and `episode` are append-only once referenced, and never dropped.** An earlier draft
listed them as reclaimable when the last `group_title` went away. That is the same erasure §2
forbids for the sync job, arriving by a different route: with no foreign keys nothing stops the
delete, no error is raised, and every post, reveal, and watched marker pointing at those
episodes becomes an unreadable orphan. The storage argument does not survive contact with the
numbers either — a 250-episode series is 250 rows against a 1 GB tier.

Everything else is bounded by catalog size times party size, far inside DSQL's 1 GB free
storage tier.

## 5. API Surface

### Authentication is client-agnostic

`Authorization: Bearer <cognito-jwt>`, verified in middleware with `jsonwebtoken` — remote
JWKS (cached, refetched on unknown `kid`), pinned RS256, audience checked. Same shape as
Outwatch's `src/access.js`, minus the Access-specific issuer handling.

**On the wire behind CloudFront the token arrives as `X-Forwarded-Authorization`**, because
OAC claims `Authorization` for its own SigV4 signature (§3). That is a transport detail the
middleware absorbs; clients still send `Authorization` and never learn about it.

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
- **No federated IdPs in phase 1 — email only.** An earlier draft enabled Sign in with Apple
  from day one, reasoning that App Store review requires it once any other social login is
  offered and that adding an IdP later means account-linking work. Both are true, and neither
  applies yet: no client ships before P5, and federated sign-in would actively break the
  signup posture in §6, because a user arriving through Google or Apple is created in the pool
  regardless of `AllowAdminCreateUserOnly`. Enabling federation in phase 1 therefore *forces*
  the pre-signup trigger that phase 1 exists to avoid.

  The linking cost is paid down instead by keeping `account.email` unique, lowercased, and
  Cognito-verified from the first migration (§4). Federation then attaches to the existing
  native user via `AdminLinkProviderForUser` on matching verified email, leaving `cognito_sub`
  unchanged — a lookup rather than a migration.

Middleware resolves the token to an `account`; a second layer resolves
`(account, group) → membership` on every group-scoped route.

### Privacy invariant, enforced structurally

Every route touching **group-scoped** data carries `:group_id` in the path, so no handler can
accidentally read across groups. There are no discovery endpoints, no user search, and no
way to enumerate groups. **Unauthorized and nonexistent both return 404** — carrying over
Outwatch's principle that an error code must not become an oracle for which ids exist.

The route table mirrors the layering rule in §4: **anything about watching is account-scoped
and carries no `:group_id`**, because it is not group data. Progress belongs to the person,
not to the room they are discussing it in.

### Routes

| Route | Purpose |
| --- | --- |
| `GET /api/me` | Account + the groups I am in |
| `PATCH /api/me` | `display_name`, `show_unrevealed_episode_titles`, `show_note_counts` |
| `POST /api/groups` | Create a group |
| `GET /api/groups/:g` | Members, watch parties, titles |
| `PATCH /api/groups/:g/me` | My membership: `display_name`, `accent_color` |
| `POST /api/groups/:g/invites` / `DELETE /api/invites/:token` | Issue / revoke |
| `POST /api/invites/:token/accept` | Join — the only way in |
| `DELETE /api/groups/:g/me` | Leave — soft delete, sets `left_at` |
| `POST /api/watch-parties` | Create — account-level, not group-scoped |
| `PATCH /api/watch-parties/:w/members/me` | `sharing_enabled` — the business-trip toggle |
| `GET /api/catalog/search?q=` | Server-side TMDB proxy |
| `POST /api/groups/:g/titles` `{tmdb_id}` | Ingest skeleton + attach |
| `GET /api/groups/:g/titles/:t` | Season grid: my progress, reveal state, all columns |
| `GET /api/groups/:g/episodes/:e/posts` | The board — reveal-filtered, portable + scoped |
| `POST /api/groups/:g/episodes/:e/posts` | `{body, reply_to_post_id, scope}` — see below |
| `PATCH` / `DELETE /api/posts/:p` | Edit / delete own — applies in every group it reaches |
| `PUT /api/groups/:g/posts/:p/reactions` | `{emoji, on}` — group-scoped; emoji in body, not path (astral chars) |
| `PUT /api/episodes/:e/watched` | Mark one — account-scoped |
| `POST /api/titles/:t/watched-through` | Bulk, chunked per §4 — account-scoped |
| `POST /api/episodes/:e/reveal` | `{mode}` — account-scoped |
| `POST /api/episodes/:e/timer` | `{action: start\|pause\|resume}` — account-scoped |
| `PUT /api/episodes/:e/offset` | `{adjust_secs}` — account-scoped |

**Post creation keeps `:group_id` in the path even though a portable post has no group.**
The group supplies the authorization check, scopes a reply, and resolves `scope`:
`portable` (the default for a top-level note) writes `group_id = NULL`; `group` writes the
path's group. A reply is forced to `group` regardless of what the caller sends.

**Reactions carry `:group_id`** because they are group-scoped even when the post they attach
to is not.

### The board read

`GET /api/groups/:g/episodes/:e/posts` resolves visibility in two parts, then applies the
spoiler gate:

```
members_at(g, t) = { a : ∃ m ∈ membership,
                         m.group_id = g AND m.account_id = a
                         AND (m.left_at IS NULL OR t < m.left_at) }

visible = { p : p.episode_id = e AND p.group_id IS NULL
                AND p.author_account_id ∈ members_at(g, p.created_at) }   -- portable
        ∪ { p : p.episode_id = e AND p.group_id = g }        -- scoped, incl. all replies
```

filtered by the caller's own `reveal` row for `e`. Reactions are loaded for `(post, g)` only.

**`members_at` is evaluated at the post's creation time, not at read time**, and that is
load-bearing. Evaluating current membership instead would drop a departed author's portable
posts from the board on the very next read — the exact erasure `left_at` exists to prevent —
while their scoped replies, which match on `p.group_id = g` unconditionally, would remain and
dangle under a parent that no longer renders. Scoped top-level posts are unaffected either
way, so the hazard is specific to portable posts whose author has left one of the groups they
reached.

**`post.created_at` is assigned by the server and never accepted from the client.** It reads
as an ordinary audit column, but `members_at` turns it into a security boundary: a
client-supplied timestamp predating `left_at` would make a post visible in a group its author
had already left. The same applies to `membership.left_at`. Both are server clock, `timestamptz`.

Because `reveal` is account-level, the gate is a single lookup per episode rather than one per
group — the caller either has revealed the episode or has not, and the answer does not change
depending on which board they are reading. **Posts are scoped to groups; revelation is not.**
`reveal` deliberately carries no `group_id`: you watch an episode once, so there is one answer
to "have I opened this board", and giving it a group would let the same episode be
simultaneously open and hidden for someone who watched it exactly once — the redundancy the
layering rule in §4 exists to prevent.

### What a locked board still returns

A locked board is not an empty response. Two things survive the gate, and both are deliberate:

- **Your own posts, always.** You can write to a board before revealing it, so you can have
  notes on an episode you have not opened. Hiding your own words from you is a bug, not a gate
  — the gate exists to keep *other people's* observations away from you.
- **The distinct authors who have written there.** This is what tells you whether opening the
  board is worth it, and it is the same call Outwatch made. Author identity resolves through the
  viewing group's `membership` as everywhere else, and the list runs through `members_at` like
  the posts do — so a locked board names only authors whose posts you would actually see once
  it opened.

Nothing else does. No bodies, no reactions, no timestamps from other authors.

**A visible reply whose parent is hidden renders without its quote.** Own-posts-always makes
this reachable: your reply survives the gate while the post it answers does not. The parent is
included only when it is itself in the visible set — the same rule Outwatch applies in
`quoteOf`, and the mirror image of the dangling-reply hazard `members_at` guards against.

### What synced reveal requires

Designed now even though `synced` ships later, because getting it wrong would mean
rebuilding the read path.

In synced mode the visible post set changes continuously as the timer advances. **Streaming
is the wrong reach.** WebSockets would mean API Gateway WebSocket APIs (priced per
connection-minute, no meaningful free tier) or a persistent connection Lambda cannot hold
cheaply. It breaks the cost model for a feature needing at most second-level freshness.

**Polling wins, and the client never tells the server where it is.** The server computes the
caller's position from `watch_session` (`elapsed_secs` plus `now - running_since`, clamped
by the 4-hour cap from §4) plus the caller's own `watch_offset`, and compares it against each
post's offset corrected by *that post's author's* `watch_offset` — the two-sided comparison in
§4. Both terms are needed and they are not interchangeable: the reader's correction moves the
reader, the author's moves the post.

The response also carries the **server clock**, so a client with a skewed one still renders a
correctly ticking timer against the same positions the gate used.

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

- **Floor, always visible, not configurable** — the author list from the locked board above.
  It answers "is opening this worth it", which is what the floor is for, and it already implies
  the weaker "does this episode have any notes".
- **Preference** — exact counts, default on, `account.show_note_counts`.

The floor is therefore the author list rather than a boolean. That is a stronger signal than an
earlier draft allowed, and it is the right one: names are what make the count actionable, and a
count without them is both less useful and barely less revealing.

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

### 2. Signup posture — two gates, not one

The important structural point is that **signup and group access are separate gates, and only
the first one ever changes**:

| Gate | Controls | Phase A | Phase B | Phase C |
| --- | --- | --- | --- | --- |
| **Identity** | Who may hold a Cognito user at all | Admin creates each one | An invite permits signup | Open, with approval |
| **Group access** | Which groups you can see | Invite redemption | *unchanged* | *unchanged* |

Group access is invite-only in every phase — `POST /api/invites/:token/accept` is the only way
into a group (§5), and an account in zero groups can see nothing, because every group-scoped
route 404s. So the privacy model does not rest on how signup works, and loosening signup later
cannot weaken it. That is what makes the progression below safe to defer rather than a door
being left open.

**Phase A (P1): `AllowAdminCreateUserOnly`, and nothing else.** Accounts are provisioned by
hand with `admin-create-user`. No pre-signup trigger, no post-confirmation trigger, no admin
route, no `is_admin` column — for a group this size that is minutes per year, and each of those
is easier to add later than to remove. `account` rows are created **lazily by the auth
middleware**: a valid JWT bearing an unknown `cognito_sub` inserts one from the token's `sub`
and `email`. That keeps `account` in sync with Cognito without a trigger, and it is the same
code path phases B and C need, so it is written once.

This removes the Cognito trigger Lambda from P1 entirely — along with the question of how such
a trigger would reach DSQL.

**Phase B: invites permit signup.** Flip `AllowAdminCreateUserOnly` off and add a pre-signup
trigger that admits a registration when a pre-approval record exists **for the incoming email**.

Nothing in the P1 schema provides that record, and it is left out on purpose rather than
overlooked. `invite` is not obviously the right home: an invitation to a group for an account
that already exists needs no email at all, so signup approval and group invitation may want to
be separate tables. Phase B picks one; pre-declaring the wrong shape now is worse than declaring
nothing.

**An earlier draft made that trigger validate an invite *token*, and that does not work.** With
the managed login UI you do not control the sign-up request, so there is no reliable place to
carry a token through it; and the trigger also fires as `PreSignUp_ExternalProvider` on
federated first sign-in, where there is no token to carry at all. Matching on email needs
neither, because the email is in the trigger event on both paths. The consequence is that
phase-B invites are addressed to an email address rather than being anonymous links — arguably
the better product for a private app. The rough edge to accept: someone invited at
`alice@work.com` who signs in with Google as `alice@gmail.com` is rejected and needs a reissue.

**Phase C: open registration with an approval queue**, gating `account` provisioning rather
than Cognito. A relaxation of B, not a rewrite.

### 3. Invite tokens must be right the first time

Cryptographically random, ≥128 bits, never sequential, constant-time comparison, redemption
attempts rate-limited per IP. A guessable or enumerable token is a total bypass of the
privacy model.

Behind CloudFront the client address comes from a forwarded header rather than the socket, so
the limiter has to be told which one to trust. And per §6.4 that limiter is best-effort: entropy
is what makes invites safe, not the rate limit.

### 4. TMDB search proxy rate limit — not for attackers

The key is *ours*. A search-as-you-type box will hammer it accidentally, TMDB throttles the
key, and every user is affected. Debounce client-side, cap per-account server-side.

**Rate limiting is per-instance and in-memory — deliberately best-effort.** The algorithm is
not the constraint: GCRA, a leaky bucket storing one timestamp per key, holds all the state
needed in a few bytes. The constraint is that a *shared* limit needs shared state, and shared
state means a synchronous write on the request path for a control that exists to save money.

So global accuracy is given up on purpose, and the reserved concurrency cap is what makes that
respectable rather than hand-waving: **with concurrency pinned at 10, a per-instance limit of
`L` is a hard global ceiling of `10L`.** Not "approximately `L`" — a provable upper bound. Set
`L` to a tenth of the target and the limiter is strictly conservative.

Two honest limits, both acceptable here:

- Counters die with the container, and this app is designed around containers being cold most
  of the time — so most requests start with an empty bucket. A burst large enough to matter is
  by definition hitting warm containers, and reserved concurrency already caps burn rate. It is
  useless against a slow drip, which is not a denial-of-wallet problem.
- It is a rate limiter, not a budget. It cannot enforce "1,000 searches this month".

**For invite redemption (§6.3) the limiter is noise suppression, not the control.** Token
entropy is: at ten concurrent instances guessing continuously, 128 bits is ~10³⁰ years out.
The limiter must not be described as what makes invites safe.

If a genuinely global limit is ever wanted without a hot-path write, a single DynamoDB
`UpdateItem` is a few milliseconds and free at this scale. Not needed now.

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

- **Postgres → DSQL is *almost entirely* a subset gap.** DSQL speaks the Postgres wire
  protocol and removes features (foreign keys, triggers, sequences, PL/pgSQL, temp tables).
  Nearly everything that works on DSQL also works on stock Postgres, so a **migration lint
  catches almost the whole divergence** — reject the forbidden syntax in CI and local tests
  become trustworthy.

  **The one real exception is index creation.** DDL requiring background work must use the
  `ASYNC` variant on DSQL: plain `CREATE INDEX` is unsupported there, and `CREATE INDEX
  ASYNC` is not valid Postgres. Every index migration therefore runs on exactly one of the
  two, and no lint can reconcile that — it is a translation, not a subset. The migration
  runner handles it as a single sanctioned rewrite (see below), and the lint enforces that
  it stays the only one.
- **MySQL → DSQL is a *translation* gap.** Different protocol and dialect
  (`ON DUPLICATE KEY UPDATE` vs `ON CONFLICT`, different `RETURNING`, UUID storage, JSON
  functions, collation and NULL semantics), no subset relationship, and nothing can lint for
  it. You would write SQL twice and test neither.

This resolves the local-development open question.

### Migration runner

DSQL's constraints compose into a fairly forced design. Hand-rolled against a `_migrations`
table (~150 lines); sqlx's and refinery's migrators both wrap files in a transaction by
default, which is exactly what DSQL forbids.

- **One statement per migration file**, applied with autocommit and no wrapping transaction.
  DSQL allows one DDL per transaction and forbids mixing DDL with DML, so a multi-statement
  file breaks. Seed data is always its own migration, never appended to a schema change.
- **`CREATE INDEX ASYNC` → `CREATE INDEX` when targeting Postgres.** One substitution,
  documented as the only permitted divergence, enforced by the lint above.
- **Wait for async index builds before marking a migration applied.** `CREATE INDEX ASYNC`
  returns a `job_id` immediately and builds in the background; `sys.wait_for_job(job_id)`
  blocks until it finishes. Without this, migration N+1 can run against an index that does
  not exist yet — AWS explicitly recommends the wait during schema migration.
- **A failed index build leaves the index `INVALID`, not absent.** Fail loudly and require a
  manual `DROP INDEX`; proceeding silently leaves a unique index that enforces constraints
  while being unusable for reads. Note `sys.jobs` purges completed and failed rows after 30
  minutes, so it is not an audit log.

### Migrations run from CI, before the code deploy

**Not at Lambda cold start.** Concurrent cold starts would race on DDL, DSQL forbids DDL inside
a transaction so there is no lock to serialize them with, and it taxes the cold start Rust was
chosen to protect.

**Not from a `migrate` entrypoint on the Lambda either**, tempting though it is given the
scheduled entrypoint already exists. Deployment is fire-and-forget by design: CI does
`PutObject`, an S3 event fires, LambdUpdate calls `UpdateFunctionCode` (§9). CI never learns
when the new code went live, so it cannot reliably invoke the *new* code's migrations before
that code starts serving.

**So: GitHub Actions runs the migrations directly, before uploading the zip.** DSQL is a public
IAM-authenticated endpoint, so this needs no VPC — only `dsql:DbConnectAdmin` on the deploy
role, which P0 must grant.

That ordering only works if a migration is safe against the code already running, which makes
**expand/contract a standing rule rather than a practice**: additive DDL ships with the deploy
that needs it, and drops ship a deploy later, once the code referencing the column is gone. No
migration may break the currently-deployed binary. This constrains every migration the project
will ever have, which is why it belongs here rather than being rediscovered during P1.

### Test strategy

- **Unit, no database** — the highest-value tier. Session offset computation including the
  4-hour running cap, reveal filtering, fan-out target selection under `sharing_enabled`,
  and bulk chunking are all pure functions, and all are logic where a bug is a spoiler leak.
- **Integration against stock Postgres** via testcontainers, paired with the migration lint
  above so dialect drift fails in CI rather than at deploy.
- **Smoke suite against a real dev DSQL cluster in CI**, catching what the lint cannot.
  `sqlx`'s compile-time query checking runs against Postgres, so it complements rather than
  replaces this.

**The test that matters most:** assert that a post the caller may not see never appears in
*any* response shape — board read, note counts, search, error messages. That invariant is what
the product rests on.

State it as "may not see" rather than "is hidden", because a locked board is not empty: the
caller's own posts and the author list both survive it by design (§5). A test asserting that a
locked board returns nothing would be asserting the wrong invariant, and the two exceptions are
exactly where a leak would hide — so each needs its own case. The author list in particular must
be filtered through `members_at`, or a locked board names people whose posts the caller could
not see even after opening it.

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

**The domain is not chosen yet, and nothing waits on it.** The hosted zone and the us-east-1
ACM certificate are the only things it gates, so P1 deploys against CloudFront's default
`*.cloudfront.net` hostname and gains an alias whenever a name is picked.

### Free tier is aggregated across the organization

**AWS applies free tier to the consolidated billing family, not to each account.** Usage is
summed across every account in the organization, and eligibility dates from the *management*
account's creation, not the member account's.

Two consequences, one benign and one worth tracking:

- **The always-free tiers do not expire**, so the management account's age is irrelevant to
  everything in the table above. All of it is always-free rather than 12-month.
- **The allowances are shared.** Spoilies competes with JakeSky and LambdUpdate for the
  Lambda allowance. In practice those are tiny — LambdUpdate fires only on deploys — so the
  headroom is real, and Cognito and DSQL are unused elsewhere, making those tiers effectively
  all Spoilies'. But "$0/month" is a claim about the organization's aggregate, not about this
  account in isolation.

A corollary for §9: **spinning the account out has a small genuine cost benefit**, since a
standalone account gets its own allowances rather than sharing them.

## 9. AWS Account Topology

Spoilies lives in **its own AWS account**, in **us-east-2**, inside the existing organization,
kept self-contained so it can be separated later without untangling anything.

### Leaving the organization is not a one-way door

`RemoveAccountFromOrganization` is a supported, documented operation. **Removing an account
does not close it** — it becomes standalone with every resource intact, and it can rejoin
later. Reversible in both directions.

Requirements to leave:

| Requirement | Note |
| --- | --- |
| Support plan, verified contact info, valid payment method | Org-created accounts do **not** collect these. AWS redirects through the missing sign-up steps at removal time. |
| Four days since creation | Applies only to accounts created in the org, not invited ones. |
| Not a delegated administrator | For any org-enabled service. Do not make this account the delegated admin for anything. |

Four consequences to plan for rather than discover:

- **`OrganizationAccountAccessRole` is not deleted automatically.** Org-created accounts get
  an IAM role letting the management account assume in. Leaving does not remove it — the
  former management account retains access until it is manually deleted. Nothing warns you.
- **Cost and usage history does not follow the account.** The management account keeps it.
  Export before separating if the history will ever matter to a business case.
- **SCP restrictions vanish on exit**, so principals can end up with *more* permission than
  they had. Audit IAM at separation rather than assuming separation only tightens things.
- **Organization agreements stop covering it** (AWS Artifact). A BAA or DPA negotiated at org
  level would need re-establishing — relevant on the commercial path.

**What is genuinely one-way is moving resources between accounts**, which is exactly why the
account is separate from day one. Transferring account ownership to a company is a *different*
process again — AWS support plus a contract amendment — and is not what `LeaveOrganization`
does.

### Keep the account self-contained

Every cross-account dependency is work at separation time. The rules:

- **Terraform state lives in a bucket in this account, managed from this repo.** LambdUpdate
  hardcodes `jluszcz-tf-state` in the main account; Spoilies must not, or spin-out drags a
  state migration into the one operation that should be boring. Note the chicken-and-egg: the
  bucket holding the state cannot be a resource in the configuration it stores. Create it with
  a small scripted bootstrap (versioning, public-access block, KMS encryption, matching the
  conventions in the `AmazonWebServices` repo), then point the `backend "s3"` block at it.
- **The code bucket, GitHub OIDC provider, and deploy role are `resource`s here, not `data`
  sources.** This is a real departure from the JakeSky and LambdUpdate pattern, where those
  already exist because the `AmazonWebServices` repo created them. That repo's backend is
  `jluszcz-tf-state` in the main account, so extending it to cover Spoilies would recreate
  exactly the cross-account state dependency this topology exists to avoid. Spoilies owns them
  outright instead.
- **Its own** LambdUpdate deployment.
- **Never IAM Identity Center for workload identity.** It is org-level and dies at
  separation. Fine for human console access; never for anything the application depends on.
- **No org CloudTrail trail, Config aggregator, or RAM share** in the dependency path.
- **A dedicated root email** that can be handed to a company later — an alias, not a personal
  address.

### Deployment topology

The established pattern, unchanged: GitHub OIDC → assume a deploy role → `PutObject` the zip
to the account's code bucket → S3 event → LambdUpdate → `UpdateFunctionCode`.

**LambdUpdate needs no code changes.** It is already account-agnostic: it takes region from
the S3 event and scopes its IAM to `arn:aws:lambda:<region>:<own-account>:function:*`.
A second, independent instance is deployed into the Spoilies account.

**Explicitly rejected: making LambdUpdate cross-account.** A main-account Lambda assuming into
Spoilies would create precisely the permanent dependency this topology exists to avoid.

Three things this requires:

1. **LambdUpdate's Terraform backend becomes partial config** — the only repo change. Drop
   `bucket` and `region` from the `backend "s3"` block and pass them via `-backend-config`
   from env scripts, which become per-account-per-region. The alternative (one state bucket,
   workspaces named `lambdupdate_<account>_<region>`) is less work but reintroduces the
   cross-account state dependency.
2. **A second deploy target in LambdUpdate's CI**, using a second account-id secret.
   `deploy-lambda.yml` needs no change — `aws-account-id` is already a per-call secret input.
3. **One-time bootstrap in the Spoilies account.** Only the Terraform state bucket is truly
   scripted-by-hand; the rest are ordinary resources in this repo's configuration: the code
   bucket `code-<account>-us-east-2-an`, the GitHub OIDC provider, and a
   `spoilies.github-deploy` role trusting `repo:jluszcz/Spoilies:*` with `s3:PutObject` scoped
   to `.../spoilies.zip` **and `dsql:DbConnectAdmin` on the cluster**, since CI runs migrations
   (§7). Single-region, so `regional: false` and no suffix on the role name — matching JakeSky
   rather than LambdUpdate.

Considered and set aside: Spoilies is a single Lambda, so it could call
`update-function-code` directly from Actions and skip the S3 indirection entirely. That would
need a new shared workflow, whereas deploying LambdUpdate reuses what already exists.

## 10. Phasing

Each phase is a coherent, shippable step, and each gets its own implementation plan.

### P0 — Account bootstrap

Everything that has to be true before anything else can deploy: the AWS account itself, a
scripted Terraform state bucket, and then — as ordinary resources in this repo's Terraform —
the code bucket, the GitHub OIDC provider, the `spoilies.github-deploy` role (including
`dsql:DbConnectAdmin`, per §7), and a LambdUpdate instance in the account. Plus the LambdUpdate
repo change to make its backend partial config, and the second deploy target in its CI.

Two scheduling notes: the account must exist **four days** before it could ever be removed from
the organization (§9), so create it early even if nothing else starts; and org-created accounts
carry no payment method, contact info, or support plan, which are collected at removal time
rather than now.

Small, but strictly first — P1's deploy step depends on all of it.

### P1 — Foundation and the spoiler gate

Cognito in phase-A posture — `AllowAdminCreateUserOnly`, email only, no triggers and no
federated IdPs (§6) — with `account` rows created lazily by the auth middleware; `group`,
`membership`, `invite`; `post` (portable and scoped); `reveal` in `open` mode only;
`watched_episode`; the board read with the gate applied. Plus the infrastructure: DSQL wiring,
migration runner, CloudFront + OAC + the `Authorization` forwarding function, and the Lambda
deploy.

Note that `invite` ships here for **group membership**, which is invite-only in every phase —
it is not yet involved in signup.

**The catalog is hand-seeded in P1, with real TMDB IDs and real episode structure**, loaded
from a seed migration rather than the API. `post`, `reveal`, and `watched_episode` all
reference `episode_id`; inventing episode identities here and replacing them in P2 would
force a data migration or lose data. Seeding real rows through a different *mechanism* means
P2 changes only how rows arrive, not what they are.

This reaches a working spoiler gate — the one thing the whole product rests on — without
TMDB integration in the way.

### P2 — Catalog

TMDB search proxy with per-account rate limiting, skeleton ingest, `group_title` management,
and the scheduled sync enforcing the six-month cache limit from §2. Replaces the P1 seed
mechanism.

### P3 — Conversation depth

Replies, reactions, edits, deletes. Note counts and the display preferences that govern them.

### P4 — Watch parties and timers

`watch_party` with fan-out and the `sharing_enabled` toggle; `watch_session`, `watch_offset`,
and `post.offset_secs`. The first phase with real concurrency exposure, so the OCC retry
work in §7 lands here.

### P5 — Synced reveal

`synced` mode, the polling read path, and the lookahead window.

**Deferred indefinitely:** Trakt watch-history import (§2), and per-group retraction of a
portable post. Retraction is purely additive — a `post_exclusion(post_id, group_id)` table
and one anti-join on the read path — so it can wait until it is actually wanted. Until then
the workarounds are to scope a note at creation, or to delete and rewrite it.

## 11. Open Questions

### Product decisions the schema depends on

- **Group roles.** §6 says insider abuse is "solved socially, by removing them", but §5 has no
  route to remove another member and no notion of who may issue invites, despite
  `group.created_by` existing. Also unresolved: what happens to a group when the last member
  leaves.
- **Post deletion.** `DELETE /api/posts/:p` — hard delete or tombstone? A hard delete leaves
  replies dangling under a missing parent, which is the failure `left_at` exists to prevent.
- **Watch party membership.** No route adds, removes, invites, or accepts. Joining a household
  exposes your progress to it, so it needs consent.
- **Un-watch and un-reveal.** `PUT /api/episodes/:e/watched` takes no body; §7's own argument
  for Outwatch's explicit `on` over a toggle applies here too. If an episode can be un-watched,
  does that retract the reveal?
- **Board read: ordering, pagination, and reply depth.** None are specified. Can a reply have a
  reply?
- **Note-count floor.** Computed through `members_at`, so it differs per viewer — and does it
  count your own notes? If you are the only author, "has notes" tells you nothing.
- **`membership.sort_order` has no route and no owner.** `PATCH /api/groups/:g/me` covers only
  `display_name` and `accent_color`. Is ordering self-set (you choose your column position for
  everyone) or viewer-set? Same question for `accent_color`: auto-assigned on join, unique
  within a group, validated format? And is `membership.display_name` nullable, falling back to
  `account.display_name`?
- **`left_at` is lossy across repeated leave/rejoin.** One column cannot represent two gaps, so
  notes written during an earlier absence become visible after a later departure. Probably
  acceptable given always-backfill, but it should be stated rather than discovered.
- **Episode ordering conventions.** Season 0 / specials, unaired episodes with null air dates,
  and multi-part episodes all need a defined order before `POST /api/titles/:t/watched-through`
  means anything — and the P1 hand-seed has to commit to that convention.

### To verify before depending on

- **Cognito tier.** The design assumes 10,000 MAU free *and* the managed login UI *and* (later)
  Google/Apple. Since the Lite/Essentials split those may not all sit in one tier.
- **That federated sign-in creates a pool user regardless of `AllowAdminCreateUserOnly`.** §5
  and §6 state this as fact and the entire phase-1 posture rests on it — it is the reason
  federation is deferred rather than enabled now. It matches AWS's documented behaviour, but
  nothing else in the design carries this much weight on an unverified claim.
- **CloudFront OAC to a Lambda Function URL** — the `Authorization` collision and how request
  bodies are signed for POST/PUT (§3).
- **DSQL specifics** — `sys.wait_for_job`, `INVALID` index behaviour, and how unique indexes
  are created given the `ASYNC` rule (§4, §7).
- **`sqlx` offline mode.** Compile-time query checking needs a live Postgres at build time or a
  committed `.sqlx` cache; CI cross-compiles to `aarch64-unknown-linux-musl` with no database.
  Worth an early spike alongside the DSQL SQLx connector's TLS stack on musl/ARM.

### Naming

- Final product name — "Spoilies" is a working name.
