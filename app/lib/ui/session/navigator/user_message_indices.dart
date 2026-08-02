/// Where the user's own messages sit in the transcript (SPEC-34).
///
/// A derived view over `chatItemsProvider` — no new store state and no protocol
/// change: the whole transcript is already in memory (SPEC-21), so "list my
/// messages" is a filter, not a fetch.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../store/chat_items.dart';
import '../../../store/store.dart';

/// Positions of [UserMessageItem]s within [items], ascending (oldest first).
///
/// These are **item positions** — indices into the ascending transcript, *not*
/// the reversed child indices the lazy list uses. See `TranscriptJumper` for the
/// transform between the two.
List<int> userMessagePositions(List<ChatItem> items) => [
  for (var p = 0; p < items.length; p++)
    if (items[p] is UserMessageItem) p,
];

/// [userMessagePositions] for a session, recomputed only when its items change.
final userMessagePositionsProvider = Provider.family<List<int>, String>(
  (ref, sessionId) =>
      userMessagePositions(ref.watch(chatItemsProvider(sessionId))),
);
