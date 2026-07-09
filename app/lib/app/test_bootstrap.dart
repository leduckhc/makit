import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _testHost = String.fromEnvironment('MAKIT_TEST_HOST');
const _testPort = String.fromEnvironment('MAKIT_TEST_PORT');
const _testBearer = String.fromEnvironment('MAKIT_TEST_BEARER');
const _testFingerprint = String.fromEnvironment('MAKIT_TEST_FP');

const _pairedServerKey = 'paired_server';
const _testServerLabel = 'e2e test server';

/// True when the app was launched under the E2E harness (MAKIT_TEST_* defines).
/// Used to skip side-effecting startup (e.g. requesting notification
/// permission, which pops a blocking system dialog on the simulator).
bool get isE2ETestMode => _testHost.isNotEmpty;

Future<void> seedTestPairingIfRequested({
  FlutterSecureStorage storage = const FlutterSecureStorage(),
}) async {
  if (_testHost.isEmpty) return;

  final port = int.tryParse(_testPort);
  if (port == null || port <= 0 || port > 65535) {
    throw StateError('MAKIT_TEST_PORT must be a valid TCP port');
  }
  if (_testBearer.isEmpty) {
    throw StateError(
      'MAKIT_TEST_BEARER must be non-empty when MAKIT_TEST_HOST is set',
    );
  }
  if (_testFingerprint.isEmpty) {
    throw StateError(
      'MAKIT_TEST_FP must be non-empty when MAKIT_TEST_HOST is set',
    );
  }

  await storage.write(
    key: _pairedServerKey,
    value: jsonEncode({
      'host': _testHost,
      'port': port,
      'fingerprint': _testFingerprint,
      'bearer': _testBearer,
      'label': _testServerLabel,
    }),
  );
}
