// Golden "screenshots" of the M3 IDE-launcher split button. Run with:
//   flutter test --update-goldens test/desktop/chat/open_in_ide_golden_test.dart
// to (re)generate the PNGs under goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/open_in_ide.dart';

Widget _scene(Brightness brightness) => ProviderScope(
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF6750A4),
      brightness: brightness,
    ),
    home: Builder(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        // Mimic the title strip surface the button actually sits on.
        return Scaffold(
          backgroundColor: cs.surfaceContainer,
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: OpenInIdeButton(path: '/repo/feature-branch'),
            ),
          ),
        );
      },
    ),
  ),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Load the Phosphor icon font so the caret renders as its glyph rather than
    // a missing-glyph box in the headless test engine.
    final ttf = File(
      '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/'
      'phosphoricons_flutter-1.0.0/lib/fonts/Phosphor-Light.ttf',
    );
    if (ttf.existsSync()) {
      final loader = FontLoader('packages/phosphoricons_flutter/PhosphorLight')
        ..addFont(Future.value(ttf.readAsBytesSync().buffer.asByteData()));
      await loader.load();
    }
  });

  // Golden tests are platform-dependent: macOS (where these were generated)
  // rasterizes fonts/shaders differently than the Linux CI runner, producing
  // sub-pixel diffs. Restrict them to macOS so CI stays green; regenerate with:
  //   flutter test --update-goldens test/desktop/chat/open_in_ide_golden_test.dart
  final skipOffMac = !Platform.isMacOS;

  testWidgets('split button — light', (tester) async {
    tester.view.devicePixelRatio = 3;
    await tester.pumpWidget(_scene(Brightness.light));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(OpenInIdeButton),
      matchesGoldenFile('goldens/ide_launcher_light.png'),
    );
  }, skip: skipOffMac);

  testWidgets('split button — dark', (tester) async {
    tester.view.devicePixelRatio = 3;
    await tester.pumpWidget(_scene(Brightness.dark));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(OpenInIdeButton),
      matchesGoldenFile('goldens/ide_launcher_dark.png'),
    );
  }, skip: skipOffMac);

  testWidgets('split button — menu open', (tester) async {
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(_scene(Brightness.light));
    // Tap the CARET, not the action. This used to tap `InkWell.first` — the
    // primary segment — so the menu never opened and this golden froze a button
    // snapshot under a name that promised a menu. It also meant the menu's
    // appearance (including SPEC-30 decision 11's target header) was untested.
    await tester.tap(find.byTooltip('Choose editor'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/ide_launcher_menu.png'),
    );
  }, skip: skipOffMac);
}
