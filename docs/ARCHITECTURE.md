# Architecture

OfflineBoard uses a **layered architecture** with a strict dependency
direction: `presentation → application/state → domain ← data`. The domain
layer defines *what* the app does; the data layer owns SQLite, the sync
protocol and the conflict engine; presentation and the Riverpod provider
graph decide *how* it is surfaced. Everything below references real files —
open any of them and the code matches.

```
┌───────────────────────────────────────────────────────────────────┐
│ presentation/                                                     │
│   screens/     projects/, tasks/, settings/, home_shell           │
│   widgets/     task_list_item, sync_status_banner, skeletons, …   │
│   providers/   Riverpod state + DI composition root (16 files)    │
│   routes/      app_router.dart (GoRouter)                         │
└──────────────┬────────────────────────────────────────────────────┘
               │ watches providers; forwards user intent to controllers
               │ (screens never import Dio, Drift, or JSON)
┌──────────────▼───────────────────────────────────────┐
│ domain/  — pure Dart, imports nothing above it       │
│   entities/      Project, Task, MutationRecord,      │
│                  TaskFilter, SyncStatus/… enums,     │
│                  ServerRecordSnapshot                 │
│   repositories/  TaskRepository, ProjectRepository   │
│                  (abstract interfaces)               │
│   sync/          SyncEngine, ConflictResolver        │
│                  (abstract interfaces)               │
└───────────────────────▲──────────────────────────────┘
                        │ implements
┌───────────────────────┴──────────────────────────────┐
│ data/                                                │
│   db/           AppDatabase + ProjectsDao/TasksDao/ │
│                 SyncQueueDao (Drift, SQLite)         │
│   remote/       SyncApiClient (Dio), MockSyncServer │
│                 (real HttpServer), sync_wire_types  │
│   sync/         SyncEngineImpl,                     │
│                 LastWriteWinsConflictResolver       │
│   repositories/ TaskRepositoryImpl,                 │
│                 ProjectRepositoryImpl (local-first) │
│   mappers/      entity_mappers.dart                 │
└──────────────┬──────────────────────────────────────┘
               │ SQLite file / HTTP on 127.0.0.1
┌──────────────▼──────────────────────────────────────┐
│ core/  — cross-cutting, imported by everyone       │
│   config/     AppConfig + SyncRetryPolicy          │
│   errors/     AppException (sealed) + ErrorMapper  │
│   theme/      AppTheme (Material 3 seed)           │
│   utils/      Clock, IdGenerator, Debouncer,       │
│               Validators, AppFormatters             │
└─────────────────────────────────────────────────────┘
```

## The dependency rule

- `lib/domain/` imports **nothing** from `data/` or `presentation/`. The
  entities (`lib/domain/entities/*.dart`) are plain immutable Dart classes
  with hand-written `toJson`/`fromJson` that doubles as the sync wire
  format — no code generation, no Flutter imports.
- `lib/data/` implements the domain interfaces. It knows Drift, SQLite,
  Dio and HTTP — and nothing about widgets or Riverpod. The engine
  (`SyncEngineImpl`) is even *connectivity-free*: it never asks whether the
  device is online; it just reports what happened and when a retry would
  be sensible.
- `lib/presentation/` watches Riverpod providers and renders. Screens
  import domain entities only; no screen imports `dio`, `drift` or the
  database.
- `lib/core/` is the shared foundation (errors, config, time, ids, theme).
  It is imported by all layers and imports nothing above itself.

**Consequence:** the repository seam is the only place transport and
storage details exist. Swapping the in-process `MockSyncServer` for a real
backend means changing `lib/presentation/providers/sync_engine_provider.dart`
(the composition root) and nothing in domain or presentation.

## Layer contents

### `core/` — cross-cutting infrastructure

| File | Role |
| --- | --- |
| `config/app_config.dart` | `AppConfig` (timeouts, `pushBatchSize = 32`, `baseUrl`) + `SyncRetryPolicy` (1s initial, ×2 multiplier, 2 min cap, `maxAttempts = 5`) |
| `errors/app_exception.dart` | sealed error taxonomy: `NetworkException`, `TimeoutException`, `UnauthorizedException`, `ServerException`, `MalformedResponseException`, `ConflictException`, `CancelledException`, `DatabaseException`, `UnknownException` — each with a user-safe `userMessage` |
| `errors/error_mapper.dart` | the *only* place Dio/HTTP/parse errors become `AppException`s (see error flow below) |
| `utils/clock.dart` | `typedef Clock = DateTime Function()` + `systemClock` — every timestamp in the app flows through an injected `Clock` |
| `utils/id_generator.dart` | `TimeBasedIdGenerator` — `<micros-since-epoch in base36>-<counter in base36>`, collision-resistant and deterministic under a pinned clock |
| `utils/debouncer.dart` | framework-free 350 ms debouncer used by the search field |
| `utils/validators.dart` | `Validators.taskTitle` / `projectName` (non-empty, ≤120 chars), date format checks |
| `utils/formatters.dart` | `AppFormatters` — UTC-millis → local date text at the presentation boundary only |
| `theme/app_theme.dart` | Material 3 light + dark from one deep-green seed |

### `domain/` — entities + contracts

Entities: `Project`, `Task` (both carry `updatedAt`, `version`,
`isDeleted` tombstone flag and a derived, never-persisted `syncStatus`),
`MutationRecord` (one queued mutation), `TaskFilter` (one immutable value
that doubles as the repository query *and* the Riverpod family argument),
`ServerRecordSnapshot` (the other party of a conflict decision), plus the
enums `SyncStatus`, `MutationType`, `EntityType`, `TaskPriority`,
`TaskCompletionFilter`, `ConflictResolution`.

Interfaces: `TaskRepository`, `ProjectRepository`
(`lib/domain/repositories/`), `SyncEngine`, `ConflictResolver`
(`lib/domain/sync/`). `lib/domain/sync/sync_engine.dart` also defines the
outcome types `SyncOutcome` and `PullOutcome` — the engine's report card.

### `data/` — implementations

- **`db/app_database.dart`** — the Drift database: tables `Projects`,
  `Tasks`, `PendingMutations`, `SyncMeta`; DAOs `ProjectsDao`, `TasksDao`,
  `SyncQueueDao`; `schemaVersion = 1`; four indexes created in
  `MigrationStrategy.onCreate`; `PRAGMA foreign_keys = ON` in
  `beforeOpen`. The generated file `app_database.g.dart` is committed, so
  CI needs no `build_runner`. The constructor takes a `QueryExecutor` —
  the app opens a file via `path_provider`, tests use
  `NativeDatabase.memory()`.
- **`remote/mock_sync_server.dart`** — the simulated backend: a real
  `HttpServer` bound to 127.0.0.1 (ephemeral port) holding the server-side
  dataset in memory, plus the `RemoteConditions` fault-injection knobs
  (latency, forced status codes, malformed bodies, dropped connections,
  deterministic conflict injection). See [API.md](API.md).
- **`remote/sync_api_client.dart`** — thin Dio client for
  `GET /sync/pull` and `POST /sync/push`; applies `AppConfig` timeouts and
  maps every failure to `AppException`.
- **`remote/sync_wire_types.dart`** — the wire DTOs (`PushMutation`,
  `PushResultItem`, `PushItemStatus`, `PullResponse`) shared by client and
  server, so the protocol contract lives in one reviewable file.
- **`sync/sync_engine_impl.dart`** — the offline-first engine: batched
  push with per-result handling, pull with a never-overwrite-pending
  guard, conflict application in Drift transactions. See
  [OFFLINE_SYNC.md](OFFLINE_SYNC.md).
- **`sync/conflict_resolver.dart`** — `LastWriteWinsConflictResolver`: a
  *pure* class (no db/clock/network) implementing the LWW rules.
- **`repositories/task_repository_impl.dart` &
  `project_repository_impl.dart`** — local-first repositories: every
  mutation = row write + queue entry in ONE Drift transaction, then an
  `unawaited` sync trigger. Reads are watch streams. Errors crossing the
  boundary are always `AppException`s (via `repository_support.dart`).
- **`mappers/entity_mappers.dart`** — Drift rows ↔ domain entities, incl.
  `deriveSyncStatus` (the queue subquery counts → `SyncStatus` rule) and
  enum index ↔ enum conversions with corrupt-value rejection.

### `presentation/` — state + UI

- **`providers/`** — 16 files: the composition root
  (`database_provider`, `sync_engine_provider`, `repositories_provider`,
  `core_providers`), lifecycle controllers (`sync_controller`,
  `sync_banner_provider`, `demo_connectivity_provider`,
  `connectivity_provider`), list/editor/filter state
  (`task_list_provider`, `project_list_provider`, `task_editor_provider`,
  `project_editor_provider`, `task_filters_provider`,
  `due_window_provider`), and derived presentation state
  (`project_stats_provider`, `entity_by_id_providers`,
  `queue_badge_provider`). Full table in
  [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md).
- **`routes/app_router.dart`** — one `GoRouter` (below).
- **`screens/`** — `projects_screen`, `project_detail_screen`,
  `project_editor_dialog`, `tasks_screen`, `task_editor_screen`,
  `settings_screen`, `home_shell`. Screens stay "dumb": they map provider
  state to widgets and forward user intent to controllers.
- **`widgets/`** — `task_list_item`, `task_filter_bar`, `sync_status_banner`,
  `status_icon`, `priority_chip`, `due_date_chip`, `skeleton`,
  `empty_view`, `error_view`, `confirm_delete_dialog`.

## How Drift fits

Drift is the **local source of truth**, not a cache. Three design points:

1. **Reactivity instead of polling.** Every read path is a `watch*`
   stream (`TasksDao.watchTasks`, `watchTask`, `watchUnsyncedTasks`,
   `ProjectsDao.watchProjects`, `watchProject`,
   `SyncQueueDao.watchCount`). Drift re-runs the SELECT whenever a table
   the query `readsFrom` changes — the UI updates because the database
   says so, with no manual refresh anywhere.
2. **Status is derived, not stored.** The watch queries join the sync
   queue via correlated subqueries (`queueCount`, `syncingCount`,
   `failedCount`) so each row's `SyncStatus` is computed in the same
   consistent snapshot as the row itself. `syncStatus` is never written to
   a table — it cannot drift out of date.
3. **Transactions for atomic local writes.** Row + queue entry commit
   together or not at all (`TaskRepositoryImpl.createTask`, `_applyEdit`,
   `deleteTask`; the whole cascade in `ProjectRepositoryImpl.deleteProject`).
   That atomicity is what makes "works offline" trivially true.

DAO queries are hand-written SQL through `customSelect` (parameterized,
all user input travels as bound `Variable`s) because the status subqueries
and the single-query filter contract are clearer in SQL than in the Dart
query builder. Pure typed access (`select(tasks)..where(...)`) is used
where it reads better (`getTaskById`, `nextBatch`, `watchCount`).

## How the sync engine stays pure and testable

`SyncEngineImpl` is the heart of the app and it is deliberately boring to
test:

- **No `DateTime.now()`** — every timestamp comes from the injected
  `Clock`. LWW compares timestamps, so determinism is not optional.
- **No id minting inline** — ids come from the injected `IdGenerator`.
- **No connectivity checks** — `SyncEngine` never asks "am I online?".
  The `SyncController` (app layer) owns connectivity, timers and backoff
  scheduling; the engine just reports `SyncOutcome.retryAfter`.
- **No widgets, no Riverpod** — it depends on `AppDatabase`,
  `SyncApiClient`, `ConflictResolver`, `Clock`, `AppConfig`,
  `IdGenerator`, all injected via the constructor. `tool/sync_smoke.dart`
  wires the whole pipeline by hand in ~100 lines.
- **The conflict resolver is pure** — `LastWriteWinsConflictResolver` is
  a const, stateless class over two immutable inputs, so the entire
  conflict matrix is exhaustively unit-testable.

## Error flow (AppException mapping)

One promise: **raw exceptions never reach the UI.** The pipeline:

```
DioException / FormatException / TypeError / SocketException
        │
        ▼  ErrorMapper.map()  (lib/core/errors/error_mapper.dart)
   DioExceptionType.connectionError ───► NetworkException   "You appear to be offline. Changes are saved locally…"
   *.timeout (connect/send/receive)  ───► TimeoutException  "The sync server is taking too long…"
   badResponse 401/409/other         ───► Unauthorized/Conflict/ServerException
   unknown (unwrapped nested cause)   ───► Network/Timeout/Malformed/Unknown
   FormatException / TypeError        ───► MalformedResponseException
   SocketException / HttpException    ───► NetworkException
        │
        ▼  SyncApiClient / SyncEngineImpl / repositories (guardRepository*)
   AppException (sealed, user-safe userMessage)
        │
        ▼  controllers (sync_controller, task_editor_provider, …)
   SyncFailed(message) / TaskEditorState.submissionError
        │
        ▼  widgets
   SyncStatusBanner (liveRegion) / ErrorView / errorText on form fields
```

Repository-side, `lib/data/repositories/repository_support.dart` provides
`guardRepository` (maps thrown raw errors to `DatabaseException`) and
`guardRepositoryStream` (maps async stream errors) — the same guarantee
for watch streams. The `SyncController` additionally wraps its rounds in a
final `on Object` catch so even an engine bug surfaces as
`SyncFailed('Something went wrong while syncing.')`.

Because `AppException` is a `sealed class`, every subtype is accounted for
wherever it is switched on — adding a new error type is a compile error
until it is handled.

## Routing structure

`lib/presentation/routes/app_router.dart` — one `GoRouter` exposed as
`appRouterProvider` (so `app.dart` just does
`routerConfig: ref.watch(appRouterProvider)`).

| Route | Navigator | Screen |
| --- | --- | --- |
| `/` | shell branch 0 | `ProjectsScreen` |
| `/tasks` | shell branch 1 | `TasksScreen` |
| `/settings` | shell branch 2 | `SettingsScreen` |
| `/project/:id` | root | `ProjectDetailScreen(projectId:)` |
| `/tasks/new?project=:id` | root | `TaskEditorScreen(projectId:)` |
| `/tasks/:id/edit` | root | `TaskEditorScreen(taskId:, initialTask: extra)` |

- The three tabs live in a `StatefulShellRoute.indexedStack` → each branch
  keeps its scroll position and filter state while the user switches tabs
  (`HomeShell` renders the `NavigationBar` and the global
  `SyncStatusBanner` pinned above the content).
- Detail/editor pages use `parentNavigatorKey: _rootNavigatorKey` so they
  cover the bottom bar — a full-page editor, never a sheet.
- There is **no auth gate** — OfflineBoard is local-first, every route is
  reachable immediately.
- The task editor takes an optional `Task` snapshot via `state.extra` and
  falls back to `taskByIdProvider` (deep links, state restoration) — so
  cold-entry to `/tasks/:id/edit` still works.

## Why not more abstraction?

No use-cases layer, no `Result<T>` wrapper, no interfaces for mappers. The
seams that matter are already seams: repository interfaces (domain ← data),
`SyncEngine`/`ConflictResolver` interfaces (engine swappable and stubbable),
`Clock`/`IdGenerator` (determinism), `ConnectivityService` (platform
swapped for a demo wrapper or a test fake in one provider override). More
layers would add ceremony without changing a single behavior.
