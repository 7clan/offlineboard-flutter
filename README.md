# OfflineBoard

An **offline-first** project & task manager built with Flutter. Every write
lands in a local SQLite database first and is *delivered* to a sync server
later — so creating, editing, filtering and deleting tasks works exactly the
same with or without a connection. A durable mutation queue, a
last-write-wins conflict resolver and a visible sync pipeline make the
offline behaviour a feature you can watch, not an edge case you hope to
avoid.

[![Flutter CI](https://github.com/7clan/offlineboard-flutter/actions/workflows/flutter_ci.yml/badge.svg)](https://github.com/7clan/offlineboard-flutter/actions/workflows/flutter_ci.yml)

## Features

- **Projects & tasks** — create/edit/delete with priorities (low → urgent),
  due dates, notes and completion; project cards show task counts and live
  progress.
- **Local source of truth** — the SQLite database (Drift) serves every read;
  the UI never blocks on the network. Reads are Drift watch streams, so the
  list re-emits the instant data changes.
- **Durable sync queue** — every mutation is written *and* enqueued in one
  database transaction (`pending_mutations` table). The queue survives app
  restarts and process death.
- **Resilient sync engine** — FIFO batches (32 per push), exponential
  backoff (1s → ×2 → 2 min cap), a starvation guard that keeps exhausted
  mutations from crowding fresh ones, and a `failed` state that requires a
  manual retry — mutations are never silently dropped.
- **Conflict resolution** — last-write-wins on `updatedAt` with a
  deterministic id tiebreak, delete tombstones, and a re-arm step that
  converges client and server without losing local edits. Idempotency keys
  (`mutationId`) make retried pushes safe.
- **Visible sync status** — a global banner (offline / queued / syncing /
  failed / synced), a live queue count in Settings, and a per-record sync
  badge on every project and task row.
- **Search & filters** — debounced (350 ms) case-insensitive search,
  completion, priority and due-window chips; the whole filter is one
  parameterized SQL query with bound variables.
- **Demo offline switch** — Settings → *Simulate offline (demo)*: the app
  reacts exactly as it does to a real connection loss (the sync controller
  cannot tell the difference).
- **Material 3** — light & dark themes from one seed, generous touch
  targets, live-region banners, 2.0× text-scale-safe layouts.

## Tech stack

| Concern | Choice |
| --- | --- |
| UI | Flutter (Material 3) |
| State / DI | Riverpod 3 (`Notifier`, `StreamProvider`, `family`, `select`) |
| Navigation | GoRouter 16 (`StatefulShellRoute.indexedStack`) |
| Local database | Drift 2 / SQLite (`sqlite3_flutter_libs`, background isolate) |
| Networking | Dio 5 (in-process mock sync server over a real `HttpServer`) |
| Connectivity | `connectivity_plus` 7 (wrapped behind a testable seam) |
| Tooling | `drift_dev` + `build_runner` (generated code is committed), `mocktail`, `intl` |

## Architecture at a glance

```
presentation/                       application/state layer
  screens (Material 3)                providers (Riverpod = DI + state)
  widgets  (reusable UI)                  │
  routes   (GoRouter)                     │ watches
      │                                   ▼
      │ watches                     domain/  (pure Dart)
      │   ┌────────────────────►  entities      Project, Task, MutationRecord
      │   │                        repositories  TaskRepository, ProjectRepository
      │   │                        sync          SyncEngine, ConflictResolver
      │   │                             ▲
      ▼   │                        data/  (implements the contracts)
   UI never sees Dio                   │
   or JSON — only                 db/   AppDatabase + DAOs (Drift, SQLite)
   domain entities                remote/ SyncApiClient (Dio) + MockSyncServer
                                  sync/  SyncEngineImpl, LWW conflict resolver
                                  repositories/ local-first impls
```

Dependency rule: `presentation → domain ← data`. The domain layer imports
nothing from data or presentation. Full details in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Quick start

```bash
flutter pub get     # dependencies (generated Drift code is committed)
flutter run         # on a connected device or emulator
flutter test        # unit / db / state / widget / sync tests
```

No backend to start: the app boots its own deterministic in-process sync
server (a real `HttpServer` on 127.0.0.1) seeded with 2 projects and 8
tasks — the full HTTP stack including timeouts, 5xx responses, malformed
payloads, dropped connections and conflicts is real and exerciseable.

End-to-end pipeline smoke check (pure Dart, no Flutter bindings):

```bash
dart run tool/sync_smoke.dart
```

## The offline-first story (2-minute demo)

1. Open **Settings** and flip **Simulate offline (demo)** — the sync banner
   switches to *Offline — changes are saved locally*.
2. Create a project and a few tasks, edit titles, complete one, delete
   another. Everything works instantly; every row shows a *pending* sync
   badge and the queue counter in Settings climbs.
3. Flip the switch back. The banner moves through *Syncing* → *All changes
   synced*, the badges clear, and the queue drains to zero — with retries
   and conflicts handled by the engine along the way (kill the server mid-
   push via the `RemoteConditions` knobs to watch backoff and failure
   states).
4. Pull the same server from a second client simulation (see
   [tool/sync_smoke.dart](tool/sync_smoke.dart) step 5–6) to watch
   conflicts resolve deterministically in both directions.

## Documentation

| Doc | Contents |
| --- | --- |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | layers, dependency rule, error flow, routing |
| [OFFLINE_SYNC](docs/OFFLINE_SYNC.md) | **the flagship**: queue, push/pull, LWW, failure modes |
| [STATE_MANAGEMENT](docs/STATE_MANAGEMENT.md) | every provider, rebuild scoping, test overrides |
| [API](docs/API.md) | the sync wire protocol with JSON examples |
| [TESTING](docs/TESTING.md) | strategy, categories, determinism |
| [PERFORMANCE](docs/PERFORMANCE.md) | watch queries, indexes, rebuild scoping, debounce |
| [ACCESSIBILITY](docs/ACCESSIBILITY.md) | semantics, 48 dp targets, 2.0× text scaling |
| [RELEASE](docs/RELEASE.md) | universal APK, AAB, ABI verification, signing |
| [AI_WORKFLOW](docs/AI_WORKFLOW.md) | AI-assisted development disclosure |
| [INTERVIEW_GUIDE](docs/INTERVIEW_GUIDE.md) | 50 questions to defend this repo |
| [CV_EVIDENCE](docs/CV_EVIDENCE.md) | verified claims for your CV |

## Project stats

- 68 Dart files under `lib/` across 4 layers; `flutter analyze` reports no
  issues.
- Deterministic throughout: injected `Clock` and `IdGenerator` — no
  `DateTime.now()` or unseeded randomness in app logic.
- CI (GitHub Actions): format gate + analyze + tests on every push and PR.

## License

Portfolio project for 7clan — see the repository for terms.
