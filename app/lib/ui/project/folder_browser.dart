import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';

/// Present the folder browser as a full-height modal sheet. Resolves with the
/// added project's id when the user adds a folder, or null if dismissed.
Future<String?> showFolderBrowser(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        const FractionallySizedBox(heightFactor: 0.92, child: FolderBrowser()),
  );
}

/// A polished server-side folder picker. Browses the server's filesystem,
/// highlights git repos, and lets the user add the current folder as a project
/// — either by descending the tree or typing an absolute path.
class FolderBrowser extends ConsumerStatefulWidget {
  const FolderBrowser({super.key});

  @override
  ConsumerState<FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends ConsumerState<FolderBrowser> {
  BrowseResult? _result;
  bool _loading = true;
  bool _adding = false;
  String? _error;
  final _pathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _browse(null);
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _browse(String? path) async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(storeControllerProvider.notifier)
          .browse(path);
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      status.failure(
        'Could not browse folder',
        error: e,
        source: StatusSources.repo,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _add(String path, String name) async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    if (_adding) return;
    setState(() => _adding = true);
    final navigator = Navigator.of(context);
    try {
      final id = await ref
          .read(storeControllerProvider.notifier)
          .addProject(path);
      if (!mounted) return;
      navigator.pop(id);
      status.success(
        'Added ${name.isEmpty ? path : name}',
        source: StatusSources.repo,
      );
    } catch (e) {
      status.failure(
        'Could not add project',
        error: e,
        source: StatusSources.repo,
      );
      if (!mounted) return;
      setState(() => _adding = false);
    }
  }

  void _submitTypedPath() {
    final typed = _pathController.text.trim();
    if (typed.isEmpty) return;
    _browse(typed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    final currentPath = result?.path ?? '';
    final baseName = currentPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .lastOrNull;

    return Column(
      children: [
        _Header(
          path: currentPath,
          canGoUp: result?.parent != null && !_loading,
          onUp: () => _browse(result?.parent),
        ),
        const Divider(height: 1),
        Expanded(child: _body(theme)),
        const Divider(height: 1),
        _ManualEntry(controller: _pathController, onSubmit: _submitTypedPath),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: FilledButton.icon(
              icon: _adding
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(PhosphorIconsLight.plus),
              label: Text(
                currentPath.isEmpty
                    ? 'Add this folder'
                    : 'Add “${baseName ?? currentPath}”',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: (_loading || _adding || currentPath.isEmpty)
                  ? null
                  : () => _add(currentPath, baseName ?? ''),
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(kSpace24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                PhosphorIconsLight.warningCircle,
                size: 40,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: kSpace12),
              Text(
                "Couldn't read this folder.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: kSpace12),
              OutlinedButton(
                onPressed: () => _browse(_result?.path),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final entries = _result?.entries ?? const [];
    if (entries.isEmpty) {
      return Center(
        child: Text('No subfolders', style: theme.textTheme.bodyMedium),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: kSpace4),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        return ListTile(
          leading: Icon(
            entry.isRepo
                ? PhosphorIconsLight.gitBranch
                : PhosphorIconsLight.folder,
            color: entry.isRepo ? theme.colorScheme.primary : null,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: entry.isRepo
              ? Chip(
                  label: const Text('repo'),
                  visualDensity: VisualDensity.compact,
                  labelStyle: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                  side: BorderSide(color: theme.colorScheme.primary),
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.08,
                  ),
                )
              : const Icon(PhosphorIconsLight.caretRight),
          onTap: () => _browse(entry.path),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.path,
    required this.canGoUp,
    required this.onUp,
  });

  final String path;
  final bool canGoUp;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 16, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(PhosphorIconsLight.arrowUp),
            tooltip: 'Up',
            onPressed: canGoUp ? onUp : null,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Add a project', style: theme.textTheme.titleMedium),
                const SizedBox(height: kSpace2),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Text(
                    path.isEmpty ? '…' : path,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualEntry extends StatelessWidget {
  const _ManualEntry({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        controller: controller,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => onSubmit(),
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(PhosphorIconsLight.keyboard),
          hintText: '…or enter a path',
          suffixIcon: IconButton(
            icon: const Icon(PhosphorIconsLight.arrowRight),
            tooltip: 'Go',
            onPressed: onSubmit,
          ),
        ),
      ),
    );
  }
}
