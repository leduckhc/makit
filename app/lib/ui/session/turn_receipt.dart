/// The turn receipt row (SPEC-47 D9/D9a/D9b/D9c/D20/D17).
///
/// One dim line closing a turn: its wall clock, how many tool calls it ran, and
/// — only when a gate actually blocked — how long it waited on the user. The
/// transcript has no other turn boundary, and a turn's wall clock is not
/// recoverable from the rows above it: the gaps *between* tool calls are model
/// latency that no row represents.
///
/// There is deliberately **no cost token** (D9a). `reduceEvent` handles
/// `session.usage` by whole-snapshot replacement and returns before appending it
/// to `events` (`store.dart:249-258`), so the fold structurally cannot see one
/// snapshot let alone two to difference — and codex prices nothing anyway
/// (`codex-map.ts:84`). Cumulative cost is one tap away in the usage popover,
/// where it is measured rather than differenced.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../store/chat_items.dart';
import 'elapsed.dart';

/// Below this width the receipt stacks onto two lines (D9c): the one-line form
/// needs ~340 logical px once the gate token is present, which does not fit a
/// phone's content box.
const double kReceiptStackWidth = 420;

/// `14 tools` / `1 tool` — hard-coded English with an explicit singular (D20).
String toolCountLabel(int n) => n == 1 ? '1 tool' : '$n tools';

/// `4m 12s waiting on you`, or null on an ungated turn (D9).
String? gateLabel(int gatedMs) {
  if (gatedMs <= 0) return null;
  final elapsed = formatElapsed(gatedMs);
  return elapsed == null ? null : '$elapsed waiting on you';
}

/// The dim, hairline-led row that closes a turn.
class TurnReceipt extends StatelessWidget {
  /// Creates the receipt for [item].
  const TurnReceipt({super.key, required this.item});

  /// The projected receipt (see `withTurnReceipts`).
  final TurnReceiptItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Quiet by SIZE, never by a dimmer colour (D9b): `onSurfaceVariant` is the
    // dimmest tone in the palette that still clears AA, so there is no headroom
    // below it — the receipt recedes because it is smaller, not greyer.
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final elapsed = formatElapsed(item.wallMs) ?? 'an unknown time';
    final headline = '$elapsed · ${toolCountLabel(item.toolCount)}';
    final gate = gateLabel(item.gatedMs);

    return Semantics(
      container: true,
      label: [
        'turn took ${formatElapsed(item.wallMs) ?? 'an unknown time'}',
        toolCountLabel(item.toolCount),
        ?gate,
      ].join(', '),
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stack =
              gate != null && constraints.maxWidth < kReceiptStackWidth;
          final hairline = Expanded(
            child: Container(height: 1, color: cs.outlineVariant),
          );
          final gateText = gate == null
              ? null
              : Text(gate, style: style?.copyWith(color: kStatusCaution));

          if (stack) {
            // The break falls between the two *thoughts* (what the turn cost /
            // what you cost it) rather than wherever the text runs out (D9c).
            return Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  children: [
                    hairline,
                    const SizedBox(width: kSpace8),
                    Text(headline, style: style),
                  ],
                ),
                ?gateText,
              ],
            );
          }
          return Row(
            children: [
              hairline,
              const SizedBox(width: kSpace8),
              Text(headline, style: style),
              if (gateText != null) ...[Text(' · ', style: style), gateText],
            ],
          );
        },
      ),
    );
  }
}
