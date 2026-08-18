import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';
import '../metrics/metrics_dashboard.dart';
import '../window_overlays.dart';

// The overlay flags live in one place so their mutual exclusion cannot be
// forgotten by a call site; re-exported so existing importers of
// `settingsOpenProvider` are unaffected.
export '../window_overlays.dart' show settingsOpenProvider;
import '../../store/store.dart';
import 'registry/settings_registry.dart';
import 'settings_detail_pane.dart';
import 'settings_item_anchor.dart';
import 'settings_nav_pane.dart';

/// Whether the in-window Settings surface is showing. Flipped by the sidebar's
/// Settings button; consumed by [DesktopWindowBody]. Kept as a provider (not a
/// route) so opening is instant and preserves the underlying chat state
/// (SPEC-desktop-settings-rework requirement #5).

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
    // Single-overlay invariant (SPEC-performance-metrics-dashboard decision 9): Settings and the metrics
    // dashboard share this z-space, so opening either closes the other. Enforced
    // here, in the one widget that hosts both, instead of at every call site that
    // opens one of them. Each listener reacts only to a transition *to* true, so
    // the pair cannot recurse.
    ref.listen<bool>(settingsOpenProvider, (_, next) {
      if (next) ref.read(metricsDashboardOpenProvider.notifier).state = false;
    });
    ref.listen<bool>(metricsDashboardOpenProvider, (_, next) {
      if (next) ref.read(settingsOpenProvider.notifier).state = false;
    });
    final open = ref.watch(settingsOpenProvider);
    final dashboardOpen = ref.watch(metricsDashboardOpenProvider);
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
        // SPEC-performance-metrics-dashboard Tier 2. Deliberately NOT wrapped in ExcludeFocus/
        // ExcludeSemantics like Settings above: the whole point of the dashboard
        // is watching cost *while* you drive a session, so the chat underneath
        // must stay interactive and reachable by assistive tech.
        if (dashboardOpen)
          Positioned.fill(
            child: MetricsDashboard(
              onClose: () =>
                  ref.read(metricsDashboardOpenProvider.notifier).state = false,
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
  /// Fixed nav-pane width (SPEC-desktop-settings-rework assumption #2: list + leading icons ~260px).
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
    // Resolved against the STATIC list here, because the repo snapshot may not
    // have arrived yet. A stored `repo:<id>` is honoured in build(), once the
    // sections that could contain it exist.
    _selectedId = kSettingsSections.any((s) => s.id == stored)
        ? stored
        : isRepoSection(stored)
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
    // A function of the live repo list: one section per pinned repo (SPEC-per-repo-settings D1).
    final sections = sectionsFor(ref.watch(reposProvider).repos);
    // Falls back rather than throwing when the selected repo disappears — removed
    // while its section was open, or a stored id whose repo is gone.
    final section = sections.firstWhere(
      (s) => s.id == _selectedId,
      orElse: () => sections.first,
    );
    // The nav pane is told which section is ACTUALLY shown, not what was requested.
    // When a stored `repo:<id>` is no longer available the detail pane falls back to
    // the first section while `_selectedId` still held the missing id, so the sidebar
    // highlighted nothing and the window looked like it had lost its place.
    final effectiveSelectedId = section.id;
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
                      sections: sections,
                      selectedId: effectiveSelectedId,
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
