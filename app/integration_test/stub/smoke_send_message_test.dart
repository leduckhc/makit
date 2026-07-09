import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../e2e_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sends hello and receives stub echo', (tester) async {
    await launchMakit(tester);
    await openFirstSession(tester);

    await sendComposerText(tester, 'hello');

    // "hello" appears in both the composer (readonly EditableText) and the
    // optimistic bubble. Don't assert exactly one.
    expect(find.text('hello'), findsAtLeastNWidgets(1));
    await pumpUntil(tester, find.text('echo: hello'));
  });
}
