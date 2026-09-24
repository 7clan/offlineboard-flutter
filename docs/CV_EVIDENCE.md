# CV evidence — verified claims only

Every claim below is backed by a real file in this repository. Anything
not yet verified is marked **pending** — nothing here is fabricated.
Reviewer instructions in brackets point at the evidence.

## Verified technologies

| Technology | Evidence |
| --- | --- |
| Flutter / Material 3 | `lib/app.dart`, `lib/core/theme/app_theme.dart` (light+dark from one seed; component themes) |
| Dart 3 (sealed classes, records, pattern matching) | `sealed class AppException` (`lib/core/errors/app_exception.dart`), sealed `SyncState` (`lib/presentation/providers/sync_controller.dart`), record types `({int count, int code})` (`RemoteConditions`, `lib/data/remote/mock_sync_server.dart`), switch pattern matching throughout the DAOs/engine |
| Riverpod 3 | 16 provider files in `lib/presentation/providers/`: `NotifierProvider`, `StreamProvider`, `StreamProvider.family`, `FutureProvider`, `Provider`, `select`, provider overrides (`databaseProvider.overrideWith` docs) |
| GoRouter 16 | `lib/presentation/routes/app_router.dart` — `StatefulShellRoute.indexedStack` with 3 branches, root-navigator detail routes, route `extra` snapshot passing |
| Drift 2 / SQLite | `lib/data/db/app_database.dart` + committed generated `app_database.g.dart`; 4 tables, 3 DAOs, custom SQL with `customSelect`, watch streams, transactions, migration strategy with 4 indexes |
| Dio 5 | `lib/data/remote/sync_api_client.dart` — timeouts from `AppConfig`, typed error translation; `lib/core/errors/error_mapper.dart` for the full `DioExceptionType` mapping |
| connectivity_plus 7 | `lib/presentation/providers/connectivity_provider.dart` behind the `ConnectivityService` seam + `demo_connectivity_provider.dart` wrapper |
| Test tooling | `mocktail`, `drift_dev`/`build_runner` in `pubspec.yaml` dev dependencies; `tool/sync_smoke.dart` pure-Dart harness |

## Verified features

- **Offline-first CRUD** — local SQLite is the source of truth: every
  mutation = row + queue entry in ONE transaction (`lib/data/repositories/
  task_repository_impl.dart`, `project_repository_impl.dart`), reads are
  watch streams; the app is fully usable offline (demo switch:
  `lib/presentation/providers/demo_connectivity_provider.dart`).
- **Durable sync queue** — `pending_mutations` table survives restarts;
  crash recovery via `clearSyncingFlags()` on every push
  (`lib/data/sync/sync_engine_impl.dart`).
- **Retry/backoff with starvation guard** — FIFO batches of 32,
  exponential backoff 1s→×2→2min cap, `maxAttempts = 5` →
  `SyncStatus.failed` + manual retry (`lib/core/config/app_config.dart`,
  `SyncQueueDao.nextBatch` where-clause, `resetFailures`).
- **LWW conflict resolution** — timestamp comparison with deterministic
  id tiebreak, delete tombstones, idempotency keys, corrected-mutation
  re-arm for convergence (`lib/data/sync/conflict_resolver.dart`,
  `SyncEngineImpl._resolveTaskConflict`).
- **Pull guard** — pending local edits are never overwritten
  (`hasPendingFor` + strictly-newer comparison in `_pullSince`).
- **Search & filtering** — debounced 350 ms search; completion, priority,
  due-window chips; one parameterized SQL query
  (`TasksDao.watchTasks`, `lib/core/utils/debouncer.dart`).
- **Visible sync pipeline** — global banner state machine
  (offline/pending/syncing/failed/synced with 3 s auto-dismiss), queue
  count in Settings, per-record status badges derived in SQL
  (`lib/presentation/providers/sync_banner_provider.dart`,
  `lib/presentation/widgets/status_icon.dart`).
- **Project delete cascade** — one transaction tombstones project + all
  child tasks, each with its own queued delete mutation
  (`ProjectRepositoryImpl.deleteProject`).

## Verified architecture

- 4 layers with strict dependency direction (presentation → domain ←
  data; domain imports nothing above it) — `docs/ARCHITECTURE.md` +
  the import graphs of `lib/domain/**` (no Flutter/package imports
  beyond pure Dart).
- Sealed error taxonomy with a single mapper; raw exceptions cannot
  reach the UI (`lib/core/errors/`, `repository_support.dart`).
- Full determinism: no `DateTime.now()` or unseeded randomness in app
  logic — injected `Clock`/`IdGenerator`
  (`lib/core/utils/clock.dart`, `id_generator.dart`).
- Deterministic in-process backend: real `HttpServer` with fault
  injection (`RemoteConditions`: latency, forced status, malformed
  bodies, dropped connections, conflict injection).

## Tests

- **Pending (test agent B-4):** the `flutter test` suite lands next in
  the categories defined in `docs/TESTING.md` (domain/unit,
  db/repository, state, widget, sync/conflict, offline→online
  integration). Counts will be filled in when the suite lands — the CI
  workflow already gates on `flutter test`.
- **Verified today:** `dart run tool/sync_smoke.dart` — end-to-end sync
  pipeline check over the real database + engine + server: 7 scenarios
  (offline creation, reconnect drain, pull idempotency + cursor rewind,
  pull guard, local-wins conflict, server-wins conflict, cascade
  delete), deterministic clock, non-zero exit on failure.
- **Verified static quality:** `flutter analyze` → 0 issues across 68
  lib files; `dart format` clean (enforced in CI).

## Accessibility (verified)

- 48×48 dp completion-checkbox target with state-following
  `Semantics(label/checked/button)` and `ExcludeSemantics` dedup
  (`lib/presentation/widgets/task_list_item.dart`).
- `Semantics(liveRegion:)` on the sync banner, editor submission errors
  and error views (announced state changes).
- Form errors via `errorText` (announced + field-associated);
  tooltips on icon-only buttons; labeled status icons and progress
  indicators.
- 2.0× text scale safety: `Wrap` rows, `Expanded`/scroll containers, no
  fixed heights on text (`docs/ACCESSIBILITY.md`).

## Performance (verified)

- Drift watch streams instead of polling; 4 indexes covering the real
  access paths incl. the per-record status subqueries; one parameterized
  query for the whole filter contract; `ListView.builder` /
  `SliverList.builder`; `const` widget usage; `select()` rebuild
  scoping; single all-tasks stream feeding per-project stats; 350 ms
  debounced search; fire-and-forget sync; background isolate database
  (`docs/PERFORMANCE.md` + the cited files).

## Release / build

- **Pending verification:** universal 3-ABI APK + AAB builds run after
  this docs pass; actual outputs will be appended to
  `docs/RELEASE.md`'s "Build verification log". The documented command
  is `flutter build apk --release --target-platform
  android-arm,android-arm64,android-x64` (universal artifact — NOT
  arm64-only, NOT `--split-per-abi`).
- CI: `.github/workflows/flutter_ci.yml` — format gate + analyze + test
  on push/PR against `main`, Flutter 3.47.5 pinned.

## Known limitations (state these honestly)

- The sync "server" is the in-process deterministic mock — a real
  backend swap is a provider-wiring change
  (`sync_engine_provider.dart`), but no production API exists.
- iOS is scaffolded but NOT verified (Linux environment; requires
  macOS/Xcode/signing) — see `docs/RELEASE.md`.
- Release artifacts in this environment are debug-signed (no upload
  keystore); Play Store upload requires keystore configuration
  documented in `docs/RELEASE.md`.
- The `flutter test` suite is landing in the next workstream; until
  then only the smoke tool + static gates are verified.
- Multi-user/multi-device concurrent editing is *simulated* via
  `RemoteConditions.conflictOnProjectId` and the smoke tool's direct
  server mutations, not by running two clients.

## CV bullets (pick 3–6)

- Built an offline-first Flutter task manager (Drift/SQLite, Riverpod 3,
  Dio, GoRouter) where local SQLite is the source of truth: every write
  commits its record and sync-queue entry in one transaction, so the app
  is fully usable with no connection.
- Implemented a durable sync queue with FIFO batching, exponential
  backoff, a starvation guard, and a failed-state/manual-retry path —
  mutations are never silently dropped, and crash recovery is automatic
  on the next push.
- Designed and implemented last-write-wins conflict resolution with
  deterministic tiebreaks, delete tombstones, idempotency keys and a
  re-based-mutation convergence step that never loses local edits; made
  the whole conflict matrix deterministic via injected clocks and id
  generators.
- Kept the UI reactive with Drift watch streams (no polling) and derived
  per-record sync status in SQL via correlated subqueries — status can
  never drift out of date because it is never stored.
- Enforced a strict `presentation → domain ← data` architecture with a
  sealed error taxonomy and a single Dio→domain exception mapper, so raw
  exceptions cannot reach the UI.
- Shipped a fault-injectable in-process sync server (real HTTP server
  with latency/5xx/malformed/dropped-connection/conflict knobs) plus an
  end-to-end smoke harness that proves the offline story: create
  offline → queue → reconnect → drain → conflict convergence in both
  directions.
