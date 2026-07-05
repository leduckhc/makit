import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import 'tool_renderers.dart';

/// Fullscreen drilldown for a tool call. Shows args, streamed deltas (output),
/// and, for the `edit` tool, a line-level diff viewer (removed / added /
/// context rows computed by [computeLineDiff]).
class ToolCallDetailScreen extends ConsumerWidget {
  const ToolCallDetailScreen({
    super.key,
    required this.sessionId,
    required this.callId,
  });
  final String sessionId;
  final String callId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(chatItemsProvider(sessionId));
    final tool = items
        .whereType<ToolCallItem>()
        .where((t) => t.callId == callId)
        .firstOrNull;

    if (tool == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('tool call')),
        body: const Center(child: Text('Tool call not found')),
      );
    }
    // Delegate to the renderer's detail view if one is registered for this
    // tool; otherwise fall back to the shared generic (non-JSON) detail so the
    // header and layout stay consistent across every tool.
    final renderer = rendererFor(tool);
    if (renderer != null) return renderer.detail(context, tool);
    return genericToolDetail(context, tool);
  }
}
