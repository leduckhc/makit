import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';
import 'registry/settings_registry.dart';
import 'settings_detail_pane.dart';
import 'settings_item_anchor.dart';
import 'settings_nav_pane.dart';

/// Whether the in-window Settings surface is showing. Flipped by the sidebar's
/// Settings button; consumed by [DesktopWindowBody]. Kept as a provider (not a
/// route) so opening is instant and preserves the underlying chat state
/// (SPEC-13 requirement #5).
final settingsOpenProvider = StateProvider<bool>((_) => false);

/// Stacks the desktop [child] (the chat shell) with the [SettingsWindow] as an
/// in-window overlay when [settingsOpenProvider] is set — no page transition,
/// so the chat state underneath stays alive.
class DesktopWindowBody extends ConsumerWidget {
  /// Creates the window body around [child].
  const DesktopWindowBody({required this.child, super.key});

  /// The primary window content (the chat shell).
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(settingsOpenProvider);
    return Stack(
      children: [
        // While Settings is open the chat underneath is excluded from focus
        // traversal and the semantics tree so it isn't reachable by keyboard or
        // assistive tech behind the modal overlay.
        ExcludeFocus(
          excluding: open,
          child: ExcludeSemantics(excluding: open, child: child),
        ),
        if (open)
          Positioned.fill(
            child: SettingsWindow(
              onClose: () =>
                  ref.read(settingsOpenProvider.notifier).state = false,
            ),
          ),
      ],
    );
  }
}

/// The two-pane Settings surface: a fixed-width nav pane (section list +
/// search) on the left and the selected section body on the right.
///
/// The selected section id is the `settings.lastSection` preference, so
/// reopening restores the same spot. Section switches are instant rebuilds
/// (no animation).
class SettingsWindow extends ConsumerStatefulWidget {
  /// Creates the settings window. [onClose] dismisses the in-window surface.
  const SettingsWindow({required this.onClose, super.key});

  /// Invoked by the close affordance.
  final VoidCallback onClose;

  @override
  ConsumerState<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends ConsumerState<SettingsWindow> {
  /// Fixed nav-pane width (SPEC-13 assumption #2: list + leading icons ~260px).
  static const double _navWidth = 260;

  late String _selectedId;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final stored = ref
        .read(preferencesControllerProvider.notifier)
        .get(lastSectionPreference);
    _selectedId = kSettingsSections.any((s) => s.id == stored)
        ? stored
        : kSettingsSections.first.id;
  }

  void _select(String sectionId, {String? targetItemId}) {
    setState(() {
      _selectedId = sectionId;
      _query = '';
    });
    // Clear the visible search text too (the field is controlled), otherwise a
    // stale query lingers after switching sections / picking a result.
    _searchController.clear();
    ref
        .read(preferencesControllerProvider.notifier)
        .set(lastSectionPreference, sectionId);
    // Point any anchored row at the deep-linked item (null when navigating by
    // section, so a prior highlight target is cleared).
    ref.read(settingsTargetItemProvider.notifier).state = targetItemId;
  }

  /// Selects the section that owns a search result and deep-links to the item.
  void _selectResult(String sectionId, String itemId) =>
      _select(sectionId, targetItemId: itemId);

  @override
  Widget build(BuildContext context) {
    final section = kSettingsSections.firstWhere((s) => s.id == _selectedId);
    // A modal focus scope: traps tab traversal inside Settings, binds Escape to
    // close, and marks the subtree as a route for assistive tech.
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        },
        child: Focus(
          autofocus: true,
          skipTraversal: true,
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            child: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: _navWidth,
                    child: SettingsNavPane(
                      sections: kSettingsSections,
                      selectedId: _selectedId,
                      query: _query,
                      controller: _searchController,
                      onQueryChanged: (q) => setState(() => _query = q),
                      onSelect: _select,
                      onSelectResult: _selectResult,
                      onClose: widget.onClose,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: SettingsDetailPane(section: section)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
