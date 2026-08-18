import 'package:flutter/foundation.dart';

/// A sessionless worktree hint carried by an empty [Tab]. Used only to pre-fill
/// the New-session dialog's Worktree field (SPEC-desktop-workspace-tabs decision 4) — never an
/// inline picker.
///
/// Lives in its own file so the pure workspace-tree model ([Tab]) can carry one
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

  /// JSON for persistence (see [Tab]).
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
