/// SPEC-30 — the **group** model: a named view over the session list, plus the
/// split/tab tree that view is arranged in.
///
/// A group is never a *place*: it cannot tell an agent where to run. It only
/// answers "what is on the canvas?", and it answers that in one of two ways —
/// derived from a worktree, or curated by hand. Everything else in SPEC-30
/// follows from that distinction, so it is modelled as a single sealed-ish
/// value type with a [kind] rather than two classes: callers switch on [kind]
/// and the persistence format stays one shape.
library;

import 'package:flutter/foundation.dart';

import '../panes/workspace_controller.dart' show WorkspaceState;

/// Who decides what a group shows.
enum GroupKind {
  /// Membership is **derived**: every session in `(projectId, worktreePath)`,
  /// and nothing else. New sessions on that branch join automatically.
  worktree,

  /// Membership is **curated**: an explicit, ordered list of session ids that
  /// may span branches and repositories. Nothing joins unless the user adds it.
  board,
}

/// How a group places a newly shown session (SPEC-30 decision 9).
///
/// Deliberately *not* a rendering mode: the tree is always whatever the user
/// last arranged, and nothing re-arranges it automatically. This only decides
/// where the next session lands.
enum LayoutMode {
  /// Open it as a new split beside the existing panes.
  split,

  /// Open it as a new tab in the focused split.
  tabs,
}

/// A view over the session list: which sessions, and how they are arranged.
@immutable
class Group {
  const Group._({
    required this.id,
    required this.kind,
    required this.label,
    required this.members,
    required this.tree,
    this.projectId,
    this.worktreePath,
    this.layoutOverride,
  });

  /// A group whose membership is derived from `(projectId, worktreePath)`.
  factory Group.worktree({
    required String id,
    required String projectId,
    required String worktreePath,
    required String label,
    required WorkspaceState tree,
    LayoutMode? layoutOverride,
  }) => Group._(
    id: id,
    kind: GroupKind.worktree,
    label: label,
    projectId: projectId,
    worktreePath: worktreePath,
    members: const [],
    tree: tree,
    layoutOverride: layoutOverride,
  );

  /// A group whose membership is the hand-picked [members] list. Duplicates are
  /// dropped (decision 3: at most once per group), first-seen order preserved.
  factory Group.board({
    required String id,
    required String label,
    required WorkspaceState tree,
    List<String> members = const [],
    LayoutMode? layoutOverride,
  }) => Group._(
    id: id,
    kind: GroupKind.board,
    label: label,
    members: _dedupe(members),
    tree: tree,
    layoutOverride: layoutOverride,
  );

  /// Rebuilds a group from [toJson], or **null** when the entry is unusable.
  ///
  /// Returning null rather than throwing is deliberate: one corrupt group must
  /// cost the user that group, not every other group in the file.
  static Group? fromJson(Map<String, Object?> json) {
    try {
      final id = json['id'];
      final label = json['label'];
      final rawTree = json['tree'];
      if (id is! String || id.isEmpty) return null;
      if (label is! String) return null;
      if (rawTree is! Map<String, Object?>) return null;
      final tree = WorkspaceState.fromJson(rawTree);
      final override = _layoutFromJson(json['layoutOverride']);

      switch (json['kind']) {
        case 'worktree':
          final projectId = json['projectId'];
          final worktreePath = json['worktreePath'];
          // Without a scope a worktree group could never resolve its members,
          // so it is corrupt rather than merely empty.
          if (projectId is! String || projectId.isEmpty) return null;
          if (worktreePath is! String || worktreePath.isEmpty) return null;
          return Group.worktree(
            id: id,
            projectId: projectId,
            worktreePath: worktreePath,
            label: label,
            tree: tree,
            layoutOverride: override,
          );
        case 'board':
          final raw = json['members'];
          return Group.board(
            id: id,
            label: label,
            members: raw is List ? raw.whereType<String>().toList() : const [],
            tree: tree,
            layoutOverride: override,
          );
        case _:
          return null;
      }
    } on Object {
      // FormatException from a bogus node kind, a cast failure, anything: the
      // entry is dropped by the caller.
      return null;
    }
  }

  /// Stable identity, minted once and persisted.
  final String id;

  /// Whether membership is derived or curated.
  final GroupKind kind;

  /// The branch name (worktree groups) or the board's name.
  final String label;

  /// Worktree groups only: the project half of the scope.
  final String? projectId;

  /// Worktree groups only: the worktree path half of the scope.
  final String? worktreePath;

  /// Boards only: the curated, de-duplicated, ordered member list. Always empty
  /// for a worktree group, whose membership is derived on demand.
  final List<String> members;

  /// The placement mode the user pinned, or null to follow the threshold
  /// preference (decision 9).
  final LayoutMode? layoutOverride;

  /// This group's own split/tab tree — the SPEC-28 workspace, one per group.
  final WorkspaceState tree;

  /// Whether this group's scope is exactly `(projectId, worktreePath)`. Always
  /// false for a board, which owns no scope.
  bool isScopedTo({required String projectId, required String? worktreePath}) =>
      kind == GroupKind.worktree &&
      this.projectId == projectId &&
      worktreePath != null &&
      this.worktreePath == worktreePath;

  /// A copy with the named fields replaced. [layoutOverride] is **preserved** —
  /// a nullable `copyWith` argument cannot express "clear it" and "leave it" at
  /// once, so clearing has its own method ([withLayout]) rather than a sentinel.
  Group copyWith({
    String? label,
    List<String>? members,
    WorkspaceState? tree,
  }) => Group._(
    id: id,
    kind: kind,
    label: label ?? this.label,
    projectId: projectId,
    worktreePath: worktreePath,
    members: kind == GroupKind.board
        ? _dedupe(members ?? this.members)
        : const [],
    tree: tree ?? this.tree,
    layoutOverride: layoutOverride,
  );

  /// A copy pinned to [mode], or following the threshold again when null.
  Group withLayout(LayoutMode? mode) => Group._(
    id: id,
    kind: kind,
    label: label,
    projectId: projectId,
    worktreePath: worktreePath,
    members: members,
    tree: tree,
    layoutOverride: mode,
  );

  /// JSON for persistence. Scope is written only for worktree groups and
  /// `members` only for boards, so a round-trip cannot smuggle one kind's data
  /// into the other.
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'label': label,
    if (kind == GroupKind.worktree) 'projectId': projectId,
    if (kind == GroupKind.worktree) 'worktreePath': worktreePath,
    if (kind == GroupKind.board) 'members': members,
    if (layoutOverride != null)
      'layoutOverride': layoutOverride == LayoutMode.split ? 'split' : 'tabs',
    'tree': tree.toJson(),
  };

  static List<String> _dedupe(List<String> ids) {
    final seen = <String>{};
    return [
      for (final id in ids)
        if (seen.add(id)) id,
    ];
  }

  /// An unknown value degrades to null (follow the threshold) rather than
  /// invalidating the whole group.
  static LayoutMode? _layoutFromJson(Object? raw) => switch (raw) {
    'split' => LayoutMode.split,
    'tabs' => LayoutMode.tabs,
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is Group &&
      other.id == id &&
      other.kind == kind &&
      other.label == label &&
      other.projectId == projectId &&
      other.worktreePath == worktreePath &&
      listEquals(other.members, members) &&
      other.layoutOverride == layoutOverride &&
      other.tree == tree;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    label,
    projectId,
    worktreePath,
    Object.hashAll(members),
    layoutOverride,
    tree,
  );

  @override
  String toString() =>
      'Group($id, ${kind.name}, "$label", '
      '${kind == GroupKind.worktree ? '$projectId:$worktreePath' : '${members.length} members'})';
}
