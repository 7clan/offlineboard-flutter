# Offline sync — the flagship design

This document describes the offline-first engine **as implemented**: every
claim maps to a class in `lib/data/` and `lib/domain/`. The runnable
counterpart is `tool/sync_smoke.dart`, which exercises the whole pipeline
end to end (`dart run tool/sync_smoke.dart`).

Core classes: `SyncEngineImpl` (`lib/data/sync/sync_engine_impl.dart`),
`LastWriteWinsConflictResolver`
(`lib/data/sync/conflict_resolver.dart`), `SyncQueueDao` /
`TasksDao` / `ProjectsDao` (`lib/data/db/app_database.dart`),
`TaskRepositoryImpl` / `ProjectRepositoryImpl`
(`lib/data/repositories/`), `MockSyncServer` / `RemoteConditions`
(`lib/data/remote/mock_sync_server.dart`), policy knobs in
`AppConfig`/`SyncRetryPolicy` (`lib/core/config/app_config.dart`).

---

## 1. Local SQLite is the source of truth

The app never *reads* from the server. Every screen is a Drift watch
stream over the local database; the server is a **delivery target**, not a
query source. Consequences:

- **Offline usability is structural, not bolted on.** Creating, editing,
  deleting, filtering and searching work identically with the network gone
  — the local row is written first, sync is a background delivery concern.
- **Stale data is impossible by construction.** The UI cannot show server
  state that has not been applied locally; it shows exactly the local row
  plus its queue-derived sync badge.
- **The queue is a table.** Not an in-memory buffer: `pending_mutations`
  is durable SQLite, so the app can be killed mid-flight and the
  mutation survives with its attempts/backoff bookkeeping intact
  (`SyncQueueDao.clearSyncingFlags()` resets in-flight markers on the next
  `pushPending()` — recovery from a crashed round).

## 2. The mutation flow (write path)

Every mutation is **one Drift transaction** followed by a fire-and-forget
sync trigger:

```
User action (e.g. TaskEditorController.save)
  → TaskRepository.createTask/updateTask/deleteTask
      ┌─ db.transaction ─────────────────────────────┐
      │  1. upsert the row (version+1, updatedAt=now)│
      │  2. syncQueueDao.enqueueMutation(record)     │
      └──────────────────────────────────────────────┘
      → unawaited(syncTrigger())      // ← fire-and-forget
         (wired to SyncController.syncNow in repositories_provider.dart)
  → watch streams re-emit (row + queue changed)
  → UI updates instantly, row badge = SyncStatus.pending
```

What lands in the queue entry (`MutationRecord`,
`lib/domain/entities/mutation_record.dart`):

| Field | Meaning |
| --- | --- |
| `mutationId` | fresh `IdGenerator()` id — the **idempotency key** the server remembers |
| `type` | `create` / `update` / `delete` |
| `entityType` | `project` / `task` |
| `entityId` | affected record id |
| `payloadJson` | full new record state (the tombstone row for deletes) |
| `baseUpdatedAt` / `baseVersion` | what the local edit was applied on top of — the values the server must still be at for a clean apply |
| `clientTimestamp` | when the edit happened — the LWW comparison key |
| `queuedAt` | when it entered the queue — push order |
| `attempts` / `lastError` | failure bookkeeping (engine-updated) |
| `isSyncing` | engine-set in-flight flag → `SyncStatus.syncing` |

Notes on the concrete repositories:

- **Updates read the base row first** (`_requireTask` / `_requireProject`),
  bump `version = base.version + 1` and stamp `updatedAt` from the
  injected clock — the row always carries the newest local write.
- **Deletes are tombstones**: the row is written back with
  `isDeleted: true` and a `delete` mutation carries the tombstone payload
  (`TaskRepositoryImpl.deleteTask`). Deleting an unknown id is a no-op.
- **Project delete cascades in the same transaction**
  (`ProjectRepositoryImpl.deleteProject`): the project tombstone plus a
  tombstone for every non-deleted child task, each with its own queued
  `delete` mutation — the server deletes every child too.
- **Idempotent queue writes**: `SyncQueueDao.enqueueMutation` checks the
  mutation id first (plus the table's `UNIQUE (mutation_id, entity_id)`
  key), so a double-enqueue is a no-op returning `false`.

## 3. The sync queue table schema

`pending_mutations` (from `lib/data/db/app_database.dart`):

```sql
CREATE TABLE pending_mutations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- row handle (order is queued_at)
  mutation_id TEXT NOT NULL,             -- idempotency key
  type INTEGER NOT NULL,                 -- MutationType index
  entity_type INTEGER NOT NULL,          -- EntityType index
  entity_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,            -- full new record state
  base_updated_at INTEGER NOT NULL,
  base_version INTEGER NOT NULL,
  client_timestamp INTEGER NOT NULL,     -- LWW comparison key
  queued_at INTEGER NOT NULL,            -- push order
  attempts INTEGER NOT NULL DEFAULT 0,   -- failed pushes so far
  last_error TEXT NULL,                  -- diagnostics
  is_syncing BOOLEAN NOT NULL DEFAULT 0  -- in-flight marker
);
-- table-level unique key (Drift `uniqueKeys`): UNIQUE (mutation_id, entity_id) — dedupe
CREATE INDEX idx_queue_entity ON pending_mutations (entity_id, is_syncing, attempts);
```

`sync_meta` (key/value table) persists the pull cursor:
`lastPullAt` = the server time of the last successful pull
(`SyncEngineImpl.lastPullCursorKey`).

Companion tables: `projects` and `tasks` carry `id`, content columns,
`created_at`, `updated_at`, `version`, `is_deleted` (tombstones). The
tasks table has `FOREIGN KEY (project_id) REFERENCES projects (id) ON
DELETE CASCADE` (enforced via `PRAGMA foreign_keys = ON` in `beforeOpen`).

## 4. Push: drain order, backoff, starvation guard, manual retry

`SyncEngineImpl.pushPending()` — one batch per call:

1. **Recover**: `clearSyncingFlags()` — rows a crashed round left marked
   in-flight return to plain `pending`.
2. **Select batch**: `SyncQueueDao.nextBatch(limit: pushBatchSize (32),
   maxAttempts: 5)` — **FIFO by `queued_at`, then row id**; mutations with
   `attempts >= maxAttempts` are **excluded** (starvation guard: exhausted
   entries must never crowd fresher ones out of the batch).
3. **Mark in flight**: `markSyncing(rowIds)` → the watch streams flip those
   rows to `SyncStatus.syncing` while the request runs.
4. **Decode** rows to wire `PushMutation`s. A corrupt queue row (payload
   JSON unparseable) **fails closed**: it gets `markAttempted` with a
   `Corrupt queue entry: …` diagnostic and stays queued — never crashes
   the round.
5. **POST /sync/push** and validate the echo: results must match the
   pushed mutation ids exactly, else the whole response is treated as
   malformed (`_validateEcho` → `MalformedResponseException`).
6. **Fold results per item**:
   - `applied` → `removeMutations([row.id])` — dequeued. (The local row
     already matches the server by construction: the server takes the
     client's `clientTimestamp` as `updatedAt` and `baseVersion + 1` as
     `version`.)
   - `conflict` → `_resolveConflict(...)` (section 6).
   - `rejected` → `markAttempted(row.id, reason)` — counts as a failed
     attempt; a rejected payload (e.g. empty title) will fail again
     unchanged, so after `maxAttempts` it surfaces as `failed` and waits
     for manual attention instead of looping forever.
7. **Transport/protocol failure** (offline, timeout, 5xx, malformed
   body): every *unresolved* mutation in the batch gets
   `markAttempted(rowIds, mappedError.userMessage)` (attempts + 1,
   `last_error` set, `is_syncing` cleared) and the outcome carries the
   mapped `AppException` plus a `retryAfter` delay.

`SyncOutcome` reports the round: `mutationsSent`, `applied`,
`conflictsResolved`, `rejected`, `failed`, `retryAfter`, `error`.

**Backoff policy** (`SyncRetryPolicy` in `app_config.dart`):
`backoffFor(attempts) = min(initialBackoff × multiplier^attempts, maxBackoff)`
→ **1s, 2s, 4s, 8s, 16s… capped at 2 minutes**; `maxAttempts = 5`.
`_retryAfter()` computes the delay from the **maximum remaining attempts**
and returns `null` when nothing is left worth retrying (queue empty, or
every entry exhausted) — that `null` is what stops the automatic retry
timer in `SyncController`.

**Failed state + manual retry**: once `attempts >= maxAttempts`, the
mutation stays queued and is *excluded from batches*; the status
subqueries (`failedCount = COUNT(*) WHERE entity_id = ? AND attempts >=
maxAttempts`) surface the record as `SyncStatus.failed`. The Settings
screen (and the failed banner) call `SyncController.retryFailed()` →
`SyncQueueDao.resetFailures()` (attempts → 0, `last_error` cleared) →
immediate `pushPending()`. **Nothing is ever dropped or dead-lettered
without the user seeing it.**

## 5. Pull: the never-overwrite-pending guard

`SyncEngineImpl.pullSince()`:

```
cursor = sync_meta.lastPullAt (0 on first pull)
GET /sync/pull?since=cursor  →  changed projects + tasks + serverTime
for each server record:
   if queue has ANY entry for this entity  → SKIP      ← guard #1
   else if local row exists and server.updatedAt <= local.updatedAt
                                            → SKIP      ← guard #2 (LWW)
   else upsert the server record            → applied
persist sync_meta.lastPullAt = serverTime
```

- **Guard #1** (`SyncQueueDao.hasPendingFor`) — a server record can never
  clobber a pending local edit. The local edit will be pushed first on
  the next round; the server's version of events gets a chance to win
  only through the *conflict* path, where the resolver compares
  timestamps.
- **Guard #2** — even without queued edits, the server only wins when its
  `updatedAt` is **strictly newer**; equal timestamps skip. Replaying a
  whole history (cursor rewind) is therefore idempotent — the smoke tool
  verifies this by rewinding the cursor to `0` and asserting nothing
  re-applies (`replay.skipped >= 2`).
- `syncNow()` runs **push before pull** so local wins reach the server
  before the local rows are compared against a pull.
- The pull cursor is persisted *after* the records are applied — if the
  app dies mid-pull, the records re-arrive next time (upserts are
  idempotent).

Pull errors: `FormatException`/`TypeError` while parsing →
`MalformedResponseException`; anything else → `DatabaseException`; already-
mapped `AppException`s rethrow untouched (`pullSince`'s catch chain).

## 6. Conflict strategy — the actual LWW rules

### 6.1 When the server says CONFLICT

The server applies a mutation only when the record is new or its stored
`version` still equals the mutation's `baseVersion`. Otherwise it answers
`conflict` **with its current record** (see [API.md](API.md)).

### 6.2 The resolver (pure LWW)

`LastWriteWinsConflictResolver.resolve({mutation, serverRecord})` —
version-vector-free, implemented in `lib/data/sync/conflict_resolver.dart`:

1. **Timestamp comparison.** `mutation.clientTimestamp` vs
   `serverRecord.updatedAt` — the newer write wins. Because both are
   "last write" timestamps, every shape falls out naturally:
   - a local **delete** newer than the server's last update wins →
     *delete beats update*;
   - a **server tombstone** newer than the local edit wins → the server
     delete stands;
   - otherwise the plain newer content wins.
2. **Deterministic tiebreak on exact equality.** Compare the two writes'
   ids lexicographically — **smaller id wins**. When the server record was
   seeded (no `lastMutationId`), the local mutation wins. No coin flips:
   every device resolving the same pair picks the same winner.

### 6.3 Applying the verdict (the engine's convergence trick)

`SyncEngineImpl._resolveTaskConflict` / `_resolveProjectConflict` run
inside **one Drift transaction**:

```
local = current row for mutation.entityId
localWins = verdict == localWins
            || (local != null && local.updatedAt > snapshot.updatedAt)
   // second clause: the row is even newer than the mutation that
   // conflicted (the user typed again) — row-level truth wins

if (localWins):
   corrected = (local ?? mutation.payload) with version = snapshot.version + 1
   upsert corrected row
   removeMutationsForEntity(entityId)          // drop ALL stale entries
   enqueue a NEW mutation:
       mutationId = fresh id
       type      = corrected.isDeleted ? delete : mutation.type
       payload   = corrected row
       baseUpdatedAt = snapshot.updatedAt      // ← re-based onto the server
       baseVersion   = snapshot.version
   // → the corrected mutation is delivered in a follow-up wave of the
   // SAME push round (bounded), so the server converges immediately —
   // WITHOUT losing local edits
else:
   upsert server payload (the winner) locally
   removeMutationsForEntity(entityId)          // drop the losing mutation
```

Three properties worth stating explicitly:

- **Row-level truth.** Repositories keep the local row in step with the
  newest queued mutation (they re-read the base and bump from it), so the
  row — not an arbitrary queue snapshot — is the local authority. If the
  user edited *again* while the first push was in flight, the second edit
  is preserved by the re-arm.
- **Superseded entries collapse.** `removeMutationsForEntity` wipes *all*
  queue entries for the entity, then one corrected mutation is re-armed —
  a rapid-edit history never leaves stale orphans behind.
- **Idempotency keys.** The re-armed mutation carries a fresh
  `mutationId`; the server remembers processed ids and answers replays
  `applied` without re-applying (`MockSyncServer._processedMutationIds`).
  Duplicate/dropped-duplicate pushes are harmless.
- **Immediate convergence.** The corrected mutation is not left waiting
  for the next sync: `pushPending` delivers it (and only it — rejected or
  failed entries are never re-attempted) in bounded follow-up waves, so a
  local-wins conflict drains the queue and converges the server within a
  single `syncNow`.

A malformed conflict record (missing `record`, unparseable payload) or a
database failure while resolving → the mutation gets `markAttempted` with
the mapped error and retries; the rest of the batch continues.

## 7. Per-record SyncStatus derivation

`syncStatus` is **derived in SQL, never stored**. Every watch query
carries three correlated subqueries:

```sql
(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = t.id) AS queueCount,
(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = t.id
 AND pm.is_syncing = 1) AS syncingCount,
(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = t.id
 AND pm.attempts >= :maxAttempts) AS failedCount
```

mapped by `deriveSyncStatus` (`lib/data/mappers/entity_mappers.dart`):

| Condition | Status | UI (status_icon.dart) |
| --- | --- | --- |
| `failedCount > 0` | `failed` | crossed-out cloud, error colors |
| `syncingCount > 0` | `syncing` | small progress indicator |
| `queueCount > 0` | `pending` | cloud with up arrow, tertiary |
| otherwise | `synced` | cloud with check, primary |

Priority order is deliberate: failed is the most actionable, an in-flight
push beats plain pending, anything queued beats synced. Because the
subqueries run in the same statement as the row read, status and row are
always a consistent snapshot — and because Drift re-runs the query when
either table changes (`readsFrom: {tasks, pendingMutations}`), badges flip
live as the queue drains.

## 8. The offline simulation switch

Production wiring (`lib/main.dart`) overrides
`connectivityServiceProvider` with `demoConnectivityProvider` —
`DemoConnectivityService` (`demo_connectivity_provider.dart`) wraps the
real platform service and can force offline:

- Settings → "Simulate offline (demo)" → `SimulateOfflineController` →
  `setForcedOffline(true)` → the wrapper's `isOnline` returns `false` and
  emits on `onConnectivityChanged`.
- The `SyncController` reacts exactly as to a genuine connection loss:
  state → `SyncOffline` (banner: "Offline — changes are saved locally"),
  rounds stop. Mutations keep queueing.
- Flipping back emits `true` → the controller drains the queue
  fire-and-forget (`_onConnectivityChanged`).
- The engine never knows the difference — connectivity is an app-layer
  concern by design, which is what makes the demo honest.

For fine-grained network faults (timeouts, 5xx, malformed bodies, dropped
connections, forced conflicts), the `RemoteConditions` knobs on the mock
server are the tool — used by tests and `tool/sync_smoke.dart`
(`server.conditions.dropConnection = true;` … `reset()`).

## 9. Failure modes and behavior

| Failure | How it happens (knob) | Engine behavior | User-visible result |
| --- | --- | --- | --- |
| **Timeout** | Dio `receiveTimeout` 20s / `connectTimeout` 8s (`AppConfig`); or `RemoteConditions.latencyMs` large | whole batch `markAttempted` + mapped `TimeoutException`; `retryAfter` = backoff | banner: "The sync server is taking too long…", rows → pending; auto retry after backoff |
| **Server error (500/503)** | `RemoteConditions.forceStatusNext = (count: 1, code: 503)` | `ErrorMapper` → `ServerException` (HTTP-level → Dio `badResponse`); batch marked attempted | banner: "Something went wrong on our side…", backoff retry |
| **Malformed response** | `RemoteConditions.malformedNext = 1` (non-JSON body); or results that don't echo the pushed ids | `MalformedResponseException` via `_validateEcho` / parse guards; batch attempted | banner: "We received an unexpected response…", retry; never a crash, never a raw exception |
| **Dropped connection** | `RemoteConditions.dropConnection = true` (accepts then destroys the socket) | client sees a hard transport error → `NetworkException` (SocketException unwrapped by `ErrorMapper._unwrapUnknown`) | offline-style banner; queue intact; retry |
| **Conflict** | `RemoteConditions.conflictOnProjectId = <id>` (server bumps version exactly when the push would apply cleanly) | per-item `conflict` result → LWW resolver → winner applied locally + queue collapsed; **not** an error | usually nothing — convergence; rows converge, queue drains; only an escaped `ConflictException` would message "This was changed elsewhere. The newest change was kept." |
| **Rejected payload** | push with empty title (server-side `_validate`) | per-item `rejected` → `markAttempted` with the reason; attempts accumulate to `failed` | row badge → failed; Settings "Retry failed" re-arms it; app-side `Validators` prevent this from user input |
| **App killed mid-push** | process death | `is_syncing` rows recovered by `clearSyncingFlags()` on next `pushPending` | seamless — queue persisted in SQLite |
| **Duplicate push** (retry after a lost response) | same `mutationId` replayed | server answers `applied` (`duplicate` reason) without re-applying | none — idempotent |
| **Offline at startup** | no network / simulation | initial round fails → `NetworkException`; backoff timer retries; queue persists | offline banner; all features usable |

## 10. The smoke tool

`tool/sync_smoke.dart` is a pure-Dart end-to-end harness (no Flutter
bindings) that wires the *real* database, repositories, engine, resolver
and server by hand with a pinned clock, and asserts the whole story:

1. local-first creation while the connection is dropped (`dropConnection`)
   — rows visible immediately, 2 mutations queued, triggers fired,
   attempts + `lastError` recorded;
2. reconnect → queue drains, statuses flip to `synced`;
3. pull idempotency incl. a full cursor rewind (own pushes skipped);
4. pull guard — a pending local edit survives a server-side change;
5. conflict resolved **local-wins** (client write newer) with convergence;
6. conflict resolved **server-wins** (server write newer);
7. project delete cascades to every child task on the server.

Run: `dart run tool/sync_smoke.dart` — exits non-zero on the first failed
expectation.
