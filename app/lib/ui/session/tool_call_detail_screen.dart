import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import 'tool_renderers.dart';

/// Fullscreen drilldown for a tool call. Shows args, streamed deltas (output),
/// and a placeholder for a richer diff viewer when the tool name == 'edit'.
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
    // Delegate to the renderer's detail view if one is registered for this tool.
    final renderer = rendererFor(tool);
    if (renderer != null) return renderer.detail(context, tool);

    // Generic fallback.
    return Scaffold(
      appBar: AppBar(
        title: Text(tool.name),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/session/$sessionId'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(title: 'Arguments', child: _Mono(_pretty(tool.args))),
          if (tool.deltas.isNotEmpty)
            _Section(title: 'Output', child: _Mono(tool.deltas.join()))
          else if (tool.output?.isNotEmpty ?? false)
            _Section(title: 'Output', child: _Mono(tool.output!)),
          // Only show a separate Result when it adds info beyond Output:
          // on failure (exit code), or when there was no Output to show.
          // Otherwise `summary` just repeats Output's first line.
          if (tool.ended &&
              ((tool.exitCode ?? 0) != 0 ||
                  (tool.deltas.isEmpty && !(tool.output?.isNotEmpty ?? false))))
            _Section(
              title: (tool.exitCode ?? 0) != 0 ? 'Error' : 'Result',
              child: Text(
                tool.summary ?? 'exit ${tool.exitCode ?? 0}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
        ],
      ),
    );
  }

  static String _pretty(Map<String, dynamic> m) =>
      m.entries.map((e) => '${e.key}: ${e.value}').join('\n');
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _Mono extends StatelessWidget {
  const _Mono(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => SelectableText(
    text,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
  );
}
