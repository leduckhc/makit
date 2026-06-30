/// Listens for `srv.request` envelopes from the server and presents the
/// appropriate UI (currently: AskUserQuestion dialog). Mount once at app
/// root so any screen sees the dialog.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/connection.dart';
import '../../transport/protocol.dart';

class SrvRequestHandler extends ConsumerStatefulWidget {
  const SrvRequestHandler({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SrvRequestHandler> createState() => _SrvRequestHandlerState();
}

class _SrvRequestHandlerState extends ConsumerState<SrvRequestHandler> {
  StreamSubscription<Envelope>? _sub;

  @override
  void initState() {
    super.initState();
    // Subscribe after first frame so we have a Navigator overlay available.
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = ref.read(connectionControllerProvider.notifier).srvRequests.listen((
      env,
    ) async {
      final kind = env.body['kind'] as String? ?? 'unknown';
      final ctx = context;
      if (!ctx.mounted) return;

      switch (kind) {
        case 'askUserQuestion':
          await _showAskUserQuestion(ctx, env);
          return;
        default:
          await _showGeneric(ctx, env);
      }
    });
  }

  Future<void> _showAskUserQuestion(BuildContext ctx, Envelope env) async {
    final question = env.body['question'] as String? ?? 'Question';
    final header = env.body['header'] as String?;
    final rawOptions = (env.body['options'] as List?) ?? const [];
    final options = rawOptions
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    final multi = env.body['multi'] == true;

    final Set<int> picked = {};

    final result = await showDialog<List<int>?>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setSt) => AlertDialog(
          title: Text(header ?? 'Question'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(question),
                  const SizedBox(height: 12),
                  for (var i = 0; i < options.length; i++)
                    _OptionTile(
                      label: options[i]['label']?.toString() ?? '?',
                      description: options[i]['description']?.toString(),
                      recommended:
                          (env.body['recommended'] as num?)?.toInt() == i,
                      selected: picked.contains(i),
                      onTap: () => setSt(() {
                        if (multi) {
                          picked.contains(i) ? picked.remove(i) : picked.add(i);
                        } else {
                          picked
                            ..clear()
                            ..add(i);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: picked.isEmpty
                  ? null
                  : () => Navigator.pop(dctx, picked.toList()..sort()),
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    final conn = ref.read(connectionControllerProvider.notifier);
    if (result == null) {
      conn.respondTo(env.id, {'ok': false, 'cancelled': true});
    } else {
      final answers = result
          .map((i) => options[i]['label']?.toString() ?? '')
          .toList();
      conn.respondTo(env.id, {
        'ok': true,
        'indices': result,
        'answers': answers,
        'answer': multi ? answers : answers.first,
      });
    }
  }

  Future<void> _showGeneric(BuildContext ctx, Envelope env) async {
    // Generic free-text fallback for unknown kinds.
    final controller = TextEditingController();
    final text = await showDialog<String?>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: Text(env.body['title']?.toString() ?? 'Server request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              env.body['message']?.toString() ??
                  env.body['kind']?.toString() ??
                  '',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Your answer'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final conn = ref.read(connectionControllerProvider.notifier);
    if (text == null) {
      conn.respondTo(env.id, {'ok': false, 'cancelled': true});
    } else {
      conn.respondTo(env.id, {'ok': true, 'text': text});
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.description,
    this.recommended = false,
  });

  final String label;
  final String? description;
  final bool recommended;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 18,
                  color: selected ? cs.primary : cs.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (recommended) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: cs.tertiary.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Recommended',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: cs.tertiary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (description != null && description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            description!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
