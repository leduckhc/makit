// Unit tests for the daemon lifecycle service. Lives beside the code under test
// (per SPEC-03 desktop layout), so it imports the flutter_test dev-dependency
// from a lib/ path.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pino/desktop/daemon/daemon_lifecycle.dart';

ProcessResult _exit(int code, {String out = '', String err = ''}) =>
    ProcessResult(0, code, out, err);

void main() {
  group('PinoCliResolver', () {
    test('returns the first existing candidate path', () async {
      final resolver = PinoCliResolver(
        candidatePaths: ['/a/pino', '/b/pino', '/c/pino'],
        exists: (p) => p == '/b/pino',
        shellLookup: () async => fail('shell lookup should not run'),
      );
      expect(await resolver.resolve(), '/b/pino');
    });

    test(
      'falls back to the login-shell lookup when no candidate exists',
      () async {
        final resolver = PinoCliResolver(
          candidatePaths: ['/a/pino'],
          exists: (_) => false,
          shellLookup: () async => '/opt/homebrew/bin/pino',
        );
        expect(await resolver.resolve(), '/opt/homebrew/bin/pino');
      },
    );

    test('returns null when nothing is found', () async {
      final resolver = PinoCliResolver(
        candidatePaths: ['/a/pino'],
        exists: (_) => false,
        shellLookup: () async => null,
      );
      expect(await resolver.resolve(), isNull);
    });
  });

  group('DaemonLifecycle', () {
    late List<List<String>> calls;
    PinoCliResolver resolverReturning(String? path) => PinoCliResolver(
      candidatePaths: path == null ? const [] : [path],
      exists: (p) => p == path,
      shellLookup: () async => null,
    );

    setUp(() => calls = []);

    DaemonLifecycle build({
      String? cliPath = '/usr/local/bin/pino',
      ProcessResult Function(String exe, List<String> args)? onRun,
    }) {
      return DaemonLifecycle(
        resolver: resolverReturning(cliPath),
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return (onRun ?? (_, _) => _exit(0))(exe, args);
        },
      );
    }

    test('start runs `pino start` and reports started', () async {
      final result = await build().start();
      expect(result.outcome, DaemonActionOutcome.started);
      expect(result.ok, isTrue);
      expect(calls.single, ['/usr/local/bin/pino', 'start']);
    });

    test('stop runs `pino stop`', () async {
      final result = await build().stop();
      expect(result.outcome, DaemonActionOutcome.stopped);
      expect(calls.single, ['/usr/local/bin/pino', 'stop']);
    });

    test('restart runs `pino restart`', () async {
      final result = await build().restart();
      expect(result.outcome, DaemonActionOutcome.restarted);
      expect(calls.single, ['/usr/local/bin/pino', 'restart']);
    });

    test('reports cliNotFound when the CLI cannot be located', () async {
      final result = await build(cliPath: null).start();
      expect(result.outcome, DaemonActionOutcome.cliNotFound);
      expect(result.ok, isFalse);
      expect(calls, isEmpty);
    });

    test('reports failed with stderr when the CLI exits non-zero', () async {
      final result = await build(
        onRun: (_, _) => _exit(1, err: 'boom'),
      ).start();
      expect(result.outcome, DaemonActionOutcome.failed);
      expect(result.ok, isFalse);
      expect(result.message, contains('boom'));
    });

    test('reports failed when spawning throws', () async {
      final lifecycle = DaemonLifecycle(
        resolver: resolverReturning('/usr/local/bin/pino'),
        run: (_, _) async => throw const ProcessException('pino', ['start']),
      );
      final result = await lifecycle.start();
      expect(result.outcome, DaemonActionOutcome.failed);
    });
  });
}
