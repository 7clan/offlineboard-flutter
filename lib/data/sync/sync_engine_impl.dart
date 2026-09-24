import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/errors/error_mapper.dart';
import '../../core/utils/clock.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/conflict_resolution.dart';
import '../../domain/entities/mutation_record.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/sync_enums.dart';
import '../../domain/entities/task.dart';
import '../../domain/sync/conflict_resolver.dart';
import '../../domain/sync/sync_engine.dart';
import '../db/app_database.dart';
import '../mappers/entity_mappers.dart';
import '../remote/sync_api_client.dart';
import '../remote/sync_wire_types.dart';

/// Offline-first sync engine: drains the durable queue to the remote and
/// applies remote changes locally.
///
/// Behaviour (see `docs/OFFLINE_SYNC.md`):
///
/// * **Push** — one batch per [pushPending] call, ordered by `queuedAt`
///   (FIFO). Per server result: `applied` dequeues; `conflict` runs the
///   injected [ConflictResolver] and applies the winner locally in a single
///   Drift transaction; `rejected` and transport errors count as failed
///   attempts (exponential backoff via [AppConfig.retryPolicy]); once a
///   mutation exhausts [SyncRetryPolicy.maxAttempts] it surfaces as
///   `SyncStatus.failed` and stays queued for [retryFailed].
/// * **Pull** — records changed since the persisted `lastPullAt` cursor are
///   applied with a last-write-wins guard: a row with pending queue entries
///   is never overwritten, and the server only wins when its `updatedAt` is
///   strictly newer than the local one.
/// * **Conflicts, row-level truth** — repositories keep the local row
///   transactionally in step with the newest queued mutation, so the row
///   always carries the newest local write. When the resolver picks the
///   local side (or the row is even newer than the mutation that
///   conflicted), the row is re-armed as a *corrected* mutation whose base
///   version matches the server, guaranteeing convergence on the next push
///   without losing any local edit.
///
/// The engine is deliberately connectivity-free (the `SyncController` owns
/// connectivity and timers) and clock-free in the sense that every timestamp
/// comes from the injected [Clock] — no `DateTime.now()` anywhere — so tests
/// stay fully deterministic.
class SyncEngineImpl implements SyncEngine {
  /// Creates the engine.
  ///
  /// [db] provides the queue, rows and transactions; [client] is the
  /// transport; [resolver] decides push conflicts; [clock], [config] and
  /// [idGenerator] are the injectable deterministic dependencies.
  SyncEngineImpl({
    required this._db,
    required this._client,
    required this._resolver,
    required this._clock,
    required this._config,
    required this._idGenerator,
  });

  /// Sync-meta key persisting the pull cursor (`lastPullAt`, UTC millis).
  static const String lastPullCursorKey = 'lastPullAt';

  final AppDatabase _db;
  final SyncApiClient _client;
  final ConflictResolver _resolver;
  final Clock _clock;
  final AppConfig _config;
  final IdGenerator _idGenerator;

  SyncQueueDao get _queue => _db.syncQueueDao;

  /// Entity ids of the mutations in the batch currently being pushed.
  ///
  /// This mirrors the queue's `is_syncing` flag (which the Drift watch
  /// streams derive `SyncStatus.syncing` from) as a live in-memory set —
  /// handy for tests and diagnostics without re-querying the database.
  Set<String> get inFlightEntityIds => UnmodifiableSetView(_inFlightEntityIds);

  final Set<String> _inFlightEntityIds = <String>{};

  int _nowMillis() => _clock().millisecondsSinceEpoch;

  // ---------------------------------------------------------------------------
  // Push
  // ---------------------------------------------------------------------------

  @override
  Future<SyncOutcome> pushPending() async {
    // Recover rows a crashed round left flagged as in-flight.
    await _queue.clearSyncingFlags();

    // Exhausted mutations stay queued as `SyncStatus.failed` until a manual
    // retryFailed() resets them — nextBatch excludes them.
    final batch = await _queue.nextBatch(
      limit: _config.pushBatchSize,
      maxAttempts: _config.retryPolicy.maxAttempts,
    );
    if (batch.isEmpty) return SyncOutcome.empty;

    final rowIds = <int>[for (final row in batch) row.id];
    _inFlightEntityIds.addAll(<String>{for (final row in batch) row.entityId});
    await _queue.markSyncing(rowIds);
    try {
      return await _pushBatch(batch);
    } finally {
      _inFlightEntityIds.removeAll(<String>{
        for (final row in batch) row.entityId,
      });
    }
  }

  /// Pushes one decoded batch and folds the per-item results into an outcome.
  Future<SyncOutcome> _pushBatch(List<PendingMutationRow> batch) async {
    final rowsByMutationId = <String, PendingMutationRow>{
      for (final row in batch) row.mutationId: row,
    };
    // Mutation ids still awaiting a verdict in this round — used to fail the
    // remainder of the batch if the transport or protocol breaks mid-round.
    final unresolved = <String>{...rowsByMutationId.keys};

    var applied = 0;
    var conflictsResolved = 0;
    var rejected = 0;
    var failed = 0;
    var sent = 0;
    AppException? failure;

    // Decode queue rows into wire mutations; corrupt entries fail closed
    // (they stay queued with a diagnostic error for manual retry).
    final records = <String, MutationRecord>{};
    final wire = <PushMutation>[];
    for (final row in batch) {
      try {
        final record = mutationFromRow(row);
        final payload = record.payload;
        records[row.mutationId] = record;
        wire.add(
          PushMutation(
            mutationId: record.mutationId,
            type: record.type,
            entityType: record.entityType,
            entityId: record.entityId,
            payload: payload,
            baseUpdatedAt: record.baseUpdatedAt,
            baseVersion: record.baseVersion,
            clientTimestamp: record.clientTimestamp,
          ),
        );
      } on Object catch (error) {
        await _queue.markAttempted([row.id], 'Corrupt queue entry: $error');
        failed++;
        unresolved.remove(row.mutationId);
      }
    }

    if (wire.isNotEmpty) {
      sent = wire.length;
      try {
        final results = await _client.push(wire);
        _validateEcho(wire, results);
        for (final result in results) {
          final row = rowsByMutationId[result.mutationId]!;
          switch (result.status) {
            case PushItemStatus.applied:
              await _queue.removeMutations([row.id]);
              applied++;
            case PushItemStatus.conflict:
              final record = records[result.mutationId]!;
              try {
                await _resolveConflict(mutation: record, item: result);
                conflictsResolved++;
              } on AppException catch (error) {
                // Malformed conflict record or a database failure while
                // resolving — this mutation retries, the rest of the batch
                // continues.
                await _queue.markAttempted([row.id], error.userMessage);
                failed++;
              }
            case PushItemStatus.rejected:
              await _queue.markAttempted([
                row.id,
              ], result.reason ?? 'Rejected by the server.');
              rejected++;
          }
          unresolved.remove(result.mutationId);
        }
      } on Object catch (error, stackTrace) {
        // Whole-batch transport failure (offline / timeout / 5xx) or a
        // malformed response: every unresolved mutation counts as a failed
        // attempt and the outcome reports the backoff delay.
        final mapped = ErrorMapper.map(error, stackTrace: stackTrace);
        failure = mapped;
        final remainingRowIds = <int>[
          for (final mutationId in unresolved) rowsByMutationId[mutationId]!.id,
        ];
        await _queue.markAttempted(remainingRowIds, mapped.userMessage);
        failed += remainingRowIds.length;
      }
    }

    return SyncOutcome(
      mutationsSent: sent,
      applied: applied,
      conflictsResolved: conflictsResolved,
      rejected: rejected,
      failed: failed,
      retryAfter: await _retryAfter(),
      error: failure,
    );
  }

  /// Fails the round when the server's `results` do not echo exactly the
  /// pushed mutation ids (malformed response guard).
  void _validateEcho(List<PushMutation> wire, List<PushResultItem> results) {
    final sentIds = <String>{for (final mutation in wire) mutation.mutationId};
    final echoIds = <String>{for (final result in results) result.mutationId};
    if (echoIds.length != results.length ||
        echoIds.difference(sentIds).isNotEmpty ||
        sentIds.difference(echoIds).isNotEmpty) {
      throw const MalformedResponseException(
        cause: FormatException('Push results do not match the pushed batch.'),
      );
    }
  }

  /// Resolves one CONFLICT result: the resolver decides mutation-vs-server,
  /// then the engine applies the winner locally and collapses the entity's
  /// queue inside a single transaction.
  Future<void> _resolveConflict({
    required MutationRecord mutation,
    required PushResultItem item,
  }) async {
    final recordJson = item.record;
    if (recordJson == null) {
      throw const MalformedResponseException(
        cause: FormatException('Conflict result is missing its record.'),
      );
    }
    final snapshot = _parseOrMalformed(
      recordJson,
      (json) => ServerRecordSnapshot.parse(
        entityType: mutation.entityType,
        json: json,
      ),
    );
    final verdict = _resolver.resolve(
      mutation: mutation,
      serverRecord: snapshot,
    );
    switch (mutation.entityType) {
      case EntityType.project:
        await _resolveProjectConflict(
          mutation: mutation,
          snapshot: snapshot,
          verdict: verdict,
        );
      case EntityType.task:
        await _resolveTaskConflict(
          mutation: mutation,
          snapshot: snapshot,
          verdict: verdict,
        );
    }
  }

  Future<void> _resolveProjectConflict({
    required MutationRecord mutation,
    required ServerRecordSnapshot snapshot,
    required ConflictResolution verdict,
  }) async {
    await _db.transaction(() async {
      final local = await _db.projectsDao.getProjectById(mutation.entityId);
      final localWins =
          verdict == ConflictResolution.localWins ||
          (local != null && local.updatedAt > snapshot.updatedAt);
      if (localWins) {
        final base = local ?? _parseProject(mutation.payload);
        final corrected = base.copyWith(version: snapshot.version + 1);
        await _db.projectsDao.upsertProject(corrected);
        await _queue.removeMutationsForEntity(mutation.entityId);
        await _queue.enqueueMutation(
          MutationRecord(
            mutationId: _idGenerator(),
            type: corrected.isDeleted ? MutationType.delete : mutation.type,
            entityType: EntityType.project,
            entityId: mutation.entityId,
            payloadJson: jsonEncode(corrected.toJson()),
            baseUpdatedAt: snapshot.updatedAt,
            baseVersion: snapshot.version,
            clientTimestamp: corrected.updatedAt,
            queuedAt: _nowMillis(),
          ),
        );
      } else {
        final winner = _parseProject(snapshot.payload);
        await _db.projectsDao.upsertProject(winner);
        await _queue.removeMutationsForEntity(mutation.entityId);
      }
    });
  }

  Future<void> _resolveTaskConflict({
    required MutationRecord mutation,
    required ServerRecordSnapshot snapshot,
    required ConflictResolution verdict,
  }) async {
    await _db.transaction(() async {
      final local = await _db.tasksDao.getTaskById(mutation.entityId);
      final localWins =
          verdict == ConflictResolution.localWins ||
          (local != null && local.updatedAt > snapshot.updatedAt);
      if (localWins) {
        final base = local ?? _parseTask(mutation.payload);
        final corrected = base.copyWith(version: snapshot.version + 1);
        await _db.tasksDao.upsertTask(corrected);
        await _queue.removeMutationsForEntity(mutation.entityId);
        await _queue.enqueueMutation(
          MutationRecord(
            mutationId: _idGenerator(),
            type: corrected.isDeleted ? MutationType.delete : mutation.type,
            entityType: EntityType.task,
            entityId: mutation.entityId,
            payloadJson: jsonEncode(corrected.toJson()),
            baseUpdatedAt: snapshot.updatedAt,
            baseVersion: snapshot.version,
            clientTimestamp: corrected.updatedAt,
            queuedAt: _nowMillis(),
          ),
        );
      } else {
        final winner = _parseTask(snapshot.payload);
        await _db.tasksDao.upsertTask(winner);
        await _queue.removeMutationsForEntity(mutation.entityId);
      }
    });
  }

  /// Backoff before the next automatic attempt, or `null` when nothing is
  /// left worth retrying (queue empty, or every entry is exhausted and
  /// waiting for a manual [retryFailed]).
  Future<Duration?> _retryAfter() async {
    final remaining = await _queue.queuedMutations();
    final retryableAttempts = <int>[
      for (final record in remaining)
        if (!_config.retryPolicy.isExhausted(record.attempts)) record.attempts,
    ];
    if (retryableAttempts.isEmpty) return null;
    return _config.retryPolicy.backoffFor(retryableAttempts.reduce(math.max));
  }

  // ---------------------------------------------------------------------------
  // Pull
  // ---------------------------------------------------------------------------

  @override
  Future<PullOutcome> pullSince() async {
    try {
      return await _pullSince();
    } on AppException {
      rethrow;
    } on FormatException catch (error, stackTrace) {
      throw MalformedResponseException(cause: error, stackTrace: stackTrace);
    } on TypeError catch (error, stackTrace) {
      throw MalformedResponseException(cause: error, stackTrace: stackTrace);
    } on Object catch (error, stackTrace) {
      throw DatabaseException(cause: error, stackTrace: stackTrace);
    }
  }

  Future<PullOutcome> _pullSince() async {
    final sinceMillis =
        int.tryParse(await _db.readMeta(lastPullCursorKey) ?? '') ?? 0;
    final response = await _client.pull(sinceMillis: sinceMillis);

    var projectsApplied = 0;
    var tasksApplied = 0;
    var skipped = 0;

    for (final json in response.projects) {
      final server = Project.fromJson(json);
      if (await _queue.hasPendingFor(server.id)) {
        skipped++;
        continue;
      }
      final local = await _db.projectsDao.getProjectById(server.id);
      if (local != null && server.updatedAt <= local.updatedAt) {
        skipped++;
        continue;
      }
      await _db.projectsDao.upsertProject(server);
      projectsApplied++;
    }

    for (final json in response.tasks) {
      final server = Task.fromJson(json);
      if (await _queue.hasPendingFor(server.id)) {
        skipped++;
        continue;
      }
      final local = await _db.tasksDao.getTaskById(server.id);
      if (local != null && server.updatedAt <= local.updatedAt) {
        skipped++;
        continue;
      }
      await _db.tasksDao.upsertTask(server);
      tasksApplied++;
    }

    await _db.writeMeta(
      lastPullCursorKey,
      response.serverTimeMillis.toString(),
    );
    return PullOutcome(
      projectsApplied: projectsApplied,
      tasksApplied: tasksApplied,
      skipped: skipped,
      serverTimeMillis: response.serverTimeMillis,
    );
  }

  // ---------------------------------------------------------------------------
  // Orchestration
  // ---------------------------------------------------------------------------

  @override
  Future<SyncOutcome> syncNow() async {
    final outcome = await pushPending();
    if (outcome.error != null) {
      // Transport is dead — the pull would only fail the same way.
      return outcome;
    }
    try {
      await pullSince();
    } on AppException catch (error) {
      return SyncOutcome(
        mutationsSent: outcome.mutationsSent,
        applied: outcome.applied,
        conflictsResolved: outcome.conflictsResolved,
        rejected: outcome.rejected,
        failed: outcome.failed,
        retryAfter: outcome.retryAfter,
        error: error,
      );
    }
    return outcome;
  }

  @override
  Future<SyncOutcome> retryFailed() async {
    await _queue.resetFailures();
    return pushPending();
  }

  @override
  Future<int> queuedMutationCount() async =>
      (await _queue.queuedMutations()).length;

  @override
  Future<List<MutationRecord>> queuedMutations() => _queue.queuedMutations();

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Parses a wire record, mapping shape errors to a malformed response.
  T _parseOrMalformed<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) parse,
  ) {
    try {
      return parse(json);
    } on FormatException catch (error, stackTrace) {
      throw MalformedResponseException(cause: error, stackTrace: stackTrace);
    } on TypeError catch (error, stackTrace) {
      throw MalformedResponseException(cause: error, stackTrace: stackTrace);
    }
  }

  /// Parses a project wire record with malformed-response mapping.
  Project _parseProject(Map<String, dynamic> json) =>
      _parseOrMalformed(json, Project.fromJson);

  /// Parses a task wire record with malformed-response mapping.
  Task _parseTask(Map<String, dynamic> json) =>
      _parseOrMalformed(json, Task.fromJson);
}
