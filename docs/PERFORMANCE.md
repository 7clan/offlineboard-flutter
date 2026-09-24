# Performance

Every technique below is in the shipped code — file, mechanism, and *why
it matters* for an offline-first task manager. No speculative
optimization; each item addresses a concrete cost.

## 1. Drift watch queries — reactivity instead of polling

**Where:** `TasksDao.watchTasks` / `watchTask` / `watchUnsyncedTasks`,
`ProjectsDao.watchProjects` / `watchProject`,
`SyncQueueDao.watchCount` (`lib/data/db/app_database.dart`).

**Mechanism:** every read is a `customSelect(...).watch()` stream. Drift
registers the tables the statement `readsFrom` (`{tasks,
pendingMutations}`) and re-runs the SELECT only when one of them changes.
The row data *and* the derived sync status (`queueCount`/`syncingCount`/
`failedCount` subqueries) arrive in one consistent emission.

**Why it matters:**
- No polling loop, no periodic "refresh" timer, no manual refetch after
  mutations — a save writes row + queue in one transaction, Drift
  re-runs the affected queries, the UI updates. One causal chain,
  zero wasted queries when nothing changes.
- The sync badge flips `pending → syncing → synced` live as the engine
  marks rows, because the *same* watch stream covers both tables —
  there is no second "status query" to keep in sync.

## 2. Indexed queries — the list access paths

**Where:** `AppDatabase.migration.onCreate`
(`lib/data/db/app_database.dart`):

```sql
CREATE INDEX idx_tasks_project   ON tasks (project_id, is_deleted);
CREATE INDEX idx_tasks_completed ON tasks (is_completed, is_deleted);
CREATE INDEX idx_tasks_due       ON tasks (is_deleted, due_date);
CREATE INDEX idx_queue_entity    ON pending_mutations (entity_id, is_syncing, attempts);
```

**Why it matters:** those four indexes exactly cover the queries the app
actually runs — the per-project list (project detail page), completion
slices (filter chips), due-date ordering/filtering (the default ORDER BY
and the due window), and the status subqueries + pull guard
(`hasPendingFor(entity_id)`) that execute **per record** during pulls.
SQLite answers each from an index instead of a table scan; the status
subqueries stay O(log n) lookups instead of O(n) scans per row.

## 3. One parameterized query for the whole filter contract

**Where:** `TasksDao.watchTasks`.

**Mechanism:** project / completion / priority / due-before / search are
folded into a single SELECT with bound `Variable`s (`conditions.join('
AND ')`, all user input parameterized — also an SQL-injection guard).
The ORDER BY is likewise index-friendly and stable.

**Why it matters:** the alternative — fetching all rows and filtering in
Dart — moves O(n) work across the database isolate boundary and
allocates n objects per emission. SQL does the filtering where the data
lives; only the result set crosses.

## 4. `ListView.builder` / `SliverList.builder` — virtualized lists

**Where:** `TasksScreen` and `ProjectsScreen`
(`ListView.builder`), `ProjectDetailScreen`
(`CustomScrollView` + `SliverList.builder`, so the filter bar and task
list scroll together).

**Why it matters:** rows build lazily as they scroll into view — with
hundreds of tasks the widget tree stays bounded by the viewport instead
of the dataset. (The skeletons also match: `ListSkeleton` builds exactly
`count` static rows.)

## 5. `const` everywhere the tree allows

**Where:** across `lib/presentation/` — e.g. `const TaskFilterBar()`,
`const ListSkeleton(count: 8, …)`, `const SizedBox(height: 8)`,
const icon/chip/text subtrees in every screen.

**Why it matters:** `const` widgets are canonicalized — identical
const subtrees are *the same instance*, so rebuilds short-circuit and
Flutter's element tree skips them. On every filter keystroke (debounced
commit) or stream emission, everything not actually changed avoids
rebuild work.

## 6. `select()` — rebuild scoping at the provider level

**Where:** `SettingsScreen`:

```dart
final queued = ref.watch(
  queueBadgeProvider.select((value) => value.value ?? 0),
);
```

**Why it matters:** `queueBadgeProvider` is a stream that re-emits on
every queue change; the screen only cares about the integer. `select`
makes the dependency the *count*, not the `AsyncValue` wrapper — the
settings screen rebuilds only when the number actually changes, not on
every event. (Family caching is the other big scoping win: see
[STATE_MANAGEMENT.md](STATE_MANAGEMENT.md).)

## 7. Derived-from-one-stream instead of N streams

**Where:** `projectStatsProvider`
(`lib/presentation/providers/project_stats_provider.dart`) — every
project card's total/completed counters are derived in Dart from
**one** watch of all tasks (`taskListProvider(TaskFilter.all)`).

**Why it matters:** the naive design opens one COUNT query per project
card (N streams, N queries per emission, N rebuild paths). The shipped
design pays for one stream; cards and headers update together with the
task list, and filtering on the tasks screen (a different family
argument) does not disturb the stats stream.

## 8. Debounced search — 350 ms

**Where:** `Debouncer` (`lib/core/utils/debouncer.dart`) wired into
`TaskFilterController.onSearchChanged`
(`lib/presentation/providers/task_filters_provider.dart`).

**Mechanism:** raw keystrokes live in the text field's local
`TextEditingController`; only after 350 ms of silence does the committed
text land in `taskFilterStateProvider`, which changes
`effectiveTaskFilterProvider`, which swaps the `taskListProvider`
family argument, which disposes the old stream and opens the new query.

**Why it matters:** without the debounce, every keystroke tears down and
rebuilds a database stream pipeline and re-runs the LIKE query. "Bu",
"Buy", "Buy " — three queries collapse into one. The raw input also
stays responsive because the field itself is uncontrolled by the
provider state.

## 9. Background-safe sync — fire-and-forget + durable queue

**Where:** `TaskRepositoryImpl._triggerSync()` (`unawaited(trigger())`),
`SyncController._onConnectivityChanged` /
`_runRound` (`lib/presentation/providers/sync_controller.dart`),
`NativeDatabase.createInBackground`
(`lib/presentation/providers/database_provider.dart`).

**Mechanism:** a committed mutation fires the sync trigger
**unawaited** — the UI's write path never waits on the network; the
round runs while the user keeps working. Rounds coalesce (`_busy` +
follow-up flag) so a burst of mutations becomes one request. SQLite work
itself runs on a background isolate via `NativeDatabase
.createInBackground`, keeping the platform thread free.

**Why it matters:** the offline-first promise is only real if local
writes are never blocked by delivery. A slow or absent server costs the
user *nothing* interactively; failures surface asynchronously through the
banner, and the queue is durable (SQLite table), so the app can be killed
at any point without losing a committed edit.

## 10. Static skeletons, no tickers

**Where:** `skeleton.dart` — `_SkeletonRow` is deliberately **not**
animated; rows are wrapped in `ExcludeSemantics` and one "Loading"
announcement is made by the container.

**Why it matters:** a shimmer would run an `AnimationController` per
placeholder row for the entire load — measurable cost (and a source of
flaky widget tests) for zero information. The static skeleton gives the
same layout affordance for free.

## 11. Small, focused widget rebuild units

**Where:** screens split along watch lines — e.g. `TasksScreen` watches
the task list while `TaskFilterBar` is its own `ConsumerStatefulWidget`
holding raw keystrokes locally; `TaskListItem` rows are `ConsumerWidget`s
that only read the editor controller when acting (not watching it).

**Why it matters:** typing in the search field rebuilds the text field's
subtree, not the screen; the list rebuilds only when the debounced
commit changes the filter. Errors from the editor controller
(`submissionError`) are watched by the editor screen only, not the list.

---

## What was deliberately *not* done

- **No pagination of the local list.** SQLite + virtualized builders make
  full-result queries cheap at realistic portfolio scale; paging a local
  table adds seam complexity (and merge pain with the sync stream) for no
  measurable win. The batched *sync* (32 per push) is where batching
  matters.
- **No memoization/selector frameworks, no codegen state classes.**
  Immutable values with proper `==` + Riverpod's family/`select` cover
  the rebuild scoping needed; anything more is ceremony.
- **No `RepaintBoundary` micro-tuning.** Nothing measured warranted it;
  premature repaint fencing is noise.

The right next step when scale demands it: verify with DevTools before
adding any of the above — the design keeps every hot path (stream
emission, index lookup, virtualized row) already O(viewport).
