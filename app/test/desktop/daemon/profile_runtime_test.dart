// Tests for the profile-switch sequence (SPEC-50 D10).
//
// `verifyThenHandOver` is the safety property of a switch: the target must be
// confirmed *answering* before anything is torn down, so a target that cannot
// come up leaves the window exactly as it was. The irreversible half — building
// the new runtime, swapping the ProviderScope, disposing the old graph — is
// injected as `handOver`, so these tests can assert the thing that matters:
// whether it is called at all.
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_lifecycle.dart';
import 'package:makit/desktop/daemon/profile_runtime.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';
import 'package:makit/desktop/daemon/server_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoWriteFs extends FileSystemAdapter {
  @override
  String? readOrNull(String path) => null;
  @override
  void writeAtomic(String path, String contents) {}
  @override
  T withLock<T>(String path, T Function() body) => body();
}

ProfileRegistry _registry() => ProfileRegistry(
  makitRoot: '/h/.makit',
  fs: _NoWriteFs(),
  profiles: const [_target],
);

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

const ServerProfile _target = ServerProfile(
  id: 'personal',
  name: 'Personal',
  kind: ProfileKind.user,
  home: '/h/.makit/profiles/personal',
  port: 7805,
  storage: ProfileStorage.namespaced,
);

MakitCliResolver _resolver() => MakitCliResolver(
  candidatePaths: const [],
  exists: (_) => false,
  shellLookup: () async => '/usr/local/bin/makit',
);

/// A lifecycle whose liveness answers come from [answers], consumed in order, so
/// a test can say "down, then up after the start".
ProfileLifecycle _lifecycle({
  required List<bool> answers,
  int startExit = 0,
  String startStdout = '',
  List<String>? spawned,
}) {
  final queue = [...answers];
  return ProfileLifecycle(
    resolver: _resolver(),
    run: (exe, args, {environment}) async {
      spawned?.addAll(args);
      return ProcessResult(0, startExit, startStdout, '');
    },
    socketExists: (_) => true,
    statusProbe: (_) async => queue.isEmpty ? false : queue.removeAt(0),
    sleep: (_) async {},
  );
}

void main() {
  group('verifyThenHandOver', () {
    test('hands over without starting an already-running target', () async {
      final spawned = <String>[];
      var handedOver = 0;
      final failure = await verifyThenHandOver(
        target: _target,
        lifecycle: _lifecycle(answers: [true], spawned: spawned),
        handOver: () async => handedOver++,
      );

      expect(failure, isNull);
      expect(handedOver, 1);
      expect(spawned, isEmpty, reason: 'a running target must not be started');
    });

    test('starts a stopped target, then hands over', () async {
      final spawned = <String>[];
      var handedOver = 0;
      final failure = await verifyThenHandOver(
        target: _target,
        // down, then up once started
        lifecycle: _lifecycle(answers: [false, true], spawned: spawned),
        handOver: () async => handedOver++,
      );

      expect(failure, isNull);
      expect(handedOver, 1);
      expect(spawned, contains('start'));
    });

    // The property the whole design exists for: a target that will not start must
    // leave the current profile untouched.
    test('does NOT hand over when the target refuses to start', () async {
      var handedOver = 0;
      final failure = await verifyThenHandOver(
        target: _target,
        lifecycle: _lifecycle(
          answers: [false],
          startExit: 1,
          startStdout: 'makit: failed to start — no response within 3000ms',
        ),
        handOver: () async => handedOver++,
      );

      expect(handedOver, 0, reason: 'the window was torn down on a failure');
      expect(failure, isNotNull);
      expect(failure, contains('failed to start'));
    });

    // The subtler failure: `makit start` exits 0 but nothing is listening. Taking
    // exit 0 as proof would hand the window to a dead server.
    test('does NOT hand over when a started target never answers', () async {
      var handedOver = 0;
      final failure = await verifyThenHandOver(
        target: _target,
        lifecycle: _lifecycle(answers: [false, false]),
        handOver: () async => handedOver++,
      );

      expect(handedOver, 0);
      expect(failure, contains('not answering'));
      expect(failure, contains('Personal'));
    });

    test('a failure names the profile, so the report is actionable', () async {
      final failure = await verifyThenHandOver(
        target: _target,
        lifecycle: _lifecycle(answers: [false], startExit: 1),
        handOver: () async {},
      );
      expect(failure, contains('Personal'));
    });

    test('hands over exactly once', () async {
      var handedOver = 0;
      await verifyThenHandOver(
        target: _target,
        lifecycle: _lifecycle(answers: [true, true, true]),
        handOver: () async => handedOver++,
      );
      expect(handedOver, 1);
    });
  });

  group('ProfileRuntime', () {
    test('exposes per-profile objects wired to the profile', () async {
      // A real runtime, but nothing is started: create() is synchronous and must
      // not touch the network or the daemon.
      final runtime = ProfileRuntime.create(
        profile: _target,
        registry: _registry(),
        prefs: await _prefs(),
      );
      addTearDown(runtime.dispose);

      expect(runtime.profile, _target);
      expect(runtime.configController.current.port, _target.port);
      // The deleter must consider THIS profile active, or a window could delete
      // the profile it is using.
      expect(
        runtime.profileDeleter.activeProfileId,
        _target.id,
        reason: 'the runtime must protect its own profile from deletion',
      );
      expect(runtime.profilesController.activeProfileId, _target.id);
    });

    test('dispose is safe on a runtime that never connected', () async {
      final runtime = ProfileRuntime.create(
        profile: _target,
        registry: _registry(),
        prefs: await _prefs(),
      );
      await expectLater(runtime.dispose(), completes);
    });

    test('dispose disposes the profilesController (no leak per switch)', () async {
      // profilesController is injected via overrideWithValue, which Riverpod does
      // not dispose, so the runtime must. A disposed ChangeNotifier throws when a
      // listener is added.
      final runtime = ProfileRuntime.create(
        profile: _target,
        registry: _registry(),
        prefs: await _prefs(),
      );
      await runtime.dispose();
      expect(
        () => runtime.profilesController.addListener(() {}),
        throwsA(isA<FlutterError>()),
      );
    });
  });
}
