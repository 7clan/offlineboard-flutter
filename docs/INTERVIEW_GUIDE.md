# OfflineBoard Interview Guide

Everything below is about **this repository** — every class, method and
file referenced exists and behaves as described. Questions are grouped by
topic; each has a **simple answer** (say this first), a **deeper
technical answer** (the real mechanism), and the **relevant files** to
review before the interview.

Read [README.md](../README.md) first, then
[docs/ARCHITECTURE.md](ARCHITECTURE.md) and
[docs/OFFLINE_SYNC.md](OFFLINE_SYNC.md). Then this guide top to bottom.

---

## A. Project overview (4 questions)

### 1. What is OfflineBoard, in one sentence?

**Question:** What is OfflineBoard?

**Simple:** An offline-first project & task manager: every write lands in
local SQLite first and is delivered to a sync server later, so the app is
fully usable with no connection — with a durable mutation queue,
retry/backoff, and last-write-wins conflict resolution.

**Deeper:** It's a portfolio project built to demonstrate production
discipline around the *hard* part of offline-first apps: local SQLite
(Drift) as the source of truth, a `pending_mutations` table that is the
offline capability itself, a sync engine (`SyncEngineImpl`) that drains
the queue in batches with per-result handling, a pure LWW conflict
resolver, a visible sync pipeline (banner + per-record badges), and
deterministic construction (injected `Clock`/`IdGenerator`) so the whole
conflict matrix is testable. The "backend" is a real in-process
`HttpServer` with fault-injection knobs — the HTTP stack is real, not
mocked at the Dio layer.

**Relevant files:** `README.md`, `PROJECT_SPEC.md`, `lib/main.dart`,
`lib/app.dart`

### 2. What are the screens and the user flow?

**Question:** Walk me through the app's screens.

**Simple:** Three tabs — Projects (home), Tasks (all tasks with filters),
Settings (sync controls + offline simulation) — plus a project detail
page, a full-page task editor, and a project editor dialog. A global sync
banner sits above the tab content.

**Deeper:** Navigation is one `GoRouter` with a
`StatefulShellRoute.indexedStack` holding three branches (each tab keeps
its scroll position and filter state in an `IndexedStack`).
`/project/:id`, `/tasks/new?project=:id` and `/tasks/:id/edit` are
root-navigator routes so they cover the bottom bar. The task editor takes
the `Task` snapshot via route `extra` when available and falls back to
`taskByIdProvider` for deep links. There is no auth gate — local-first
means every route is reachable immediately.

**Relevant files:** `lib/presentation/routes/app_router.dart`,
`lib/presentation/screens/home_shell.dart`

### 3. Which packages does it use and why?

**Question:** Why this stack?

**Simple:** Riverpod 3 (state + DI), GoRouter 16 (navigation), Dio 5
(HTTP), Drift 2 (type-safe SQLite), `connectivity_plus` (online state),
`path_provider` + `sqlite3_flutter_libs` (database file), `intl`
(formatting), `mocktail` (tests).

**Deeper:** Every choice maps to a problem: Riverpod for compile-safe DI
and `family`/`select` rebuild scoping without BuildContext; GoRouter for
declarative routing with `StatefulShellRoute` tab-state preservation;
Drift because watch streams give table-change reactivity (no polling) and
typed SQL with transactions; Dio because its timeout taxonomy feeds the
error mapping cleanly; `connectivity_plus` is wrapped behind a
`ConnectivityService` seam so the demo switch and tests control it.

**Relevant files:** `pubspec.yaml`

### 4. How big is the app, and how is quality enforced?

**Question:** What's the size and quality story?

**Simple:** 67 Dart files under `lib/` across core/domain/data/presentation;
`flutter analyze` reports no issues; `dart format` is clean; the sync
pipeline has an end-to-end smoke harness (`tool/sync_smoke.dart`); CI runs
format + analyze + tests on every push and PR.

**Deeper:** The generated Drift code (`app_database.g.dart`) is committed,
so CI needs no `build_runner` step. Quality gates ran after every
implementation wave (no lint suppressions — analyzer findings were fixed
properly). The test suite is landing in the structured categories defined
in `docs/TESTING.md`; until it lands, claims are marked pending rather
than fabricated.

**Relevant files:** `docs/TESTING.md`,
`.github/workflows/flutter_ci.yml`, `tool/sync_smoke.dart`

---

## B. Drift & SQLite (8 questions)

### 5. What is the database schema?

**Question:** Describe the SQLite schema.

**Simple:** Four tables: `projects`, `tasks`, `pending_mutations` (the
sync queue) and `sync_meta` (key/value bookkeeping). `schemaVersion` is 1;
tasks have a foreign key to projects with `ON DELETE CASCADE`.

**Deeper:** `Projects` and `Tasks` both carry `id` (client-generated
text), content columns, `created_at`, `updated_at` (UTC millis), an
`is_deleted` tombstone flag. `PendingMutations` carries the mutation
id, type/entityType indexes, `payload_json` (full record state),
`base_updated_at`/`base_version` (what the edit was applied on top of),
`client_timestamp` (LWW key), `queued_at` (push order), `attempts`,
`last_error`, `is_syncing`. `SyncMeta` persists `lastPullAt` — the pull
cursor. Indexes are created in `MigrationStrategy.onCreate`; the FK is
enforced with `PRAGMA foreign_keys = ON` in `beforeOpen` (belt and
braces, since SQLite doesn't enable FKs by default).

**Relevant files:** `lib/data/db/app_database.dart`

### 6. How does Drift's generated code work here, and why is it committed?

**Question:** What does `app_database.g.dart` do?

**Simple:** Drift's `build_runner` output implements the tables as typed
Dart classes — data classes (`ProjectRow`, `TaskRow`,
`PendingMutationRow`, `SyncMetaRow`), companions for inserts, the mixin
APIs for each DAO, and the database class's plumbing. It's committed so
CI never runs code generation.

**Deeper:** The `@DriftDatabase(tables: […], daos: […])` annotation makes
`AppDatabase extends _$AppDatabase` with the four tables attached;
`@DriftAccessor` on each DAO generates the `_$ProjectsDaoMixin` etc. that
gives typed access to the tables. Row classes get `==`/`copyWith`
free. Because the file is checked in, the workflow is: edit the schema →
run `dart run build_runner build` → commit the regenerated file with the
schema change. `schemaVersion = 1` + the `MigrationStrategy` are the
seam where future migrations would go (Drift supports
`onUpgrade`/`TableMigration`).

**Relevant files:** `lib/data/db/app_database.dart`,
`lib/data/db/app_database.g.dart` (generated, committed)

### 7. Why do the DAOs use hand-written SQL instead of the Dart query builder?

**Question:** Why `customSelect` with raw SQL?

**Simple:** The list queries need three correlated subqueries against
`pending_mutations` for the per-record sync status, plus a multi-
dimensional filter — clearer and faster to express in one SQL statement
than in the builder.

**Deeper:** `TasksDao.watchTasks` folds project/completion/priority/
due-before/search into one SELECT with bound `Variable`s (all user input
parameterized — an injection guard by construction) and attaches
`queueCount`/`syncingCount`/`failedCount` subqueries, so row and status
are one consistent snapshot. `readsFrom: {tasks, pendingMutations}` tells
Drift when to re-run it. One subtlety worth knowing: the `attempts >= ?`
placeholder of the status subqueries appears *before* the WHERE
placeholder, so `maxAttempts` binds first — a real bind-order bug that
was caught and fixed (commit `bf05a2e`). Typed builder queries are used
where they read better (`getTaskById`, `nextBatch`, `watchCount`).

**Relevant files:** `lib/data/db/app_database.dart` (`TasksDao`,
`ProjectsDao`)

### 8. How do watch streams work, and why no polling?

**Question:** How does the UI stay current with the database?

**Simple:** Every read is a Drift `watch()` stream; Drift re-runs the
query when a table the statement `readsFrom` changes. No refresh timers
anywhere.

**Deeper:** The chain is: mutation commits row + queue entry in a
transaction → Drift's stream query invalidation re-runs the SELECT → the
stream re-emits with fresh data *and* fresh sync badges → Riverpod
`StreamProvider` updates the screen. `SyncQueueDao.watchCount` uses the
typed builder (`countAll()` + `watchSingle()`) for the queue badge. The
status subqueries mean the same stream covers both the row and its queue
state — there is no second status query to fall out of sync.

**Relevant files:** `lib/data/db/app_database.dart`,
`lib/presentation/providers/task_list_provider.dart`,
`lib/presentation/providers/queue_badge_provider.dart`

### 9. How are transactions used?

**Question:** Where and why does the code use database transactions?

**Simple:** Every local mutation writes the record row *and* enqueues its
sync-queue entry inside one `db.transaction(...)` — atomic by design, so
you can never have a queued mutation without its row or vice versa.

**Deeper:** `TaskRepositoryImpl.createTask/_applyEdit/deleteTask` and the
whole cascade in `ProjectRepositoryImpl.deleteProject` (project
tombstone + N child task tombstones + N+1 queue entries in ONE
transaction). Conflict application is also transactional:
`SyncEngineImpl._resolveTaskConflict` reads the local row, writes the
winner, collapses the entity's queue and re-arms the corrected mutation
inside one transaction — a crash mid-resolution leaves no half-applied
state. This atomicity is the load-bearing wall of offline-first: the
queue *cannot* lie about the local row.

**Relevant files:** `lib/data/repositories/task_repository_impl.dart`,
`lib/data/repositories/project_repository_impl.dart`,
`lib/data/sync/sync_engine_impl.dart`

### 10. Which indexes exist and why those?

**Question:** Why those four indexes?

**Simple:** They exactly cover the app's access paths: per-project
lists, completion filtering, due-date ordering/filtering, and the sync
status subqueries.

**Deeper:** `idx_tasks_project (project_id, is_deleted)` serves the
project detail list; `idx_tasks_completed (is_completed, is_deleted)` the
completion chips; `idx_tasks_due (is_deleted, due_date)` the default
ORDER BY (due date nulls last) and due-window filter;
`idx_queue_entity (entity_id, is_syncing, attempts)` the correlated
status subqueries and `hasPendingFor()` — which runs per record during
pulls, so it must stay an index lookup, not a scan. Each index includes
the tombstone/flags columns because nearly every query filters
`is_deleted = 0`.

**Relevant files:** `lib/data/db/app_database.dart`
(`MigrationStrategy.onCreate`)

### 11. How are enums stored?

**Question:** How do enums like `TaskPriority` and `MutationType` travel
through SQLite and the wire?

**Simple:** As integer indexes in SQLite, by *name* on the wire; the
mappers own both conversions and reject corrupt values loudly.

**Deeper:** Index storage keeps SQL filtering/ordering fast
(`ORDER BY t.priority DESC`). Wire names (`"urgent"`, `"create"`) are
robust to reordering. `entityTypeFromIndex`/`mutationTypeFromIndex`/
`priorityFromIndex` throw `FormatException` on out-of-range indexes
instead of defaulting — corrupt rows surface as mapped errors, never as
silent wrong data. `TaskPriority.tryFromName` returns `null` for unknown
names so `Task.fromJson` can decide it's malformed input.

**Relevant files:** `lib/domain/entities/sync_enums.dart`,
`lib/domain/entities/task.dart`, `lib/data/mappers/entity_mappers.dart`

### 12. How does the database open, and how is it isolated from the UI?

**Question:** Where does the SQLite file live and who runs the queries?

**Simple:** `databaseProvider` opens `<app-documents>/offlineboard.db`
through a `LazyDatabase` on `NativeDatabase.createInBackground` — queries
run on a background isolate, keeping the platform thread free. Tests
override the provider with `NativeDatabase.memory()`.

**Deeper:** `AppDatabase`'s constructor takes a `QueryExecutor` —
deliberately platform-free, so the database class itself has no
`path_provider` import (that lives in the provider wiring). The
`LazyDatabase` defers the async directory lookup to the first query,
which keeps the provider synchronous. Because every consumer
(repositories, engine, queue badge) *watches* `databaseProvider`, one
test override swaps the entire graph onto an in-memory database.

**Relevant files:** `lib/presentation/providers/database_provider.dart`,
`lib/data/db/app_database.dart`

---

## C. Offline-first design (6 questions)

### 13. What does "offline-first" mean in this codebase, concretely?

**Question:** Concretely, what makes the app offline-first?

**Simple:** The local SQLite database is the source of truth — every read
is a local watch stream, every write is a local transaction that also
enqueues a mutation. The server is a delivery target; being offline only
pauses delivery.

**Deeper:** The repositories' write path is: `db.transaction(() { upsert
row; enqueueMutation(record); })` then `unawaited(syncTrigger())`. The UI
never blocks on the network — the write is committed locally before sync
even starts. Read paths are watch streams over the local tables. The
queue is a SQLite table, so it survives process death. `SyncController`
owns connectivity and simply doesn't run rounds while offline. The demo
switch in Settings proves the claim: forcing offline changes nothing
about local usability.

**Relevant files:** `lib/data/repositories/task_repository_impl.dart`,
`docs/OFFLINE_SYNC.md`

### 14. How does a mutation flow from tap to server?

**Question:** Trace a task creation end to end.

**Simple:** Editor validates → repository transaction (row + queue
entry) → unawaited sync trigger → `SyncController` runs a round → engine
pushes the batch → server applies → mutation dequeued → watch streams
re-emit with `synced` badges.

**Deeper:** `TaskEditorController.save` runs `Validators.taskTitle`,
then `TaskRepositoryImpl.createTask`: mints an id via `IdGenerator`,
stamps `version = 1` + `updatedAt` from the injected clock, writes row +
`MutationRecord` (type `create`, `baseVersion: 0`, payload = full row
JSON, `clientTimestamp` = now) atomically, fires the trigger. The
controller coalesces bursts (`_busy` + follow-up flag). The engine takes
the FIFO batch, marks rows `is_syncing` (badges → `syncing`), POSTs, and
on `applied` dequeues — badges flip to `synced` because the status
subqueries now find no queue rows. Every step emits through providers,
so the UI story ("pending → syncing → synced") is just the database
talking.

**Relevant files:** `lib/presentation/providers/task_editor_provider.dart`,
`lib/data/repositories/task_repository_impl.dart`,
`lib/data/sync/sync_engine_impl.dart`

### 15. How is the queue durable?

**Question:** What happens if the app is killed mid-sync?

**Simple:** The queue is a SQLite table — committed mutations survive
restart. In-flight markers are cleared on the next push
(`clearSyncingFlags()`), so nothing is lost or stuck.

**Deeper:** `pushPending()` starts with `_queue.clearSyncingFlags()` —
rows a crashed round left flagged as in-flight return to plain
`pending`. `attempts`/`last_error` bookkeeping is likewise persisted, so
backoff continues sensibly after a restart. The pull cursor
(`sync_meta.lastPullAt`) is persisted *after* records are applied — a
crash mid-pull just means the same records re-arrive (upserts are
idempotent) next time.

**Relevant files:** `lib/data/sync/sync_engine_impl.dart`,
`lib/data/db/app_database.dart` (`SyncQueueDao`)

### 16. How does the offline simulation work — is it honest?

**Question:** Explain the "Simulate offline" switch.

**Simple:** `DemoConnectivityService` wraps the platform connectivity
service and can force `isOnline` false; the sync controller reacts
exactly as to a real connection loss — the engine literally cannot tell
the difference, which is what makes it honest.

**Deeper:** `main.dart` overrides `connectivityServiceProvider` with
`demoConnectivityProvider`, so the app's connectivity source is always
the wrapper. The Settings switch drives `SimulateOfflineController`,
which pokes the wrapper's `setForcedOffline` directly (no provider
rebuild); the wrapper emits on `onConnectivityChanged` and the
`SyncController` transitions to `SyncOffline` / drains on reconnect. The
`platformConnectivityProvider` seam exists so widget tests can stub the
platform layer and still exercise the switch without platform channels.

**Relevant files:**
`lib/presentation/providers/demo_connectivity_provider.dart`,
`lib/main.dart`, `lib/presentation/screens/settings/settings_screen.dart`

### 17. How does pull avoid overwriting pending local edits?

**Question:** What is the pull guard?

**Simple:** Two guards: a server record is skipped if the entity has ANY
queued mutation (`hasPendingFor`), and skipped unless the server's
`updatedAt` is strictly newer than the local row's.

**Deeper:** Guard #1 means local edits always get to the server first —
the server's version of events can only win through the *conflict* path,
where the LWW resolver compares timestamps properly. Guard #2 makes pulls
idempotent: rewinding the cursor replays history but nothing re-applies
(the smoke tool asserts exactly this). Push-before-pull ordering in
`syncNow()` completes the story: local wins reach the server before the
comparison happens.

**Relevant files:** `lib/data/sync/sync_engine_impl.dart`
(`_pullSince`), `lib/data/db/app_database.dart` (`hasPendingFor`)

### 18. What is "stale data" in this app?

**Question:** Can the UI show stale data?

**Simple:** The UI always shows the local row plus its queue-derived sync
badge — it can show *not-yet-synced* data, never *stale-then-replaced*
data: server records only enter the local database through the guarded
pull.

**Deeper:** Because reads never hit the network, "stale" would mean the
local row disagrees with the server — which is exactly what the
`pending`/`failed` badges communicate. After a successful sync, client
and server rows are identical by construction: the server stores the
client's `clientTimestamp` as `updatedAt` and `baseVersion + 1` as
`version`. `synced` therefore means "in step, as far as the client
knows" — an honest, bounded claim.

**Relevant files:** `lib/domain/entities/sync_enums.dart`
(`SyncStatus`), `lib/data/sync/sync_engine_impl.dart`

---

## D. Sync queue, retry & backoff (6 questions)

### 19. What is the drain order and batch size?

**Question:** How are mutations ordered and batched?

**Simple:** FIFO by `queued_at` (then row id), batched at 32 per push —
`SyncQueueDao.nextBatch` with `limit` from `AppConfig.pushBatchSize`.

**Deeper:** FIFO keeps server-side ordering sane (a create for a project
pushes before its tasks' creates, since queue order follows commit
order). Batching bounds request size and lets conflicts resolve per
mutation — a rejected item doesn't fail the whole batch. One batch per
`pushPending()` call; the controller's follow-up pass drains the rest.

**Relevant files:** `lib/data/db/app_database.dart` (`nextBatch`),
`lib/core/config/app_config.dart`

### 20. What is the starvation guard?

**Question:** Why doesn't a poisoned mutation block the queue?

**Simple:** `nextBatch` excludes mutations with `attempts >=
maxAttempts` — exhausted entries stay queued (surfacing as `failed`) but
can never crowd fresher entries out of the batch.

**Deeper:** Without the guard, a permanently-failing mutation would
occupy a batch slot on every round while fresh mutations behind it wait
— classic queue starvation. With it, fresh mutations always drain; the
failed entry remains visible (per-record `failed` badge, queue count,
Settings "Retry failed") and re-enters batches only after
`resetFailures()` sets attempts back to 0.

**Relevant files:** `lib/data/db/app_database.dart` (`nextBatch`
where-clause), `lib/data/sync/sync_engine_impl.dart` (`retryFailed`)

### 21. What exactly is the retry/backoff policy?

**Question:** How do retries and backoff work?

**Simple:** Exponential backoff — 1s initial, ×2 multiplier, capped at 2
minutes, `maxAttempts = 5`. The engine *reports* the delay
(`SyncOutcome.retryAfter`); the `SyncController` *schedules* it.

**Deeper:** `SyncRetryPolicy.backoffFor(attempts)` computes
`min(initial × multiplier^attempts, max)`. After a failed round,
`_retryAfter()` takes the max remaining attempts among queued,
non-exhausted mutations and returns null when nothing is left worth
retrying — the controller's timer is *cleared* on null, which is how
exhausted mutations stop auto-retrying (manual retry only). Each failed
attempt bumps `attempts` and records `last_error` via `markAttempted`,
so diagnostics are durable.

**Relevant files:** `lib/core/config/app_config.dart`
(`SyncRetryPolicy`), `lib/data/sync/sync_engine_impl.dart`
(`_retryAfter`), `lib/presentation/providers/sync_controller.dart`
(`_scheduleRetry`)

### 22. What happens after max attempts — is data dropped?

**Question:** What happens to a mutation that keeps failing?

**Simple:** Never dropped. After 5 failed attempts it surfaces as
`SyncStatus.failed` (crossed-out cloud badge) and waits for the manual
"Retry failed" action, which resets the bookkeeping and re-pushes.

**Deeper:** The status subqueries use `attempts >= maxAttempts` for
`failedCount`, so the *record's* badge (not just a queue row) flips.
`retryFailed()` → `SyncQueueDao.resetFailures()` (attempts → 0,
`last_error` cleared) → immediate `pushPending()`. This design keeps the
queue honest: the user always sees that something is undelivered, and
rejection (e.g. an invalid payload that will never apply) doesn't loop
forever.

**Relevant files:** `lib/data/db/app_database.dart` (`resetFailures`),
`lib/data/mappers/entity_mappers.dart` (`deriveSyncStatus`),
`lib/presentation/screens/settings/settings_screen.dart`

### 23. How are push results validated against a malformed server?

**Question:** What if the server's response doesn't match what you sent?

**Simple:** `_validateEcho` requires the echoed mutation ids to match the
pushed batch exactly — no missing, extra or duplicate ids — otherwise the
whole response is rejected as `MalformedResponseException` and the batch
is retried.

**Deeper:** Beyond the echo check, `SyncApiClient.push` requires a
`results` list of JSON objects, and `PushResultItem.fromJson` throws
`FormatException` on unknown statuses or missing ids — all mapped to
`MalformedResponseException`. Corrupt *queue rows* (payload JSON that
won't decode) fail closed too: `markAttempted` with a "Corrupt queue
entry" diagnostic, without failing the round. The design principle: a
lying or broken server costs you a retry, never your data.

**Relevant files:** `lib/data/sync/sync_engine_impl.dart`
(`_validateEcho`), `lib/data/remote/sync_api_client.dart`,
`lib/data/remote/sync_wire_types.dart`

### 24. What does SyncOutcome report and who consumes it?

**Question:** How does the engine communicate a round's result?

**Simple:** `SyncOutcome` — `mutationsSent`, `applied`,
`conflictsResolved`, `rejected`, `failed`, `retryAfter` (nullable
Duration), `error` (the mapped transport error, if any) — consumed by the
`SyncController` to set state and schedule retries.

**Deeper:** `hasFailures` (`failed > 0 || rejected > 0 || error != null`)
drives the `SyncFailed(message)` state with the error's `userMessage`;
`retryAfter` is null exactly when nothing is retryable. Keeping this as a
value object (rather than throwing) is what makes the engine
connectivity-free and its behavior assertable — the smoke tool asserts
`applied == 2`, `conflictsResolved >= 1`, etc.

**Relevant files:** `lib/domain/sync/sync_engine.dart`,
`lib/presentation/providers/sync_controller.dart`, `tool/sync_smoke.dart`

---

## E. Conflict resolution & idempotency (6 questions)

### 25. When does the server report a conflict?

**Question:** What triggers a CONFLICT result?

**Simple:** The server applies a mutation only if the record is new or
its stored `version` still equals the mutation's `baseVersion`; on
mismatch it answers `conflict` with its current record.

**Deeper:** The client's `baseVersion` records what the local edit was
applied on top of. If another client (or the deterministic injector
`RemoteConditions.conflictOnProjectId`, which bumps the server record
exactly when a push would otherwise apply cleanly) moved the server
forward, versions diverge and the server sends its full record back for
the client to resolve — the server is the arbiter of divergence, the
client of the resolution.

**Relevant files:** `lib/data/remote/mock_sync_server.dart`
(`_applyMutation`), `lib/data/remote/sync_wire_types.dart`

### 26. Explain the LWW rules precisely.

**Question:** How exactly does the resolver decide?

**Simple:** Compare the local mutation's `clientTimestamp` with the
server record's `updatedAt` — newer wins. On an exact tie, compare the
two writes' ids lexicographically; smaller id wins (and if the server has
no `lastMutationId`, local wins).

**Deeper:** `LastWriteWinsConflictResolver.resolve` — because both
sides compare *last-write* timestamps, all shapes fall out naturally: a
local delete newer than the server's last update wins (delete beats
update); a server tombstone newer than the local edit wins (the server
delete stands); otherwise newer content wins. The tiebreak is
deterministic across devices (no coin flips — every client resolving the
same pair picks the same winner). The class is pure and const: no
database, clock, or network — the conflict matrix is exhaustively
unit-testable.

**Relevant files:** `lib/data/sync/conflict_resolver.dart`,
`lib/domain/sync/conflict_resolver.dart`

### 27. What happens after the verdict — how do client and server converge?

**Question:** Walk me through conflict application.

**Simple:** The winner is applied locally in one Drift transaction and
the entity's queue is collapsed. If local wins, a *corrected* mutation is
re-armed with the server's version as its base — the next push applies
cleanly. If the server wins, its record replaces the local row and the
mutation is dropped.

**Deeper:** `_resolveTaskConflict`: `localWins = verdict == localWins ||
(local != null && local.updatedAt > snapshot.updatedAt)` — the second
clause is *row-level truth*: if the user typed again while the first push
was in flight, the newer row wins over the conflicting mutation. On local
wins: `corrected = base.copyWith(version: snapshot.version + 1)`,
`removeMutationsForEntity` (wipes ALL stale entries for the entity —
rapid edits never leave orphans), then one new mutation with a fresh
`mutationId`, `baseUpdatedAt = snapshot.updatedAt`, `baseVersion =
snapshot.version` and type `delete` if the corrected row is a tombstone.
Convergence without losing any local edit.

**Relevant files:** `lib/data/sync/sync_engine_impl.dart`
(`_resolveTaskConflict` / `_resolveProjectConflict`)

### 28. How do tombstones work?

**Question:** How are deletes synced?

**Simple:** Deleting writes the row back with `isDeleted: true` (and
`version + 1`, fresh `updatedAt`) and queues a `delete` mutation carrying
the tombstone payload — the delete then syncs like any other write.

**Deeper:** Tombstones exist so deletes can *converge*: LWW compares
timestamps, so a newer local delete beats an older server update and
vice versa (a server tombstone newer than the local edit stands). Locally
the tombstone row is filtered out of every list query (`is_deleted = 0`
in the WHERE, and in the indexes). The pull response includes
tombstones — applying one hides the row locally. The server's delete
handling writes the tombstone with `baseVersion + 1` and the client's
`clientTimestamp`.

**Relevant files:** `lib/data/repositories/task_repository_impl.dart`
(`deleteTask`), `lib/data/remote/mock_sync_server.dart`,
`lib/domain/entities/project.dart`

### 29. How does idempotency work?

**Question:** What happens if the same mutation is pushed twice?

**Simple:** The `mutationId` is an idempotency key: the server remembers
processed ids and answers `applied` (`reason: "duplicate"`) without
re-applying — a retry after a lost response is harmless.

**Deeper:** Locally, `SyncQueueDao.enqueueMutation` checks for the
mutation id first and the table's `UNIQUE (mutation_id, entity_id)` key
backs it up, so double-enqueues are no-ops. The re-armed conflict
mutation gets a *fresh* `mutationId` (it's a different write), while
baseVersion points at the server's current state. This is the
at-least-once-delivery + exactly-once-apply pattern.

**Relevant files:** `lib/domain/entities/mutation_record.dart`,
`lib/data/remote/mock_sync_server.dart` (`_processedMutationIds`),
`lib/data/db/app_database.dart` (`enqueueMutation`)

### 30. How does the project-delete cascade reach the server?

**Question:** What happens when you delete a project with tasks?

**Simple:** One transaction tombstones the project and every non-deleted
child task, each with its own queued `delete` mutation — the server
deletes every child too.

**Deeper:** `ProjectRepositoryImpl.deleteProject` fetches the children
(`getTasksForProject`), then in a single transaction writes the project
tombstone first (children keep their FK parent) and loops over children
writing tombstones + queue entries. The smoke tool's step 7 asserts the
server tombstoned both the project and the task and the local list no
longer contains the project. The delete-confirmation dialog explains the
queued/offline-safe consequence to the user.

**Relevant files:** `lib/data/repositories/project_repository_impl.dart`,
`tool/sync_smoke.dart` (scenario 7)

---

## F. Riverpod & connectivity (7 questions)

### 31. What provider types are used and where?

**Question:** Map the Riverpod provider types to their jobs.

**Simple:** `StreamProvider`/`StreamProvider.family` over Drift watch
queries (lists, by-id, queue count); `NotifierProvider` for controllers
(sync, editors, filters, banner, offline simulation); plain `Provider`
for DI (database, repositories, engine, config, clock, ids) and derived
values (stats, effective filter); `FutureProvider` for the async server/
client/engine chain.

**Deeper:** The DI spine is: `databaseProvider` → `syncServerProvider`
(FutureProvider — the ephemeral port exists only after `start()`) →
`syncApiClientProvider` → `syncEngineProvider`; repositories read the
database and wire the sync trigger to `syncControllerProvider.notifier`.
The engine being a FutureProvider is why `SyncController.build` watches
it — the notifier rebuilds when the engine materializes and kicks the
initial round.

**Relevant files:** `lib/presentation/providers/sync_engine_provider.dart`,
`docs/STATE_MANAGEMENT.md` (full table)

### 32. Why is `taskListProvider` a family, and why does it work?

**Question:** Explain the family design.

**Simple:** `StreamProvider.family<List<Task>, TaskFilter>` — one cached
stream per distinct filter. It works because `TaskFilter` is an immutable
value with proper `==`/`hashCode` (it's simultaneously the repository
query and the family argument).

**Deeper:** Riverpod hashes the family argument to key the cache: equal
filters reuse the same stream (and its latest `AsyncValue`), a changed
filter disposes the old stream and opens the new query. The debounced
search commits a new `TaskFilter` only after 350 ms of silence, so
stream churn is bounded. `TaskFilter`'s sentinel-based `copyWith`
(`Object? projectId = _unset` + `identical(...)`) lets callers clear
nullable dimensions — the canonical Dart pattern for nullable copyWith.

**Relevant files:** `lib/presentation/providers/task_list_provider.dart`,
`lib/domain/entities/task_filter.dart`

### 33. Where is rebuild scoping used?

**Question:** How do you avoid unnecessary rebuilds?

**Simple:** `select()` on the queue badge in Settings (rebuild only when
the integer changes), family caching for list streams, one shared
all-tasks stream feeding `projectStatsProvider`, and widget-level
splitting (the filter bar holds raw keystrokes locally).

**Deeper:** `queueBadgeProvider` re-emits on every queue change, but
Settings only depends on `value.value ?? 0`. `projectStatsProvider`
derives every project card's counters from `taskListProvider(TaskFilter
.all)` — one stream, not N COUNT queries, and filtering on the tasks
screen (a different family argument) doesn't disturb it. The search
field is uncontrolled: typing rebuilds the text field, not the screen.

**Relevant files:** `lib/presentation/screens/settings/settings_screen.dart`,
`lib/presentation/providers/project_stats_provider.dart`,
`docs/PERFORMANCE.md`

### 34. How does the SyncController work?

**Question:** Describe the sync lifecycle controller.

**Simple:** A `Notifier<SyncState>` (sealed: `SyncIdle` /
`SyncSyncing(queuedCount)` / `SyncFailed(message)` / `SyncOffline`) that
watches the engine and connectivity, subscribes to connectivity changes,
and funnels every round through `_runRound` with coalescing and retry
scheduling.

**Deeper:** `build()` watches `syncEngineProvider` (kicks the initial
round deferred, once — never writes state synchronously during build) and
`connectivityServiceProvider`, subscribing to `onConnectivityChanged`:
offline → `SyncOffline`; regain while offline → drain fire-and-forget.
`_runRound` guards with `_busy` + `_followUpPending` (a burst of mutation
triggers = one round + one follow-up, not N concurrent pushes), maps
failures to `SyncFailed(userMessage)`, schedules `_scheduleRetry
(outcome.retryAfter …)` — and *clears* the timer on null backoff, which
is what stops auto-retry when mutations are exhausted. A final `on
Object` catch guarantees even an engine bug surfaces as a user-safe
message.

**Relevant files:** `lib/presentation/providers/sync_controller.dart`

### 35. How does the sync banner state machine work?

**Question:** How is the banner derived?

**Simple:** `syncBannerProvider` (a Notifier) watches the sync
controller + live queue count and maps to
`hidden/offline/pending/syncing/failed/synced`; the `synced`
confirmation auto-dismisses after 3 seconds.

**Deeper:** The interesting derivation: `SyncState` has no explicit
"pending" — the banner derives it as `SyncIdle` + `queueBadge > 0`
("N changes waiting to sync" + a "Sync now" button). The transition into
idle *from* syncing/failed/pending shows the brief `synced`
confirmation (`_scheduleDismiss` timer, disposed via `ref.onDispose`).
The banner is pure presentation state — its buttons delegate to the sync
controller; no engine or repository access lives in the widget.

**Relevant files:** `lib/presentation/providers/sync_banner_provider.dart`,
`lib/presentation/widgets/sync_status_banner.dart`

### 36. How is connectivity handled?

**Question:** How does the app know it's online?

**Simple:** `ConnectivityService` — an abstract seam over
`connectivity_plus`; production wraps it further with the demo
wrapper (`main.dart` override), tests override it with a fake subclass
or stub the platform layer.

**Deeper:** `ConnectivityPlusService.initialize()` seeds `isOnline` from
a real platform check (optimistic `true` on failure — a wrong guess costs
one failed, retried sync round rather than a stuck offline badge) and
forwards `onConnectivityChanged`. The online predicate is "results
non-empty and not containing `none`" (per `connectivity_plus`
semantics). The engine never asks about connectivity — the separation is
what makes the demo switch and test fakes honest.

**Relevant files:** `lib/presentation/providers/connectivity_provider.dart`,
`lib/presentation/providers/demo_connectivity_provider.dart`

### 37. How do screens prime the global task editor?

**Question:** The editor is a global provider — how does it get per-task state?

**Simple:** Screens *prime* it on entry: `startCreate(projectId:)` or
`startEdit(task)` when the editor opens; edit mode uses the route's
`Task` snapshot when present and otherwise loads via `taskByIdProvider`.

**Deeper:** `TaskEditorScreen` is a `ConsumerStatefulWidget`; its
`initState` primes from `initialTask` (route `extra`), and a listener on
`taskByIdProvider(taskId)` covers the deep-link case where the snapshot
isn't available. List tiles toggle completion without opening the editor
— `toggleCompleted(taskId)` re-reads the row first (never trusts a stale
snapshot), so rapid taps converge. `startCreate` resets to
`TaskEditorState.initial` with the target project, and the editor's
notes field uses `''` = "no notes" (persisted as `null`) — the sentinel
copyWith on the state clears nullable errors/dates.

**Relevant files:** `lib/presentation/providers/task_editor_provider.dart`,
`lib/presentation/screens/tasks/task_editor_screen.dart`

---

## G. Error handling & data consistency (4 questions)

### 38. How are errors mapped to user-safe messages?

**Question:** How do you guarantee no raw exceptions in the UI?

**Simple:** One mapper — `ErrorMapper.map` translates
Dio/HTTP/parse/socket failures into the sealed `AppException` hierarchy,
each carrying a user-safe `userMessage`. Repositories wrap calls and
streams (`guardRepository`/`guardRepositoryStream`); controllers put the
messages into state; widgets render strings.

**Deeper:** Dio types map precisely: connection timeouts →
`TimeoutException`; `connectionError` → `NetworkException`;
`badResponse` → 401 `UnauthorizedException` (with an optional
server-provided message), 409 `ConflictException`, otherwise
`ServerException(statusCode)`; `unknown` is *unwrapped* (nested
DioExceptions, SocketException/HttpException, FormatException/TypeError
inside) before classification; `FormatException`/`TypeError` →
`MalformedResponseException`. Because `AppException` is sealed, every
subtype must be handled wherever it's switched. The
`SyncController`'s final `on Object` catch is belt-and-braces so even an
engine bug can't leak a stack trace.

**Relevant files:** `lib/core/errors/error_mapper.dart`,
`lib/core/errors/app_exception.dart`,
`lib/data/repositories/repository_support.dart`

### 39. How is per-record sync status derived?

**Question:** Where does the `synced/pending/syncing/failed` badge come from?

**Simple:** Derived in SQL — the watch queries carry three correlated
subqueries (`queueCount`, `syncingCount`, `failedCount` with `attempts >=
maxAttempts`); `deriveSyncStatus` maps them with priority failed >
syncing > pending > synced.

**Deeper:** Because the subqueries run in the same statement as the row,
status and row are always a consistent snapshot; because the status is
never *stored*, it cannot drift out of date — the queue is the single
source. The priority order is deliberate: failed is most actionable, an
in-flight push beats plain pending, anything queued beats synced. The
badge widget (`SyncStatusIcon`) maps each status to icon + color +
semantic label.

**Relevant files:** `lib/data/mappers/entity_mappers.dart`
(`deriveSyncStatus`), `lib/data/db/app_database.dart` (status
subqueries), `lib/presentation/widgets/status_icon.dart`

### 40. How is data consistency maintained across client and server?

**Question:** What invariant guarantees client/server agreement?

**Simple:** The queue never lies about the local row (they're written in
one transaction), pushes are idempotent, the pull never overwrites
pending local edits, and conflicts converge by LWW with re-based
mutations — after every successful round, client and server rows are
identical by construction.

**Deeper:** The server stores the client's `clientTimestamp` as
`updatedAt` and `baseVersion + 1` as `version` on apply, so a successful
push leaves both sides byte-identical — `synced` is a truthful claim.
Row-level truth handles the mid-flight edit case (the row, not the
mutation, is the local authority). The pull cursor persists after
records are applied, so crashes only cause idempotent re-pulls.

**Relevant files:** `lib/data/sync/sync_engine_impl.dart`,
`lib/data/remote/mock_sync_server.dart`, `docs/OFFLINE_SYNC.md`

### 41. How do the fault-injection knobs enable failure testing?

**Question:** How do you test failure modes without infrastructure?

**Simple:** `RemoteConditions` — mutable knobs held by reference by the
mock server: `latencyMs`, `forceStatusNext` (count + HTTP code),
`malformedNext`, `dropConnection` (accept then destroy the socket), and
`conflictOnProjectId` (deterministic conflict injection). Flipping one
affects the very next request.

**Deeper:** Because the server is a real `HttpServer` on 127.0.0.1, these
knobs produce *real* wire behavior: `dropConnection` gives the client a
genuine socket-level transport error (mapped to `NetworkException` via
`ErrorMapper._unwrapUnknown`); `forceStatusNext(503)` gives a real HTTP
5xx path; `conflictOnProjectId` bumps the server record exactly when a
push would apply cleanly, simulating a concurrent editor with full
determinism. The smoke tool drives scenarios 1 (offline) and 5–6
(conflicts) with exactly these knobs.

**Relevant files:** `lib/data/remote/mock_sync_server.dart`
(`RemoteConditions`), `tool/sync_smoke.dart`

---

## H. Routing & app structure (2 questions)

### 42. How is GoRouter structured?

**Question:** Describe the routing setup.

**Simple:** One `GoRouter` provided as `appRouterProvider` (the app
watches it in `MaterialApp.router`): a `StatefulShellRoute.indexedStack`
with three tab branches (`/`, `/tasks`, `/settings`) and root-navigator
routes for `/project/:id`, `/tasks/new`, `/tasks/:id/edit`.

**Deeper:** The shell keeps each branch's navigator state alive in an
`IndexedStack` — switching tabs preserves scroll position and filter
state. Detail/editor pages use `parentNavigatorKey: _rootNavigatorKey`
to cover the bottom navigation bar (the task editor is deliberately a
full page, never a sheet). No auth gate — local-first, every route
reachable immediately. The router is a provider so screens stay free of
navigation wiring and tests can watch the same graph.

**Relevant files:** `lib/presentation/routes/app_router.dart`,
`lib/app.dart`

### 43. Why is there no auth/login flow?

**Question:** Where's the login screen?

**Simple:** There isn't one — OfflineBoard is local-first with no remote
account: the local database is the source of truth and the sync server
is a simulation, so a gate would be ceremony.

**Deeper:** This is a deliberate scope decision from the spec: the
project's hard problems are persistence, sync and conflict resolution —
not session management. The error taxonomy still carries
`UnauthorizedException` (401 mapping in `ErrorMapper`), so adding auth
later is an interceptor + redirect away, but nothing in the current data
model requires it.

**Relevant files:** `PROJECT_SPEC.md`, `lib/presentation/routes/app_router.dart`

---

## I. Performance (3 questions)

### 44. What performance techniques are actually in the code?

**Question:** What did you do for performance?

**Simple:** Drift watch queries instead of polling; four indexes covering
the real access paths; one parameterized query for the whole filter
contract; `ListView.builder`/`SliverList.builder`; `const` widgets;
`select()` rebuild scoping; one shared stream feeding project stats;
350 ms debounced search; fire-and-forget sync; static skeletons.

**Deeper:** Each maps to a cost it removes: watch queries eliminate
periodic re-queries; the indexes make the status subqueries (which run
per record) O(log n) lookups; virtualization bounds the widget tree by
the viewport; `const` canonicalizes subtrees so rebuilds short-circuit;
the debounce collapses per-keystroke stream teardown/rebuild into
per-pause; fire-and-forget keeps the write path off the network
critical path. The skeleton is deliberately *not* animated — an
AnimationController per placeholder row costs more than the content it
mimics.

**Relevant files:** `docs/PERFORMANCE.md`, `lib/data/db/app_database.dart`,
`lib/presentation/providers/task_filters_provider.dart`

### 45. Why debounce at 350 ms, and how?

**Question:** Explain the search debounce.

**Simple:** A framework-free `Debouncer` (350 ms) — raw keystrokes stay
in the text field; only after 350 ms of silence does the text commit to
`taskFilterStateProvider`, which swaps the `taskListProvider` family
argument (disposing the old stream, opening the new query).

**Deeper:** Without it, "Buy" would tear down and rebuild the database
stream pipeline per character. The controller's `onSearchChanged`
reschedules on each event; `setSearch` commits immediately (tests,
clearing); `clear()` cancels pending timers. The debouncer is disposed
via `ref.onDispose` in the filter controller's `build`. Being
framework-free, it's trivially unit-testable with a fake clock.

**Relevant files:** `lib/core/utils/debouncer.dart`,
`lib/presentation/providers/task_filters_provider.dart`

### 46. Why is sync "background-safe"?

**Question:** What does background-safe sync mean here?

**Simple:** Committed mutations fire the sync trigger `unawaited` —
local writes never wait on the network; rounds coalesce; the queue is
durable SQLite; SQLite itself runs on a background isolate
(`NativeDatabase.createInBackground`).

**Deeper:** A slow or absent server costs the user nothing
interactively; failures surface asynchronously through the banner. Round
coalescing (`_busy` + `_followUpPending`) means a burst of mutations
becomes one request plus one follow-up instead of N concurrent pushes.
Because the queue is a table, the app can be killed anywhere without
losing a committed edit — the definition of durable offline delivery.

**Relevant files:** `lib/data/repositories/task_repository_impl.dart`
(`_triggerSync`), `lib/presentation/providers/sync_controller.dart`,
`lib/presentation/providers/database_provider.dart`

---

## J. Accessibility (2 questions)

### 47. What accessibility implementations exist?

**Question:** What a11y work is in the code?

**Simple:** A 48×48 dp tap target for the completion checkbox whose
`Semantics` label follows state ("Mark task 'X' as complete/not
complete", with the `checked` flag and inner semantics excluded);
`liveRegion` on the sync banner, editor errors and error views; form
errors through `errorText`; tooltips on every icon-only button; `Wrap`-
based rows that reflow at 2.0× text scale; standard Material chips with
built-in selected-state semantics.

**Deeper:** The pattern to know: `Semantics(label: …, checked: …,
button: true, onTap: …)` around `ExcludeSemantics(child: …)` — one
announcement, correct role, no double-speak. Live regions matter most
here because the sync pipeline's value is *observable state changes*
(offline → syncing → synced/failed). Text scaling: no fixed heights on
content, `Expanded`/`SingleChildScrollView` containers, `maxLines` only
where ellipsis is intended, and the theme never clamps text.

**Relevant files:** `lib/presentation/widgets/task_list_item.dart`,
`lib/presentation/widgets/sync_status_banner.dart`,
`lib/core/theme/app_theme.dart`, `docs/ACCESSIBILITY.md`

### 48. How does the app behave at large text scales?

**Question:** What happens at 2.0× text scaling?

**Simple:** Layouts reflow instead of clipping: the task row's meta
chips are a `Wrap` (chips flow to new lines), filter bars wrap per row,
screens are Column+Expanded or scrollable, and the priority selector
scrolls horizontally.

**Deeper:** The invariant is "no fixed heights around text" —
`SizedBox(height:)` only for spacing; content areas are `Expanded` (list
screens) or `SingleChildScrollView` (editors). `maxLines: 2` +
ellipsis on task titles is the one intentional clamp (title text is
bounded by design). The Material 3 theme's component sizing absorbs the
rest.

**Relevant files:** `lib/presentation/widgets/task_list_item.dart`,
`lib/presentation/widgets/task_filter_bar.dart`,
`docs/ACCESSIBILITY.md`

---

## K. Testing & quality (2 questions)

### 49. What is the testing strategy?

**Question:** How is the app tested?

**Simple:** Determinism first (injected `Clock`/`IdGenerator` — no
`DateTime.now()` in app logic), a memory-database override that swaps the
whole provider graph, a fake connectivity seam, `RemoteConditions` fault
injection, and categories: domain/unit, db/repository, state
(ProviderContainer), widget, sync/conflict, and one offline→online
integration flow. Plus `dart run tool/sync_smoke.dart` — an end-to-end
pipeline check that runs today.

**Deeper:** The design decisions are what make the suite cheap: the
engine is connectivity-free (no timers to control — it *returns*
backoff), the resolver is pure (the conflict matrix is data-in/data-
out), the database constructor takes a `QueryExecutor` (memory in tests),
and enums reject corrupt values loudly (malformed-response tests).
Widget tests wire the demo switch exactly like `main.dart` and stub
`platformConnectivityProvider` to stay off platform channels. Test counts
are reported as pending until the dedicated test agent's suite lands —
no fabrication.

**Relevant files:** `docs/TESTING.md`, `tool/sync_smoke.dart`,
`lib/presentation/providers/core_providers.dart`

### 50. How is determinism achieved, and why does it matter here?

**Question:** Why the injected Clock and IdGenerator?

**Simple:** Every timestamp and id flows through injected `Clock` /
`IdGenerator` providers — tests pin them. It matters because LWW
compares timestamps: non-deterministic time means non-reproducible
conflict outcomes.

**Deeper:** `typedef Clock = DateTime Function()` with `systemClock`
returning UTC (unambiguous comparisons); `TimeBasedIdGenerator` emits
`<micros base36>-<counter base36>` — collision-resistant across
processes/reboots *and* fully deterministic under a pinned clock. The
server takes the same clock (`MockSyncServer(clock: …)`), so client and
server time are one controllable timeline in tests — the smoke tool
advances time explicitly between scenarios (`advance(Duration(minutes:
1))`) to make "newer" unambiguous. Ids double as idempotency keys, so
id determinism also makes replay tests exact.

**Relevant files:** `lib/core/utils/clock.dart`,
`lib/core/utils/id_generator.dart`,
`lib/presentation/providers/core_providers.dart`, `tool/sync_smoke.dart`
