import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../chat/sidebar_layout.dart' show kTitleBarStripHeight;
import 'registry/settings_item.dart';
import 'registry/settings_registry.dart';
import 'registry/settings_section.dart';

/// Left pane: a close/title header, a search field, and either the section list
/// or a flat list of search results that deep-link into a section.
class SettingsNavPane extends StatelessWidget {
  /// Creates the nav pane.
  const SettingsNavPane({
    required this.sections,
    required this.selectedId,
    required this.query,
    required this.controller,
    required this.onQueryChanged,
    required this.onSelect,
    required this.onSelectResult,
    required this.onClose,
    super.key,
  });

  /// All sections, in display order.
  final List<SettingsSection> sections;

  /// The currently selected section id.
  final String selectedId;

  /// The current search query (empty = show the section list).
  final String query;

  /// Controls the search field's text, so the owner can clear it (e.g. after a
  /// result is picked) and the displayed text stays in sync with [query].
  final TextEditingController controller;

  /// Called as the search field changes.
  final ValueChanged<String> onQueryChanged;

  /// Called to select a section (from a tile or a search result).
  final ValueChanged<String> onSelect;

  /// Called to deep-link a search result: selects its [sectionId] and reveals
  /// the matching item id.
  final void Function(String sectionId, String itemId) onSelectResult;

  /// Dismisses the settings surface.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Clear the macOS traffic-light buttons that overlay the top-left
        // corner (the OS titlebar is hidden), so the close button / title
        // don't collide with them.
        const SizedBox(height: kTitleBarStripHeight),
        _Header(onClose: onClose),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: TextField(
            controller: controller,
            onChanged: onQueryChanged,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search settings',
              prefixIcon: Icon(Symbols.search, weight: 200, size: 18),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: searching
              ? _SearchResults(query: query, onSelectResult: onSelectResult)
              : _SectionList(
                  sections: sections,
                  selectedId: selectedId,
                  onSelect: onSelect,
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close settings',
            icon: const Icon(Symbols.close, weight: 200),
            onPressed: onClose,
          ),
          const SizedBox(width: 4),
          Text('Settings', style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _SectionList extends StatelessWidget {
  const _SectionList({
    required this.sections,
    required this.selectedId,
    required this.onSelect,
  });
  final List<SettingsSection> sections;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        for (final section in sections)
          ListTile(
            selected: section.id == selectedId,
            selectedColor: cs.primary,
            selectedTileColor: cs.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            leading: Icon(section.icon, weight: 200),
            title: Text(section.title),
            onTap: () => onSelect(section.id),
          ),
      ],
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.query, required this.onSelectResult});
  final String query;
  final void Function(String sectionId, String itemId) onSelectResult;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final results = searchSettings(query);
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No matches', style: TextStyle(color: cs.outline)),
      );
    }
    final sectionTitles = {for (final s in kSettingsSections) s.id: s.title};
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        for (final result in results)
          ListTile(
            dense: true,
            title: Text(result.item.title),
            subtitle: Text(sectionTitles[result.sectionId] ?? result.sectionId),
            trailing:
                result.item.availability == SettingsAvailability.comingSoon
                ? Text(
                    'Coming soon',
                    style: TextStyle(color: cs.outline, fontSize: 11),
                  )
                : null,
            onTap: () => onSelectResult(result.sectionId, result.item.id),
          ),
      ],
    );
  }
}
