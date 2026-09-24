import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/errors/error_mapper.dart';
import 'sync_wire_types.dart';

/// Thin Dio-based client for the sync protocol.
///
/// Responsibilities: apply the [AppConfig] timeouts, serialize / parse the
/// wire types, and translate every transport or parsing failure into an
/// [AppException] — repositories and the sync engine never see a
/// `DioException`.
class SyncApiClient {
  /// Creates a client pointed at [baseUrl] (the mock server's address in
  /// the app wiring, any address in tests).
  SyncApiClient({required String baseUrl, required AppConfig config, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: config.connectTimeout,
              sendTimeout: config.connectTimeout,
              receiveTimeout: config.receiveTimeout,
              responseType: ResponseType.json,
              headers: {'content-type': 'application/json'},
            ),
          );

  final Dio _dio;

  /// Fetches every record changed since [sinceMillis].
  ///
  /// Throws [NetworkException]/[TimeoutException]/[ServerException] on
  /// transport problems and [MalformedResponseException] when the body does
  /// not match the protocol.
  Future<PullResponse> pull({required int sinceMillis}) async {
    try {
      final response = await _dio.get<dynamic>(
        '/sync/pull',
        queryParameters: <String, dynamic>{'since': sinceMillis},
      );
      return PullResponse.fromJson(_bodyMap(response.data));
    } on DioException catch (error, stackTrace) {
      throw ErrorMapper.map(error, stackTrace: stackTrace);
    } on FormatException catch (error, stackTrace) {
      throw MalformedResponseException(cause: error, stackTrace: stackTrace);
    } on TypeError catch (error, stackTrace) {
      throw MalformedResponseException(cause: error, stackTrace: stackTrace);
    }
  }

  /// Pushes a batch of queued mutations and returns the per-item results.
  ///
  /// Same error contract as [pull]. A transport failure throws for the
  /// whole batch (the engine marks every entry attempted and schedules a
  /// backoff retry).
  Future<List<PushResultItem>> push(List<PushMutation> mutations) async {
    if (mutations.isEmpty) return const <PushResultItem>[];
    try {
      final response = await _dio.post<dynamic>(
        '/sync/push',
        data: <String, dynamic>{
          'mutations': [for (final mutation in mutations) mutation.toJson()],
        },
      );
      final body = _bodyMap(response.data);
      final rawResults = body['results'];
      if (rawResults is! List) {
        throw const FormatException('Push response is missing "results".');
      }
      return [
        for (final item in rawResults)
          if (item is Map<String, dynamic>)
            PushResultItem.fromJson(item)
          else
            throw const FormatException('Push result entry is malformed.'),
      ];
    } on DioException catch (error, stackTrace) {
      throw ErrorMapper.map(error, stackTrace: stackTrace);
    } on FormatException catch (error, stackTrace) {
      throw MalformedResponseException(cause: error, stackTrace: stackTrace);
    } on TypeError catch (error, stackTrace) {
      throw MalformedResponseException(cause: error, stackTrace: stackTrace);
    }
  }

  /// Validates that [data] is a JSON object, else reports it as malformed.
  static Map<String, dynamic> _bodyMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.trim().isNotEmpty) {
      // Some transports hand the body over as text; decode once.
      final decoded = const JsonDecoder().convert(data);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    throw const FormatException('Response body is not a JSON object.');
  }
}
