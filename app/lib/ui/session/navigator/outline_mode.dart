/// Outline mode: the transcript reduced to the prompts you sent (SPEC-34).
///
/// Unlike the other four navigators, outline is not an overlay — it changes which
/// rows exist. It therefore filters the transcript at its **source**: both
/// surfaces read [transcriptItemsProvider] instead of `chatItemsProvider`
/// directly, so the fold happens in one place rather than in two hand-kept-in-sync
/// `itemBuilder`s.
///
/// Filtering (rather than hiding) is what keeps the rest of the machinery honest:
/// the lazy list's `itemCount`, the child-index transform and
/// `findChildIndexCallback` all derive from the same list, so they cannot
/// disagree about how many rows there are.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../store/chat_items.dart';
import '../../../store/store.dart';
import 'navigator_style.dart';

/// Whether outline mode is currently on, per session.
///
/// Per session, not global: outlining one conversation should not outline the
/// others in a split view.
final outlineModeProvider = StateProvider.family<bool, String>(
  (ref, _) => false,
);

/// An item position the transcript should land on once outline mode is left.
///
/// A row cannot reach the `TranscriptJumper` (it is owned by the navigator
/// overlay, which is the row's *sibling* in the surface's `Stack`, not its
/// ancestor). So a tapped prompt posts its position here and `MessageOutline`
/// — which does own the jumper — performs the jump. Set to null once consumed.
final outlineExitJumpProvider = StateProvider.family<int?, String>(
  (ref, _) => null,
);

/// The rows the transcript should render.
///
/// Identical to `chatItemsProvider` unless outline mode is on *and* the outline
/// style is selected — a stale `true` from a since-changed style must never
/// silently hide the transcript.
final transcriptItemsProvider = Provider.family<List<ChatItem>, String>((
  ref,
  sessionId,
) {
  final items = ref.watch(chatItemsProvider(sessionId));
  final style = ref.watch(messageNavigatorStyleProvider);
  if (style != MessageNavigatorStyle.outline) return items;
  if (!ref.watch(outlineModeProvider(sessionId))) return items;
  final hideTools = ref.watch(outlineOptionsProvider).hideTools;
  return outlineItems(items, hideTools: hideTools);
});

/// [items] reduced to the user's messages, plus tool calls unless [hideTools].
List<ChatItem> outlineItems(
  List<ChatItem> items, {
  required bool hideTools,
}) => [
  for (final item in items)
    if (item is UserMessageItem || (!hideTools && item is ToolCallItem)) item,
];

/// How many rows [outlineItems] would drop between the user message at
/// [position] and the next one — the "N rows hidden" count.
int hiddenRowsAfter(
  List<ChatItem> items,
  int position, {
  required bool hideTools,
}) {
  var hidden = 0;
  for (var p = position + 1; p < items.length; p++) {
    final item = items[p];
    if (item is UserMessageItem) break;
    if (item is ToolCallItem && !hideTools) continue;
    hidden++;
  }
  return hidden;
}
