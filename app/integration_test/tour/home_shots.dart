// Screenshot pass for the repo list: enters demo mode, then holds still on the
// home screen (expanded) and again with the tail revealed, so `simctl io
// screenshot` can capture the density. Run via tool/shoot-home.sh.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/main.dart' as app;

import 'mobile_parity_tour.dart' show enterDemoMode, hold, waitFor;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home screen holds still for screenshots', (tester) async {
    app.main();
    await hold(tester, const Duration(seconds: 2));
    await enterDemoMode(tester);

    // Shot 1: the list as it opens.
    await hold(tester, const Duration(seconds: 6));

    // Shot 2: with the quiet tail expanded.
    final more = find.textContaining('more');
    if (more.evaluate().isNotEmpty) {
      await tester.tap(more.first, warnIfMissed: false);
      await waitFor(tester, find.text('old-experiment'));
    }
    await hold(tester, const Duration(seconds: 6));
  });
}
