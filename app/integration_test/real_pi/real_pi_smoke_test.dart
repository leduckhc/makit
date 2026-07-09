// Real-pi e2e: drives the actual Flutter app against the genuine `pi --mode
// rpc` subprocess, whose LLM is swapped for the deterministic fake model
// (server/test/fake-model). Run via `tool/e2e.sh --mode real`.
//
// Unlike the stub suite (integration_test/stub/), this asserts what real pi +
// the fake model actually produce: the fake model streams a fixed reply
// ("makit e2e ok") for any prompt. This exercises the real
// pi → PiAdapter → WS → app path end to end.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real pi streams the fake model reply end to end', (
    tester,
  ) async {
    await launchMakit(tester);
    await openFirstSession(tester);

    await sendComposerText(tester, 'hello');

    // Our message echoes into the transcript.
    expect(find.text('hello'), findsAtLeastNWidgets(1));

    // The fake model streams a deterministic reply back through real pi.
    await pumpUntil(
      tester,
      find.textContaining('makit e2e ok'),
      reason: 'real pi never streamed the fake model reply',
    );
  });
}
