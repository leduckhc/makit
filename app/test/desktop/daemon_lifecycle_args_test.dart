import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';

/// Verifies host/port are forwarded to the `makit` CLI. (The broader lifecycle
/// suite lives beside the code in `lib/desktop/daemon/`, which `flutter test`
/// does not run; this endpoint-forwarding behavior is exercised here so CI
/// covers it.)
void main() {
  late List<List<String>> calls;

  DaemonLifecycle build() => DaemonLifecycle(
        resolver: MakitCliResolver(
          candidatePaths: const ['/usr/local/bin/makit'],
          exists: (p) => p == '/usr/local/bin/makit',
          shellLookup: () async => null,
        ),
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
      );

  setUp(() => calls = []);

  test('start forwards --host and --port when provided', () async {
    await build().start(host: '127.0.0.1', port: 9000);
    expect(calls.single, [
      '/usr/local/bin/makit',
      'start',
      '--host',
      '127.0.0.1',
      '--port',
      '9000',
    ]);
  });

  test('restart forwards --host and --port when provided', () async {
    await build().restart(host: 'localhost', port: 8801);
    expect(calls.single, [
      '/usr/local/bin/makit',
      'restart',
      '--host',
      'localhost',
      '--port',
      '8801',
    ]);
  });

  test('start omits flags when host/port are absent', () async {
    await build().start();
    expect(calls.single, ['/usr/local/bin/makit', 'start']);
  });
}
