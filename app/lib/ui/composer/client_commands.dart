/// Client commands — slash commands that the app handles locally without
/// sending anything to the agent. They show up in the slash palette
/// alongside agent-provided commands and server commands.
///
/// To add a new client command, add an entry to [clientCommands]. The
/// handler runs in widget context with access to Riverpod via [ref].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../store/connection.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../transport/protocol.dart';

typedef ClientCmdHandler = Future<void> Function(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
});

class ClientCommand {
  const ClientCommand({
    required this.name,
    required this.description,
    required this.handler,
  });

  final String name;
  final String description;
  final ClientCmdHandler handler;

  SlashCmd toSlashCmd() =>
      SlashCmd(name: name, description: description, source: 'builtin');
}

/// Try to handle [raw] (e.g. `/new`) as a client command. Returns true if a
/// handler matched; false if [raw] should be sent on to the agent.
Future<bool> handleClientCommand(
  String raw, {
  required BuildContext context,
  required WidgetRef ref,
  required String sessionId,
}) async {
  if (!raw.startsWith('/')) return false;
  final firstSpace = raw.indexOf(RegExp(r'\s'));
  final name = firstSpace < 0 ? raw.substring(1) : raw.substring(1, firstSpace);
  for (final c in clientCommands) {
    if (c.name == name) {
      await c.handler(context, ref, sessionId: sessionId);
      return true;
    }
  }
  return false;
}

final List<ClientCommand> clientCommands = <ClientCommand>[
  ClientCommand(
    name: 'new',
    description: 'Start a fresh agent session in the same project',
    handler: (context, ref, {required sessionId}) async {
      final session = ref.read(sessionsProvider).byId(sessionId);
      if (session == null) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        final newId = await ref
            .read(storeControllerProvider.notifier)
            .spawnSession(session.projectId);
        if (!context.mounted) return;
        context.go('/session/$newId');
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Could not spawn session: $e')));
      }
    },
  ),
  ClientCommand(
    name: 'cancel',
    description: 'Cancel the current agent turn',
    handler: (context, ref, {required sessionId}) async {
      try {
        await ref.read(connectionControllerProvider.notifier).request(
          MsgType.cmd,
          {'kind': 'cancel', 'sessionId': sessionId},
        );
      } catch (_) {/* best-effort */}
    },
  ),
  ClientCommand(
    name: 'unpair',
    description: 'Forget the paired desktop server and return to pairing',
    handler: (context, ref, {required sessionId}) async {
      await ref.read(connectionControllerProvider.notifier).unpair();
      if (!context.mounted) return;
      context.go('/pair');
    },
  ),
  ClientCommand(
    name: 'help',
    description: 'Show available commands',
    handler: (context, ref, {required sessionId}) async {
      final agentCmds = ref.read(commandsProvider(sessionId));
      final lines = [
        for (final c in clientCommands) '/${c.name}  —  ${c.description}',
        for (final c in agentCmds) '${c.invocation}  —  ${c.description}',
      ];
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Available commands'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Text(
                lines.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    },
  ),
];
