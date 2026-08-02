import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/composer_attachments.dart';
import 'package:makit/store/media.dart';
import 'package:makit/ui/composer/attachment_chips.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final _bytes = Uint8List.fromList([1, 2, 3]);

ComposerAttachment _att({
  String id = 'l1',
  AttachmentStatus status = AttachmentStatus.ready,
  String name = 'shot.png',
  String? error,
}) => ComposerAttachment(
  localId: id,
  bytes: _bytes,
  mime: 'image/png',
  name: name,
  status: status,
  mediaId: status == AttachmentStatus.ready ? 'a' * 64 : null,
  error: error,
);

Widget _host(Widget child) => ProviderScope(
  overrides: [mediaFetcherProvider.overrideWithValue(null)],
  child: MaterialApp(home: Scaffold(body: child)),
);

/// Services `SystemChannels.platform` clipboard calls with an in-memory value.
///
/// Necessary, not belt-and-braces: `flutter_test` installs **no** default
/// clipboard mock in this Flutter version, so an un-mocked `Clipboard.getData`
/// never completes and the test hangs instead of failing (verified).
void _mockClipboard(WidgetTester tester, {String? text}) {
  String? current = text;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async => switch (call.method) {
      'Clipboard.getData' => current == null ? null : {'text': current},
      'Clipboard.setData' =>
        current = (call.arguments as Map)['text'] as String?,
      _ => null,
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

/// Whether the **composer's own** shortcut map claims V (⌘V/Ctrl+V).
///
/// Scoped to descendants of [Composer] on purpose: `MaterialApp` installs its own
/// `Shortcuts` above it, so `find.byType(Shortcuts).first` inspects the app's map
/// and would report "not claimed" no matter what the composer does.
bool composerClaimsPaste(WidgetTester tester) => tester
    .widgetList<Shortcuts>(
      find.descendant(
        of: find.byType(Composer),
        matching: find.byType(Shortcuts),
      ),
    )
    .any(
      (s) => s.shortcuts.keys.any(
        (a) => a is SingleActivator && a.trigger == LogicalKeyboardKey.keyV,
      ),
    );

void main() {
  group('AttachmentChips', () {
    testWidgets('shows one chip per attachment with its name', (tester) async {
      await tester.pumpWidget(
        _host(
          AttachmentChips(
            attachments: [
              _att(name: 'a.png'),
              _att(id: 'l2', name: 'b.png'),
            ],
            onRemove: (_) {},
            onRetry: (_) {},
          ),
        ),
      );
      expect(find.text('a.png'), findsOneWidget);
      expect(find.text('b.png'), findsOneWidget);
    });

    testWidgets('the remove button reports the right attachment', (
      tester,
    ) async {
      final removed = <String>[];
      await tester.pumpWidget(
        _host(
          AttachmentChips(
            attachments: [
              _att(id: 'l1'),
              _att(id: 'l2'),
            ],
            onRemove: removed.add,
            onRetry: (_) {},
          ),
        ),
      );
      await tester.tap(find.byIcon(PhosphorIconsLight.x).last);
      expect(removed, ['l2']);
    });

    testWidgets('an uploading chip shows progress and cannot be retried', (
      tester,
    ) async {
      final retried = <String>[];
      await tester.pumpWidget(
        _host(
          AttachmentChips(
            attachments: [_att(status: AttachmentStatus.uploading)],
            onRemove: (_) {},
            onRetry: retried.add,
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(AttachmentChip));
      expect(retried, isEmpty);
    });

    testWidgets('a failed chip shows the reason and retries on tap', (
      tester,
    ) async {
      final retried = <String>[];
      await tester.pumpWidget(
        _host(
          AttachmentChips(
            attachments: [
              _att(status: AttachmentStatus.failed, error: 'too large to send'),
            ],
            onRemove: (_) {},
            onRetry: retried.add,
          ),
        ),
      );
      expect(find.text('too large to send'), findsOneWidget);
      await tester.tap(find.byType(AttachmentChip));
      expect(retried, ['l1']);
    });
  });

  group('Composer with attachments', () {
    testWidgets('send is enabled by a ready attachment even with no text', (
      tester,
    ) async {
      final sent = <String>[];
      await tester.pumpWidget(
        _host(
          Composer(onSend: sent.add, attachments: [_att()], onAttach: () {}),
        ),
      );
      // Empty field + one ready image is a legitimate turn.
      final send = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.arrowUp),
      );
      expect(send.onPressed, isNotNull);
      await tester.tap(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.arrowUp),
      );
      expect(sent, ['']);
    });

    testWidgets('send is disabled while an upload is in flight', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Composer(
            onSend: (_) {},
            attachments: [_att(status: AttachmentStatus.uploading)],
            onAttach: () {},
          ),
        ),
      );
      // Sending now would name a mediaId the server has never seen.
      final send = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.arrowUp),
      );
      expect(send.onPressed, isNull);
    });

    testWidgets('typing text does not enable send while uploading', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Composer(
            onSend: (_) {},
            attachments: [_att(status: AttachmentStatus.uploading)],
            onAttach: () {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      final send = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.arrowUp),
      );
      expect(send.onPressed, isNull, reason: 'the image is not stored yet');
    });

    testWidgets('the paperclip is enabled when attaching is possible', (
      tester,
    ) async {
      var tapped = 0;
      await tester.pumpWidget(
        _host(Composer(onSend: (_) {}, onAttach: () => tapped++)),
      );
      await tester.tap(find.byIcon(PhosphorIconsLight.paperclip));
      expect(tapped, 1);
    });

    testWidgets('the paperclip is disabled when attaching is impossible', (
      tester,
    ) async {
      await tester.pumpWidget(_host(Composer(onSend: (_) {})));
      final clip = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.paperclip),
      );
      // Null onAttach = this session cannot take attachments; the affordance
      // stays visible but inert, with an honest tooltip.
      expect(clip.onPressed, isNull);
      expect(clip.tooltip, isNotNull);
      expect(clip.tooltip, isNot(contains('v2')));
      expect(clip.tooltip, contains('server'));
    });

    testWidgets('chips are shown above the field', (tester) async {
      await tester.pumpWidget(
        _host(Composer(onSend: (_) {}, attachments: [_att()], onAttach: () {})),
      );
      expect(find.byType(AttachmentChips), findsOneWidget);
      final chipY = tester.getCenter(find.byType(AttachmentChips)).dy;
      final fieldY = tester.getCenter(find.byType(TextField)).dy;
      expect(chipY, lessThan(fieldY));
    });

    testWidgets('no chips row when nothing is attached', (tester) async {
      await tester.pumpWidget(_host(Composer(onSend: (_) {}, onAttach: () {})));
      expect(find.byType(AttachmentChips), findsNothing);
    });

    testWidgets('paste with an image on the clipboard attaches it', (
      tester,
    ) async {
      Uint8List? pasted;
      _mockClipboard(tester, text: 'clip text');
      await tester.pumpWidget(
        _host(
          Composer(
            onSend: (_) {},
            onAttach: () {},
            readClipboardImage: () async =>
                (bytes: _bytes, mime: 'image/png', name: 'pasted.png'),
            onPasteImage: (bytes, mime, name) => pasted = bytes,
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(pasted, _bytes);
      // An image paste must not ALSO drop the clipboard text into the field.
      expect(find.text('clip text'), findsNothing);
    });

    testWidgets('⌘V is NOT claimed when the composer cannot attach images', (
      tester,
    ) async {
      // Composers with no paste callbacks (the free-text answer composer, or a
      // session that cannot attach) must keep the field's native paste — hijacking
      // it there costs undo/IME behaviour and buys nothing.
      _mockClipboard(tester, text: 'native paste');
      await tester.pumpWidget(_host(Composer(onSend: (_) {}, onAttach: () {})));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(composerClaimsPaste(tester), isFalse);
    });

    testWidgets('⌘V IS claimed when an image paste is possible', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Composer(
            onSend: (_) {},
            onAttach: () {},
            readClipboardImage: () async => null,
            onPasteImage: (_, _, _) {},
          ),
        ),
      );
      expect(composerClaimsPaste(tester), isTrue);
    });

    testWidgets('paste with no image still pastes text', (tester) async {
      // The paste handler must fall through, never swallow a text paste.
      Uint8List? pasted;
      _mockClipboard(tester, text: 'clip text');
      await tester.pumpWidget(
        _host(
          Composer(
            onSend: (_) {},
            onAttach: () {},
            readClipboardImage: () async => null,
            onPasteImage: (bytes, mime, name) => pasted = bytes,
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      // NOT pumpAndSettle: once text lands in a focused field the cursor blink
      // animation never settles, and the test would hang rather than fail.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(pasted, isNull);
      expect(find.text('clip text'), findsOneWidget);
    });
  });
}
