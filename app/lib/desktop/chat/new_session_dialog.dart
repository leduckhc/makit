import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/project/folder_browser.dart';
import 'selected_session.dart';

/// Opens the "New session" dialog: pick a project + a harness, then spawn.
Future<void> showNewSessionDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _NewSessionDialog(),
  );
}

class _NewSessionDialog extends ConsumerStatefulWidget {
  const _NewSessionDialog();

  @override
  ConsumerState<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends ConsumerState<_NewSessionDialog> {
  List<AgentDescriptor> _agents = const [];
  bool _loadingAgents = true;
  String? _projectId;
  String? _agentId;
  bool _spawning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAgents();
    // Preselect the first project if there is exactly one obvious choice.
    final projects = ref.read(projectsProvider).projects;
    if (projects.isNotEmpty) _projectId = projects.first.id;
  }

  Future<void> _loadAgents() async {
    final agents = await ref
        .read(storeControllerProvider.notifier)
        .fetchAgents();
    if (!mounted) return;
    setState(() {
      _agents = agents;
      _agentId = agents
          .firstWhere(
            (a) => a.available,
            orElse: () => agents.isEmpty
                ? const AgentDescriptor(
                    id: '',
                    label: '',
                    transport: '',
                    available: false,
                  )
                : agents.first,
          )
          .id;
      if (_agentId!.isEmpty) _agentId = null;
      _loadingAgents = false;
    });
  }

  Future<void> _addProject() async {
    final id = await showFolderBrowser(context);
    if (!mounted || id == null) return;
    setState(() => _projectId = id);
  }

  Future<void> _start() async {
    final projectId = _projectId;
    if (projectId == null) return;
    setState(() {
      _spawning = true;
      _error = null;
    });
    try {
      final sessionId = await ref
          .read(storeControllerProvider.notifier)
          .spawnSession(projectId, agent: _agentId);
      if (!mounted) return;
      ref.read(selectedSessionProvider.notifier).state = sessionId;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _spawning = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(projectsProvider).projects;
    final canStart = _projectId != null && !_spawning;

    return AlertDialog(
      title: const Text('New session'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Project'),
            const SizedBox(height: 6),
            if (projects.isEmpty)
              OutlinedButton.icon(
                onPressed: _addProject,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add a project folder'),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: _projectId,
                isExpanded: true,
                items: [
                  for (final p in projects)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: (v) => setState(() => _projectId = v),
              ),
            const SizedBox(height: 16),
            const Text('Harness'),
            const SizedBox(height: 6),
            if (_loadingAgents)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (_agents.isEmpty)
              const Text('Using the host default harness.')
            else
              DropdownButtonFormField<String>(
                initialValue: _agentId,
                isExpanded: true,
                items: [
                  for (final a in _agents)
                    DropdownMenuItem(
                      value: a.id,
                      enabled: a.available,
                      child: Text(
                        a.available ? a.label : '${a.label} (unavailable)',
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _agentId = v),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _spawning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canStart ? _start : null,
          child: _spawning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Start'),
        ),
      ],
    );
  }
}
