import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/ui/ports/ports_glyph.dart';

import '../e2e_helpers.dart';

/// SPEC-41 — full-stack proof that a listening port reaches the UI: the real
/// e2e server runs a deterministic port scan (`makeDeterministicPortsExec`
/// attributes `:5173` to the project's primary worktree), the app holds the
/// ref-counted `ports.watch` while the home screen is mounted, the
/// `ports.snapshot` frame crosses a real WSS connection, the glyph lights on
/// that worktree's row, tapping it lists the port, and tapping the port shows
/// its command.
///
/// Unit tests cannot show this: they feed the reducer directly and would pass
/// even if the frame never left the server (project skill
/// `makit-verify-feature-end-to-end`).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a served port lights the glyph → lists → shows the command', (
    tester,
  ) async {
    await launchMakit(tester);

    // The glyph appears once the watch-gated snapshot arrives.
    await pumpUntil(
      tester,
      find.byType(PortsGlyph),
      reason: 'ports.snapshot never lit the worktree-row glyph',
    );

    await tester.tap(find.byType(PortsGlyph).first);
    await tester.pumpAndSettle();

    // Sheet 1 — the port list. Its row is keyed by port number.
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('ports-list-row-5173')),
      reason: 'the ports list sheet did not show the served port',
    );

    await tester.tap(find.byKey(const ValueKey('ports-list-row-5173')));
    await tester.pumpAndSettle();

    // Sheet 2 — the detail. Every fact is a labelled row; the command is one.
    expect(find.text('command'), findsOneWidget);
    expect(find.textContaining('vite'), findsWidgets);
  });
}
