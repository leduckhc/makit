// macOS e2e for attachment paste (SPEC-33). Runs on the REAL macOS engine
// against the REAL system pasteboard, which is the one part of this feature no
// widget test can cover: `super_clipboard`'s native read path (and the fact that
// Flutter's own text-only `Clipboard` cannot do this at all).
//
// It writes a PNG to the pasteboard, presses ⌘V in the desktop composer, and
// asserts an attachment chip appears and the send button becomes live. The
// upload itself is faked here — the real POST → worktree file → prompt chain is
// covered server-side by `server/test/ws/attachments_e2e.test.ts`.
//
// Run: flutter test integration_test/desktop/attachment_paste_e2e_test.dart -d macos
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/store/media.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/media_client.dart';
import 'package:makit/ui/composer/attachment_chips.dart';
import 'package:super_clipboard/super_clipboard.dart';

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Attach a screenshot',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
  // Explicit worktree ensures predictable test materialization, but is not
  // required — sessions with null worktreePath use the agent's cwd (SPEC-33 §7).
  worktreePath: '/tmp/makit-e2e-worktree',
);

/// A real 1×1 PNG — the pasteboard rejects bytes that are not a decodable image.
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

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: const MaterialApp(
    home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('⌘V of a real clipboard image stages an attachment', (
    tester,
  ) async {
    final clipboard = SystemClipboard.instance;
    expect(
      clipboard,
      isNotNull,
      reason: 'macOS must expose a system clipboard via super_clipboard',
    );
    // Put a real image on the real pasteboard.
    await clipboard!.write([DataWriterItem()..add(Formats.png(_png))]);

    final uploaded = <int>[];
    final c = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWithValue(SessionsState([_session()])),
        eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        // Fake the upload: this test is about the clipboard + staging path.
        mediaUploaderProvider.overrideWithValue((bytes, mime) async {
          uploaded.add(bytes.length);
          return MediaDescriptor(
            mediaId: 'a' * 64,
            mime: mime,
            sizeBytes: bytes.length,
          );
        }),
      ],
    );
    addTearDown(c.dispose);

    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();

    // Focus the composer, then paste.
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);

    // The clipboard read + upload are async; give them a bounded window.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(AttachmentChip).evaluate().isNotEmpty &&
          uploaded.isNotEmpty) {
        break;
      }
    }

    expect(
      find.byType(AttachmentChip),
      findsOneWidget,
      reason: 'a pasted image must appear as a chip above the composer',
    );
    expect(uploaded, [_png.length], reason: 'the pasted bytes were uploaded');
    // Ready + no text is still a sendable turn. The send button is enabled.
    await tester.pump(const Duration(milliseconds: 200));
    // `IconButton`, not `ElevatedButton` — the composer builds the send control
    // with `IconButton.filled`. Note the key alone would already prove enabled
    // (the disabled variant is keyed 'send-disabled'), so this is belt and
    // braces against that mapping changing.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is IconButton &&
            w.key == const ValueKey('send') &&
            w.onPressed != null,
      ),
      findsOneWidget,
      reason: 'send must be enabled once the upload is ready',
    );
  });
}
