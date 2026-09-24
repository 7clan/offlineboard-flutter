# Sync API protocol

The remote contract as implemented by `MockSyncServer`
(`lib/data/remote/mock_sync_server.dart`) and consumed by `SyncApiClient`
(`lib/data/remote/sync_api_client.dart`). The wire DTOs live in
`lib/data/remote/sync_wire_types.dart` — both sides of the link use that
one file, which is what makes the protocol reviewable in a single place.

In the shipped app the "server" is a deterministic in-process `HttpServer`
bound to `127.0.0.1` on an **ephemeral port** (`MockSyncServer.start()`),
seeded with 2 projects and 8 tasks. It is a real HTTP endpoint over a real
socket — Dio, timeouts, connection errors and dropped connections behave
exactly as against a remote host.

Base configuration (`AppConfig`, `lib/core/config/app_config.dart`):
`connectTimeout = 8s`, `receiveTimeout = 20s`, `pushBatchSize = 32`,
`content-type: application/json`.

---

## `GET /sync/pull?since=<millis>`

Fetch every record changed since the cursor. `since` is UTC millis
(default `0` = full history). The client persists the returned
`serverTime` as its next cursor (`sync_meta.lastPullAt`).

**Response — 200:**

```json
{
  "data": {
    "projects": [
      {
        "id": "p-server-1",
        "name": "Personal",
        "colorValue": 4281236786,
        "createdAt": 1704067200000,
        "updatedAt": 1704067200000,
        "version": 1,
        "isDeleted": false
      },
      {
        "id": "p-server-2",
        "name": "Work",
        "colorValue": 4278217052,
        "createdAt": 1704067201000,
        "updatedAt": 1704067260000,
        "version": 2,
        "isDeleted": false,
        "lastMutationId": "server-seed-edit"
      }
    ],
    "tasks": [
      {
        "id": "t-server-1",
        "projectId": "p-server-1",
        "title": "Buy groceries",
        "notes": null,
        "priority": "medium",
        "dueDate": 1704240000000,
        "isCompleted": false,
        "createdAt": 1704067200000,
        "updatedAt": 1704067201000,
        "version": 1,
        "isDeleted": false
      }
    ],
    "serverTime": 1704067260000
  }
}
```

Facts:

- Records are sorted by `updatedAt` ascending (server side).
- **Tombstones are included** — a `tasks` entry with `"isDeleted": true`
  means "this record was deleted"; the client applies it and hides the
  row locally.
- `lastMutationId` (optional, string) is the mutation id of the last write
  the server accepted — the LWW tiebreak key. Absent on seeded records.
- `PullResponse.fromJson` validates: `data` must be an object,
  `serverTime` a number, `projects`/`tasks` lists — anything else throws
  `FormatException`, which the client maps to
  `MalformedResponseException`.
- Client-side pull guard (see [OFFLINE_SYNC.md](OFFLINE_SYNC.md)): a
  record with pending local mutations is skipped; otherwise the server
  record is applied only if strictly newer (`updatedAt > local.updatedAt`).

## `POST /sync/push`

Body — one batch of queued mutations (≤ 32, the client's
`pushBatchSize`):

```json
{
  "mutations": [
    {
      "mutationId": "lwjuzf0-1a",
      "type": "create",
      "entityType": "task",
      "entityId": "lwjuzf1-2",
      "payload": {
        "id": "lwjuzf1-2",
        "projectId": "p-server-1",
        "title": "Buy groceries",
        "notes": null,
        "priority": "high",
        "dueDate": null,
        "isCompleted": false,
        "createdAt": 1735689600000,
        "updatedAt": 1735689600000,
        "version": 1,
        "isDeleted": false
      },
      "baseUpdatedAt": 0,
      "baseVersion": 0,
      "clientTimestamp": 1735689600000
    }
  ]
}
```

Field semantics (`PushMutation.toJson()`):

| Field | Meaning |
| --- | --- |
| `mutationId` | client-generated **idempotency key** — the server remembers it and answers replays `applied` without re-applying |
| `type` | `create` / `update` / `delete` |
| `entityType` | `project` / `task` |
| `entityId` | affected record id |
| `payload` | **full new record state** (the tombstone row for deletes) — no JSON patches |
| `baseUpdatedAt` | the `updatedAt` the local edit was applied on top of |
| `baseVersion` | the `version` the local edit was applied on top of — the server must still be at this value for a clean apply |
| `clientTimestamp` | when the edit happened — becomes the record's `updatedAt` on apply, and is the LWW comparison key |

**Response — 200** (one result per pushed mutation, order not guaranteed —
matching is by echoed `mutationId`):

```json
{
  "results": [
    { "mutationId": "lwjuzf0-1a", "status": "applied" },
    {
      "mutationId": "lwjuzf2-3",
      "status": "conflict",
      "record": {
        "id": "p-server-1",
        "name": "Renamed on the server",
        "colorValue": 4281236786,
        "createdAt": 1704067200000,
        "updatedAt": 1704067300000,
        "version": 3,
        "isDeleted": false,
        "lastMutationId": "server-side-bump"
      }
    },
    {
      "mutationId": "lwjuzf4-5",
      "status": "rejected",
      "reason": "Task title must not be empty."
    }
  ]
}
```

### Per-item result statuses (`PushItemStatus`)

| Status | When | Client action (engine) |
| --- | --- | --- |
| `applied` | record new, or server still at `baseVersion` (or an idempotent replay — then with `reason: "duplicate"`) | dequeue the mutation; the local row already matches by construction (the server stored the client's `clientTimestamp`/`baseVersion + 1`) |
| `conflict` | server `version != baseVersion` | `record` carries the server's current state → run `LastWriteWinsConflictResolver`, apply the winner, collapse the entity's queue (re-arm a corrected mutation when local wins) |
| `rejected` | payload fails server-side validation | `reason` explains it; counts as a failed attempt — retrying unchanged fails again, so it surfaces as `failed` after `maxAttempts` and waits for manual attention |

**Malformed mutations** (wrong types, missing fields, unknown type/entity
names) are answered `rejected` per item (`"Mutation is missing required
fields."` / `"Unknown mutation type or entity type."` / `"Malformed
mutation."`).

**Protocol-level guards on the client** (`SyncApiClient.push` /
`SyncEngineImpl._validateEcho`):

- response body must be a JSON object with a `results` **list** of
  objects, else `MalformedResponseException`;
- the echoed mutation ids must match the pushed ids **exactly** (no
  missing, no extra, no duplicates) — else the whole response is rejected
  as malformed and the batch is retried.

### Server-side application rules (`_applyMutation`)

1. **Idempotency first** — a replayed `mutationId` is answered
   `applied` (`reason: "duplicate"`) without re-applying.
2. Record unknown → create semantics: payload validated, stored with
   `version = baseVersion + 1`, `updatedAt = clientTimestamp`,
   `lastMutationId = mutationId` → `applied`.
3. `type == delete` → tombstone: existing record with `isDeleted: true`,
   `version = baseVersion + 1`, `updatedAt = clientTimestamp` →
   `applied`.
4. Server `version != baseVersion` → `conflict` with the current record.
5. Otherwise the payload replaces the record (`version =
   baseVersion + 1`, `updatedAt = clientTimestamp`) → `applied`.

Payload validation (`_validate`) — the only path to `rejected`:

- project: `name` non-empty string;
- task: `title` non-empty string, `projectId` non-empty string,
  `priority` one of `low|medium|high|urgent`.

Bad request shapes (non-JSON body, no `mutations` list) → **HTTP 400**
with `{"message": "..."}` (the client maps non-2xx to `ServerException`).

## `RemoteConditions` — fault injection knobs

The knobs are **mutable and held by reference** by the server — flipping
one affects the very next request (that is how tests and the smoke tool
script scenarios):

| Knob | Type | Effect |
| --- | --- | --- |
| `latencyMs` | `int` (default 0) | artificial per-request delay — makes syncing states observable |
| `forceStatusNext` | `({int count, int code})?` | answer the next `count` requests with HTTP `code` (e.g. 503); decrements per use |
| `malformedNext` | `int` | answer the next N requests with a non-JSON body (`{{not-json`) |
| `dropConnection` | `bool` | accept the request, then destroy the socket without responding — the client observes a hard transport error |
| `conflictOnProjectId` | `String?` | **deterministic conflict injection**: bump the server record (version + 1, `updatedAt` = now, `lastMutationId = 'server-side-bump'`) exactly when a push touching this entity id would otherwise apply cleanly — simulates a concurrent editor |
| `reset()` | — | restore healthy conditions |

Example (as used by `tool/sync_smoke.dart`):

```dart
server.conditions.dropConnection = true;   // go "offline"
// …create tasks locally, watch the queue grow…
server.conditions.reset();                  // reconnect
await engine.syncNow();                    // queue drains
```

## Error mapping (client side)

Every transport/parse failure becomes an `AppException`
(`ErrorMapper.map`, `lib/core/errors/error_mapper.dart`) — the engine and
UI never see a `DioException`:

| Wire event | Mapped exception | Engine behavior |
| --- | --- | --- |
| connection refused / dropped socket | `NetworkException` | batch marked attempted, backoff retry |
| connect/send/receive timeout | `TimeoutException` | same |
| HTTP 5xx (or 400) | `ServerException(statusCode:, serverMessage:)` | same |
| HTTP 401 | `UnauthorizedException` | same (none produced by the mock server) |
| non-JSON body / bad shape / echo mismatch | `MalformedResponseException` | same |
| per-item `rejected` | — (not an exception) | `markAttempted(reason)` |
| per-item `conflict` | — (not an exception) | resolver path |

## Versioning & compatibility notes

- Enums travel **by name** on the wire (`"create"`, `"task"`,
  `"medium"`) but are stored as **indexes** in SQLite — the mappers
  (`lib/data/mappers/entity_mappers.dart`) own both directions, so
  reordering an enum cannot corrupt stored data, and unknown wire names
  fail loudly (`FormatException`) instead of silently defaulting.
- The protocol carries **full record state**, not diffs — a payload
  applies atomically and needs no ordering guarantees beyond `baseVersion`.
- No auth headers in this simulation; `SyncApiClient`'s Dio base options
  set `content-type: application/json` only.
