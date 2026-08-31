import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/ui/session/chat_message.dart';
import 'package:makit/ui/session/tool_renderers.dart'
    show kReadableContentMaxWidth;

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  /// Selects everything in the agent message and returns what a copy would put
  /// on the clipboard (captured off the platform channel).
  Future<String> copyAll(WidgetTester tester) async {
    // Let the markdown lay out and register its selectables before selecting.
    await tester.pump();
    final state = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    state.selectAll();
    await tester.pump();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    // Guarantee the global mock is removed even if invoke/pump throws, so it
    // can't leak into later tests (the binary messenger persists per file).
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    // Trigger the same copy path as Cmd/Ctrl+C (non-deprecated).
    Actions.invoke(
      tester.element(find.byType(MarkdownBody)),
      CopySelectionTextIntent.copy,
    );
    await tester.pump();
    return copied ?? '';
  }

  testWidgets(
    'user message renders in a right-aligned bubble with a timestamp',
    (tester) async {
      await tester.pumpWidget(
        wrap(const ChatBubble.user(text: 'hello', ts: 0)),
      );
      expect(find.text('hello'), findsOneWidget);
      expect(find.byType(MarkdownBody), findsNothing);
      final align = tester.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerRight);
    },
  );

  testWidgets('agent message renders markdown (no bubble) with a timestamp', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: '# Title\n\nsome **bold** text', ts: 0)),
    );
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(Align), findsNothing);
    expect(find.textContaining('Title'), findsWidgets);
  });

  testWidgets(
    'agent message fills the readable column so a short reply hugs the left '
    '(not centered)',
    (tester) async {
      // A window wider than the column, so the cap limits the message.
      // The default 800 pt surface is narrower than the column.
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Mimic the desktop pane: a Center wrapper loosens the width, which used
      // to let the message shrink-wrap to its text and appear centered.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kReadableContentMaxWidth,
                ),
                child: const AgentMessage(text: 'Done!', ts: 0),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // The block fills the full readable column instead of shrink-wrapping to
      // "Done!", so its start-aligned content sits at the column's left edge.
      expect(
        tester.getSize(find.byType(AgentMessage)).width,
        kReadableContentMaxWidth,
      );
    },
  );

  testWidgets('fenced code block gets syntax highlighting + a copy button', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: '```dart\nvoid main() {}\n```', ts: 0)),
    );
    expect(find.byType(HighlightView), findsOneWidget);
    expect(find.byIcon(PhosphorIconsLight.copy), findsOneWidget);
  });

  testWidgets(
    'agent markdown is wrapped in one SelectionArea with selectable:false '
    'so a single drag spans lines and inline code',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const AgentMessage(
            text: 'first line with `inline` code\n\nsecond paragraph',
            ts: 0,
          ),
        ),
      );

      // A single SelectionArea must wrap the markdown: MarkdownBody's own
      // per-block SelectableText can't select across paragraphs or over the
      // custom inline-code widget.
      final md = find.byType(MarkdownBody);
      expect(md, findsOneWidget);
      expect(
        find.ancestor(of: md, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      // Selection is delegated to the SelectionArea, not per-block widgets.
      expect(tester.widget<MarkdownBody>(md).selectable, isFalse);
    },
  );

  testWidgets('copying multiple blocks separates them with newlines', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: 'para one\n\npara two', ts: 0)),
    );
    expect(await copyAll(tester), 'para one\npara two');
  });

  testWidgets('copying inline code keeps it on the same line (no newline)', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: 'start `code` end', ts: 0)),
    );
    expect(await copyAll(tester), 'start code end');
  });

  group('remote markdown images', () {
    // An agent can link a 4000px screenshot; decoding it at full resolution
    // parks ~64MB of RGBA in the image cache for a ~600pt paragraph. The
    // makit-media path already bounds this (media_view.dart) — so must this one.
    final uri = Uri.parse('https://example.invalid/shot.png');

    test('decode is bounded to the drawn width in device pixels', () {
      final provider = remoteImageProvider(
        uri,
        width: 300,
        devicePixelRatio: 2,
      );
      expect(provider, isA<ResizeImage>());
      final resize = provider as ResizeImage;
      expect(resize.width, 600);
      // Height is left unbounded on purpose: a tall screenshot must keep its
      // aspect ratio, exactly as _MediaImage does for thumbnails.
      expect(resize.height, isNull);
      expect(resize.policy, ResizeImagePolicy.fit);
      expect(resize.imageProvider, isA<NetworkImage>());
    });

    test('a sub-pixel width still decodes at least one pixel', () {
      // (width * dpr).round() would be 0 here, and ResizeImagePolicy.fit would
      // then decode to a zero-width — i.e. invisible — image.
      final provider = remoteImageProvider(
        uri,
        width: 0.4,
        devicePixelRatio: 1,
      );
      expect((provider as ResizeImage).width, 1);
    });

    test('an unbounded width falls back to an unresized provider', () {
      // No finite width to size against (e.g. an unconstrained axis) — a bogus
      // cacheWidth would be worse than none.
      expect(
        remoteImageProvider(uri, width: double.infinity, devicePixelRatio: 2),
        isA<NetworkImage>(),
      );
    });
  });
}
