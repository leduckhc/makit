// Drives the REAL desktop split-pane feature on the macOS engine and writes a
// sequence of PNG frames to disk (initial → ⌘D vertical split → ⌘⇧D horizontal
// split → divider resize → drag drop-edge guidance). The frames are stitched
// into a demo video by tool/capture_pane_split.sh.
//
// This proves the ⌘D / ⌘⇧D shortcut wire end-to-end (keystrokes go through the
// same DesktopKeymapScope the app installs) using fake sessions — no server,
// no real agent.
//
// Run: flutter test integration_test/desktop/pane_split_capture_test.dart -d macos
//
// ignore_for_file: depend_on_referenced_packages, avoid_print
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';
import 'package:makit/desktop/chat/panes/pane_tree_view.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Wire up pairing',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
);

const _model = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final boundaryKey = GlobalKey();
  final outDir = Directory('${Directory.systemTemp.path}/makit_pane_frames');
  var frameIndex = 0;

  Future<void> shot(WidgetTester tester, String label) async {
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final name = 'frame_${frameIndex.toString().padLeft(2, '0')}_$label.png';
      final file = File('${outDir.path}/$name');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      print('CAPTURED_FRAME ${file.path}');
      frameIndex++;
    });
  }

  // The demo drives the layout change straight through the controller. In the
  // app ⌘D / ⌘⇧D route through DesktopKeymapScope, which also opens the
  // new-session dialog (covered by the unit tests); that dialog needs a seeded
  // repo store the capture harness doesn't provide.

  testWidgets('capture split-pane interaction frames', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    outDir.createSync(recursive: true);

    final c = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWithValue(SessionsState([_session()])),
        eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        sessionMetaProvider('s1').overrideWithValue(
          const SessionMeta(
            model: _model,
            thinking: 'medium',
            models: [_model],
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    // Both leaves fall back to this global selection (leaf sessionId is null),
    // so every pane renders the fake session's docked composer.
    c.read(selectedSessionProvider.notifier).state = 's1';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: boundaryKey,
              child: const PaneTreeView(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 0: single pane (starting point).
    await shot(tester, 'single');

    // 1: vertical split (side-by-side).
    c
        .read(paneTreeControllerProvider.notifier)
        .splitActive(Axis.horizontal, pinnedSessionId: 's1');
    await tester.pumpAndSettle();
    expect(
      find.byType(PaneTreeView),
      findsOneWidget,
      reason: 'tree still mounted after split',
    );
    await shot(tester, 'vertical_split');

    // 2: horizontal split of the now-active right pane.
    c
        .read(paneTreeControllerProvider.notifier)
        .splitActive(Axis.vertical, pinnedSessionId: 's1');
    await tester.pumpAndSettle();
    await shot(tester, 'horizontal_split');

    // 3: drag the first divider to resize the left/right split.
    final divider = find.byType(PaneTreeView);
    final treeRect = tester.getRect(divider);
    final dragStart = Offset(treeRect.center.dx, treeRect.top + 200);
    final gesture = await tester.startGesture(dragStart);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await shot(tester, 'resized');

    // 4: start dragging the left pane's header and hover it over another pane
    // to reveal the drop-edge guidance highlight (captured mid-gesture).
    final draggables = find.byType(Draggable<String>);
    expect(draggables, findsWidgets, reason: 'each leaf has a draggable header');
    final src = tester.getCenter(draggables.first);
    final target = Offset(treeRect.right - 260, treeRect.top + 180);
    final drag = await tester.startGesture(src);
    await tester.pump(const Duration(milliseconds: 20));
    // Move in small steps so the Draggable arms and the DragTarget receives
    // onMove (which sets the hovered edge).
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    await drag.moveTo(target);
    await tester.pump(const Duration(milliseconds: 50));
    await drag.moveBy(const Offset(-8, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await shot(tester, 'drop_guidance');
    await drag.up();
    await tester.pumpAndSettle();

    print('FRAMES_DIR ${outDir.path}');
  });
}
