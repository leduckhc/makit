/// Client commands — slash commands that the app handles locally without
/// sending anything to the agent. They show up in the slash palette
/// alongside agent-provided commands and server commands.
///
/// To add a new client command, add an entry to [clientCommands]. The
/// handler runs in widget context with access to Riverpod via [ref].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/connection.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../transport/protocol.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../widgets/sheet_header.dart';
import '../widgets/searchable_list_sheet.dart';
import '../session/session_identity.dart';
import '../../app/routes.dart';

typedef ClientCmdHandler =
    Future<void> Function(
      BuildContext context,
      WidgetRef ref, {
      required String sessionId,
      required String arg,
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
  final arg = firstSpace < 0 ? '' : raw.substring(firstSpace + 1).trim();
  for (final c in clientCommands) {
    if (c.name == name) {
      await c.handler(context, ref, sessionId: sessionId, arg: arg);
      return true;
    }
  }
  return false;
}

final List<ClientCommand> clientCommands = <ClientCommand>[
  ClientCommand(
    name: 'new',
    description: 'Start a fresh agent in this worktree',
    handler: (context, ref, {required sessionId, required arg}) async {
      // Resolved before the first await: `ref` throws once its widget is
      // unmounted, and the record must survive the thing that reported to it.
      final status = ref.status;
      final session = ref.read(sessionsProvider).byId(sessionId);
      if (session == null) return;
      // SPEC-tab-groups decision 18: the new agent runs in THIS pane's worktree, so no
      // dialog is needed. A session with no worktree on disk yet cannot answer
      // "where does it run?" — spawning bare would silently land the agent in
      // the repo's primary checkout, so refuse and say why.
      final worktreePath = session.worktreePath;
      if (worktreePath == null) {
        status.warning(
          'This session has no worktree yet — send a message '
          'first, or start one from the sidebar.',
          source: StatusSources.session,
          sessionId: sessionId,
        );
        return;
      }
      try {
        final newId = await ref
            .read(storeControllerProvider.notifier)
            .spawnSession(
              session.projectId,
              worktreePath: worktreePath,
              branch: session.branch,
            );
        if (!context.mounted) return;
        context.go(routeForSession(newId));
      } catch (e) {
        status.failure(
          'Could not spawn session',
          error: e,
          source: StatusSources.session,
          sessionId: sessionId,
        );
      }
    },
  ),
  ClientCommand(
    name: 'cancel',
    description: 'Cancel the current agent turn',
    handler: (context, ref, {required sessionId, required arg}) async {
      try {
        await ref.read(connectionControllerProvider.notifier).request(
          MsgType.cmd,
          {'kind': 'cancel', 'sessionId': sessionId},
        );
      } catch (_) {
        /* best-effort */
      }
    },
  ),
  ClientCommand(
    name: 'unpair',
    description: 'Forget the paired desktop server and return to pairing',
    handler: (context, ref, {required sessionId, required arg}) async {
      await ref.read(connectionControllerProvider.notifier).unpair();
      if (!context.mounted) return;
      context.go(kRouteRoot);
    },
  ),
  ClientCommand(
    name: 'help',
    description: 'Show available commands',
    handler: (context, ref, {required sessionId, required arg}) async {
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
                style: Theme.of(context).textTheme.bodySmall?.mono,
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
  ClientCommand(
    name: 'ask',
    description:
        'Debug: ask the server to ask you a question (round-trip test)',
    handler: (context, ref, {required sessionId, required arg}) async {
      try {
        await ref.read(connectionControllerProvider.notifier).request(
          MsgType.cmd,
          {'kind': 'debug.ask', 'sessionId': sessionId},
        );
      } catch (_) {
        /* best-effort */
      }
    },
  ),
  ClientCommand(
    name: 'compact',
    description: 'Compact the conversation to free up context',
    handler: (context, ref, {required sessionId, required arg}) async {
      final meta = ref.read(sessionMetaProvider(sessionId));
      if (meta == null) {
        ref.status.warning(
          'Not available for this session',
          source: StatusSources.agent,
          sessionId: sessionId,
        );
        return;
      }
      ref
          .read(storeControllerProvider.notifier)
          .sendSessionAction(sessionId, 'compact');
      ref.status.info(
        'Compact requested',
        source: StatusSources.agent,
        sessionId: sessionId,
      );
    },
  ),
  ClientCommand(
    name: 'thinking',
    description: 'Set the agent thinking level',
    handler: (context, ref, {required sessionId, required arg}) async {
      // Resolved before the first await: `ref` throws once its widget is
      // unmounted, and the record must survive the thing that reported to it.
      final status = ref.status;
      final level = await _pickThinkingLevel(context);
      if (level == null || !context.mounted) return;
      ref
          .read(storeControllerProvider.notifier)
          .sendSessionAction(sessionId, 'thinking', args: {'level': level});
      status.info(
        'Thinking level: $level',
        source: StatusSources.agent,
        sessionId: sessionId,
      );
    },
  ),
  ClientCommand(
    name: 'model',
    description: 'Switch the agent model',
    handler: (context, ref, {required sessionId, required arg}) async {
      // Resolved before the first await: `ref` throws once its widget is
      // unmounted, and the record must survive the thing that reported to it.
      final status = ref.status;
      final meta = ref.read(sessionMetaProvider(sessionId));
      final models = meta?.models ?? const [];
      if (models.isEmpty) {
        status.warning(
          'No models available for this session',
          source: StatusSources.agent,
          sessionId: sessionId,
        );
        return;
      }
      final picked = await _pickModel(context, models, meta?.model);
      if (picked == null || !context.mounted) return;
      // Re-read after the picker await: the active model may have changed
      // (e.g. TUI-side switch) while the sheet was open.
      final current = ref.read(sessionMetaProvider(sessionId))?.model;
      if (current != null &&
          current.provider == picked.provider &&
          current.id == picked.id) {
        return;
      }
      ref
          .read(storeControllerProvider.notifier)
          .sendSessionAction(
            sessionId,
            'model',
            args: {'provider': picked.provider, 'id': picked.id},
          );
      status.progress(
        'Switching to ${picked.name}…',
        source: StatusSources.agent,
        sessionId: sessionId,
      );
    },
  ),
  ClientCommand(
    name: 'session',
    description: 'Show this session’s identity, or /session id to copy its id',
    handler: (context, ref, {required sessionId, required arg}) async {
      // WHY a CLIENT command and not sent to the agent (D7): pi's own `/session`
      // is an agent command, so in makit's composer it would fall through to
      // `store.sendMessage` and — mid-turn — land in the server's pending queue,
      // executing only after the turn it was meant to help you hand off.
      // Intercepting it here answers at 100% of a turn. This handler returning
      // (via `handleClientCommand` matching) is the fix for that bug.
      //
      // Resolved before any await (SPEC-status-and-activity D3, enforced by
      // `test/status/status_lifetime_test.dart`): `ref` dies with its widget.
      final status = ref.status;
      // `/session id` copies ONLY the bare agent session id (D6). The panel's
      // `Copy all` is the "give me everything" job; this is "give me the id", so
      // it must not emit the whole label:value payload.
      if (arg == 'id') {
        final id = ref.read(sessionIdentityProvider(sessionId)).agentSessionId;
        if (id == null) {
          // Say why rather than copying an empty string: a draft (or a back end
          // with no native session concept) has no id to hand off yet.
          status.warning(
            'No agent session id yet',
            source: StatusSources.session,
            sessionId: sessionId,
          );
          return;
        }
        // A clipboard write can throw for real (another process holds it on
        // Windows; the host denies it). Unreported, the user gets neither the id
        // nor a reason — so the write is waited on, and only a write that landed
        // is allowed to claim success. Same contract as the panel's `Copy all`.
        try {
          await Clipboard.setData(ClipboardData(text: id));
        } catch (e) {
          status.failure(
            'Could not copy session id',
            error: e,
            source: StatusSources.session,
            sessionId: sessionId,
          );
          return;
        }
        status.info(
          'Session id copied',
          source: StatusSources.session,
          detail: id,
          sessionId: sessionId,
        );
        return;
      }
      // Bare `/session` opens the panel. Presented as a bottom sheet
      // (`desktop: false`) like the other client commands (`/model`,
      // `/thinking`): the invocation comes from the composer, where a sheet is
      // the established surface. `sessionId` is passed so the open panel watches
      // and fills in live (D19).
      if (!context.mounted) return;
      await showSessionIdentity(
        context: context,
        desktop: false,
        sessionId: sessionId,
      );
    },
  ),
  ClientCommand(
    name: 'name',
    description: 'Rename this session (shown in the session list)',
    handler: (context, ref, {required sessionId, required arg}) async {
      // Resolved before the first await: `ref` throws once its widget is
      // unmounted, and the record must survive the thing that reported to it.
      final status = ref.status;
      final current = ref.read(sessionsProvider).byId(sessionId)?.title ?? '';
      final title = arg.isNotEmpty
          ? arg
          : await _promptSessionName(context, initial: current);
      if (title == null || title.isEmpty || !context.mounted) return;
      ref
          .read(storeControllerProvider.notifier)
          .sendSessionAction(sessionId, 'name', args: {'name': title});
      status.success(
        'Renamed to “$title”',
        source: StatusSources.session,
        sessionId: sessionId,
      );
    },
  ),
];

/// Prompt for a session name via a simple text dialog. Resolves with the
/// trimmed name, or null if dismissed/empty.
Future<String?> _promptSessionName(
  BuildContext context, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: controller.text.length,
  );
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rename session'),
      content: StatefulBuilder(
        builder: (ctx, setState) => TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'Session name',
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(PhosphorIconsLight.x),
                    tooltip: 'Clear',
                    onPressed: () {
                      controller.clear();
                      setState(() {});
                    },
                  ),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Rename'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

/// pi's thinking levels, low → high. `off` disables reasoning. Shared with the
/// composer's [ThinkingSignal] indicator so the bar count matches the picker.
const thinkingLevels = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh'];

/// Present the thinking-level options in a modal sheet; resolves with the
/// chosen level or null if dismissed.
Future<String?> _pickThinkingLevel(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader(title: 'Thinking level'),
          for (final level in thinkingLevels)
            ListTile(
              title: Text(level),
              onTap: () => Navigator.pop(sheetContext, level),
            ),
        ],
      ),
    ),
  );
}

/// Present the selectable models in a modal sheet, marking [current]. Resolves
/// with the chosen model or null if dismissed. The sheet is capped at ~85% of
/// the screen height and offers a search button to filter by name/provider.
Future<ModelInfo?> _pickModel(
  BuildContext context,
  List<ModelInfo> models,
  ModelInfo? current,
) {
  bool matches(ModelInfo m, String q) {
    final ql = q.toLowerCase();
    return m.name.toLowerCase().contains(ql) ||
        m.provider.toLowerCase().contains(ql);
  }

  return showSearchableListSheet<ModelInfo>(
    context: context,
    title: 'Model',
    items: models,
    matches: matches,
    tileBuilder: (ctx, m) => ListTile(
      title: Text(m.name),
      subtitle: Text(m.provider),
      trailing:
          (current != null &&
              current.provider == m.provider &&
              current.id == m.id)
          ? const Icon(PhosphorIconsLight.check)
          : null,
      onTap: () => Navigator.of(ctx).pop(m),
    ),
  );
}
