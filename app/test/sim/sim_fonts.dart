/// Font loading shared by the audit harnesses in this directory.
///
/// Without this the headless engine falls back to Ahem and every glyph
/// rasterises as a black box, which makes an audit image worthless. Kept here
/// so a new harness does not have to re-derive the list (and the non-obvious
/// `kMonoFontFamily` binding) from scratch.
library;

import 'dart:io';

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

/// Registers the real system + Phosphor faces the app asks for. Call from
/// `setUpAll`. Silently skips a face that is not on this machine, so the
/// harness still runs (with worse images) off a developer Mac.
Future<void> loadSimFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> bind(String path, List<String> families) async {
    final file = File(path);
    if (!file.existsSync()) return;
    final bytes = file.readAsBytesSync().buffer.asByteData();
    for (final family in families) {
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
  }

  // `kSansFontFamily` plus the two names Flutter's default text theme asks for.
  await bind('/System/Library/Fonts/SFNS.ttf', [
    'SF Pro Text',
    'Roboto',
    '.SF NS',
  ]);
  // `kMonoFontFamily` is the literal 'monospace', which the headless engine does
  // NOT resolve — every port number and command would be an Ahem box.
  await bind('/System/Library/Fonts/SFNSMono.ttf', [
    'monospace',
    'SF Mono',
    'Menlo',
  ]);
  for (final weight in ['Light', 'Regular', 'Bold']) {
    await bind(
      '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/'
      'phosphoricons_flutter-1.0.0/lib/fonts/Phosphor-$weight.ttf',
      ['packages/phosphoricons_flutter/Phosphor$weight'],
    );
  }
}

/// True when audit goldens must be skipped: they are anchored to the real clock
/// (so ages read sensibly) and rasterise differently off macOS, so they are a
/// deliberate audit tool rather than a regression gate.
///
///   PORTS_AUDIT=1 flutter test --no-pub --update-goldens test/sim/
bool get skipSimAudit =>
    !Platform.isMacOS || Platform.environment['PORTS_AUDIT'] == null;
