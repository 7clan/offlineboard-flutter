# State management (Riverpod)

OfflineBoard uses **Riverpod 3** as both the DI container and the state
solution. All 16 provider files live in `lib/presentation/providers/` —
that is the application/state layer of the architecture. Screens are
"dumb": they watch providers and forward user intent to notifiers.

Every provider below is real code — file, type, what it watches, and how
rebuilds are scoped.

## Provider inventory

### Composition root (infrastructure)

| Provider | File | Type | Provides / watches |
| --- | --- | --- | --- |
| `appConfigProvider` | `core_providers.dart` | `Provider<AppConfig>` | const `AppConfig` — timeouts, batch size, retry policy. Override in tests to tighten backoff. |
| `clockProvider` | `core_providers.dart` | `Provider<Clock>` | `systemClock` (real UTC). **Override with a pinned clock for determinism.** |
| `idGeneratorProvider` | `core_providers.dart` | `Provider<IdGenerator>` | `TimeBasedIdGenerator(clock: ref.watch(clockProvider)).next` — the instance (and its counter) is owned by the provider, ids stay unique per app lifetime. |
| `databaseProvider` | `database_provider.dart` | `Provider<AppDatabase>` | Drift database on a `LazyDatabase` → `NativeDatabase.createInBackground(file)` in the app documents dir; **tests override with `AppDatabase(NativeDatabase.memory())`** and the whole graph inherits the swap. `ref.onDispose` closes it. |
| `conflictResolverProvider` | `sync_engine_provider.dart` | `Provider<ConflictResolver>` | `const LastWriteWinsConflictResolver()` — stateless; tests may stub it to force verdicts. |
| `syncServerProvider` | `sync_engine_provider.dart` | `FutureProvider<MockSyncServer>` | binds the in-process HTTP server; ephemeral port known only after `start()` — hence a Future. Disposed via `server.close()`. |
| `syncApiClientProvider` | `sync_engine_provider.dart` | `FutureProvider<SyncApiClient>` | Dio client pointed at `server.baseUrl` with `AppConfig` timeouts. |
| `syncEngineProvider` | `sync_engine_provider.dart` | `FutureProvider<SyncEngine>` | `SyncEngineImpl(db, client, resolver, clock, config, idGenerator)` — watches everything above. |
| `projectRepositoryProvider` | `repositories_provider.dart` | `Provider<ProjectRepository>` | `ProjectRepositoryImpl` with `syncTrigger: () => ref.read(syncControllerProvider.notifier).syncNow()` — the fire-and-forget bridge from committed mutations to sync rounds. |
| `taskRepositoryProvider` | `repositories_provider.dart` | `Provider<TaskRepository>` | `TaskRepositoryImpl`, same wiring. |
| `connectivityServiceProvider` | `connectivity_provider.dart` | `Provider<ConnectivityService>` | production: `ConnectivityPlusService` on `connectivity_plus`; **in `main.dart` it is overridden with `ref.watch(demoConnectivityProvider)`** — the demo wrapper. This is the seam tests override with a fake. |
| `platformConnectivityProvider` | `demo_connectivity_provider.dart` | `Provider<ConnectivityService>` | the raw platform service behind the wrapper — the seam tests stub to stay off platform channels while still exercising the demo switch. |
| `demoConnectivityProvider` | `demo_connectivity_provider.dart` | `Provider<DemoConnectivityService>` | wraps `platformConnectivityProvider`; `isForcedOffline` toggled by the Settings switch without rebuilding any provider. |

### Sync lifecycle

| Provider | File | Type | Provides / watches |
| --- | --- | --- | --- |
| `syncControllerProvider` | `sync_controller.dart` | `NotifierProvider<SyncController, SyncState>` | the app-level sync lifecycle. State is the sealed family `SyncIdle` / `SyncSyncing(queuedCount)` / `SyncFailed(message)` / `SyncOffline`. Watches `syncEngineProvider` (boots the first round when the engine materializes) and `connectivityServiceProvider`. |
| `queueBadgeProvider` | `queue_badge_provider.dart` | `StreamProvider<int>` | `databaseProvider.syncQueueDao.watchCount()` — live queue size (pending + syncing + failed). |
| `syncBannerProvider` | `sync_banner_provider.dart` | `NotifierProvider<SyncBannerController, SyncBannerState>` | pure presentation state: watches `syncControllerProvider` + `queueBadgeProvider`, maps to `SyncBannerKind.hidden/offline/pending/syncing/failed/synced`, auto-dismisses `synced` after 3 s. |

### Lists, editors, filters

| Provider | File | Type | Provides / watches |
| --- | --- | --- | --- |
| `projectListProvider` | `project_list_provider.dart` | `StreamProvider<List<Project>>` | `projectRepositoryProvider.watchProjects()` — live, with derived per-record sync status. |
| `taskListProvider` | `task_list_provider.dart` | `StreamProvider.family<List<Task>, TaskFilter>` | the live task list for **any** filter. The family argument is immutable with proper `==`/`hashCode`, so Riverpod caches one stream per distinct filter and disposes it when the filter changes. |
| `taskFilterStateProvider` | `task_filters_provider.dart` | `NotifierProvider<TaskFilterController, TaskFilterState>` | the filter bar: search (debounced), completion, priority, project dimension. `TaskFilterState` is one immutable value. |
| `activeTaskFilterProvider` | `task_filters_provider.dart` | `Provider<TaskFilter>` | derives the domain filter from the state — feeds `taskListProvider`. |
| `dueWindowProvider` | `due_window_provider.dart` | `NotifierProvider<DueWindowController, DueWindow>` | the due-window chip row (`any/today/thisWeek/overdue`); `clearAll()` also resets the shared filter state. |
| `effectiveTaskFilterProvider` | `due_window_provider.dart` | `Provider<TaskFilter>` | shared filter state + due window mapped onto `dueBefore` via the injected clock. The tasks screen *and* every project detail page watch this (pinning the project dimension with `copyWith`), so both surfaces share one filter bar. |
| `taskEditorProvider` | `task_editor_provider.dart` | `NotifierProvider<TaskEditorController, TaskEditorState>` | the global task editor form (create/edit). |
| `projectEditorProvider` | `project_editor_provider.dart` | `NotifierProvider<ProjectEditorController, ProjectEditorState>` | the project editor form. |
| `projectStatsProvider` | `project_stats_provider.dart` | `Provider<Map<String, ProjectStats>>` | per-project total/completed derived from **one** watch of all tasks (`taskListProvider(TaskFilter.all)`) — project cards and detail headers update together with no extra database streams. |
| `projectByIdProvider` | `entity_by_id_providers.dart` | `StreamProvider.family<Project?, String>` | single live project; `null` = unknown id; tombstones included so the detail page can show its "deleted" state. |
| `taskByIdProvider` | `entity_by_id_providers.dart` | `StreamProvider.family<Task?, String>` | single live task — the editor's source when opened without a snapshot (deep links). |
| `simulateOfflineProvider` | `demo_connectivity_provider.dart` | `NotifierProvider<SimulateOfflineController, bool>` | the Settings switch state; pokes the wrapper directly (no provider rebuild). |

## StreamProvider over Drift watch queries

The read model is "stream all the way down":

```
Drift watch (customSelect(...).watch(), readsFrom: {tasks, pendingMutations})
   → repository watchTasks() wrapped in guardRepositoryStream (AppException mapping)
      → taskListProvider (StreamProvider.family)
         → screen: tasksAsync.when(loading: skeleton, error: ErrorView, data: list)
```

- `AsyncValue.when` gives the three UI states for free; the first frame
  shows `ListSkeleton`, then the stream's first emission lands.
- There is **no manual refresh anywhere**: a mutation writes the row +
  queue in a transaction, Drift re-runs the SELECT, the stream re-emits,
  the list and the sync badges update — one causal chain.
- The `family` argument doubles as the SQL WHERE clause
  (`TaskFilter.toTaskFilter` → one parameterized query), so filter state
  and query are literally the same immutable object.

## Notifier state classes (the details that matter)

- **Sentinel-based copyWith.** `TaskEditorState`, `TaskFilterState`,
  `ProjectEditorState` and `TaskFilter` all use the canonical Dart pattern
  for nullable-copyWith semantics: `Object? dueDate = _unset` +
  `identical(value, _unset)` — otherwise `copyWith(dueDate: null)` could
  never *clear* a due date. (This exact bug class was caught in the
  sibling project's backend conditions; it is why the pattern is applied
  uniformly here.)
- **Value equality everywhere.** Every state class implements `==`/
  `hashCode` — required for `family` caching (equal filter = same stream)
  and free correctness for Riverpod's change detection.
- **Errors are user-safe strings in state**, never exception objects:
  `TaskEditorState.submissionError` / `titleError` come from
  `AppException.userMessage` or `Validators` — the widget layer can never
  render a raw stack trace because it never receives one.

## How the sync controller reacts to connectivity

`SyncController.build()` (`sync_controller.dart`):

1. `ref.watch(syncEngineProvider)` — the engine boots asynchronously
   (server binds an ephemeral port); the notifier rebuilds once it is
   ready, then kicks the **initial sync round** deferred via
   `unawaited(Future(_kickInitialSync))` (never writes state synchronously
   during build).
2. `ref.watch(connectivityServiceProvider)` and subscribes to
   `onConnectivityChanged`:
   - goes offline → `state = SyncOffline`, rounds stop, mutations keep
     queueing;
   - regains connectivity while offline → `state = SyncIdle` then an
     **unawaited drain round**.
3. `_runRound(engine, round)` — the single funnel for every round
   (initial, manual "Sync now", "Retry failed", repository triggers):
   - **coalescing**: while `_busy`, additional triggers set
     `_followUpPending` and return — a burst of mutations becomes *one*
     round plus one follow-up instead of N concurrent pushes;
   - guard: if offline → `SyncOffline`, no engine call;
   - `state = SyncSyncing(await engine.queuedMutationCount())` → run →
     outcome failures map to `SyncFailed(error.userMessage)` and
     `_scheduleRetry(outcome.retryAfter ?? backoffFor(1))`; clean →
     `SyncIdle`;
   - `on AppException` / `on Object` belt-and-braces: even an engine bug
     becomes `SyncFailed('Something went wrong while syncing.')`;
   - `_scheduleRetry(null)` **clears** the timer — that is how exhausted
     mutations stop auto-retrying (manual "Retry failed" only).
4. `ref.onDispose(_disposeResources)` cancels the retry timer and the
   connectivity subscription.

## How screens prime the global editor

The task editor is a global `NotifierProvider` — screens prime it rather
than owning form state:

- **Create mode** (`TasksScreen` FAB, `ProjectDetailScreen` FAB):
  navigate to `/tasks/new?project=:id`; `TaskEditorScreen.initState`
  (a `ConsumerStatefulWidget`) calls
  `taskEditorController.startCreate(projectId: …)` — or the editor offers
  the project dropdown when no project is preset.
- **Edit mode**: the route carries the `Task` snapshot as `extra`
  (`context.push('/tasks/$id/edit', extra: task)`) → the screen calls
  `startEdit(task)` immediately (no waiting for the stream); when there is
  no `extra` (deep link / state restoration), it waits for
  `taskByIdProvider(taskId)` and primes once the task arrives.
- **List tiles** never open the editor just to toggle completion:
  `TaskListItem`'s checkbox calls
  `taskEditorProvider.notifier.toggleCompleted(taskId)` directly, which
  re-reads the current row first (never trusts a stale snapshot) — rapid
  taps converge correctly.
- The project editor dialog primes `projectEditorProvider` the same way
  (`startCreate` / `startEdit`) and returns a `ProjectEditorResult` so the
  detail page can navigate away after a delete.

## Rebuild scoping (`select` usage)

- `SettingsScreen`:
  `ref.watch(queueBadgeProvider.select((value) => value.value ?? 0))` —
  the screen rebuilds only when the **count** changes, not on every
  stream event wrapper change.
- Family caching is the big scoping win: `taskListProvider(filter)`
  keeps one stream per distinct filter; changing the search text (after
  debounce) swaps to a new family instance and disposes the old stream.
- `projectStatsProvider` watches `taskListProvider(TaskFilter.all)` —
  ONE all-tasks stream feeds every project card's counters; switching
  filters on the tasks screen does not disturb it (different family
  argument).
- Widgets split along watch lines: `TaskFilterBar` (a
  `ConsumerStatefulWidget` holding the raw keystrokes locally) does not
  rebuild the list per character — the debounce commits to
  `taskFilterStateProvider` only after 350 ms of silence.

## Test overrides (the two lines that matter)

```dart
// 1) Everything on an in-memory database — repositories, engine, queue
//    badge inherit the swap because they all watch databaseProvider:
ProviderScope(
  overrides: [
    databaseProvider.overrideWith(
      (ref) => AppDatabase(NativeDatabase.memory()),
    ),
  ],
  child: const OfflineBoardApp(),
)

// 2) Fake connectivity (offline→online integration flows):
class FakeConnectivityService extends ConnectivityService {
  FakeConnectivityService(this.online);
  bool online;
  final _changes = StreamController<bool>.broadcast();
  @override bool get isOnline => online;
  @override Stream<bool> get onConnectivityChanged => _changes.stream;
  void emit(bool value) { online = value; _changes.add(value); }
}

connectivityServiceProvider.overrideWithValue(fake)

// For widget tests that exercise the demo switch instead, wire it exactly
// like main.dart AND stub the platform source (no platform channels):
connectivityServiceProvider.overrideWith(
  (ref) => ref.watch(demoConnectivityProvider),
),
platformConnectivityProvider.overrideWithValue(fake),

// Determinism (unit/state tests) — pin the clock with any closure; the
// doc comment in core_providers.dart sketches a MutableClock helper:
var now = DateTime.utc(2024, 1, 1);
clockProvider.overrideWithValue(() => now),
idGeneratorProvider.overrideWithValue(() => 'fixed-id'),
appConfigProvider.overrideWithValue(const AppConfig(
  retryPolicy: SyncRetryPolicy(maxAttempts: 2, initialBackoff: Duration(ms: 10)),
)),
```

Details in [TESTING.md](TESTING.md); provider typing and the override
surface are the reasons screens stay trivially widget-testable.
