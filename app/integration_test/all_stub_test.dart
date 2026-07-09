// Single integration-test entrypoint for the stub-adapter suite.
//
// `flutter test integration_test/<dir>` rebuilds AND relaunches the app once
// per *_test.dart file. On an iOS simulator that per-file build dominates CI
// wall-time (6 files → 6 cold app builds/launches). Running every scenario
// from ONE entrypoint means a single build + single launch, cutting the e2e
// step several-fold.
//
// Each imported `main()` only registers its `testWidgets` (and calls the
// idempotent `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`), so
// calling them in sequence composes cleanly — the runner executes all the
// registered tests in one process. The individual files stay runnable on their
// own for focused local iteration (`flutter test integration_test/stub/foo_test.dart`).
//
// Order mirrors the alphabetical order `flutter test <dir>` used, so shared
// stub-server state accumulates the same way it did across the split files.
import 'stub/ask_wizard_e2e_test.dart' as ask_wizard;
import 'stub/markdown_render_test.dart' as markdown_render;
import 'stub/smoke_ask_question_test.dart' as smoke_ask_question;
import 'stub/smoke_pairing_test.dart' as smoke_pairing;
import 'stub/smoke_send_message_test.dart' as smoke_send_message;
import 'stub/streaming_test.dart' as streaming;

void main() {
  ask_wizard.main();
  markdown_render.main();
  smoke_ask_question.main();
  smoke_pairing.main();
  smoke_send_message.main();
  streaming.main();
}
