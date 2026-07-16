import 'package:flutter/material.dart';

import '../../store/models.dart';

/// Choice returned by [NewSessionSheet]: which agent + base branch to use.
class NewSessionChoice {
  const NewSessionChoice({this.agent, this.baseBranch});
  final String? agent;
  final String? baseBranch;
}

/// Bottom sheet that lets the user pick the base branch to fork off and, when
/// more than one agent is available, which agent to spawn. Empty [agents] or
/// [branches] hide that section. Pops a [NewSessionChoice], or null if
/// dismissed. (SPEC-19, moved from home_screen.)
class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({
    super.key,
    required this.agents,
    required this.branches,
    this.initialBranch,
  });

  final List<AgentDescriptor> agents;
  final List<String> branches;
  final String? initialBranch;

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  String? _agent;
  String? _branch;

  @override
  void initState() {
    super.initState();
    _branch =
        widget.initialBranch ??
        (widget.branches.isEmpty ? null : widget.branches.first);
    _agent = widget.agents.isEmpty ? null : widget.agents.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New session', style: theme.textTheme.titleMedium),
            if (widget.branches.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Branch from'),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: widget.branches.contains(_branch)
                    ? _branch
                    : widget.branches.first,
                isExpanded: true,
                items: [
                  for (final b in widget.branches)
                    DropdownMenuItem(
                      value: b,
                      child: Text(b, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _branch = v),
              ),
            ],
            if (widget.agents.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Agent'),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _agent,
                isExpanded: true,
                items: [
                  for (final a in widget.agents)
                    DropdownMenuItem(value: a.id, child: Text(a.label)),
                ],
                onChanged: (v) => setState(() => _agent = v),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                NewSessionChoice(agent: _agent, baseBranch: _branch),
              ),
              child: const Text('Start'),
            ),
          ],
        ),
      ),
    );
  }
}
