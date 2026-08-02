import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/store/media.dart';
import 'package:makit/ui/session/chat_message.dart';
import 'package:makit/ui/session/media_view.dart';

SessionEvent _userEvent(Map<String, Object?> payload) => SessionEvent(
  seq: 1,
  sessionId: 's1',
  ts: 1000,
  kind: EventKind.userMessage,
  payload: payload,
);

const _id = 'abc0123456789012345678901234567890123456789012345678901234567890';

void main() {
  group('folding user.message attachments', () {
    test('descriptors on the payload become attachments on the item', () {
      final items = foldEvents([
        _userEvent({
          'text': 'why is this misaligned?',
          'attachments': [
            {'mediaId': _id, 'mime': 'image/png', 'name': 'shot.png'},
          ],
        }),
      ]);

      final item = items.single as UserMessageItem;
      expect(item.text, 'why is this misaligned?');
      expect(item.attachments, hasLength(1));
      expect(item.attachments.single.mediaId, _id);
      expect(item.attachments.single.mime, 'image/png');
      expect(item.attachments.single.name, 'shot.png');
    });

    test('the optimistic wire form round-trips back through tryParse', () {
      // `appendOptimisticMessage` writes `toEchoWire()` into a payload that this
      // very fold parses back, in-process. A field dropped from one side is a
      // field missing from the rendered bubble forever, because the optimistic
      // copy is the one that survives the seq-collision dedup.
      const ref = MediaAttachmentRef(
        mediaId: _id,
        mime: 'image/jpeg',
        name: 'shot.jpg',
      );
      expect(MediaAttachmentRef.tryParse(ref.toEchoWire()), ref);
    });

    test('history with no attachments key folds exactly as before', () {
      // Every event recorded before SPEC-33 lacks the field; a resumed session
      // must not crash or render an empty strip.
      final item =
          foldEvents([
                _userEvent({'text': 'plain'}),
              ]).single
              as UserMessageItem;
      expect(item.text, 'plain');
      expect(item.attachments, isEmpty);
    });

    test(
      'malformed attachment entries are skipped, not rendered as blanks',
      () {
        final item =
            foldEvents([
                  _userEvent({
                    'text': 'x',
                    'attachments': [
                      null,
                      'nope',
                      {'mime': 'image/png'}, // no id
                      {'mediaId': 'not-a-sha', 'mime': 'image/png'},
                      {'mediaId': _id, 'mime': 'image/png'},
                    ],
                  }),
                ]).single
                as UserMessageItem;
        expect(item.attachments, hasLength(1));
        expect(item.attachments.single.mediaId, _id);
      },
    );

    test('a non-list attachments value is ignored', () {
      final item =
          foldEvents([
                _userEvent({'text': 'x', 'attachments': 'shot.png'}),
              ]).single
              as UserMessageItem;
      expect(item.attachments, isEmpty);
    });
  });

  group('SessionDTO.promptImage', () {
    test('is decoded from the sessions snapshot', () {
      final sessions = WireCodec.decodeSessions([
        {'id': 's1', 'projectId': 'p', 'agent': 'pi', 'promptImage': true},
      ]);
      expect(sessions!.single.promptImage, isTrue);
    });

    test('defaults to false when the server does not report it', () {
      final sessions = WireCodec.decodeSessions([
        {'id': 's1', 'projectId': 'p', 'agent': 'codex'},
      ]);
      expect(sessions!.single.promptImage, isFalse);
    });
  });

  group('user bubble', () {
    Widget host(Widget child) => ProviderScope(
      // No endpoint: thumbnails render their labelled placeholder instead of
      // reaching for HTTP, which is all these tests need to assert.
      overrides: [mediaFetcherProvider.overrideWithValue(null)],
      child: MaterialApp(home: Scaffold(body: child)),
    );

    testWidgets('renders one thumbnail per attachment', (tester) async {
      await tester.pumpWidget(
        host(
          const ChatBubble.user(
            text: 'look',
            ts: 1000,
            attachments: [
              MediaAttachmentRef(mediaId: _id, mime: 'image/png'),
              MediaAttachmentRef(mediaId: 'b$_id', mime: 'image/png'),
            ],
          ),
        ),
      );
      expect(find.byType(UserAttachmentThumb), findsNWidgets(2));
    });

    testWidgets('shows the hand-off note when the agent cannot see images', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ChatBubble.user(
            text: 'look',
            ts: 1000,
            attachments: [MediaAttachmentRef(mediaId: _id, mime: 'image/png')],
            promptImage: false,
          ),
        ),
      );
      expect(find.text(kSentAsFileNote), findsOneWidget);
    });

    testWidgets('hides the note when the agent takes images directly', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ChatBubble.user(
            text: 'look',
            ts: 1000,
            attachments: [MediaAttachmentRef(mediaId: _id, mime: 'image/png')],
            promptImage: true,
          ),
        ),
      );
      expect(find.text(kSentAsFileNote), findsNothing);
    });

    testWidgets('a text-only message shows no note and no strip', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const ChatBubble.user(text: 'hi', ts: 1000)),
      );
      expect(find.byType(UserAttachmentThumb), findsNothing);
      expect(find.text(kSentAsFileNote), findsNothing);
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('an image-only message renders without an empty text line', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const ChatBubble.user(
            text: '',
            ts: 1000,
            attachments: [MediaAttachmentRef(mediaId: _id, mime: 'image/png')],
          ),
        ),
      );
      expect(find.byType(UserAttachmentThumb), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });
  });
}
