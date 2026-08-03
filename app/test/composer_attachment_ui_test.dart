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

/// The composer's attachment capability, with only the bits a test cares about
/// overridden. [pick] null = nowhere to upload (an inert paperclip, no ⌘V).
ComposerAttachmentsApi _api({
  List<ComposerAttachment> staged = const [],
  VoidCallback? pick,
  ValueChanged<String>? remove,
  ValueChanged<String>? retry,
  Future<({Uint8List bytes, String mime, String name})?> Function()?
  readClipboardImage,
  void Function(({Uint8List bytes, String mime, String name}) image)?
  stagePasted,
}) => ComposerAttachmentsApi(
  staged: staged,
  pick: pick ?? () {},
  remove: remove ?? (_) {},
  retry: retry ?? (_) {},
  readClipboardImage: readClipboardImage ?? () async => null,
  stagePasted: stagePasted ?? (_) {},
);

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
          Composer(
            onSend: sent.add,
            attachments: _api(staged: [_att()]),
          ),
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
            attachments: _api(
              staged: [_att(status: AttachmentStatus.uploading)],
            ),
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
            attachments: _api(
              staged: [_att(status: AttachmentStatus.uploading)],
            ),
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
        _host(
          Composer(
            onSend: (_) {},
            attachments: _api(pick: () => tapped++),
          ),
        ),
      );
      await tester.tap(find.byIcon(PhosphorIconsLight.paperclip));
      expect(tapped, 1);
    });

    testWidgets('an attachment-unaware composer does not blame the server', (
      tester,
    ) async {
      // No attachments API at all (the free-text answer composer). The clip stays
      // visible but inert — and must NOT promise that connecting fixes it, since
      // connecting never enables attachments here.
      await tester.pumpWidget(_host(Composer(onSend: (_) {})));
      final clip = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.paperclip),
      );
      expect(clip.onPressed, isNull);
      expect(clip.tooltip, isNotNull);
      expect(clip.tooltip, isNot(contains('v2')));
      expect(
        clip.tooltip,
        isNot(contains('server')),
        reason: 'no connectivity fix exists for this composer',
      );
    });

    testWidgets('a session with nowhere to upload names the real reason', (
      tester,
    ) async {
      // Attachment-aware, but `pick` is null: nothing is paired, so the tooltip
      // points at the thing the user can actually fix.
      await tester.pumpWidget(
        _host(
          Composer(
            onSend: (_) {},
            attachments: ComposerAttachmentsApi(
              staged: const [],
              remove: (_) {},
              retry: (_) {},
              readClipboardImage: () async => null,
              stagePasted: (_) {},
            ),
          ),
        ),
      );
      final clip = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.paperclip),
      );
      expect(clip.onPressed, isNull);
      expect(clip.tooltip, contains('server'));
    });

    testWidgets('chips are shown above the field', (tester) async {
      await tester.pumpWidget(
        _host(
          Composer(
            onSend: (_) {},
            attachments: _api(staged: [_att()]),
          ),
        ),
      );
      expect(find.byType(AttachmentChips), findsOneWidget);
      final chipY = tester.getCenter(find.byType(AttachmentChips)).dy;
      final fieldY = tester.getCenter(find.byType(TextField)).dy;
      expect(chipY, lessThan(fieldY));
    });

    testWidgets('no chips row when nothing is attached', (tester) async {
      await tester.pumpWidget(
        _host(Composer(onSend: (_) {}, attachments: _api())),
      );
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
            attachments: _api(
              readClipboardImage: () async =>
                  (bytes: _bytes, mime: 'image/png', name: 'pasted.png'),
              stagePasted: (image) => pasted = image.bytes,
            ),
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
      // A composer with no attachments API (the free-text answer composer) must
      // keep the field's native paste — hijacking it there costs undo/IME
      // behaviour and buys nothing.
      _mockClipboard(tester, text: 'native paste');
      await tester.pumpWidget(_host(Composer(onSend: (_) {})));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(composerClaimsPaste(tester), isFalse);
    });

    testWidgets('⌘V is NOT claimed when there is nowhere to upload', (
      tester,
    ) async {
      // Staged chips stay visible and removable, but a session that cannot
      // stage a new image must not claim the paste either.
      _mockClipboard(tester, text: 'native paste');
      await tester.pumpWidget(
        _host(
          Composer(
            onSend: (_) {},
            attachments: ComposerAttachmentsApi(
              staged: [_att()],
              remove: (_) {},
              retry: (_) {},
              readClipboardImage: () async =>
                  (bytes: _bytes, mime: 'image/png', name: 'x.png'),
              stagePasted: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(composerClaimsPaste(tester), isFalse);
      expect(find.byType(AttachmentChips), findsOneWidget);
      final clip = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.paperclip),
      );
      expect(clip.onPressed, isNull);
    });

    testWidgets('⌘V IS claimed when an image paste is possible', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(Composer(onSend: (_) {}, attachments: _api())),
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
            attachments: _api(
              readClipboardImage: () async => null,
              stagePasted: (image) => pasted = image.bytes,
            ),
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
