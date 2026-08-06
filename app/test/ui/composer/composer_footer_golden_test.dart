// Golden "screenshot" of the SPEC-40 composer footer. Run:
//   flutter test --update-goldens test/ui/composer/composer_footer_golden_test.dart
// to (re)generate the PNGs under goldens/.
//
// Worth a golden rather than only assertions: the whole change is about how much
// of a label survives, and "185pt of a wanted 187.5pt" is not something a reader
// of a test can picture. The image shows a pi footer reading `Claude Opus 4.6`
// where it used to read `anthropic/Cl…`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:makit/ui/composer/composer_selectors.dart';
import 'package:makit/ui/composer/context_usage.dart';

void _noop(String _) {}

/// The option names `pi-acp` really sends: `${provider}/${name}`.
const _model = 'anthropic/Claude Opus 4.6';

SessionConfigOption _select(
  String id,
  String category,
  String current,
  List<String> values,
) => SessionConfigOption(
  id: id,
  name: id,
  category: category,
  type: ConfigOptionType.select,
  currentValue: current,
  options: [for (final v in values) ConfigOptionValue(value: v, name: v)],
);

ProviderContainer _container(List<SessionConfigOption> options) =>
    ProviderContainer(
      overrides: [
        sessionMetaProvider('s1').overrideWithValue(
          SessionMeta(thinking: '', models: const [], configOptions: options),
        ),
        sessionsProvider.overrideWithValue(
          SessionsState([
            Session(
              id: 's1',
              projectId: 'p1',
              agent: 'pi',
              title: 'T',
              status: SessionStatus.idle,
              policy: ApprovalPolicy.askOnRisky,
              lastPreview: '',
              lastActivityAt: 0,
            ),
          ]),
        ),
        // Seeded, or the ring renders nothing and the golden shows a footer
        // that never occurs in practice.
        sessionUsageProvider('s1').overrideWithValue(
          const SessionUsage(
            contextTokens: 288000,
            contextWindow: 1000000,
            measuredAt: 1,
          ),
        ),
      ],
    );

void main() {
  // Text goldens are platform-dependent (macOS rasterizes glyphs differently
  // than the Linux CI runner), same convention as the SPEC-37 goldens.
  final skipOffMac = !Platform.isMacOS;

  for (final (name, width, options) in <(String, double, List<SessionConfigOption>)>[
    // 393pt is the iPhone 15/16/17 width; the label fits whole there.
    (
      'pi_393',
      393,
      [
        _select('model', 'model', _model, [_model]),
        _select('thought_level', 'thought_level', 'high', ['off', 'high']),
      ],
    ),
    // 375pt (SE/mini) is the tightest supported phone: the chips yield and the
    // name clips by a single character.
    (
      'pi_375',
      375,
      [
        _select('model', 'model', _model, [_model]),
        _select('thought_level', 'thought_level', 'high', ['off', 'high']),
      ],
    ),
    // A wide pane keeps every chip — nothing is hidden for free.
    (
      'codex_700',
      700,
      [
        _select('model', 'model', 'gpt-5.6-codex', ['gpt-5.6-codex']),
        _select('thought_level', 'thought_level', 'high', ['off', 'high']),
        _select('context', 'model_config', '256k', ['128k', '256k']),
      ],
    ),
  ]) {
    testWidgets('footer — $name', (tester) async {
      // physicalSize is in PHYSICAL pixels, so it must be scaled by the DPR.
      tester.view.physicalSize = Size(width * 3, 200 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final c = _container(options);
      addTearDown(c.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: makitDarkTheme,
            home: Builder(
              builder: (context) => Scaffold(
                backgroundColor: Theme.of(context).colorScheme.surface,
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: const Composer(
                      onSend: _noop,
                      alwaysExpanded: true,
                      footerActions: [
                        ComposerConfigOptions(sessionId: 's1'),
                      ],
                      footerTrailing: ContextUsageButton(
                        sessionId: 's1',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(Composer),
        matchesGoldenFile('goldens/spec40_footer_$name.png'),
      );
    }, skip: skipOffMac);
  }
}
