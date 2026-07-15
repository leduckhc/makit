import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The focus node for the desktop chat composer's text field. Held app-wide so
/// the global "focus composer" shortcut can move the cursor into the field
/// from anywhere in the window. Owned by the provider (app-lifetime); the
/// [Composer] borrows it rather than creating its own.
final desktopComposerFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'desktopComposer');
  ref.onDispose(node.dispose);
  return node;
});
