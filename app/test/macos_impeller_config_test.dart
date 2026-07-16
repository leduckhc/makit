import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// macOS must ship with Impeller enabled so release builds do not fall back
/// to Skia. Flutter reads `FLTEnableImpeller` from Runner/Info.plist.
/// See https://docs.flutter.dev/perf/impeller#macos
void main() {
  test('macOS Info.plist enables Impeller', () {
    final plist = File('macos/Runner/Info.plist');
    expect(plist.existsSync(), isTrue, reason: 'missing ${plist.path}');

    final xml = plist.readAsStringSync();
    expect(
      xml.contains('<key>FLTEnableImpeller</key>'),
      isTrue,
      reason: 'FLTEnableImpeller key missing from macOS Info.plist',
    );

    // Key must be followed by a true bool (allow whitespace / self-close).
    final enabled = RegExp(
      r'<key>FLTEnableImpeller</key>\s*<true\s*/>',
    ).hasMatch(xml);
    expect(enabled, isTrue, reason: 'FLTEnableImpeller must be <true/>');
  });
}
