import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// SPEC-48 D8 — the snackbar layer is gone, and stays gone.
///
/// A convention ("post to the StatusCenter instead") loses to the path of least
/// resistance: `ScaffoldMessenger.of(context).showSnackBar(...)` is three words
/// of muscle memory, and the 73rd inline snackbar would land in the next PR that
/// needed to tell the user something. It would also be *invisible* — a message
/// that is not on the record cannot be copied, re-read, or filed in a bug report,
/// which is the whole complaint this feature answers.
///
/// `ScaffoldMessenger` itself is not banned (the framework mounts one, and
/// `MaterialApp` needs it); the **call** is.
void main() {
  test('no lib/ file calls showSnackBar — post to the StatusCenter instead', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('showSnackBar')) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use `ref.status.failure(...)` / `.success(...)` / `.info(...)` '
          '(lib/status/status_providers.dart) so the message lands on the '
          'Activity record and can be copied. Offenders:\n'
          '${offenders.join('\n')}',
    );
  });
}
