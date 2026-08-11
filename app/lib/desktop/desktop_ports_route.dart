/// How the desktop shell opens the global Ports screen (SPEC-42 P2a, corrected).
///
/// The desktop window is a plain `MaterialApp(home: …)`; only the mobile app
/// uses `MaterialApp.router` + `routerProvider`. So every desktop affordance
/// that reached the screen with `context.go(kRoutePorts)` — the `⌘⇧P` shortcut
/// and the worktree menu's `Ports (n)…` — threw *No GoRouter found in context*
/// at runtime, while their widget tests passed because the tests wrapped the
/// widget in a router the real shell does not have.
///
/// One helper, used by all three entry points (shortcut, worktree menu,
/// menubar), so there is a single answer to "how does the desktop show Ports"
/// and the at-most-one guard cannot drift between them.
library;

import 'package:flutter/material.dart';

import '../ui/ports/ports_screen.dart';

/// Pushes [PortsScreen] on the desktop shell's navigator, at most once.
///
/// The guard matters because the keymap scope sits ABOVE the pushed route, so
/// `⌘⇧P` keeps firing while the screen is already on top — without it, holding
/// the chord stacks a pile of identical screens the user has to dismiss one by
/// one.
abstract final class DesktopPortsRoute {
  static bool _open = false;

  /// Whether the screen this helper pushed is currently on the navigator.
  /// Exposed for tests, which cannot otherwise observe the guard.
  @visibleForTesting
  static bool get isOpen => _open;

  /// Shows the Ports screen, optionally pre-filtered to [repoId] (D8). A null
  /// [navigator] (no window yet) is a no-op rather than a crash — the tray can
  /// be clicked before the shell has mounted.
  static Future<void> open(NavigatorState? navigator, {String? repoId}) async {
    if (navigator == null || _open) return;
    _open = true;
    try {
      await navigator.push(
        MaterialPageRoute<void>(builder: (_) => PortsScreen(repoId: repoId)),
      );
    } finally {
      _open = false;
    }
  }
}
