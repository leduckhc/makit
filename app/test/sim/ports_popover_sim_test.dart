// Scratch AUDIT harness for the SPEC-41 §2a desktop ports popover, rendered
// against `mockups/open-ports.html` §2a. Same conventions as
// `ports_screen_sim_test.dart`: real fonts, real theme, real clock.
//
//   PORTS_AUDIT=1 flutter test --no-pub --update-goldens test/sim/ports_popover_sim_test.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/ports_glyph.dart';
import 'package:makit/ui/ports/ports_popover.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'sim_fonts.dart';

final int _nowMs = DateTime.now().millisecondsSinceEpoch;

PortInfo _port({
  required int port,
  required String command,
  String address = '127.0.0.1',
  PortReach reach = PortReach.loopback,
  int pid = 48211,
  PortHealth? health,
  String? openUrl,
  int? startedAt,
}) => PortInfo(
  key: '$pid:$address:$port',
  port: port,
  address: address,
  reach: reach,
  pid: pid,
  command: command,
  startedAt: startedAt ?? _nowMs - 41 * 60 * 1000,
  health: health,
  openUrl: openUrl,
);

/// The mockup §2a population, one port per tone: a 200, a 404 (which arrives as
/// `httpError`, NOT `ok` with a 4xx status — faking that hid the amber tint the
/// first time this harness ran), a refused socket, and an unprobed listener.
final _ports = [
  _port(
    port: 5173,
    command: '/opt/homebrew/Cellar/node/26.5.1/bin/node vite --port 5173',
    health: PortHealth(
      kind: PortHealthKind.ok,
      status: 200,
      probedAt: _nowMs - 4000,
    ),
    openUrl: 'http://127.0.0.1:5173',
  ),
  _port(
    port: 9787,
    command: '/opt/homebrew/Cellar/node/26.5.1/bin/node dist/serve.js',
    address: '0.0.0.0',
    reach: PortReach.exposed,
    pid: 47120,
    health: PortHealth(
      kind: PortHealthKind.httpError,
      status: 404,
      probedAt: _nowMs - 3000,
    ),
    openUrl: 'http://127.0.0.1:9787',
    startedAt: _nowMs - 2 * 60 * 60 * 1000,
  ),
  _port(
    port: 5175,
    command: '/opt/homebrew/Cellar/node/26.5.1/bin/node vite --port 5175',
    pid: 50110,
    health: PortHealth(kind: PortHealthKind.refused, probedAt: _nowMs - 2000),
    startedAt: _nowMs - 12 * 60 * 1000,
  ),
  _port(
    port: 5432,
    command: '/usr/local/opt/postgresql@16/bin/postgres -D /data',
    pid: 51002,
    startedAt: _nowMs - 3 * 24 * 60 * 60 * 1000,
  ),
];

/// A macOS window shaped like the product: a 280 pt sidebar whose worktree row
/// carries the plug on its right edge, and a chat pane beside it. The popover
/// must land in the PANE, leaving the row it describes visible.
Widget _scene({required List<PortInfo> ports, required ThemeData theme}) =>
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
                  _row(theme, 'perf/optimize', ports.length),
                  const SizedBox(height: kSpace4),
                  _row(theme, 'main', 0),
                  const SizedBox(height: kSpace4),
                  _row(theme, 'fix/scroll-anchor', 0),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Text(
                  'What is the state of chat',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

/// A stand-in for the sidebar's worktree row: branch line, then a sub-row whose
/// right edge holds the plug (the real row's layout, per mockup §5).
Widget _row(ThemeData theme, String branch, int portCount) {
  final cs = theme.colorScheme;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: kSpace6),
    decoration: BoxDecoration(
      color: portCount > 0 ? cs.surfaceContainer : null,
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
                branch,
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
            if (portCount > 0)
              PortsPopover(
                state: PortsGlyphState.serving,
                count: portCount,
                branch: branch,
                ports: _ports.take(portCount).toList(),
                nowMs: _nowMs,
              ),
          ],
        ),
      ],
    ),
  );
}

void main() {
  setUpAll(loadSimFonts);

  for (final (name, theme) in <(String, ThemeData)>[
    // Light first: it is what the reported screenshot was taken in, and the one
    // where the tinted pills have the least contrast headroom.
    ('light', makitLightTheme),
    ('dark', makitDarkTheme),
  ]) {
    testWidgets('ports popover in a sidebar — $name', (tester) async {
      const dpr = 2.0;
      tester.view.physicalSize = const Size(900 * dpr, 560 * dpr);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_scene(ports: _ports, theme: theme));
      await tester.pumpAndSettle();

      // Hover the glyph and wait out the 350 ms dwell.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.byType(PortsGlyph)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byKey(kPortsPopover), findsOneWidget);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('images/ports_popover_$name.png'),
      );
    }, skip: skipSimAudit);
  }
}
