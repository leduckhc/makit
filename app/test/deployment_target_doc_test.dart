// Pins the supported-platform table in BUILD_AND_DEPLOY.md to the real floors.
//
// A deployment target lives inside project.pbxproj, where nobody reads it.
// BUILD_AND_DEPLOY.md repeats it as a table, and says this:
//   "Change this table in the same commit as any deployment-target change."
// Prose cannot enforce that. This test can.
//
// The gap is not hypothetical. The Flutter 3.47.0 bump (#167) ran
// `flutter build macos`, which raised the macOS floor to 12.0, and the table
// moved with it. Nobody ran `flutter build ios` in that sitting.
// The iOS migrator therefore fired later, on the next device build, and raised
// the iOS floor 13.0 to 15.0 while the table still promised 13.0.
// Support for two iOS majors disappeared with no record.
//
// See docs/FLUTTER-BUMP-HANDOUT.md section 11, cost 1.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tests run with the working directory at `app/`.
final _repoRoot = Directory.current.parent.path;

/// Reads the one deployment floor that [buildSetting] holds in [pbxprojPath].
///
/// Xcode repeats a build setting once per configuration (Debug, Release,
/// Profile). A single floor must therefore appear as one distinct value.
/// Two values mean one configuration escaped a migration, which ships a
/// different floor than the table claims for at least one build mode.
String _pbxprojFloor(String pbxprojPath, String buildSetting) {
  final file = File('$_repoRoot/$pbxprojPath');
  expect(file.existsSync(), isTrue, reason: 'missing $pbxprojPath');

  final matches = RegExp(
    '$buildSetting = ([0-9.]+);',
  ).allMatches(file.readAsStringSync()).map((m) => m.group(1)!).toSet();

  expect(
    matches,
    hasLength(1),
    reason: '$pbxprojPath must set one $buildSetting, found $matches',
  );
  return matches.single;
}

/// Reads the minimum that the BUILD_AND_DEPLOY.md table states for [platform].
///
/// The row shape is `| iOS | **13.0** | ... |`, so the bold cell is the claim.
String _documentedFloor(String platform) {
  final doc = File('$_repoRoot/BUILD_AND_DEPLOY.md');
  expect(doc.existsSync(), isTrue, reason: 'missing BUILD_AND_DEPLOY.md');

  final row = RegExp(
    r'^\|\s*' + platform + r'\s*\|\s*\*\*([0-9.]+)\*\*',
    multiLine: true,
  ).firstMatch(doc.readAsStringSync());

  expect(
    row,
    isNotNull,
    reason: 'BUILD_AND_DEPLOY.md has no supported-platform row for $platform',
  );
  return row!.group(1)!;
}

void main() {
  group('BUILD_AND_DEPLOY.md states the real deployment floor', () {
    test('iOS', () {
      expect(
        _documentedFloor('iOS'),
        _pbxprojFloor(
          'app/ios/Runner.xcodeproj/project.pbxproj',
          'IPHONEOS_DEPLOYMENT_TARGET',
        ),
        reason:
            'the table and the iOS project disagree. '
            'A Flutter bump migrated the project; update the table.',
      );
    });

    test('macOS', () {
      expect(
        _documentedFloor('macOS'),
        _pbxprojFloor(
          'app/macos/Runner.xcodeproj/project.pbxproj',
          'MACOSX_DEPLOYMENT_TARGET',
        ),
        reason:
            'the table and the macOS project disagree. '
            'A Flutter bump migrated the project; update the table.',
      );
    });
  });
}
