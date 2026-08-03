/// SPEC-35 — a steered message says so on its own bubble.
///
/// Steering and queueing are chosen by the transport, not by the user, so the
/// only honest place to teach the difference is the transcript: a message that
/// went into the turn that was already running is captioned, the same way an
/// attachment handed over as a file is (SPEC-33).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/transport/protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/ui/session/chat_message.dart';
import 'package:makit/ui/session/chat_transcript.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

SessionEvent _userMessage({required bool steered}) => SessionEvent(
  seq: 1,
  sessionId: 's1',
  ts: 1000,
  kind: EventKind.userMessage,
  payload: {'text': 'do X instead', if (steered) 'steered': true},
);

void main() {
  test('foldEvents carries the steered flag onto the item', () {
    final steered = foldEvents([_userMessage(steered: true)])
        .whereType<UserMessageItem>()
        .single;
    expect(steered.steered, isTrue);

    final plain = foldEvents([_userMessage(steered: false)])
        .whereType<UserMessageItem>()
        .single;
    expect(plain.steered, isFalse);
  });

  testWidgets('a steered bubble is captioned', (tester) async {
    await tester.pumpWidget(
      _host(const ChatBubble.user(text: 'do X instead', ts: 1000, steered: true)),
    );
    expect(find.text(kSteeredNote), findsOneWidget);
  });

  testWidgets('an ordinary bubble is not captioned', (tester) async {
    await tester.pumpWidget(
      _host(const ChatBubble.user(text: 'do X instead', ts: 1000)),
    );
    expect(find.text(kSteeredNote), findsNothing);
  });

  testWidgets('the transcript row carries the flag through to the caption', (
    tester,
  ) async {
    // The wiring, not just the widget: a steered event must reach the bubble
    // through foldEvents + chatItemWidget, which is what both surfaces render.
    final item = foldEvents([_userMessage(steered: true)])
        .whereType<UserMessageItem>()
        .single;
    await tester.pumpWidget(
      ProviderScope(child: _host(chatItemWidget('s1', item))),
    );
    expect(find.text(kSteeredNote), findsOneWidget);
  });
}
