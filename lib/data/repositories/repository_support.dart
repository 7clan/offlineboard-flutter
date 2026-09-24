import 'dart:async';

import '../../core/errors/app_exception.dart';

/// Maps a raw repository-level failure to an [AppException].
///
/// Repository implementations sit on Drift/SQLite, so anything that is not
/// already an [AppException] is a local-storage failure by definition — raw
/// exceptions never cross the repository boundary.
AppException mapRepositoryError(Object error, [StackTrace? stackTrace]) {
  if (error is AppException) return error;
  return DatabaseException(cause: error, stackTrace: stackTrace);
}

/// Runs [action] with every raw failure mapped to a [DatabaseException].
Future<T> guardRepository<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on AppException {
    rethrow;
  } on Object catch (error, stackTrace) {
    throw mapRepositoryError(error, stackTrace);
  }
}

/// Re-emits [stream]'s errors as mapped [AppException]s.
///
/// Watch streams fail asynchronously (a Drift query erroring mid-listen);
/// this keeps the promise that widgets only ever see [AppException]s.
Stream<T> guardRepositoryStream<T>(Stream<T> stream) {
  return stream.transform(
    StreamTransformer<T, T>.fromHandlers(
      handleError: (Object error, StackTrace stackTrace, EventSink<T> sink) {
        sink.addError(mapRepositoryError(error, stackTrace));
      },
    ),
  );
}
