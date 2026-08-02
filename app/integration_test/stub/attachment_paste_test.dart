import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/ui/composer/attachment_chips.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../e2e_helpers.dart';

/// A real 1×1 PNG. Must be a decodable image: the pasteboard (and the image
/// widget in the chip) both reject arbitrary bytes.
final Uint8List _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

/// Full-stack attachment flow (SPEC-33), with nothing faked between the app and
/// the server: a real image on the real device pasteboard → the real
/// `POST /media` upload over the pinned client → a real `send.message` naming
/// the id → the stub agent's reply quoting the file it was handed.
///
/// This is the test that proves the feature *works*, as opposed to proving each
/// half works in isolation.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pastes an image, uploads it, and the agent is handed the file', (
    tester,
  ) async {
    await launchMakit(tester);
    await openFirstSession(tester);

    final clipboard = SystemClipboard.instance;
    expect(
      clipboard,
      isNotNull,
      reason: 'no system clipboard on this platform',
    );
    await clipboard!.write([DataWriterItem()..add(Formats.png(_png))]);

    // Focus the composer and paste.
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);

    // The chip appears once the clipboard read lands; the upload then flips it
    // to ready, which is what re-enables the send button.
    await pumpUntil(
      tester,
      find.byType(AttachmentChip),
      reason: 'pasting an image did not stage an attachment chip',
    );
    await pumpUntil(
      tester,
      find.byKey(const ValueKey('send')),
      reason: 'send never became enabled — the upload probably failed',
    );

    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 100));

    // The stub agent echoes the prompt it received, so this asserts the agent
    // was actually told about a file on disk.
    await pumpUntil(
      tester,
      find.textContaining('Attached files:'),
      reason: 'the agent was never handed the attachment path',
    );
    // …and the staged chip is gone, so the next message does not resend it.
    expect(find.byType(AttachmentChip), findsNothing);
  });
}
