import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/diagnostics/error_capture.dart';
import 'package:makit/diagnostics/log.dart';

void main() {
  test(
    'describeFlutterError includes exception, context, library and stack',
    () {
      final details = FlutterErrorDetails(
        exception: StateError('_dependents.isEmpty is not true'),
        stack: StackTrace.fromString('#0 someFrame'),
        library: 'widgets library',
        context: ErrorDescription('during a deactivate'),
      );
      final msg = describeFlutterError(details);
      expect(msg, contains('_dependents.isEmpty is not true'));
      expect(msg, contains('during a deactivate'));
      expect(msg, contains('widgets library'));
      expect(msg, contains('someFrame'));
    },
  );

  test('installErrorCapture funnels a framework error into the log', () {
    final log = MakitLog(minLevel: LogLevel.debug);
    final restore = installErrorCapture(log);
    addTearDown(restore);

    FlutterError.reportError(
      FlutterErrorDetails(exception: Exception('boom in build')),
    );

    final rec = log.records.single;
    expect(rec.level, LogLevel.error);
    expect(rec.tag, 'flutter');
    expect(rec.message, contains('boom in build'));
  });

  test('the disposer restores the previous FlutterError handler', () {
    final captured = <FlutterErrorDetails>[];
    final prior = FlutterError.onError;
    FlutterError.onError = captured.add;
    addTearDown(() => FlutterError.onError = prior);

    final log = MakitLog(minLevel: LogLevel.debug);
    final restore = installErrorCapture(log);
    restore();

    FlutterError.reportError(FlutterErrorDetails(exception: Exception('x')));
    // Restored handler saw it; the log did not.
    expect(captured, hasLength(1));
    expect(log.records, isEmpty);
  });
}
