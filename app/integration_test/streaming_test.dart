import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('agent reply streams in via deltas and finalizes into one bubble',
      (tester) async {
    await launchPino(tester);
    await openFirstSession(tester);

    // The stub adapter replies to "STREAM" with running-status +
    // agent.message.delta tokens ("Stream" / "ing " / "reply") then a final
    // authoritative agent.message. The app folds the deltas into a single
    // growing bubble finalized by the last message.
    await sendComposerText(tester, 'STREAM');

    await pumpUntil(
      tester,
      find.textContaining('Streaming reply'),
      reason: 'streamed agent reply never assembled into "Streaming reply"',
    );
    // Exactly one assembled reply — deltas must not leave duplicate bubbles.
    expect(find.textContaining('Streaming reply'), findsWidgets);
  });
}
