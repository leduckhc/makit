import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';

/// Verifies serve args are forwarded to the `makit` CLI and the CLI-path
/// override is honoured. (The broader lifecycle suite lives beside the code in
/// `lib/desktop/daemon/`, which `flutter test` does not run; this
/// arg-forwarding behavior is exercised here so CI covers it.)
void main() {
  late List<List<String>> calls;

  DaemonLifecycle build({String Function()? overridePath}) => DaemonLifecycle(
    resolver: MakitCliResolver(
      candidatePaths: const ['/usr/local/bin/makit'],
      exists: (p) =>
          p == '/usr/local/bin/makit' || p == '/opt/dev/makit',
      shellLookup: () async => null,
      overridePath: overridePath,
    ),
    run: (exe, args) async {
      calls.add([exe, ...args]);
      return ProcessResult(0, 0, '', '');
    },
  );

  setUp(() => calls = []);

  test('start forwards serveArgs verbatim after the verb', () async {
    await build().start(serveArgs: const ['--lan', '--port', '9000']);
    expect(calls.single, [
      '/usr/local/bin/makit',
      'start',
      '--lan',
      '--port',
      '9000',
    ]);
  });

  test('restart forwards serveArgs verbatim after the verb', () async {
    await build().restart(
      serveArgs: const ['--host', '127.0.0.1', '--port', '8801'],
    );
    expect(calls.single, [
      '/usr/local/bin/makit',
      'restart',
      '--host',
      '127.0.0.1',
      '--port',
      '8801',
    ]);
  });

  test('start omits serve args when none are given', () async {
    await build().start();
    expect(calls.single, ['/usr/local/bin/makit', 'start']);
  });

  test('an existing CLI-path override takes precedence over candidates', () async {
    await build(overridePath: () => '/opt/dev/makit').start();
    expect(calls.single.first, '/opt/dev/makit');
  });

  test('a missing CLI-path override falls back to auto-discovery', () async {
    await build(overridePath: () => '/nope/makit').start();
    expect(calls.single.first, '/usr/local/bin/makit');
  });
}
