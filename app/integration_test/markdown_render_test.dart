import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('assistant markdown reply renders headings, code + links', (
    tester,
  ) async {
    await launchPino(tester);
    await openFirstSession(tester);

    // The stub adapter replies with a markdown sample (heading, bold, link,
    // fenced dart code block) when it sees "MARKDOWN".
    await sendComposerText(tester, 'MARKDOWN');

    // The reply arrives and is rendered as markdown (not a plain bubble).
    await pumpUntil(
      tester,
      find.byType(MarkdownBody),
      reason: 'assistant markdown reply never rendered a MarkdownBody',
    );
    expect(find.textContaining('Markdown demo'), findsWidgets);

    // Fenced code block → syntax-highlighted view with a copy button.
    expect(find.byType(HighlightView), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);

    // Message timestamp gutter (HH:mm) is present under the turns.
    final hhmm = RegExp(r'^\d{2}:\d{2}$');
    final hasTimestamp = find.byType(Text).evaluate().any((e) {
      final data = (e.widget as Text).data;
      return data != null && hhmm.hasMatch(data);
    });
    expect(hasTimestamp, isTrue, reason: 'no HH:mm timestamp found');
  });
}
