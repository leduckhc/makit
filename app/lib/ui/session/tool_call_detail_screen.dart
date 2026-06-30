import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../store/models.dart';
import '../../store/store.dart';

/// Fullscreen drilldown for a tool call. Shows args, streamed deltas (output),
/// and a placeholder for a richer diff viewer when the tool name == 'edit'.
class ToolCallDetailScreen extends ConsumerWidget {
  const ToolCallDetailScreen({super.key, required this.sessionId, required this.callId});
  final String sessionId;
  final String callId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(chatItemsProvider(sessionId));
    final tool = items.whereType<ToolCallItem>().where((t) => t.callId == callId).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(tool?.name ?? 'tool call'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/session/$sessionId'),
        ),
      ),
      body: tool == null
          ? const Center(child: Text('Tool call not found'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _Section(title: 'Arguments', child: _Mono(_pretty(tool.args))),
                if (tool.deltas.isNotEmpty)
                  _Section(title: 'Output', child: _Mono(tool.deltas.join())),
                if (tool.ended)
                  _Section(
                    title: 'Result',
                    child: Text(
                      tool.summary ?? 'exit ${tool.exitCode ?? 0}',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                if (tool.name == 'edit')
                  const _Section(
                    title: 'Diff',
                    child: Text(
                      '(diff viewer coming in M6 — render a unified diff with syntax highlighting)',
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
  Widget build(BuildContext context) =>
      SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5));
}
