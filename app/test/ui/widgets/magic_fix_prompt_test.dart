// The magic "Fix" prompt (SPEC-pr-actions-next-step-bar §6.2): the preamble, then the problems as a
// checklist. The list is data, not wording — it must stay in precedence order and
// must not be overridable, while the preamble must be.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/ui/widgets/pr_actions.dart';
import 'package:makit/ui/widgets/pr_signals.dart';

/// Resolve the prompt for [status] through a real ref, with [overrides] applied.
Future<String> _prompt(
  WidgetTester tester,
  PrStatus status, {
  Map<String, Object?> overrides = const {},
}) async {
  late String out;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesControllerProvider.overrideWith(
          (ref) => PreferencesController(null, overrides),
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            out = ref.magicFixPrompt([
              for (final s in status.signals)
                if (s.remedy is PromptRemedy)
                  (label: s.label, detail: s.detail),
            ]);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return out;
}

PrStatus _busy() => prStatus(
  pr: const PullRequest(
    number: 42,
    url: '',
    state: 'OPEN',
    title: 't',
    isDraft: false,
    checkRollup: 'fail',
    unresolvedComments: 3,
    checks: [
      PrCheck(name: 'analyze', bucket: 'fail'),
      PrCheck(name: 'flutter test', bucket: 'fail'),
    ],
  ),
  branch: 'feat/x',
  uncommittedFiles: 2,
);

void main() {
  testWidgets('leads with the built-in preamble', (tester) async {
    expect(await _prompt(tester, _busy()), startsWith(kMagicFixPreamble));
  });

  testWidgets('lists every prompt-backed problem, one per line', (
    tester,
  ) async {
    final p = await _prompt(tester, _busy());
    expect(p, contains('- 2 files uncommitted'));
    expect(p, contains('- 2 checks failing'));
    expect(p, contains('- 3 threads open'));
  });

  testWidgets('carries the detail we already know, so it need not look it up', (
    tester,
  ) async {
    // Without this the agent has to rediscover which checks failed.
    expect(
      await _prompt(tester, _busy()),
      contains('- 2 checks failing (analyze · flutter test)'),
    );
  });

  testWidgets('keeps precedence order — commit before pull', (tester) async {
    // An unordered list invites a pull onto a dirty tree.
    final status = prStatus(
      pr: const PullRequest(
        number: 1,
        url: '',
        state: 'OPEN',
        title: 't',
        isDraft: false,
        checkRollup: 'pass',
      ),
      branch: 'feat/x',
      uncommittedFiles: 1,
      commitsBehind: 2,
    );
    final p = await _prompt(tester, status);
    expect(p.indexOf('uncommitted'), lessThan(p.indexOf('behind')));
  });

  testWidgets('omits facts you cannot act on', (tester) async {
    final status = prStatus(
      pr: const PullRequest(
        number: 1,
        url: '',
        state: 'OPEN',
        title: 't',
        isDraft: false,
        checkRollup: 'pending',
        checks: [
          PrCheck(name: 'a', bucket: 'pending'),
          PrCheck(name: 'b', bucket: 'pass'),
        ],
      ),
      branch: 'feat/x',
      uncommittedFiles: 1,
    );
    expect(await _prompt(tester, status), isNot(contains('still running')));
  });

  testWidgets('a Settings override replaces the preamble but not the list', (
    tester,
  ) async {
    final p = await _prompt(
      tester,
      _busy(),
      overrides: {prMagicFixPromptPreference.id: 'MY preamble'},
    );
    expect(p, startsWith('MY preamble'));
    expect(p, isNot(contains(kMagicFixPreamble)));
    expect(p, contains('- 3 threads open'), reason: 'the facts are data');
  });
}
