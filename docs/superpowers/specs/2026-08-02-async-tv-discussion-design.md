# Spoilies — Async TV Discussion Service Design

**Date:** 2026-08-02
**Revised:** 2026-08-16
**Status:** Design complete. Catalog, architecture, data model, API surface, abuse posture,
error handling, testing, account topology, and phasing are all decided, including exactly what
the spoiler gate returns on a locked board. The product decisions §11 once held open — group
roles, post deletion, un-watch, board paging, membership presentation, watch-party consent,
episode ordering — are resolved and folded into the sections they belong to. **P0 and P1 are both
ready to plan.**

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

**Region: us-east-2**, matching the existing estate — and, with no custom domain (§8), with no
exceptions. Should a domain ever be added, its ACM certificate has to live in **us-east-1** to be
usable by CloudFront, which is the only thing that would ever put a resource outside us-east-2.

**Not API Gateway.** CloudFront's always-free tier is 1 TB egress + 10M requests/month with no
expiry; API Gateway HTTP API is $1/M with only a 12-month free tier. The trade-off is losing
API Gateway's built-in JWT authorizer — but that middleware is being written anyway, and
Outwatch's `src/access.js` is a working reference for the shape (remote JWKS, pinned
algorithm, audience check), even though the implementation language differs.

**What CloudFront is actually for.** The cost argument above rules out API Gateway; it does
*not* justify CloudFront, because a Lambda Function URL has no per-request charge and calling
it directly is already free. Three things earn its place, and none of them is speed:

1. **Somewhere to attach OAC**, which is what makes the Function URL non-public at all. This one
   is sufficient on its own.
2. **One origin for `/api/*` and the S3 client later** — one hostname, therefore no CORS.
3. **The option of a custom domain.** A Function URL is `https://<id>.lambda-url.us-east-2.on.aws`
   and nothing can be aliased onto it, so `api.<domain>` would require a distribution in front.
   No domain is being registered (§8), so this is a door left open rather than a reason.

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

**Cognito for identity, on the Lite tier.** All three things this design wants sit in one tier:
Lite carries **10,000 MAUs free permanently** — AWS states the allowance "does not automatically
expire at the end of your 12-month AWS Free Tier term" — plus managed login and social/SAML/OIDC
federation. What Lite lacks is the *visual branding editor* for the login page, which is what
Essentials adds at $0.015/MAU. Standard JWTs mean a small middleware layer is the entire user
management story, and **phase 1 is email-only with no federated IdPs** (§5, §6).

One number to carry forward if federation ever lands: on Essentials the free allowance for
**SAML/OIDC** federation is 50 MAU, not 10,000. Google and Apple are social providers and are
not subject to that, so a built-in social IdP is materially cheaper than a generic OIDC one.

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

**Why not DuckDB over files in S3:** genuinely tempting, for everything it deletes. Local
development would be exact rather than an approximation of DSQL, foreign keys would come back,
the migration runner would stop being special, the 3,000-row transaction cap would disappear, and
S3 object versioning is a passable point-in-time story for free.

It fails on writes, and not marginally. **DuckDB cannot open a database file on S3 for writing at
all** — `ATTACH` over HTTP or S3 is read-only, and omitting `READ_ONLY` errors with *"Cannot open
an HTTP file for both reading and writing."* So every write is GET-the-whole-database, mutate a
local copy, PUT-the-whole-database. The only concurrency primitive left is a conditional PUT on
the object's ETag, which serialises every write in the system against every other one — a
reaction conflicts with an unrelated reveal on a different show — and rewrites the entire
database to record a hundred bytes. Nor can a conflict simply be retried: the local copy is stale
by then, so each write has to be replayable against freshly fetched state. That is a hand-rolled
transaction log sitting underneath `reveal`, `left_at`, and `members_at`, which are the
invariants this design is least willing to get wrong.

**DuckLake is the sanctioned multi-writer answer, and it does not help here.** It requires a
catalog database with real concurrency; its own documentation puts Postgres in that role and
labels DuckDB and SQLite catalogs as suitable only for local proofs of concept. That is DSQL plus
S3 plus a lakehouse format, to store a few tens of megabytes.

Two smaller costs worth recording. `sqlx`'s compile-time query checking — listed above as a
deciding advantage of writing this in Rust — has no DuckDB backend, so it would become runtime
validation on the read path the type system was chosen to police. And DuckDB is a columnar
analytics engine being asked to serve small point lookups with a high write-to-data ratio, which
is the inverse of its design centre. Cost decides nothing: both are $0 at this scale.

The trade, stated plainly, is *incidental complexity already designed around* for *essential
complexity that would have to be invented*, landing on the write path where a bug is a lost
`reveal` rather than a slow query. **The same objection applies to any single-writer, whole-file
store**, SQLite on S3 included; the constraint is the storage shape, not DuckDB.

**Why DSQL:** serverless distributed Postgres on a public IAM-authenticated endpoint — no
VPC, no NAT, no connection pooling infrastructure. Scales to zero with *no* resume penalty.
Free tier is 100k DPUs + 1 GB storage permanently. SQL ergonomics are retained, so the
complex discussion read stays one query.

### DSQL constraints this design must respect

- **No foreign keys.** Referential integrity moves into a validation layer in the app.
- **No triggers, no PL/pgSQL, no temp tables.** Use CTEs; put logic in the app.
- **UUID primary keys throughout.** DSQL partitions on key distribution, so a monotonically
  increasing key concentrates writes on one partition. DSQL does support `CREATE SEQUENCE` and
  `GENERATED … AS IDENTITY`; the choice here is about distribution, not availability.
- **Index creation is always asynchronous.** `CREATE [UNIQUE] INDEX ASYNC` is the only form —
  plain `CREATE INDEX` is unsupported. **Inline `UNIQUE` and `PRIMARY KEY` constraints in
  `CREATE TABLE` are supported**, however, which keeps almost every constraint in §4 out of the
  async path entirely. See §7 for what that buys the migration runner.
- **Optimistic concurrency control.** Conflicting transactions return a serialization error
  rather than blocking. The app needs retry logic around writes. Note that an async index going
  active also updates the system catalog, and concurrent transactions touching the same
  namespace at that moment can see a concurrency error.
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
membership         group_id, account_id, role, display_name (nullable), accent_color,
                   left_at, removed_by (nullable)
invite             group_id, token, created_by, expires_at, max_uses, uses, revoked_at
watch_party        name, created_by
watch_party_member watch_party_id, account_id, status, sharing_enabled

title              tmdb_id, name, poster_path, status, tmdb_synced_at
episode            title_id, tmdb_id, season_number, episode_number, name, air_date, still_path
group_title        group_id, title_id

post               episode_id, author_account_id, group_id (nullable),
                   body, created_at, edited_at, offset_secs,
                   reply_to_post_id, parent_deleted_at
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

**Every one of these is declared inline on `CREATE TABLE`, as a column or table constraint.**
DSQL supports inline `UNIQUE` and `PRIMARY KEY` there, and using them sidesteps the async index
path completely: no `job_id` to wait on, no window in which the constraint is unenforced, and no
exposure to the `INVALID`-index failure mode in §7 — which is at its nastiest for unique indexes,
because a failed build still enforces uniqueness on writes while being unusable for reads. It is
also ordinary Postgres, so these migrations run unmodified against the local test database.

The consequence for §7's migration lint is that the sanctioned `ASYNC` rewrite applies only to
the *non-unique* read indexes, of which this design has few. A unique index would only ever be
created asynchronously if one had to be added to a table that already exists.

### The layering rule

Every table sits at exactly one of two layers, and the layer follows from a single question:
**does this describe the person, or the person's presence in one group?**

| Layer | Keyed on | Holds |
| --- | --- | --- |
| **Account** | `account_id` | Everything about watching: progress, reveals, timers, offsets. Authored posts. Spoiler-display preferences. Watch parties. |
| **Membership** | `group_id` + `account_id` | Presentation and standing: display name, accent colour, role. Plus group-scoped conversation — replies and reactions. |

You watch an episode once, so watching is account-level. You may present differently to your
roommates than to your coworkers, so presentation is membership-level. Being an admin is
membership-level for the same reason: it is a standing within one room, not a property of you.

**Mismatched layers are what produced the redundancy this design originally had.** Keying
progress on `membership_id` meant somebody in three *Star Trek* groups marked each episode
watched three times, and could hold "revealed" in one group and "hidden" in another for an
episode they had watched exactly once. When adding a layer, check it against the question above.

### Membership: presentation and standing

`account` is a login. `membership` is that account's presence in one group — how you appear
there, and what you may do there.

**Presentation.**

- **`display_name` is nullable and falls back to `account.display_name`.** NULL means "use my
  account name here": joining needs no naming step, renaming your account updates every group
  where you never overrode it, and the override stays available for the group that knows you as
  something else. Resolution is a `COALESCE` over a join the board read already performs. A
  copied-on-join name would instead leave every existing group showing a stale value, with no
  way to distinguish that from a deliberate override.
- **`accent_color` holds a palette name, not a colour value.** The server keeps a fixed palette
  of around a dozen colours chosen to stay legible in both light and dark; joining assigns the
  first one unused in that group, reusing once the palette is exhausted. `PATCH /api/groups/:g/me`
  accepts a palette name and nothing else. Free-form hex would carry no contrast guarantee —
  somebody picks `#111111` and is invisible in dark mode — and keeping the palette finite makes
  "distinct within a group" a cheap best-effort assignment rather than a constraint that can fail
  a join.
- **There is no `sort_order`.** Grid columns render as the caller first, then everyone else by
  resolved display name. An earlier draft carried the column over from Outwatch, where it was a
  hand-curated roster field; hand curation does not survive self-service groups, and the column
  had no route and no owner. A derived order costs nothing and cannot go stale.

**Roles.** `membership.role ∈ 'admin' | 'member'`. Creating a group seeds the creator's own
membership as `admin`; `group.created_by` stays a provenance record and confers nothing, so
ejecting or demoting a creator needs no special case.

| Any member may | Only an admin may |
| --- | --- |
| Issue an invite | Remove another member, and re-admit one |
| Leave the group | Promote a member to admin |
| Write, reply, react | Delete the group |

Inviting is deliberately *not* an admin power. Group access is invite-gated in every phase and an
account in zero groups can see nothing (§6), so restricting who may invite buys no privacy — it
only adds a bottleneck to the one action that makes a group useful.

Two invariants keep a group from becoming unadministrable. Both are app-layer, like every other
integrity rule here:

- **A group always has at least one admin.** Demotion is *self-only* — an admin steps down
  through `PATCH /api/groups/:g/me`, and the last one cannot. Admins deliberately cannot demote
  each other: peers demoting peers is a race with no tiebreaker, because this design has no
  owner sitting above them to resolve it.
- **The last admin cannot leave while other members remain.** They must promote a successor or
  delete the group first; the attempt otherwise fails. A sole admin who is also the sole member
  leaves freely, and the group goes dormant — see below.

### The watch party

A `watch_party` is a persistent set of accounts who watch together on the same screen — couples,
roommates, families. **Up to 10 active members**, enforced in the app layer. It is not a group and
has nothing to do with privacy: it holds no boards, no posts, and no visibility rules. Its entire
job is that people who watched an episode together tick it once between them.

**A watch party is account-level, not group-scoped.** Your household is your household regardless
of which group you are looking at. Scoping parties to groups would break under account-level
progress: somebody in a roommate party in one group and a partner party in another would have a
single solo viewing fan out to both, claiming two households watched an episode when one person
did. A party renders inside any group's grid as one column merging whichever of its members
belong to that group.

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

**Joining requires consent, because a party exposes your progress to it.**
`POST /api/watch-parties/:w/invites` takes an email address and always answers 202, so the route
never becomes an oracle for which accounts exist (§5). If the address resolves, a
`watch_party_member` row lands with `status = 'pending'`; the invitee sees it on `GET /api/me` and
accepts or declines. Only `status = 'active'` rows take part in fan-out or count against the
ten-member cap.

Addressing the invite to an email rather than minting a token is the same call §6 makes for
phase-B signup invites, and for the same reasons — but here it also spares two people who live in
the same house a link-passing ritual. Restricting invitees to accounts you already share a *group*
with was the alternative, and it fails the obvious case: your partner is your partner before the
two of you happen to join the same discussion group.

**`watch_party.created_by` may remove any member; anyone may remove themselves.** There is
deliberately no role column here. The bus-factor argument that ruled a bare `created_by` out for
groups barely applies to a household of at most ten: if the creator vanishes, the recovery is to
leave and re-form the party, which costs nothing, because progress is per-account and never lived
in the party to begin with. A group cannot be re-formed that cheaply — its conversation is inside
it.

**Leaving a party is a hard delete**, unlike leaving a group. Nothing references
`watch_party_member` historically: fan-out happens at write time, so every past write is already
materialised as ordinary per-account rows. There is no provenance to preserve, so there is no
`left_at` here and no reason for one.

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
  **`role` does not survive: a rejoin lands as `member`.** Otherwise a removed admin who kept
  or was handed an invite link would walk back in holding the power to remove the people who
  removed them.

**Being removed is not the same as leaving, and `left_at` alone cannot tell them apart.**
`DELETE /api/groups/:g/members/:a` sets `left_at` *and* `removed_by`, naming the acting admin.
While `removed_by` is set, `POST /api/invites/:token/accept` refuses for that account.

Without that, removal would not really be a control. Invites are issuable by any member (§4), so
a well-meaning one could undo an ejection immediately — and worse, an unexpired token the removed
person already holds would let them readmit themselves, since accepting an invite is exactly the
operation that clears `left_at`. Re-admission is therefore an explicit admin action that clears
`removed_by`, which also keeps a mistaken removal recoverable.

**`left_at` is lossy across repeated leave and rejoin, and that is accepted.** One column cannot
represent two gaps, so after a second departure, notes written during an *earlier* absence become
visible: the rule is a single upper bound, and rejoining moved it. The alternative is a
membership-interval table and a range containment check on every board read. Given that joining
already backfills the entire back catalogue by design, a slightly larger backfill is consistent
with the model rather than surprising — but it is written down here rather than discovered later.

**An emptied group persists; leaving never destroys it.** When the last member leaves, the
`group` row, its scoped posts, and its memberships all stay. Every route 404s because nobody
holds a live membership, so it is unreachable rather than gone. This matches the soft-delete
posture everywhere else and costs a handful of rows. Deleting on last-leave would instead let one
person clicking *Leave* destroy every group-scoped note and reply in the room — precisely the
erasure `left_at` exists to prevent.

Two things follow. **Admins can delete a group explicitly** (`DELETE /api/groups/:g`), which is
the deliberate, authorised version of that destruction and removes the group's memberships,
invites, `group_title` rows, scoped posts, replies, and reactions. Portable posts survive: they
belong to their authors and to episodes, and only lose one place they were visible. And
**dormant groups are eventually swept**: a group with no live membership for ~90 days is dropped
by the scheduled Lambda that already prunes invites and sessions (§4, growth and pruning). The
delay is not itself a recovery path — with no live membership nobody can issue an invite, so
undoing an accidental last departure is an out-of-band fix. It is a hedge against a single click
destroying a room's history irreversibly.

### Reveal is a mode, not a boolean

```
reveal   account_id, episode_id, mode, created_at
         mode ∈ 'open' | 'synced'          -- absence of row = hidden
```

A binary reveal flag would have precluded planned future behaviour: **posts appearing in
sync with the watch timer, auto-revealing as you watch**. Synced reveal is not "open", it
is "open up to where I am".

- `open` — every post on the board is visible. Marking an episode watched writes this. The API
  also accepts `hidden`, which is not a stored value: it deletes the row, since absence *is*
  hidden. Expressing the retraction as a mode keeps one route for the whole state machine.
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

### Deleting a post detaches its replies

`DELETE /api/posts/:p` is a **hard delete**, and it applies in every group the post reached. No
tombstone, no `[deleted]` placeholder, and no `deleted_at` predicate threaded through every read
path and through `members_at` forever. When you delete your words, they leave.

What must not leave with them is anybody else's. So the delete does two things to each reply
pointing at that post:

- **`reply_to_post_id` → `NULL`**, so the reply becomes an ordinary top-level note rather than a
  pointer into nothing. This is Outwatch's behaviour, in `migrations/0007`.
- **`parent_deleted_at` → now**, so it can still render as an answer to a note that is gone.

**`parent_deleted_at` is its own column rather than a reuse of `edited_at`.** The two describe
different events and both can be true of one note. `edited_at` means the author rewrote the body;
stamping it on a detach would report an edit that never happened, and once the author really does
edit, the two become indistinguishable. Leaving `reply_to_post_id` pointing at the deleted id was
the other alternative and is worse: with no foreign keys nothing would ever clean it up, and an
unresolvable parent is precisely how §5 renders a *locked* parent — so a note you cannot see yet
and a note that no longer exists would look the same.

Cascading the delete down to the replies was rejected outright. It would let one person's delete
destroy other people's words, which is the erasure the rest of this section is built to prevent.

Editing is unaffected: `PATCH /api/posts/:p` stamps `edited_at` and freezes `created_at`,
`offset_secs`, and `reply_to_post_id`, so an edit can neither move a note on the timeline nor
re-point its quote.

### Progress is per-episode

Outwatch tracked seasons and derived episode reveals. With arbitrary shows — including ones
airing week to week — episode-level is the honest unit. "Watched through episode N" becomes
a bulk write; a season grid derives from it.

**`reveal` and `watched_episode` stay separate tables** even though marking watched implies
revealing. They mean different things: one is "I've seen the episode", the other is "I've
read the board". Watching writes both; revealing writes only the reveal. Collapsing them
would lose the distinction between a board opened out of impatience and an episode actually
watched.

**Both are explicit two-way toggles, and neither retracts the other.** `PUT /api/episodes/:e/watched`
takes `{watched: bool}` and `PUT /api/episodes/:e/reveal` takes `{mode}` including `hidden` — the
same argument §7 makes for Outwatch's explicit `on` over a toggling reaction endpoint, which is
that a toggle is not idempotent and therefore cannot be retried safely under optimistic
concurrency.

Marking watched still writes both. **Un-marking writes only the watched half**, and the asymmetry
is the honest one: `reveal` records that you read the board, and un-watching cannot unread it.
Retracting it automatically would mean that marking an episode watched weeks after you
deliberately opened its board, then correcting a misclick on the watched flag, silently re-locks a
board you have already read. A misclick in the other direction stays fully recoverable, because
re-hiding is its own one-click action rather than a side effect of anything.

**Episode order is `(season_number, episode_number)`**, with season 0 sorting first. This is the
canonical order for the grid and for `POST /api/titles/:t/watched-through`, which marks every
episode at or before its target in that order **except**:

- **Season 0.** Specials are skipped by any range and marked individually. Nobody saying "I'm
  through season 3" means "and all the specials", and TMDB's specials are frequently
  out-of-continuity anyway.
- **Anything with a null or future `air_date`.** You cannot have watched an episode that has not
  aired, and a show mid-run would otherwise mark its unaired remainder watched forever.

Multi-part episodes need no handling: TMDB rows them separately, so they are ordinary episodes.
Air-date ordering was considered and rejected — null air dates make the order partial, TMDB's
dates are often regional or wrong, and the grid renders by number regardless. The P1 hand-seed
(§10) commits to this convention, so P2's ingest has to preserve it rather than invent it.

### Bulk writes must chunk

"Mark this whole series watched" writes to both `watched_episode` and `reveal`, so it is two rows
per episode, and fan-out multiplies that by the sharing members of the author's watch party. A
250-episode show for a 10-member party is 5,000 rows — over DSQL's 3,000-row transaction cap
before the series is even a long one. Bulk progress writes batch by episode range and commit per
chunk.

Account-level progress helps here rather than hurting: the row count no longer multiplies by
how many groups discuss the title. Somebody in three *Star Trek* groups writes one set of
rows, not three. The remaining multiplier is party size, which is capped at ten — so the worst
case is bounded and known, which is what makes fixed-size chunking sufficient.

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
Lambda that already runs for the TMDB refresh — the same job that prunes spent invites and
dormant groups. No new infrastructure.

| Table | Growth | Prunable? |
| --- | --- | --- |
| `watch_session` | Unbounded, worthless when dead | **Yes** — as above |
| `invite` | Grows per invite issued | **Yes** — drop expired/revoked after a grace period |
| `reveal`, `watched_episode` | accounts × episodes-in-catalog | No, but bounded and meaningful |
| `watch_offset` | Same bound, sparse — only actual corrections | No, but tiny |
| `group`, `membership` | Grows per group created, never per use | **Dormant only** — a group with no live membership for ~90 days |
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
| `POST /api/groups` | Create a group — creator becomes its first admin |
| `GET /api/groups/:g` | Members, watch parties, titles |
| `DELETE /api/groups/:g` | Delete — **admin only** |
| `PATCH /api/groups/:g/me` | My membership: `display_name`, `accent_color`, and self-demotion from `admin` |
| `PATCH /api/groups/:g/members/:a` | `{role}` promotes to admin; `{removed: false}` re-admits. **Admin only** |
| `DELETE /api/groups/:g/members/:a` | Remove someone — **admin only**; sets `left_at` and `removed_by` |
| `POST /api/groups/:g/invites` / `DELETE /api/invites/:token` | Issue / revoke — any member |
| `POST /api/invites/:token/accept` | Join — the only way in |
| `DELETE /api/groups/:g/me` | Leave — soft delete, sets `left_at` |
| `POST /api/watch-parties` | Create — account-level, not group-scoped |
| `POST /api/watch-parties/:w/invites` | `{email}` — always 202; creates a `pending` member if it resolves |
| `PATCH /api/watch-parties/:w/members/me` | `{status}` accept/decline; `{sharing_enabled}` — the business-trip toggle |
| `DELETE /api/watch-parties/:w/members/:a` | Leave, or removal by `created_by`. Hard delete |
| `GET /api/catalog/search?q=` | Server-side TMDB proxy |
| `POST /api/groups/:g/titles` `{tmdb_id}` | Ingest skeleton + attach |
| `GET /api/groups/:g/titles/:t` | Season grid: my progress, reveal state, per-episode note floor, all columns |
| `GET /api/groups/:g/episodes/:e/posts` | The board — reveal-filtered, portable + scoped, paged |
| `POST /api/groups/:g/episodes/:e/posts` | `{body, reply_to_post_id, scope}` — see below |
| `PATCH` / `DELETE /api/posts/:p` | Edit / delete own — applies in every group it reaches |
| `PUT /api/groups/:g/posts/:p/reactions` | `{emoji, on}` — group-scoped; emoji in body, not path (astral chars) |
| `PUT /api/episodes/:e/watched` | `{watched}` — account-scoped |
| `POST /api/titles/:t/watched-through` | Bulk, chunked per §4 — account-scoped |
| `PUT /api/episodes/:e/reveal` | `{mode: open\|hidden}` — account-scoped |
| `POST /api/episodes/:e/timer` | `{action: start\|pause\|resume}` — account-scoped |
| `PUT /api/episodes/:e/offset` | `{adjust_secs}` — account-scoped |

**Role changes are split across two routes on purpose.** `PATCH /api/groups/:g/members/:a` only
ever *promotes*, and `PATCH /api/groups/:g/me` is the only way to stop being an admin. That
mirrors the §4 invariants directly: an admin cannot demote a peer, and the last admin cannot
demote themselves or leave while others remain — a 409 in both cases, since the request is
well-formed and the group's state is what rejects it. The same route carries re-admission,
because clearing `removed_by` is the other thing only an admin may do to somebody else's
membership.

**Both watched and reveal are `PUT` with an explicit body**, so every progress write is
idempotent and therefore safe to retry under the serialization conflicts §7 describes. There is
no toggle endpoint anywhere in this API.

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

**The board is one flat chronological list, ordered by `(created_at, id)` ascending.** Replies
are not nested: `reply_to_post_id` renders as a quote of its parent, so a reply may point at
another reply and "depth" never becomes a rendering question. Nesting would have bought a
familiar shape at the cost of recursive assembly, a cycle guard, and an arbitrary cap that is
wrong the first time somebody wants to answer an answer. Oldest-first is the only defensible
order for a discussion read alongside an episode, and it is the order `synced` reveal will need
in P5.

**Paged with a keyset cursor on `(created_at, id)`.** The sort key is total — `created_at` alone
is not, since two notes can share a millisecond — so the cursor is just the last row's pair, and
paging cannot skip or repeat a note as the board grows underneath it. Offset pagination would do
both. The response carries an opaque cursor rather than the pair itself, so the encoding stays
free to change.

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
- **The distinct *other* authors who have written there.** This is what tells you whether opening
  the board is worth it, and it is the same call Outwatch made. Author identity resolves through
  the viewing group's `membership` as everywhere else, and the list runs through `members_at` like
  the posts do — so a locked board names only authors whose posts you would actually see once it
  opened. **You are excluded from it.** Your own notes already render right there, so naming
  yourself is redundant, and excluding yourself gives the list a sharper meaning: empty means
  "nothing here you have not already seen", which is exactly the question the floor exists to
  answer.

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

**Both are computed over the same set: posts you would see on opening, minus your own.** So both
run through `members_at` and both differ per viewer, and both live on the season grid
(`GET /api/groups/:g/titles/:t`) as well as the board, because the grid is where you decide what
to open. Counting your own notes would make "1 note" mean either "one stranger wrote here" or
"that was me", resolvable only by opening the board — which defeats the point of a floor.

## 6. Abuse and Cost Protection

### Framing: private-by-default already did most of the work

There is no public surface. No open discussion, no discovery, no user search, groups
reachable only by invite. This eliminates spam, stranger harassment, and scraping **by
construction rather than by controls**. What remains is an insider problem — someone you
invited behaving badly — which is solved socially, by removing them: `DELETE
/api/groups/:g/members/:a`, admin-only, and a group always has an admin able to run it (§4).

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
hand with `admin-create-user`. No pre-signup trigger, no post-confirmation trigger, no
service-administrator route, and nothing on `account` marking one — for a group this size that is
minutes per year, and each of those is easier to add later than to remove. (`membership.role` in
§4 is unrelated: it is standing inside one group, and confers nothing over the service or over
who may hold an account.) `account` rows are created **lazily by the auth
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

- **Naturally idempotent, retry freely** — reveals, `watched`, reactions, watch-party fan-out,
  role changes, membership removal. Every one of these is a `PUT` or a `PATCH` carrying the
  desired state rather than a toggle, which is what makes them retryable at all. (Outwatch's
  choice to make `PUT .../reactions` take an explicit `on` rather than toggling pays off directly
  here.)
- **Not idempotent** — timer actions (`start` zeroes the session) and post creation. Retry
  after a *failed* transaction is still safe, since nothing committed. The risk is only
  retry after an **ambiguous** failure such as a network timeout after commit.
  **Decision for v1: accept it.** A duplicate note is a minor annoyance the author can
  delete. If it bites, a client-supplied idempotency key fixes it with no schema change.

Conflict-prone paths to watch: fan-out to a 10-member watch party, reactions on a busy post,
simultaneous timer ticks, and chunked bulk progress writes. Separately, a migration's async index
going active can surface a conflict in unrelated transactions touching that namespace (§3), so
the retry wrapper matters during deploys and not only under user load.

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

  The exception is narrower than it first looks. DSQL accepts inline `UNIQUE` and `PRIMARY KEY`
  constraints in `CREATE TABLE`, and §4 declares every uniqueness constraint that way, so the
  rewrite only ever touches the handful of non-unique read indexes. Those are also the indexes
  whose absence degrades a query rather than breaking a guarantee, which is the safer half of the
  divergence to be carrying.
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
  blocks the session until it finishes and returns a boolean. Without this, migration N+1 can
  run against an index that does not exist yet — AWS explicitly recommends the wait during
  schema migration.
- **A failed index build leaves the index `INVALID`, not absent.** Fail loudly and require a
  manual `DROP INDEX`; proceeding silently leaves a unique index that, in AWS's words, keeps DML
  "subject to uniqueness constraints until you drop the index" while remaining unusable for
  reads. Note `sys.jobs` purges completed and failed rows after 30 minutes, so it is not an audit
  log — the runner must read a job's status while it still exists, not afterwards.

### Migrations run from CI, before the code deploy

**Not at Lambda cold start.** Concurrent cold starts would race on DDL, DSQL forbids DDL inside
a transaction so there is no lock to serialize them with, and it taxes the cold start Rust was
chosen to protect.

**GitHub Actions runs the migrations directly, before uploading the zip.** DSQL is a public
IAM-authenticated endpoint, so this needs no VPC — only `dsql:DbConnectAdmin`.

That ordering only works if a migration is safe against the code already running, which makes
**expand/contract a standing rule rather than a practice**: additive DDL ships with the deploy
that needs it, and drops ship a deploy later, once the code referencing the column is gone. No
migration may break the currently-deployed binary. This constrains every migration the project
will ever have, which is why it belongs here rather than being rediscovered during P1.

**`dsql:DbConnectAdmin` is the strongest permission in the design, so it gets its own role.**
It cannot be scoped below the cluster, and it is admin on the database — read everything, drop
anything. That is a capability CI does not otherwise have: `lambda:UpdateFunctionCode` already
lets CI run code as the function, but it reaches the data only through the application, and
only through code that was reviewed and merged. Database admin is an independent path.

So the trust boundary carries the scoping the IAM policy cannot:

- **A separate `spoilies.github-migrate` role**, not the deploy role. The deploy role is
  trusted broadly (`repo:jluszcz/Spoilies:*`) because it needs to work from any branch; putting
  DDL rights on it would let any pushed branch migrate production.
- **Trusted only from `repo:jluszcz/Spoilies:ref:refs/heads/main`**, so a pull-request branch
  cannot assume it at all.
- **Behind a GitHub Environment** with protection rules, which is where a manual approval gate
  goes if one is ever wanted.

**The alternative considered: a `migrate` entrypoint on the Lambda, invoked by CI.** That needs
only `lambda:InvokeFunction`, which adds nothing to CI's blast radius — but it moves DDL rights
onto the request-serving role, or costs a second function to avoid that. Running migrations
directly is fewer moving parts, and the trust scoping above closes most of the gap. Revisit if
CI's credentials ever become a real concern rather than a theoretical one.

### Test strategy

- **Unit, no database** — the highest-value tier. Session offset computation including the
  4-hour running cap, reveal filtering, `members_at` evaluation at post-creation time, the
  watched-through range (season 0 and unaired episodes excluded), fan-out target selection under
  `sharing_enabled`, and bulk chunking are all pure functions, and all are logic where a bug is a
  spoiler leak or silent data loss.
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
not see even after opening it; and it must exclude the caller, or the floor stops meaning what
§5 says it means.

## 8. Cost Model

At the stated scale, **$0/month** — every component sits inside a permanent free tier, and there
is no domain to pay for:

| Service | Free allowance | Expiry |
| --- | --- | --- |
| CloudFront | 1 TB egress, 10M requests/mo | Always |
| Lambda | 1M requests, 400k GB-s/mo | Always |
| Aurora DSQL | 100k DPU, 1 GB storage/mo | Always |
| Cognito (Lite tier) | 10,000 MAU/mo | Always |
| Lambda Function URLs | No per-request charge | n/a |
| CloudFront Functions | ~$0.10/M — the `Authorization` forwarder (§3) | n/a |
| S3 (code bucket, Terraform state) | 5 GB | 12 months, then pennies |

Beyond free tier: DSQL is $8.00/M DPU and $0.33/GB-month (us-east-1/us-east-2). This holds
until well past a few hundred users.

**No domain is being registered, and nothing in the design needs one.** The service runs on
CloudFront's default `*.cloudfront.net` hostname. That removes the only recurring charge in the
estate — a Route 53 hosted zone at $0.50/mo — along with the us-east-1 ACM certificate and the
cross-region wrinkle §3 notes about it.

Adding a domain later is additive and small: register it, create the hosted zone, issue the
certificate in us-east-1, and add an alias plus `viewer_certificate` to the existing distribution.
Nothing else moves, because the distribution, the origin, OAC, and the auth path are all
independent of the hostname. **The name "Spoilies" is settled regardless** — it is already the
repo, the AWS account, the IAM role names, and the S3 key, and none of that depends on owning the
matching domain.

### Free tier is aggregated across the organization

**AWS applies free tier to the consolidated billing family, not to each account.** Usage is
summed across every account in the organization, and eligibility dates from the *management*
account's creation, not the member account's.

Two consequences, one benign and one worth tracking:

- **The always-free tiers do not expire**, so the management account's age is irrelevant to
  everything in the table above. All of it is always-free rather than 12-month.
- **The allowances are shared.** Spoilies competes with the other projects in the organization
  for the Lambda allowance. In practice those are tiny, so the headroom is real, and Cognito and
  DSQL are unused elsewhere, making those tiers effectively all Spoilies'. But "$0/month" is a
  claim about the organization's aggregate, not about this account in isolation.

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

- **Terraform state lives in a bucket in this account, managed from this repo.** The other
  projects hardcode `jluszcz-tf-state` in the main account; Spoilies must not, or spin-out drags
  a state migration into the one operation that should be boring. Note the chicken-and-egg: the
  bucket holding the state cannot be a resource in the configuration it stores. Create it with
  a small scripted bootstrap (versioning, public-access block, KMS encryption, matching the
  conventions in the `AmazonWebServices` repo), then point the `backend "s3"` block at it.
- **The code bucket, GitHub OIDC provider, and deploy role are `resource`s here, not `data`
  sources.** This is a real departure from the JakeSky pattern, where those already exist
  because the `AmazonWebServices` repo created them. That repo's backend is `jluszcz-tf-state`
  in the main account, so extending it to cover Spoilies would recreate exactly the
  cross-account state dependency this topology exists to avoid. Spoilies owns them outright
  instead, which costs nothing because a human applies the Terraform.
- **Never IAM Identity Center for workload identity.** It is org-level and dies at
  separation. Fine for human console access; never for anything the application depends on.
- **No org CloudTrail trail, Config aggregator, or RAM share** in the dependency path.
- **A dedicated root email** that can be handed to a company later — an alias, not a personal
  address.

### Deployment topology

**Terraform is applied from a laptop with an active SSO session, never from CI**, matching
`AmazonWebServices`. CI's Terraform job runs `init -backend=false`, `fmt -check`, and `validate`
— offline, with no AWS credentials configured at all.

That is what makes the ownership decision above cost nothing. Creating the OIDC provider and
deploy roles from this repo's own configuration would be circular if CI applied the Terraform,
since CI authenticates *through* those roles; because a human applies it, the first apply is
just the first apply. An org-created account has no other credential path initially, so that
apply necessarily runs through `OrganizationAccountAccessRole` assumed from the management
account — the same role §9 warns survives account removal. CI takes over via OIDC afterwards.

**LambdUpdate is not part of this.** `github-utils` retired it in v2 (`deploy-lambda.yml`
updates the function itself), and Spoilies already pins `@v2`. The current flow is: GitHub OIDC
→ assume the deploy role → `PutObject` the zip to the account's code bucket →
`lambda:UpdateFunctionCode` → `aws lambda wait function-updated-v2`. No S3 event, no second
LambdUpdate instance, no partial-backend-config change in another repo, and no cross-account
question to reject. An earlier draft of this section planned all of that; it is obsolete.

Two roles, deliberately split (§7):

| Role | Trusted from | Grants |
| --- | --- | --- |
| `spoilies.github-deploy` | `repo:jluszcz/Spoilies:*` | `s3:PutObject` on `.../spoilies.zip`, `lambda:UpdateFunctionCode`, `lambda:GetFunction` |
| `spoilies.github-migrate` | `repo:jluszcz/Spoilies:ref:refs/heads/main` | `dsql:DbConnectAdmin` on the cluster |

Single-region, so `regional: false` and no suffix on the role names — matching JakeSky.

The remaining hand-run step is the Terraform state bucket, which cannot be a resource in the
configuration it stores.

## 10. Phasing

Each phase is a coherent, shippable step, and each gets its own implementation plan.

### P0 — Account bootstrap

Everything that has to be true before anything else can deploy: the AWS account itself, a
scripted Terraform state bucket, and then — as ordinary resources in this repo's Terraform,
applied locally — the code bucket, the GitHub OIDC provider, and the two deploy roles from §9.
Plus a Terraform `fmt`/`validate` job in CI, mirroring `AmazonWebServices`.

**No cross-repo work.** An earlier draft had P0 deploying a second LambdUpdate instance and
changing LambdUpdate's own backend and CI. `github-utils` v2 retired LambdUpdate, and Spoilies
already pins `@v2`, so all of that is gone — P0 is now entirely within this repo and its AWS
account.

Two scheduling notes: the account must exist **four days** before it could ever be removed from
the organization (§9), so create it early even if nothing else starts; and org-created accounts
carry no payment method, contact info, or support plan, which are collected at removal time
rather than now.

Small, but strictly first — P1's deploy step depends on all of it.

### P1 — Foundation and the spoiler gate

Cognito on the Lite tier in phase-A posture — `AllowAdminCreateUserOnly`, email only, no triggers
and no federated IdPs (§6) — with `account` rows created lazily by the auth middleware; `group`,
`membership` (including `role`), `invite`; `post` (portable and scoped); `reveal` in `open` mode
only; `watched_episode`; the board read with the gate applied, ordered and paged. Plus the
infrastructure: DSQL wiring, migration runner, CloudFront + OAC + the `Authorization` forwarding
function, and the Lambda deploy.

`role` ships here rather than later even though a first group has one member. It is a column on a
table P1 already creates, and the alternative is a migration plus a backfill deciding who was
retroactively in charge of every existing group.

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

Replies, reactions, edits, deletes — including the detach-and-mark rule for `parent_deleted_at`.
Note counts and the display preferences that govern them.

### P4 — Watch parties and timers

`watch_party` with the email-addressed invite, the pending/active consent flow, fan-out, and the
`sharing_enabled` toggle; `watch_session`, `watch_offset`, and `post.offset_secs`, with the
4-hour running cap and the lazy session cleanup from §4. The first phase with real concurrency
exposure, so the OCC retry work in §7 lands here.

### P5 — Synced reveal

`synced` mode, the polling read path, and the lookahead window.

**Deferred indefinitely:** Trakt watch-history import (§2), and per-group retraction of a
portable post. Retraction is purely additive — a `post_exclusion(post_id, group_id)` table
and one anti-join on the read path — so it can wait until it is actually wanted. Until then
the workarounds are to scope a note at creation, or to delete and rewrite it.

## 11. Open Questions

The product decisions this section used to hold are resolved and now live in the sections they
belong to: group roles and membership presentation in §4, post deletion and reply shape in §4,
un-watch, episode ordering, and watch-party consent in §4, board paging and the note floor in §5.
What remains is verification, and none of it changes a design decision — each answer changes an
implementation.

### Verified, and what it settled

- **Cognito tier: Lite.** It carries the 10,000 permanently-free MAUs, managed login, and social
  federation together, so §3's assumptions sit in one tier. What Lite lacks is the visual branding
  editor, which Essentials adds at $0.015/MAU. If federation ever lands, prefer a built-in social
  provider: on Essentials the free allowance for **SAML/OIDC** federation is 50 MAU, not 10,000.
- **DSQL index mechanics.** `CREATE [UNIQUE] INDEX ASYNC` is the only index form;
  `sys.wait_for_job(job_id)` blocks and returns a boolean; a failed build leaves an `INVALID`
  index that still enforces uniqueness on writes; `sys.jobs` purges after 30 minutes. Crucially,
  inline `UNIQUE` and `PRIMARY KEY` in `CREATE TABLE` are supported, which keeps every constraint
  in §4 out of the async path (§4, §7). DSQL also supports sequences and identity columns now —
  UUID keys remain the choice, for distribution rather than necessity.
- **Federated sign-in versus `AllowAdminCreateUserOnly`** — supported by scope rather than by an
  explicit statement. The API reference defines the flag against exactly one operation ("users can
  register themselves and create a new user profile with the `SignUp` operation"), and the
  pre-sign-up trigger documentation describes federated first sign-in as a separate creation path.
  So the flag does not gate federated users. This no longer needs to be load-bearing: P1's
  no-federation posture is correct whichever way it resolves, so the empirical check moves to
  whichever phase enables federation.

### Still to verify, in the phase that depends on it

- **CloudFront OAC to a Lambda Function URL** (§3) — the `Authorization` collision and how
  request bodies are signed for POST/PUT. Needs a deployed distribution to answer honestly; P1.
- **`sqlx` offline mode** — compile-time query checking needs a live Postgres at build time or a
  committed `.sqlx` cache, and CI cross-compiles to `aarch64-unknown-linux-musl` with no
  database. Worth an early spike alongside the DSQL SQLx connector's TLS stack on musl/ARM; P0.
