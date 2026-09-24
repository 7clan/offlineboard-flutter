import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/utils/clock.dart';
import '../../domain/entities/sync_enums.dart';
import 'sync_wire_types.dart';

/// Runtime fault injection for the simulated sync backend.
///
/// OfflineBoard ships with a deterministic in-process "remote" (a real
/// `HttpServer` on 127.0.0.1) so the full network stack — including
/// timeouts, server errors, malformed payloads, dropped connections and
/// conflicts — can be exercised and *seen* without infrastructure. These
/// toggles are honest about being simulated: tests (and reviewers via the
/// debug screen) use them to force the offline behaviours on demand.
///
/// The class is deliberately mutable and referenced (not copied) by the
/// server, so flipping a flag affects the very next request.
class RemoteConditions {
  /// Creates healthy conditions.
  RemoteConditions({
    this.latencyMs = 0,
    this.forceStatusNext,
    this.malformedNext = 0,
    this.dropConnection = false,
    this.conflictOnProjectId,
  });

  /// Artificial per-request latency — makes syncing states observable.
  int latencyMs;

  /// Answers the next [count] requests with HTTP [code] (e.g. 503).
  ({int count, int code})? forceStatusNext;

  /// Answers the next [malformedNext] requests with a non-JSON body.
  int malformedNext;

  /// Accepts the request, then closes the connection without responding —
  /// the client sees a hard transport error.
  bool dropConnection;

  /// Forces a server-side version bump for pushes touching this project
  /// id, exactly when the push would otherwise apply cleanly — a
  /// deterministic CONFLICT trigger (simulates a concurrent editor).
  String? conflictOnProjectId;

  /// Restores healthy conditions.
  void reset() {
    latencyMs = 0;
    forceStatusNext = null;
    malformedNext = 0;
    dropConnection = false;
    conflictOnProjectId = null;
  }
}

/// The simulated sync backend: an in-process HTTP server holding the
/// server-side dataset.
///
/// Protocol (see `docs/OFFLINE_SYNC.md`):
///
/// * `GET /sync/pull?since=<millis>` →
///   `{"data": {"projects": [...], "tasks": [...], "serverTime": <millis>}}`
/// * `POST /sync/push {"mutations": [...]}` →
///   `{"results": [{"mutationId", "status", "record"?, "reason"?}]}`
///
/// Conflict model: a mutation applies when the record is new or the server
/// is still at the pushed base version; otherwise the server answers
/// `conflict` together with its current record. Applied records take the
/// client's `clientTimestamp` as `updatedAt` and `baseVersion + 1` as
/// `version`, so a successful push leaves client and server identical.
/// Deletes produce tombstones that keep syncing. Replayed `mutationId`s
/// are idempotent.
class MockSyncServer {
  /// Creates a server. [conditions] is kept by reference — mutate it to
  /// inject faults. [clock] provides the server time (tests pin it).
  MockSyncServer({RemoteConditions? conditions, Clock? clock})
    : conditions = conditions ?? RemoteConditions(),
      _clock = clock ?? systemClock;

  /// Live fault-injection toggles for this server.
  final RemoteConditions conditions;

  final Clock _clock;
  HttpServer? _server;

  /// Applied mutation ids → idempotency.
  final Set<String> _processedMutationIds = {};

  /// Server-side project records by id.
  final Map<String, Map<String, dynamic>> projects = {};

  /// Server-side task records by id.
  final Map<String, Map<String, dynamic>> tasks = {};

  /// Binds to 127.0.0.1 on an ephemeral port and seeds the dataset.
  Future<void> start() async {
    if (_server != null) return;
    _seed();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (Object _) {});
  }

  /// Stops the server (tests call this in `tearDown`).
  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// The bound port (only meaningful after [start]).
  int get port => _server?.port ?? 0;

  /// Base URL the sync client should talk to, e.g. `http://127.0.0.1:41237`.
  String get baseUrl => 'http://127.0.0.1:$port';

  /// Server-side record lookup by entity kind and id.
  Map<String, dynamic>? recordOf(EntityType type, String id) {
    return switch (type) {
      EntityType.project => projects[id],
      EntityType.task => tasks[id],
    };
  }

  // ---------------------------------------------------------------------------
  // Request handling
  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    try {
      if (conditions.latencyMs > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: conditions.latencyMs),
        );
      }
      final forced = conditions.forceStatusNext;
      if (forced != null && forced.count > 0) {
        conditions.forceStatusNext = (
          count: forced.count - 1,
          code: forced.code,
        );
        request.response.statusCode = forced.code;
        await request.response.close();
        return;
      }
      if (conditions.dropConnection) {
        // Accept, then hang up without answering: detach the raw socket
        // and destroy it — the client observes a hard transport error.
        final socket = await request.response.detachSocket();
        socket.destroy();
        return;
      }
      if (conditions.malformedNext > 0) {
        conditions.malformedNext--;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{{not-json');
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && request.uri.path == '/sync/pull') {
        await _handlePull(request);
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/sync/push') {
        await _handlePush(request);
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } on Exception {
      // The simulated server never crashes the app under test.
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Exception {
        // Socket already gone — nothing left to do.
      }
    }
  }

  Future<void> _handlePull(HttpRequest request) async {
    final since = int.tryParse(request.uri.queryParameters['since'] ?? '') ?? 0;
    final now = _clock().millisecondsSinceEpoch;
    final changedProjects = [
      for (final record in projects.values)
        if ((record['updatedAt'] as num).toInt() > since) record,
    ]..sort((a, b) => (a['updatedAt'] as num).compareTo(b['updatedAt'] as num));
    final changedTasks = [
      for (final record in tasks.values)
        if ((record['updatedAt'] as num).toInt() > since) record,
    ]..sort((a, b) => (a['updatedAt'] as num).compareTo(b['updatedAt'] as num));

    final body = jsonEncode(<String, dynamic>{
      'data': <String, dynamic>{
        'projects': changedProjects,
        'tasks': changedTasks,
        'serverTime': now,
      },
    });
    request.response.headers.contentType = ContentType.json;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> _handlePush(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      _respond(request, HttpStatus.badRequest, {
        'message': 'Push body is not valid JSON.',
      });
      return;
    }
    if (decoded is! Map<String, dynamic> || decoded['mutations'] is! List) {
      _respond(request, HttpStatus.badRequest, {
        'message': 'Push body must contain a "mutations" list.',
      });
      return;
    }

    final results = <Map<String, dynamic>>[];
    for (final rawMutation in decoded['mutations'] as List) {
      results.add(_applyMutation(rawMutation));
    }
    _respond(request, HttpStatus.ok, {'results': results});
  }

  void _respond(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    unawaited(request.response.close());
  }

  // ---------------------------------------------------------------------------
  // Mutation application (the conflict model)
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _applyMutation(Object? rawMutation) {
    if (rawMutation is! Map<String, dynamic>) {
      return _result(
        '?',
        PushItemStatus.rejected,
        reason: 'Malformed mutation.',
      );
    }
    final mutationId = rawMutation['mutationId'];
    final typeName = rawMutation['type'];
    final entityTypeName = rawMutation['entityType'];
    final entityId = rawMutation['entityId'];
    final payload = rawMutation['payload'];
    final baseVersion = rawMutation['baseVersion'];
    final baseUpdatedAt = rawMutation['baseUpdatedAt'];
    final clientTimestamp = rawMutation['clientTimestamp'];

    if (mutationId is! String ||
        typeName is! String ||
        entityTypeName is! String ||
        entityId is! String ||
        payload is! Map<String, dynamic> ||
        baseVersion is! num ||
        baseUpdatedAt is! num ||
        clientTimestamp is! num) {
      return _result(
        mutationId is String ? mutationId : '?',
        PushItemStatus.rejected,
        reason: 'Mutation is missing required fields.',
      );
    }

    // Idempotency: replayed mutation ids are acknowledged, not re-applied.
    if (_processedMutationIds.contains(mutationId)) {
      return _result(mutationId, PushItemStatus.applied, reason: 'duplicate');
    }

    final type = switch (typeName) {
      'create' => MutationType.create,
      'update' => MutationType.update,
      'delete' => MutationType.delete,
      _ => null,
    };
    final entityType = switch (entityTypeName) {
      'project' => EntityType.project,
      'task' => EntityType.task,
      _ => null,
    };
    if (type == null || entityType == null) {
      return _result(
        mutationId,
        PushItemStatus.rejected,
        reason: 'Unknown mutation type or entity type.',
      );
    }

    final store = switch (entityType) {
      EntityType.project => projects,
      EntityType.task => tasks,
    };
    var record = store[entityId];

    // Deterministic conflict injection: bump the server record exactly
    // when the push would otherwise apply cleanly.
    if (record != null &&
        conditions.conflictOnProjectId == entityId &&
        (record['version'] as num).toInt() == baseVersion.toInt()) {
      record = _bump(record);
      store[entityId] = record;
    }

    if (record == null) {
      // Record unknown to the server: apply (create semantics).
      final reason = _validate(entityType, payload);
      if (reason != null) {
        return _result(mutationId, PushItemStatus.rejected, reason: reason);
      }
      final created = Map<String, dynamic>.of(payload)
        ..['version'] = baseVersion.toInt() + 1
        ..['updatedAt'] = clientTimestamp.toInt()
        ..['lastMutationId'] = mutationId;
      store[entityId] = created;
      _processedMutationIds.add(mutationId);
      return _result(mutationId, PushItemStatus.applied);
    }

    if ((record['version'] as num).toInt() != baseVersion.toInt()) {
      // Stale base: report the conflict with the server's current record.
      return _result(mutationId, PushItemStatus.conflict, record: record);
    }

    if (type == MutationType.delete) {
      final tombstone = Map<String, dynamic>.of(record)
        ..['isDeleted'] = true
        ..['version'] = baseVersion.toInt() + 1
        ..['updatedAt'] = clientTimestamp.toInt()
        ..['lastMutationId'] = mutationId;
      store[entityId] = tombstone;
      _processedMutationIds.add(mutationId);
      return _result(mutationId, PushItemStatus.applied);
    }

    final reason = _validate(entityType, payload);
    if (reason != null) {
      return _result(mutationId, PushItemStatus.rejected, reason: reason);
    }
    final applied = Map<String, dynamic>.of(payload)
      ..['version'] = baseVersion.toInt() + 1
      ..['updatedAt'] = clientTimestamp.toInt()
      ..['lastMutationId'] = mutationId;
    store[entityId] = applied;
    _processedMutationIds.add(mutationId);
    return _result(mutationId, PushItemStatus.applied);
  }

  Map<String, dynamic> _bump(Map<String, dynamic> record) {
    // Simulates another client writing concurrently.
    return Map<String, dynamic>.of(record)
      ..['version'] = (record['version'] as num).toInt() + 1
      ..['updatedAt'] = _clock().millisecondsSinceEpoch
      ..['lastMutationId'] = 'server-side-bump';
  }

  /// Payload validation — the only path to `rejected`.
  String? _validate(EntityType entityType, Map<String, dynamic> payload) {
    switch (entityType) {
      case EntityType.project:
        final name = payload['name'];
        if (name is! String || name.trim().isEmpty) {
          return 'Project name must not be empty.';
        }
      case EntityType.task:
        final title = payload['title'];
        if (title is! String || title.trim().isEmpty) {
          return 'Task title must not be empty.';
        }
        final projectId = payload['projectId'];
        if (projectId is! String || projectId.trim().isEmpty) {
          return 'Task must reference a project.';
        }
        final priority = payload['priority'];
        if (priority is! String ||
            const {'low', 'medium', 'high', 'urgent'}.contains(priority) ==
                false) {
          return 'Task priority is unknown.';
        }
    }
    return null;
  }

  Map<String, dynamic> _result(
    String mutationId,
    PushItemStatus status, {
    Map<String, dynamic>? record,
    String? reason,
  }) {
    return <String, dynamic>{
      'mutationId': mutationId,
      'status': status.name,
      'record': ?record,
      'reason': ?reason,
    };
  }

  // ---------------------------------------------------------------------------
  // Seed dataset — 2 projects, 8 tasks, mixed updatedAt/version
  // ---------------------------------------------------------------------------

  void _seed() {
    const seedBase = 1704067200000; // 2024-01-01T00:00:00Z, deterministic.

    projects['p-server-1'] = {
      'id': 'p-server-1',
      'name': 'Personal',
      'colorValue': 0xFF2E7D32,
      'createdAt': seedBase,
      'updatedAt': seedBase,
      'version': 1,
      'isDeleted': false,
    };
    projects['p-server-2'] = {
      'id': 'p-server-2',
      'name': 'Work',
      'colorValue': 0xFF00695C,
      'createdAt': seedBase + 1000,
      'updatedAt': seedBase + 60000, // edited once — version 2
      'version': 2,
      'isDeleted': false,
      'lastMutationId': 'server-seed-edit',
    };

    int taskSeed(int n) => seedBase + n * 1000;
    void task(
      String id,
      String projectId,
      String title,
      String priority, {
      int? dueDate,
      bool isCompleted = false,
      int version = 1,
      int updatedAtOffset = 0,
      String? notes,
    }) {
      tasks[id] = {
        'id': id,
        'projectId': projectId,
        'title': title,
        'notes': notes,
        'priority': priority,
        'dueDate': dueDate,
        'isCompleted': isCompleted,
        'createdAt': taskSeed(0),
        'updatedAt': taskSeed(updatedAtOffset),
        'version': version,
        'isDeleted': false,
        if (version > 1) 'lastMutationId': 'server-seed-edit-$id',
      };
    }

    task(
      't-server-1',
      'p-server-1',
      'Buy groceries',
      'medium',
      dueDate: seedBase + 86400000 * 2,
      updatedAtOffset: 1,
    );
    task(
      't-server-2',
      'p-server-1',
      'Renew passport',
      'high',
      dueDate: seedBase + 86400000 * 30,
      updatedAtOffset: 2,
    );
    task(
      't-server-3',
      'p-server-1',
      'Water the plants',
      'low',
      updatedAtOffset: 3,
    );
    task(
      't-server-4',
      'p-server-1',
      'Book dentist appointment',
      'urgent',
      dueDate: seedBase + 86400000 * 7,
      updatedAtOffset: 4,
    );
    task(
      't-server-5',
      'p-server-2',
      'Prepare quarterly review',
      'urgent',
      notes: 'Slides + budget draft',
      updatedAtOffset: 5,
    );
    task(
      't-server-6',
      'p-server-2',
      'Reply to design feedback',
      'high',
      version: 3,
      updatedAtOffset: 6,
    );
    task(
      't-server-7',
      'p-server-2',
      'Submit expense report',
      'medium',
      isCompleted: true,
      version: 2,
      updatedAtOffset: 7,
    );
    task(
      't-server-8',
      'p-server-2',
      'Plan team offsite',
      'low',
      dueDate: seedBase + 86400000 * 60,
      version: 2,
      updatedAtOffset: 8,
    );
  }
}
