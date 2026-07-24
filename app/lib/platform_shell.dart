/// SPEC-28 (decision 10) — platform/size-class entry shell.
///
/// The workspace layout is promised for **desktop and iPad**. macOS always
/// gets it (bootstrapped separately in `runDesktopApp`). On iPadOS the choice
/// is by **size class**, not just `Platform`: a full-screen (regular×regular)
/// iPad reaches the workspace, while a Stage-Manager / Slide-Over / split-view
/// iPad in a compact width falls back to the mobile push-navigation router —
/// the same router iPhone always uses.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';

/// Minimum logical extent (in both dimensions) treated as a *regular* size
/// class. Consistent with the existing 600px mobile/desktop breakpoint used
/// elsewhere in the app (e.g. the composer layout).
const double kWorkspaceMinExtent = 600;

/// Pure routing decision: should the given [platform]/[size] use the workspace
/// (desktop-style) shell rather than the mobile router?
///
/// - macOS → always the workspace shell.
/// - iOS → workspace only when both extents are a regular size class
///   (full-screen iPad); compact widths (iPhone, split-view) → mobile.
/// - everything else → mobile router.
bool prefersWorkspaceShell({
  required TargetPlatform platform,
  required Size size,
}) {
  switch (platform) {
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.iOS:
      return size.width >= kWorkspaceMinExtent &&
          size.height >= kWorkspaceMinExtent;
    default:
      return false;
  }
}

/// Chooses the workspace (desktop) widget tree or the mobile router based on
/// the live [MediaQuery] size class and the current platform.
///
/// The choice sits at the top of the widget tree and reads [MediaQuery.sizeOf],
/// so it rebuilds — and re-selects — automatically on iPad rotation / resize
/// without any explicit listener or extra state.
class PlatformShell extends StatelessWidget {
  const PlatformShell({
    super.key,
    required this.workspaceBuilder,
    required this.mobileBuilder,
  });

  /// Builds the desktop-style workspace tree (macOS / regular iPad).
  final WidgetBuilder workspaceBuilder;

  /// Builds the mobile push-navigation router (iPhone / compact iPad).
  final WidgetBuilder mobileBuilder;

  @override
  Widget build(BuildContext context) {
    final useWorkspace = prefersWorkspaceShell(
      platform: defaultTargetPlatform,
      size: MediaQuery.sizeOf(context),
    );
    return useWorkspace ? workspaceBuilder(context) : mobileBuilder(context);
  }
}
