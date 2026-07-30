/// SPEC-30 Lane 3 — placement policy (decision 9) and membership reconciliation.
///
/// Two pure operations over the split/tab tree, kept free of the widget layer
/// so their tests stay fast and deterministic:
///
/// * [place] — where a newly shown session lands (a new split, or a tab in the
///   active split). It **never re-arranges** anything already on the canvas;
///   that invariant is the whole point of the lane (decision 9).
/// * [reconcile] — bring a group's tree in line with its resolved membership:
///   place members not yet shown, drop tabs whose session is no longer a
///   member, and leave every other pane exactly where it was.
///
/// Both delegate their tree surgery to [WorkspaceController], which already owns
/// the tree invariants (collapse-on-empty, active-split focus, dedupe). The
/// pure variants run that controller with a null commit sink over a throwaway
/// copy; the `*Into` variants drive a live controller so a reactive caller's
/// mutations flow through its sink to the groups layer.
library;

import 'package:flutter/widgets.dart' show Axis;

import '../panes/split_node.dart';
import '../panes/workspace_controller.dart';

import '../selected_worktree.dart';
import 'group.dart';

/// The evolving tree of [c].
///
/// Placement legitimately drives a [WorkspaceController] and must observe its
/// tree *between* mutations, but `.state` is protected outside a StateNotifier
/// subclass (`groups_controller.dart` does the identical thing and is exempt
/// only because it *is* one). Funnelling every read through here keeps the
/// suppression to a single line instead of a file-wide `ignore_for_file`, which
/// would also hide any future accidental misuse.
// ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
WorkspaceState _treeOf(WorkspaceController c) => c.state;

/// Places [sessionId] into [tree] per [mode] and returns the new tree, leaving
/// every pane already present byte-identical (decision 9).
WorkspaceState place(
  WorkspaceState tree,
  String sessionId, {
  required LayoutMode mode,
}) {
  final scratch = WorkspaceController(null, tree);
  placeInto(scratch, sessionId, mode: mode);
  return _treeOf(scratch);
}

/// Applies [place]'s policy to a **live** [controller], so the mutation is
/// reported through its commit sink. A session already shown is left where it
/// is (decision 3: at most once per group).
void placeInto(
  WorkspaceController controller,
  String sessionId, {
  required LayoutMode mode,
}) {
  if (controller.isSessionBound(sessionId)) return;
  switch (mode) {
    case LayoutMode.tabs:
      // Fill the active split's empty placeholder if there is one, else append
      // a tab there — both are [revealSession]'s job.
      controller.revealSession(sessionId);
    case LayoutMode.split:
      // Split beside the existing panes, then bind the session into the new
      // split's fresh placeholder. When nothing is shown yet there is nothing
      // to split beside, so just fill the starter tab.
      if (_hasBoundTab(_treeOf(controller))) {
        controller.divideActive(Axis.horizontal);
      }
      controller.revealSession(sessionId);
  }
}

/// Returns [tree] reconciled to [members]: members not yet shown are placed,
/// tabs whose session is no longer a member are removed, and everything else is
/// untouched. An empty worktree group seeds its starter tab with [emptyHint]
/// (decision 20) so the pane renders `WorktreeStarter` rather than the
/// no-worktree placeholder.
WorkspaceState reconcile(
  WorkspaceState tree,
  List<String> members, {
  required int threshold,
  LayoutMode? layoutOverride,
  SelectedWorktree? emptyHint,
}) {
  final scratch = WorkspaceController(null, tree);
  reconcileInto(
    scratch,
    members,
    threshold: threshold,
    layoutOverride: layoutOverride,
    emptyHint: emptyHint,
  );
  return _treeOf(scratch);
}

/// Applies [reconcile] to a **live** [controller]. The placement mode is
/// recomputed for each new session from the count already shown, so a burst of
/// arrivals still respects the threshold (the first N-1 split, the rest tab) —
/// exactly as they would landing one snapshot at a time.
void reconcileInto(
  WorkspaceController controller,
  List<String> members, {
  required int threshold,
  LayoutMode? layoutOverride,
  SelectedWorktree? emptyHint,
  Set<String> unlocated = const {},
}) {
  final memberSet = members.toSet();

  // (b) Drop tabs whose session is no longer a member. Done first so their
  // splits collapse before we measure how many panes are shown.
  //
  // [unlocated] sessions are exempt: a session the server has not placed in a
  // worktree yet (a freshly spawned draft, before its first message promotes
  // it) is *pending placement*, not out-of-scope. Dropping it would make the
  // tab the New-session dialog just opened vanish on the next snapshot and
  // reappear a moment later — the user would see a flicker and lose their
  // composer text. It is left alone until the server says where it lives.
  for (final id in boundSessionIds(_treeOf(controller))) {
    if (memberSet.contains(id) || unlocated.contains(id)) continue;
    controller.unbindSession(id);
  }

  // (a) Place members not yet shown, honouring the group's override or, absent
  // one, the threshold against the running shown-count.
  for (final id in members) {
    if (controller.isSessionBound(id)) continue;
    final mode =
        layoutOverride ??
        (_boundCount(_treeOf(controller)) < threshold
            ? LayoutMode.split
            : LayoutMode.tabs);
    placeInto(controller, id, mode: mode);
  }

  // (decision 20) An empty worktree group renders the in-pane starter, which
  // needs its scope on the placeholder tab. A pending tab still counts as
  // occupied, so the starter does not replace a session you just started.
  if (memberSet.isEmpty &&
      emptyHint != null &&
      !_hasBoundTab(_treeOf(controller))) {
    _seedEmptyHint(controller, emptyHint);
  }
}

/// Seeds the active empty placeholder with [hint] when it is not already there,
/// so the starter knows which worktree to run in. No-op once a session is bound
/// or the hint already matches (keeping the tree byte-identical).
void _seedEmptyHint(WorkspaceController controller, SelectedWorktree hint) {
  final tab = _activeTab(_treeOf(controller));
  if (tab == null || tab.sessionId != null || tab.worktree == hint) return;
  controller.revealWorktree(hint);
}

/// Every session id hosted by a tab anywhere in [state].
List<String> boundSessionIds(WorkspaceState state) {
  final ids = <String>[];
  firstSplitWhere<bool>(state.root, (split) {
    ids.addAll(split.tabs.map((t) => t.sessionId).nonNulls);
    return null;
  });
  return ids;
}

int _boundCount(WorkspaceState state) => boundSessionIds(state).length;

bool _hasBoundTab(WorkspaceState state) =>
    firstSplitWhere<bool>(state.root, (split) {
      for (final t in split.tabs) {
        if (t.sessionId != null) return true;
      }
      return null;
    }) ??
    false;

Tab? _activeTab(WorkspaceState state) {
  final split = firstSplitWhere<Split>(
    state.root,
    (s) => s.id == state.activeSplitId ? s : null,
  );
  if (split == null) return null;
  for (final t in split.tabs) {
    if (t.id == split.activeTabId) return t;
  }
  return null;
}
