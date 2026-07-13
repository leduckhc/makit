import 'package:flutter/material.dart';

import 'desktop_chat_pane.dart';
import 'desktop_sidebar.dart';

/// The desktop chat surface: a fixed-width [DesktopSidebar] on the left and the
/// [DesktopChatPane] filling the rest. This is the primary window of the
/// desktop app (Unit E wires it into `runDesktopApp`).
class DesktopChatShell extends StatelessWidget {
  /// Creates the two-pane chat shell.
  const DesktopChatShell({super.key, this.onOpenSettings});

  /// Forwarded to the sidebar footer to open the Settings/Server section.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 280,
            child: DesktopSidebar(onOpenSettings: onOpenSettings),
          ),
          const VerticalDivider(width: 1),
          const Expanded(child: DesktopChatPane()),
        ],
      ),
    );
  }
}
