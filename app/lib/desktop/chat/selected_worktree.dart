import 'package:flutter/foundation.dart';

/// A sessionless worktree shown in a pane. Puts the pane in "start a session
/// here" mode (harness cards); the session is spawned in this existing worktree
/// on the first message. A pane hosts either a session or a [SelectedWorktree]
/// (or nothing) — never both.
///
/// Lives in its own file so the pure pane-tree model ([PaneLeaf]) can bind one
/// without importing the provider layer (which would form an import cycle).
@immutable
class SelectedWorktree {
  const SelectedWorktree({
    required this.projectId,
    required this.path,
    required this.branch,
  });

  final String projectId;
  final String path;
  final String? branch;

  @override
  bool operator ==(Object other) =>
      other is SelectedWorktree &&
      other.projectId == projectId &&
      other.path == path &&
      other.branch == branch;

  @override
  int get hashCode => Object.hash(projectId, path, branch);
}
