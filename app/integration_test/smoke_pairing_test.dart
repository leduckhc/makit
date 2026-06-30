import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots with test pairing and shows project/session snapshots', (
    tester,
  ) async {
    await launchPino(tester);

    // AppBar title
    expect(find.text('pino'), findsWidgets);
    // Project name header appears in _ProjectSection (a Row, not a ListTile)
    // Session from the stub adapter
    expect(find.text('new session'), findsOneWidget);
  });
}
