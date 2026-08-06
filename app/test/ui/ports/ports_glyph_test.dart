import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/ports_glyph.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('PortsGlyph', () {
    testWidgets('renders nothing when the state is none', (tester) async {
      await tester.pumpWidget(
        _host(const PortsGlyph(state: PortsGlyphState.none, count: 0)),
      );
      expect(find.byIcon(PhosphorIconsLight.plug), findsNothing);
    });

    testWidgets('renders the plug when serving', (tester) async {
      await tester.pumpWidget(
        _host(const PortsGlyph(state: PortsGlyphState.serving, count: 3)),
      );
      expect(find.byIcon(PhosphorIconsLight.plug), findsOneWidget);
      expect(find.byKey(kPortsAttentionDot), findsNothing);
    });

    testWidgets('shows the attention dot on attention', (tester) async {
      await tester.pumpWidget(
        _host(const PortsGlyph(state: PortsGlyphState.attention, count: 1)),
      );
      expect(find.byKey(kPortsAttentionDot), findsOneWidget);
    });

    testWidgets('shows the attention dot on exposed too', (tester) async {
      await tester.pumpWidget(
        _host(const PortsGlyph(state: PortsGlyphState.exposed, count: 1)),
      );
      expect(find.byKey(kPortsAttentionDot), findsOneWidget);
    });

    testWidgets('publishes a semantics label naming the state (not colour)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const PortsGlyph(state: PortsGlyphState.attention, count: 2)),
      );
      expect(find.bySemanticsLabel(RegExp('needs attention')), findsOneWidget);
    });
  });
}
