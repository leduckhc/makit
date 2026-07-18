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

  /// JSON for persistence (see [PaneTreeState]).
  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'path': path,
    'branch': branch,
  };

  /// Rebuilds a worktree from its [toJson] map.
  factory SelectedWorktree.fromJson(Map<String, Object?> json) =>
      SelectedWorktree(
        projectId: json['projectId'] as String,
        path: json['path'] as String,
        branch: json['branch'] as String?,
      );
}

/// The pane-tree key prefix for a still-pending draft's virtual worktree.
/// Distinguishes a session-scoped virtual key from every real worktree path so
/// the pane can host a draft's harness picker before anything exists on disk.
const String kDraftWorktreePrefix = 'draft:';

/// The virtual worktree for a still-pending draft [sessionId], keyed by
/// `draft:<sessionId>` so the pane tree can host the draft's harness picker
/// before any real worktree exists on disk. The key is distinct from every real
/// worktree path; the worktree materializes on the draft's first message.
SelectedWorktree draftWorktreeFor(String projectId, String sessionId) =>
    SelectedWorktree(
      projectId: projectId,
      path: '$kDraftWorktreePrefix$sessionId',
      branch: null,
    );
