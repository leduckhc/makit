import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/platform_shell.dart';

void main() {
  group('prefersWorkspaceShell', () {
    test('macOS always routes to the workspace shell', () {
      expect(
        prefersWorkspaceShell(
          platform: TargetPlatform.macOS,
          size: const Size(320, 480),
        ),
        isTrue,
      );
    });

    test('iPadOS with a regular×regular size class routes to workspace', () {
      // Full-screen iPad (landscape): both extents are regular.
      expect(
        prefersWorkspaceShell(
          platform: TargetPlatform.iOS,
          size: const Size(1024, 768),
        ),
        isTrue,
      );
    });

    test('iOS compact width (iPhone / Slide Over) routes to mobile', () {
      expect(
        prefersWorkspaceShell(
          platform: TargetPlatform.iOS,
          size: const Size(390, 844),
        ),
        isFalse,
      );
    });

    test(
      'iPad Stage-Manager / split-view compact width falls back to mobile',
      () {
        // A narrow split-view column: regular height but compact width.
        expect(
          prefersWorkspaceShell(
            platform: TargetPlatform.iOS,
            size: const Size(507, 1024),
          ),
          isFalse,
        );
      },
    );

    test('non-Apple platforms always route to mobile', () {
      expect(
        prefersWorkspaceShell(
          platform: TargetPlatform.android,
          size: const Size(1280, 800),
        ),
        isFalse,
      );
    });
  });

  group('PlatformShell', () {
    Widget shell() => PlatformShell(
      workspaceBuilder: (_) => const Text('WORKSPACE'),
      mobileBuilder: (_) => const Text('MOBILE'),
    );

    Future<void> pumpAt(WidgetTester tester, Size logicalSize) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = logicalSize;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery.fromView(
          view: tester.view,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: shell(),
          ),
        ),
      );
    }

    testWidgets('picks workspace for a regular×regular iPad', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpAt(tester, const Size(1024, 768));
        expect(find.text('WORKSPACE'), findsOneWidget);
        expect(find.text('MOBILE'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('picks mobile for a compact iOS width', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpAt(tester, const Size(390, 844));
        expect(find.text('MOBILE'), findsOneWidget);
        expect(find.text('WORKSPACE'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('picks workspace on macOS regardless of size', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await pumpAt(tester, const Size(320, 480));
        expect(find.text('WORKSPACE'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('switches live when the iPad size class changes', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        // Start full-screen (regular×regular) → workspace.
        await pumpAt(tester, const Size(1024, 768));
        expect(find.text('WORKSPACE'), findsOneWidget);

        // Resize into a compact split-view column → mobile, no restart.
        tester.view.physicalSize = const Size(400, 1024);
        await tester.pump();
        expect(find.text('MOBILE'), findsOneWidget);
        expect(find.text('WORKSPACE'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
