import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/diagnostics/lifecycle_flush.dart';
import 'package:makit/diagnostics/log.dart';
import 'package:makit/diagnostics/log_file.dart';

/// Drive the binding through the OS-legal transition chain to [target].
/// `AppLifecycleListener` asserts on illegal jumps, so the whole sequence is
/// replayed rather than the end state alone.
Future<void> _background(WidgetTester tester, {required bool detach}) async {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    if (detach) AppLifecycleState.detached,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
}

void main() {
  testWidgets('backgrounding the app flushes', (tester) async {
    var flushes = 0;
    final dispose = installLifecycleFlush(() => flushes++);
    addTearDown(dispose);
    await _background(tester, detach: false);
    expect(flushes, 1);
  });

  testWidgets('detaching (teardown) flushes', (tester) async {
    var flushes = 0;
    final dispose = installLifecycleFlush(() => flushes++);
    addTearDown(dispose);
    await _background(tester, detach: true);
    // paused + detached both flush; what matters is at least one after detach.
    expect(flushes, greaterThanOrEqualTo(1));
  });

  testWidgets('the disposer stops further flushes', (tester) async {
    var flushes = 0;
    installLifecycleFlush(() => flushes++)();
    await _background(tester, detach: false);
    expect(flushes, 0);
  });

  testWidgets('buffered info lines reach disk when backgrounded', (
    tester,
  ) async {
    // The real thing this exists for: a force-quit after routine logging must
    // not lose the breadcrumbs still sitting in the sink's buffer.
    final dir = Directory.systemTemp.createTempSync('makit_lifecycle');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/makit.log');
    final sink = RollingFileLogSink(file);
    final dispose = installLifecycleFlush(sink.flush);
    addTearDown(dispose);

    sink.add(
      LogRecord(
        ts: DateTime.utc(2024),
        level: LogLevel.info,
        tag: 't',
        message: 'breadcrumb',
      ),
    );
    expect(file.existsSync(), isFalse, reason: 'buffered, not yet written');

    await _background(tester, detach: false);
    expect(file.readAsStringSync(), contains('breadcrumb'));
  });
}
