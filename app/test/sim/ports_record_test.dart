// Frame recorder for the SPEC-open-ports/42 ports popover, for the PR demo.
//
// The data is REAL: `server/tool/capture-ports-snapshot.ts` runs the production
// `PortsService` (real `lsof`/`ps`, real TCP health probe, real `git worktree
// list`) on this machine and writes the wire DTO to JSON; this harness decodes it
// with the app's own `PortsSnapshot.fromJson`, so the recording exercises the
// real wire contract and the real widgets — not a hand-written fixture.
//
// Host screen recording is unavailable in this environment (macOS TCC attributes
// it to the enclosing Makit.app, which cannot be restarted mid-session), so the
// frames are captured from inside Flutter instead.
//
//   PORTS_RECORD=1 flutter test --no-pub --update-goldens test/sim/ports_record_test.dart
//   then: tool/make-ports-recording.sh
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/ports_glyph.dart';
import 'package:makit/ui/ports/ports_popover.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'sim_fonts.dart';

/// Where `capture-ports-snapshot.ts` left the real scan.
const _snapshotPath = '/tmp/ports-snapshot.json';

/// Total frames and the step between them. 24 frames at 12 fps = 2 s, long
/// enough to read the popover once it lands.
const int _kFrames = 24;
const Duration _kStep = Duration(milliseconds: 80);

/// A worktree the real snapshot attributed ports to, with its branch label.
class _Tree {
  _Tree(this.path, this.branch, this.ports);
  final String path;
  final String branch;
  final List<PortInfo> ports;
}

/// Groups the real snapshot by worktree, so the sidebar shows the branches that
/// genuinely own ports on this machine right now.
List<_Tree> _trees(PortsSnapshot snap) {
  final byPath = <String, List<PortInfo>>{};
  for (final p in snap.ports) {
    final wt = p.worktreePath;
    if (wt != null && wt.isNotEmpty) (byPath[wt] ??= []).add(p);
  }
  final trees = byPath.entries.map((e) {
    final ports = e.value..sort((a, b) => a.port.compareTo(b.port));
    // The branch is not on the DTO; the last path segment is what the sidebar
    // row shows for these worktrees and is enough for a demo label.
    return _Tree(e.key, e.key.split('/').last, ports);
  }).toList();
  trees.sort((a, b) => b.ports.length.compareTo(a.ports.length));
  return trees;
}

Widget _sidebarRow(
  ThemeData theme,
  _Tree tree,
  int nowMs, {
  required bool hosted,
}) {
  final cs = theme.colorScheme;
  return Container(
    margin: const EdgeInsets.only(bottom: kSpace4),
    padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: kSpace6),
    decoration: BoxDecoration(
      color: hosted ? cs.surfaceContainer : null,
      borderRadius: BorderRadius.circular(kRadius8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(PhosphorIconsLight.gitBranch, size: 13, color: cs.primary),
            const SizedBox(width: kSpace6),
            Expanded(
              child: Text(
                tree.branch,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text('...', style: theme.textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: kSpace2),
        Row(
          children: [
            Text(
              '18h ago',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            PortsPopover(
              state: tree.ports.any((p) => p.reach == PortReach.exposed)
                  ? PortsGlyphState.exposed
                  : PortsGlyphState.serving,
              count: tree.ports.length,
              branch: tree.branch,
              ports: tree.ports,
              nowMs: nowMs,
            ),
          ],
        ),
      ],
    ),
  );
}

void main() {
  late PortsSnapshot snapshot;

  setUpAll(() async {
    await loadSimFonts();
    final file = File(_snapshotPath);
    if (!file.existsSync()) return;
    final decoded = PortsSnapshot.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
    if (decoded != null) snapshot = decoded;
  });

  // Opt-in: this writes 24 PNGs per theme and depends on a scan captured on the
  // host, so it must never run as part of the normal suite.
  final skip =
      !Platform.isMacOS ||
      Platform.environment['PORTS_RECORD'] == null ||
      !File(_snapshotPath).existsSync();

  for (final (name, theme) in <(String, ThemeData)>[
    ('light', makitLightTheme),
    ('dark', makitDarkTheme),
  ]) {
    testWidgets('record — $name', (tester) async {
      const dpr = 2.0;
      tester.view.physicalSize = const Size(900 * dpr, 460 * dpr);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);

      final trees = _trees(snapshot);
      expect(
        trees,
        isNotEmpty,
        reason: 'the captured scan attributed no ports to a worktree',
      );
      final nowMs = snapshot.scannedAt;

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            backgroundColor: theme.colorScheme.surface,
            body: Row(
              children: [
                Container(
                  width: 280,
                  color: theme.colorScheme.surfaceContainerLow,
                  padding: const EdgeInsets.all(kSpace8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, t) in trees.indexed)
                        _sidebarRow(theme, t, nowMs, hosted: i == 0),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      'real ports on this machine · scanned live',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dir = Directory('test/sim/frames/$name');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(140, 400));
      addTearDown(mouse.removePointer);
      await tester.pump();

      // The glyph on the first (top) row — the one the sidebar shows as hosted.
      final target = tester.getCenter(find.byType(PortsGlyph).first);

      for (var f = 0; f < _kFrames; f++) {
        // Frames 0-2 resting, 3 arrives on the glyph, then the 350 ms dwell
        // elapses and the popover opens on its own — the real timing, not a
        // scripted reveal.
        if (f == 3) await mouse.moveTo(target);
        if (f == 20) await mouse.moveTo(const Offset(700, 400));
        await tester.pump(_kStep);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'frames/$name/f${f.toString().padLeft(3, '0')}.png',
          ),
        );
      }
    }, skip: skip);
  }
}
