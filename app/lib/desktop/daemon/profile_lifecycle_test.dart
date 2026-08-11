// Unit tests for [ProfileLifecycle] (SPEC-50 P3, D7/D8).
// Co-located with the code under test (per SPEC-03 desktop layout).
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_lifecycle.dart';
import 'package:makit/desktop/daemon/server_profile.dart';

ServerProfile _profile({
  String id = 'work',
  String home = '/home/.makit/profiles/work',
}) => ServerProfile(
  id: id,
  name: 'Work',
  kind: ProfileKind.user,
  home: home,
  port: 7801,
  storage: ProfileStorage.namespaced,
);

/// Records every spawn so tests can assert the verb and the environment.
class _RecordingRunner {
  final List<({String exe, List<String> args, Map<String, String>? env})>
  calls = [];
  ProcessResult result = ProcessResult(0, 0, '', '');

  Future<ProcessResult> run(
    String exe,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    calls.add((exe: exe, args: args, env: environment));
    return result;
  }
}

MakitCliResolver _resolver({String? path = '/usr/local/bin/makit'}) =>
    MakitCliResolver(
      candidatePaths: const [],
      exists: (_) => false,
      shellLookup: () async => path,
    );

void main() {
  group('ProfileLifecycle.start/stop', () {
    test('start runs `makit start` with the profile MAKIT_HOME', () async {
      final runner = _RecordingRunner();
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(),
        run: runner.run,
      );

      final result = await lifecycle.start(_profile());

      expect(result.outcome, DaemonActionOutcome.started);
      expect(runner.calls.single.exe, '/usr/local/bin/makit');
      expect(runner.calls.single.args, ['start']);
      expect(runner.calls.single.env, {
        'MAKIT_HOME': '/home/.makit/profiles/work',
      });
    });

    test('stop runs `makit stop` with the profile MAKIT_HOME', () async {
      final runner = _RecordingRunner();
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(),
        run: runner.run,
      );

      final result = await lifecycle.stop(_profile());

      expect(result.outcome, DaemonActionOutcome.stopped);
      expect(runner.calls.single.args, ['stop']);
      expect(runner.calls.single.env, {
        'MAKIT_HOME': '/home/.makit/profiles/work',
      });
    });

    test('reports cliNotFound when the CLI cannot be resolved', () async {
      final runner = _RecordingRunner();
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(path: null),
        run: runner.run,
      );

      final result = await lifecycle.start(_profile());

      expect(result.outcome, DaemonActionOutcome.cliNotFound);
      expect(runner.calls, isEmpty);
    });

    test('reports failed with both streams on a non-zero exit', () async {
      final runner = _RecordingRunner()
        ..result = ProcessResult(0, 1, 'port in use', 'bind failed');
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(),
        run: runner.run,
      );

      final result = await lifecycle.start(_profile());

      expect(result.outcome, DaemonActionOutcome.failed);
      expect(result.message, contains('bind failed'));
      expect(result.message, contains('port in use'));
    });
  });

  group('ProfileLifecycle.isRunning', () {
    test(
      'false when the control socket is absent (no probe attempted)',
      () async {
        var probed = false;
        final lifecycle = ProfileLifecycle(
          resolver: _resolver(),
          run: _RecordingRunner().run,
          socketExists: (_) => false,
          statusProbe: (_) async {
            probed = true;
            return true;
          },
        );

        expect(await lifecycle.isRunning(_profile()), isFalse);
        expect(probed, isFalse);
      },
    );

    test(
      'false when the socket exists but the probe fails (stale socket)',
      () async {
        final lifecycle = ProfileLifecycle(
          resolver: _resolver(),
          run: _RecordingRunner().run,
          socketExists: (_) => true,
          statusProbe: (_) async => false,
        );

        expect(await lifecycle.isRunning(_profile()), isFalse);
      },
    );

    test('true when the socket exists and the probe succeeds', () async {
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(),
        run: _RecordingRunner().run,
        socketExists: (_) => true,
        statusProbe: (_) async => true,
      );

      expect(await lifecycle.isRunning(_profile()), isTrue);
    });
  });

  group('ProfileLifecycle.stopAndConfirm', () {
    test('returns true once the socket disappears after stop', () async {
      final runner = _RecordingRunner();
      var polls = 0;
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(),
        run: runner.run,
        // Present for the first two checks, then gone.
        socketExists: (_) => polls++ < 2,
        sleep: (_) async {},
      );

      final ok = await lifecycle.stopAndConfirm(
        _profile(),
        timeout: const Duration(seconds: 1),
      );

      expect(ok, isTrue);
      expect(runner.calls.single.args, ['stop']);
    });

    test(
      'returns false only while a daemon is genuinely still listening',
      () async {
        // Socket present AND the probe answers: a live daemon that ignored the
        // stop. Nothing may be unlinked under it.
        final lifecycle = ProfileLifecycle(
          resolver: _resolver(),
          run: _RecordingRunner().run,
          socketExists: (_) => true,
          statusProbe: (_) async => true,
          sleep: (_) async {},
        );

        final ok = await lifecycle.stopAndConfirm(
          _profile(),
          timeout: const Duration(milliseconds: 100),
        );

        expect(ok, isFalse);
      },
    );

    // The orphan case, and the reason D9 exists at all. A daemon killed with
    // SIGKILL never unlinks its control socket, and `makit stop` on an already
    // dead daemon removes only the pid file -- verified against the real binary:
    // after SIGKILL, `makit stop` prints "not running" and control.sock REMAINS.
    // Polling the socket file alone therefore reported every crashed profile as
    // still running, so ProfileDeleter refused it forever and the 27 orphans in
    // the spec's evidence could never be reclaimed.
    test('treats a stale socket with no listener as stopped', () async {
      var probes = 0;
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(),
        run: _RecordingRunner().run,
        // The socket file never goes away...
        socketExists: (_) => true,
        // ...but nothing is listening on it.
        statusProbe: (_) async {
          probes++;
          return false;
        },
        sleep: (_) async {},
      );

      final ok = await lifecycle.stopAndConfirm(
        _profile(),
        timeout: const Duration(seconds: 5),
      );

      expect(ok, isTrue, reason: 'a dead daemon must not block a delete');
      // And it must not have burned the whole timeout to work that out.
      expect(probes, lessThanOrEqualTo(2));
    });

    test(
      'waits for the daemon PID to exit, not just the control socket',
      () async {
        // The SIGTERM handler closes the socket ~100ms before the process
        // actually exits. Confirming on the socket alone would greenlight a
        // delete while the daemon is still alive and may still be writing
        // makit.db-wal (SPEC-50 D8).
        var aliveChecks = 0;
        final lifecycle = ProfileLifecycle(
          resolver: _resolver(),
          run: _RecordingRunner().run,
          socketExists: (_) => false, // socket already gone
          readPid: (_) => 4242,
          // Alive for the first two polls, then the process exits.
          processAlive: (pid) {
            expect(pid, 4242);
            return aliveChecks++ < 2;
          },
          sleep: (_) async {},
        );

        final ok = await lifecycle.stopAndConfirm(
          _profile(),
          timeout: const Duration(seconds: 5),
        );

        expect(ok, isTrue);
        expect(
          aliveChecks,
          greaterThanOrEqualTo(3),
          reason: 'must poll the process, not stop at the socket',
        );
      },
    );

    test(
      'returns false when the process is still alive at the timeout',
      () async {
        final lifecycle = ProfileLifecycle(
          resolver: _resolver(),
          run: _RecordingRunner().run,
          socketExists: (_) => false, // socket gone...
          readPid: (_) => 99,
          processAlive: (_) => true, // ...but the process never exits
          sleep: (_) async {},
        );

        final ok = await lifecycle.stopAndConfirm(
          _profile(),
          timeout: const Duration(milliseconds: 100),
        );

        expect(ok, isFalse, reason: 'must not unlink under a live process');
      },
    );

    test('returns false when the stop command itself fails', () async {
      // A failed `makit stop` (or a missing CLI) means no shutdown was issued.
      // Combined with a stale/absent socket and no pid, the old code would have
      // returned true and let the delete proceed under a live daemon.
      final runner = _RecordingRunner()
        ..result = ProcessResult(0, 1, 'boom', 'bind failed');
      var probed = false;
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(),
        run: runner.run,
        socketExists: (_) {
          probed = true;
          return false;
        },
        readPid: (_) => null,
        sleep: (_) async {},
      );

      final ok = await lifecycle.stopAndConfirm(
        _profile(),
        timeout: const Duration(seconds: 5),
      );

      expect(ok, isFalse);
      expect(
        probed,
        isFalse,
        reason: 'must abort before probing on stop failure',
      );
    });

    test('returns false when the makit CLI cannot be found', () async {
      final lifecycle = ProfileLifecycle(
        resolver: _resolver(path: null),
        run: _RecordingRunner().run,
        socketExists: (_) => false,
        readPid: (_) => null,
        sleep: (_) async {},
      );

      final ok = await lifecycle.stopAndConfirm(
        _profile(),
        timeout: const Duration(seconds: 5),
      );

      expect(ok, isFalse);
    });
  });
}
