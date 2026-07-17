import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The focus node for a desktop chat composer's text field, keyed by the
/// hosting pane's leaf id. Held per-leaf (not app-wide) so two split panes each
/// bind their own text field to their own node — sharing one node would
/// double-attach two `TextField`s to a single `FocusNode` (illegal). The global
/// "focus composer" shortcut targets the active leaf's node via this family.
///
/// `autoDispose` ties each node's lifetime to its pane: when a leaf closes and
/// nothing watches its node, the provider disposes it — no leak, no manual
/// registry. The [Composer] borrows the node rather than creating its own.
final desktopComposerFocusProvider = Provider.autoDispose
    .family<FocusNode, String>((ref, leafId) {
      final node = FocusNode(debugLabel: 'desktopComposer:$leafId');
      ref.onDispose(node.dispose);
      return node;
    });
