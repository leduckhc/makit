// Tests for the profile-switch confirmation sheets (SPEC-50 D10).
//
// These sheets are the last thing between a click and an irreversible action, so
// what they *say* is part of the contract, not decoration. In particular
// `confirmSwitchAwayAndDelete` gates a delete that erases a profile's database,
// media, pairings and TLS identity — it had no coverage at all until `ocr` pointed
// that out.
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/daemon/server_profile.dart';
import 'package:makit/desktop/settings/sections/profile_switch_sheet.dart';

const ServerProfile _work = ServerProfile(
  id: 'work',
  name: 'Work',
  kind: ProfileKind.user,
  home: '/h/.makit',
  port: 7777,
  storage: ProfileStorage.legacy,
);

const ServerProfile _personal = ServerProfile(
  id: 'personal',
  name: 'Personal',
  kind: ProfileKind.user,
  home: '/h/.makit/profiles/personal',
  port: 7805,
  storage: ProfileStorage.namespaced,
);

/// Mounts a button that opens [open] and records what it returned.
Future<List<bool?>> _run(
  WidgetTester tester,
  Future<bool> Function(BuildContext) open,
) async {
  final results = <bool?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: makitDarkTheme,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(await open(context)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  group('confirmProfileSwitch', () {
    Future<List<bool?>> open(
      WidgetTester tester, {
      bool targetRunning = true,
    }) => _run(
      tester,
      (context) => confirmProfileSwitch(
        context,
        from: _work,
        to: _personal,
        targetRunning: targetRunning,
      ),
    );

    testWidgets('names the target and both halves of the consequence', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Switch to “Personal”?'), findsOneWidget);
      expect(find.text('WHAT HAPPENS HERE'), findsOneWidget);
      expect(find.text('WHAT KEEPS RUNNING'), findsOneWidget);
      // The reassuring half is the point: switching must not read as "stops my
      // work".
      expect(find.textContaining('Work’s server stays up'), findsOneWidget);
      expect(
        find.textContaining('Work’s agents are not interrupted'),
        findsOneWidget,
      );
      expect(find.textContaining('stay paired'), findsOneWidget);
    });

    testWidgets('promises to start the target only when it is stopped', (
      tester,
    ) async {
      await open(tester, targetRunning: false);
      expect(find.textContaining('Personal’s server starts'), findsOneWidget);
    });

    testWidgets('does not promise a start when the target already runs', (
      tester,
    ) async {
      await open(tester);
      expect(
        find.textContaining('server starts'),
        findsNothing,
        reason: 'claiming to start a running server is a small lie',
      );
    });

    testWidgets('returns true only when confirmed', (tester) async {
      final results = await open(tester);
      await tester.tap(find.text('Switch to Personal'));
      await tester.pumpAndSettle();
      expect(results, [true]);
    });

    testWidgets('returns false on Cancel', (tester) async {
      final results = await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });

    testWidgets('returns false when dismissed by tapping outside', (
      tester,
    ) async {
      // A dismissed dialog pops `null`; treating that as consent would switch a
      // window the user only meant to look at.
      final results = await open(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });
  });

  group('confirmSwitchAwayAndDelete', () {
    Future<List<bool?>> open(WidgetTester tester) => _run(
      tester,
      (context) =>
          confirmSwitchAwayAndDelete(context, victim: _personal, target: _work),
    );

    testWidgets('leads with the delete, not the switch', (tester) async {
      // The switch is the mechanism; the deletion is what the user must weigh.
      await open(tester);
      expect(find.text('Delete “Personal”?'), findsOneWidget);
    });

    testWidgets('explains why a switch is involved at all', (tester) async {
      await open(tester);
      expect(
        find.textContaining('the profile this window is using'),
        findsOneWidget,
      );
      expect(find.textContaining('switch to “Work” first'), findsOneWidget);
    });

    testWidgets('names what is destroyed and what survives', (tester) async {
      await open(tester);
      expect(find.text('WHAT HAPPENS'), findsOneWidget);
      expect(find.text('WHAT IS KEPT'), findsOneWidget);
      expect(
        find.textContaining('sessions, transcripts, pairings'),
        findsOneWidget,
      );
      // Without this line, "delete" next to a path beside your worktree reads as
      // "deletes my branch".
      expect(
        find.textContaining('worktrees and repos are never touched'),
        findsOneWidget,
      );
      expect(
        find.textContaining('every other profile is unaffected'),
        findsOneWidget,
      );
    });

    testWidgets('returns true only when confirmed', (tester) async {
      final results = await open(tester);
      await tester.tap(find.textContaining('Switch & delete'));
      await tester.pumpAndSettle();
      expect(results, [true]);
    });

    testWidgets('returns false on Cancel', (tester) async {
      final results = await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });

    testWidgets('returns false when dismissed', (tester) async {
      final results = await open(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });
  });
}
