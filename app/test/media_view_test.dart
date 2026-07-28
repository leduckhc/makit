import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/store/media.dart';
import 'package:makit/transport/media_client.dart';
import 'package:makit/ui/session/media_view.dart';

import 'media_client_test.dart' show kPng;

Widget _host(Widget child, {MediaFetcher? fetcher}) => ProviderScope(
  overrides: [mediaFetcherProvider.overrideWithValue(fetcher)],
  child: MaterialApp(home: Scaffold(body: child)),
);

/// Distinct ids per test on purpose: [MakitMediaImage] is keyed by the content
/// hash and Flutter's ImageCache is process-wide, so reusing an id would serve
/// one test's decoded bytes to the next (which is exactly the caching we want
/// in the app, and exactly what must not silently pass a test).
AgentMediaItem _item({String? alt, String id = 'a'}) => AgentMediaItem(
  seq: 1,
  ts: 0,
  mediaId: id * 64,
  mime: 'image/png',
  sizeBytes: kPng.length,
  alt: alt,
);

void main() {
  testWidgets('renders the image once the bytes load', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _host(AgentMediaView(item: _item()), fetcher: (_) async => kPng),
      );
      // Decoding is genuinely async; give the image stream a chance to settle.
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(MediaPlaceholder), findsNothing);
  });

  testWidgets('shows a placeholder — not a spinner — for a GC\'d blob', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _host(
          AgentMediaView(item: _item(alt: 'shot.png', id: 'b')),
          fetcher: (id) async => throw MediaNotFoundException(id),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    expect(find.byType(MediaPlaceholder), findsOneWidget);
    // The alt text is the only description left once the bytes are gone.
    expect(find.textContaining('shot.png'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows a placeholder when no server is reachable at all', (
    tester,
  ) async {
    // Unpaired / fake-data mode: there is no endpoint, so there is no fetcher.
    await tester.pumpWidget(
      _host(AgentMediaView(item: _item(id: 'c')), fetcher: null),
    );
    await tester.pump();
    expect(find.byType(MediaPlaceholder), findsOneWidget);
  });

  testWidgets('tapping the thumbnail opens a fullscreen viewer', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _host(AgentMediaView(item: _item(id: 'd')), fetcher: (_) async => kPng),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.tap(find.byType(AgentMediaView));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    });
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  test('the media provider caches by mediaId, so a scroll-back is free', () {
    // Content-addressed bytes are immutable, so identity is the id alone —
    // Flutter's ImageCache then dedupes across rebuilds and list recycling.
    Future<Uint8List> fetchA(String _) async => kPng;
    Future<Uint8List> fetchB(String _) async => kPng;
    expect(
      MakitMediaImage('a' * 64, fetchA),
      equals(MakitMediaImage('a' * 64, fetchB)),
    );
    expect(
      MakitMediaImage('a' * 64, fetchA),
      isNot(equals(MakitMediaImage('b' * 64, fetchA))),
    );
  });
}
