# Testing strategy

> **Status:** the test suite is being added by the dedicated test workstream
> (agent B-4) that follows this documentation pass. This document defines
> the strategy, the categories and the conventions the suite follows, so
> the tests land into a shaped structure rather than an ad-hoc pile. The
> `flutter test` gate in CI (`.github/workflows/flutter_ci.yml`) runs the
> full suite on every push and PR.
>
> One end-to-end check already exists and is runnable today:
> `dart run tool/sync_smoke.dart` (pure Dart, no Flutter bindings) — it
> wires the real database, repositories, engine, resolver and mock server
> and asserts the complete offline-first story in 7 scenarios.

## How to run

```bash
flutter test                      # everything
flutter test test/data/sync       # one category
flutter test --plain-name "..."   # one test by name
dart run tool/sync_smoke.dart     # pipeline smoke check (exit code != 0 on failure)
```

Gates that CI enforces on every push/PR: `dart format
--output=none --set-exit-if-changed .`, `flutter analyze`, `flutter test`.

## Why the app is testable at all (the design decisions)

The suite is cheap to write because the production code already paid for
it:

- **`databaseProvider` takes a `QueryExecutor`** —
  `AppDatabase(NativeDatabase.memory())` in tests, file via
  `path_provider` in the app. Generated Drift code is committed, so tests
  need no `build_runner` step.
- **`Clock` and `IdGenerator` are injected** (`core_providers.dart`) —
  the last-write-wins resolver compares timestamps, so determinism is a
  correctness requirement, not a nicety. No `DateTime.now()` or unseeded
  randomness exists in app logic (grep-able).
- **`ConnectivityService` is an abstract seam** — a fake subclass with a
  `StreamController<bool>` drives offline/online transitions; the demo
  wrapper (`demo_connectivity_provider.dart`) gives widget tests the
  Settings switch through the exact `main.dart` wiring.
- **`RemoteConditions` on the mock server** — timeouts, 5xx, malformed
  bodies, dropped connections and deterministic conflicts are toggled
  live, mid-test, on a real socket.
- **The engine is connectivity-free and framework-free** — no timers of
  its own to control; backoff delays are *returned* (`SyncOutcome
  .retryAfter`), the `SyncController` schedules them.
- **The conflict resolver is pure** — the whole LWW matrix is plain
  data-in/data-out unit tests.

## Categories (the B-4 suite lands in this shape)

### 1. Domain / unit (`test/domain/`, `test/core/`)

- `LastWriteWinsConflictResolver` — the exhaustive conflict matrix:
  newer local / newer server / exact-timestamp tie (smaller id wins;
  seeded server record ⇒ local wins) / local delete vs server update /
  server tombstone vs local edit.
- `AppConfig`/`SyncRetryPolicy.backoffFor` — 1s → 2s → 4s… capped at
  2 min; `isExhausted(5) == true`.
- `ErrorMapper` — every `DioExceptionType` → expected `AppException`;
  HTTP 401/409/5xx; nested `unknown` unwrapping to `NetworkException`;
  already-mapped exceptions pass through.
- Entities: `Project.fromJson`/`Task.fromJson` malformed shapes throw
  `FormatException` (missing keys, wrong types, unknown priority);
  sentinel-based `copyWith` clears nullable fields; `==`/`hashCode`
  contracts (the `TaskFilter` family depends on it).
- `TimeBasedIdGenerator` — unique under a pinned clock, deterministic
  sequence. `Debouncer` — fires after 350 ms of silence, reschedules on
  new events, `cancel()` suppresses.
- `deriveSyncStatus` — failed beats syncing beats pending beats synced.

### 2. Database / repository (`test/data/`, `test/data/db/`)

Drift on `NativeDatabase.memory()` (optionally
`NativeDatabase.memory(logStatements: true)` while debugging). Close the
database in `tearDown`.

- `TasksDao.watchTasks` — the full filter contract in one query:
  per-project, completion slices, priority, due-before, case-insensitive
  LIKE search, and the ORDER BY contract (incomplete first, due date
  nulls last, urgent priority first, title NOCASE). SQL bind order (the
  `maxAttempts` placeholder precedes the WHERE placeholder — a real bug
  fixed in commit bf05a2e) is regression-covered here.
- Status subqueries: enqueue a mutation → `watchTask` emits
  `SyncStatus.pending`; `markSyncing` → `syncing`; `attempts >=
  maxAttempts` → `failed`; dequeue → `synced`.
- `SyncQueueDao` — FIFO `nextBatch` ordering; starvation guard
  (exhausted entries excluded); `enqueueMutation` idempotency;
  `resetFailures`; `watchCount` reactivity; `hasPendingFor`.
- Repositories — the atomicity contract: every mutation writes row +
  queue entry in one transaction (assert both or neither by injecting a
  failing queue write); version/updatedAt bumps; delete → tombstone +
  queued delete mutation; project delete → cascade tombstones every child
  with one mutation each; unknown-id deletes are no-ops; errors leaving
  the repository are `AppException`s (`guardRepository` /
  `guardRepositoryStream` — including asynchronous stream errors).

### 3. State (`test/presentation/providers/` with `ProviderContainer`)

- `SyncController` — the connectivity state machine: offline →
  `SyncOffline`; online transition triggers a drain; round coalescing
  (`_busy` + follow-up: burst of `syncNow()` = one round + one
  follow-up); failure → `SyncFailed(userMessage)` and retry scheduling
  from `outcome.retryAfter`; `null` backoff stops the timer (exhausted
  mutations wait for `retryFailed()`).
- `SyncBannerController` — the banner mapping table (idle + queue > 0 →
  pending; transition into idle from syncing/failed/pending → `synced`
  with 3 s auto-dismiss — use `fakeAsync`/`pump` with an advanced clock).
- `TaskEditorController` — validation gates save; create vs update paths;
  `AppException` → `submissionError`; `toggleCompleted` re-reads the row
  (rapid taps converge).
- `TaskFilterController` — debounced search commits after 350 ms and only
  when the text actually changed (`fakeAsync`); `setSearch` commits
  immediately; `clear()` resets everything.
- `effectiveTaskFilterProvider` / `dueWindowCutoff` — pure function
  (window → millis bound) with a pinned clock.

### 4. Widget (`test/presentation/`)

`ProviderScope` with overrides (below) around real screens:

- `ProjectsScreen` / `TasksScreen` — loading skeleton, empty state, error
  state (`ErrorView` + retry), list rendering, per-record sync badge
  presence; the FAB guides project creation when none exist.
- `TaskEditorScreen` — title validation error (`errorText`), project
  dropdown validation, save success/error paths, delete confirmation
  dialog copy (mentions the queued/offline-safe delete).
- `SyncStatusBanner` — all banner kinds render the right message and
  buttons delegate to the controller.
- Semantics assertions — the checkbox's state-following label
  ("Mark task 'X' as complete/not complete"), `liveRegion` on
  banners/errors, `ExcludeSemantics` skeleton rows with an overall
  "Loading" label.

### 5. Sync / conflict integration (`test/data/sync/`)

Real `MockSyncServer` + real `SyncApiClient` (real Dio, real socket),
memory database, pinned clock — i.e. the `tool/sync_smoke.dart` scenarios
as repeatable tests, plus:

- push applies / conflicts / rejects, per-result handling;
- conflict local-wins → corrected mutation re-based onto the server's
  version (next push applies cleanly, queue drains, no data loss);
- conflict server-wins → server record applied locally, mutation dropped;
- pull guard: pending local edits survive a newer server record;
- cursor persistence: rewind `sync_meta.lastPullAt` → replay is
  idempotent;
- fault injection per `RemoteConditions`: `forceStatusNext(503)` →
  `ServerException` + `markAttempted`; `malformedNext` →
  `MalformedResponseException`; `dropConnection` → `NetworkException`;
  `conflictOnProjectId` → deterministic conflict;
- idempotency: replaying the same `mutationId` answers `applied
  (duplicate)` without re-applying.

### 6. Offline → online flow (the spec's integration requirement)

The full user-level story through the real widget tree or the real
providers:

1. fake connectivity offline (or the demo switch) → create project +
   tasks → rows visible immediately, `queueBadgeProvider` > 0, banner
   shows offline;
2. attempts recorded with diagnostics while offline (backoff scheduled);
3. connectivity restored → queue drains automatically, banner passes
   through syncing → synced (auto-dismiss), statuses flip to `synced`,
   queue badge → 0;
4. the server dataset contains every record (assert on
   `server.projects` / `server.tasks`).

## Conventions

- **Determinism first**: every test that touches timestamps or ids
  overrides `clockProvider`/`idGeneratorProvider` (or constructs
  implementations directly with a pinned clock). No `Future.delayed`
  sleeps to "wait for sync" — poll a condition like the smoke tool's
  `until()` helper, or await provider streams.
- **Dio delivers via zone timers** — when pumping real network calls in
  widget tests, settle with pump + a short real delay + pump (the
  pattern proven in the sibling CareRoute project), because the socket
  events land in timers Dio schedules.
- **Databases and servers are closed in `tearDown`** — leak-free
  `ProviderContainer`s via `addTearDown(container.dispose)`.
- **No secrets, no network beyond 127.0.0.1** — the suite is hermetic.
- Assertions live at the level where the bug would be: DAO SQL in db
  tests, state transitions in provider tests, rendered semantics in
  widget tests.
