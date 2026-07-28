import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/ui/widgets/connection_chip.dart';

import '../e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots with test pairing and shows project/session snapshots', (
    tester,
  ) async {
    await launchMakit(tester);

    // AppBar title.
    expect(find.text('makit'), findsWidgets);
    // Session from the stub adapter — proves the WS snapshot hydrated.
    expect(find.text('new session'), findsOneWidget);

    // Paired + connected: ConnectionChip collapses to SizedBox.shrink on the
    // happy path. Assert on the chip itself rather than on the names of its
    // unhappy-path icons — that keeps this non-vacuous. If the chip is renamed
    // or dropped, the first expect fails instead of silently passing.
    final chip = find.byType(ConnectionChip);
    expect(chip, findsWidgets, reason: 'ConnectionChip should be mounted');
    // Every unhappy state renders a label (Offline / Reconnecting /
    // Connecting / Issue / Demo) plus an icon or spinner. Connected renders
    // nothing at all.
    expect(
      find.descendant(of: chip, matching: find.byType(Text)),
      findsNothing,
      reason: 'connected chip must render no status label',
    );
    expect(
      find.descendant(of: chip, matching: find.byType(Icon)),
      findsNothing,
      reason: 'connected chip must render no status icon',
    );
    expect(
      find.descendant(
        of: chip,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
      reason: 'connected chip must render no connecting spinner',
    );
  });
}
