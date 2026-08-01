/// The prompt palette: a filterable list of the messages you sent, opened from
/// a small affordance in the transcript's top-right corner (SPEC-34).
///
/// **Why this style exists.** It is the only navigator that can *search* — the
/// rail and scrubber locate a prompt by position, the palette by content. So it
/// is the one place where the corpus can widen from "your own messages" to the
/// whole transcript (`searchAll`), and the one place where result order in the
/// list diverges from item order in the transcript. That divergence is the
/// trap: `jumpToItem` takes an **item position** (an index into
/// `context.items`), never a filtered-list index. Every entry therefore carries
/// its own position so the two never get conflated.
///
/// **Scope boundary.** This widget owns its trigger button and the keys handled
/// *inside* the open overlay only. It deliberately registers **no** global app
/// shortcut (⌘/): the desktop keymap lives in `lib/shortcuts/` and
/// `lib/desktop/chat/keymap_scope.dart` and wiring a rebindable shortcut to open
/// the palette is a separate task.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyEvent, KeyDownEvent, KeyUpEvent;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../store/chat_items.dart';
import 'message_navigator_overlay.dart';
import 'navigator_style.dart';

/// Distance from the top of the viewport to the trigger button.
const double _kPaletteTop = 12;

/// Inset of the trigger button and panel from the trailing edge.
const double _kPaletteInset = 10;

/// Fixed width of the open panel.
const double _kPaletteWidth = 320;

/// Maximum height of the scrolling result list before it scrolls internally.
const double _kResultsMaxHeight = 320;

/// Screen-reader label for the trigger — also how tests find it.
const String _kTriggerLabel = 'Find your messages';

/// One searchable row: the text shown and filtered on, the role tag (only
/// surfaced when [PaletteOptions.searchAll] is on), and the **item position** it
/// jumps to — the index into `context.items`, never a filtered-list index.
@immutable
class _PaletteEntry {
  const _PaletteEntry({
    required this.position,
    required this.role,
    required this.text,
  });

  final int position;
  final String role;
  final String text;
}

/// The prompt palette.
class MessagePalette extends ConsumerStatefulWidget {
  /// Creates the palette for [context].
  const MessagePalette({super.key, required this.context});

  /// The transcript state to navigate.
  final MessageNavigatorContext context;

  @override
  ConsumerState<MessagePalette> createState() => _MessagePaletteState();
}

class _MessagePaletteState extends ConsumerState<MessagePalette> {
  final TextEditingController _query = TextEditingController();

  /// Whether the panel is open. Closed is the resting state — just the button.
  bool _open = false;

  /// Index into the *filtered* results of the highlighted row.
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: _kPaletteTop,
      right: _kPaletteInset,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          _trigger(scheme),
          if (_open) ...[const SizedBox(height: kSpace8), _panel(scheme)],
        ],
      ),
    );
  }

  /// The compact, unobtrusive affordance that opens the palette.
  Widget _trigger(ColorScheme scheme) {
    return Semantics(
      button: true,
      label: _kTriggerLabel,
      child: Tooltip(
        message: _kTriggerLabel,
        child: Material(
          color: scheme.surfaceContainerHigh,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.all(kSpace6),
              child: Icon(
                Icons.manage_search,
                size: kSpace16,
                color: _open ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The open panel: a filter field over a scrolling result list.
  Widget _panel(ColorScheme scheme) {
    final options = ref.watch(paletteOptionsProvider);
    final results = _filtered(searchAll: options.searchAll);
    final selected = results.isEmpty
        ? -1
        : _selected.clamp(0, results.length - 1);

    return Focus(
      // The field below holds focus; this node only intercepts navigation keys
      // as they bubble up, so it must never take focus or traversal itself.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(kRadius12),
        elevation: 8,
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: _kPaletteWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(scheme),
              const Divider(height: 1),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: _kResultsMaxHeight,
                  ),
                  child: results.isEmpty
                      ? _emptyState(scheme)
                      : _resultsList(
                          results,
                          selected,
                          options.searchAll,
                          scheme,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace8,
      ),
      child: TextField(
        controller: _query,
        autofocus: true,
        // Reset the highlight to the top whenever the corpus is re-narrowed, so
        // the selection can never point past the new result list.
        onChanged: (_) => setState(() => _selected = 0),
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: 'Search your messages',
          prefixIcon: Icon(
            Icons.search,
            size: kSpace16,
            color: scheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: kSpace32),
        ),
      ),
    );
  }

  Widget _resultsList(
    List<_PaletteEntry> results,
    int selected,
    bool showTags,
    ColorScheme scheme,
  ) {
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: kSpace4),
      itemCount: results.length,
      itemBuilder: (context, i) =>
          _resultRow(results[i], i == selected, showTags, scheme),
    );
  }

  Widget _resultRow(
    _PaletteEntry entry,
    bool isSelected,
    bool showTags,
    ColorScheme scheme,
  ) {
    return MergeSemantics(
      child: Semantics(
        selected: isSelected,
        child: InkWell(
          onTap: () => _commitEntry(entry),
          child: Container(
            color: isSelected ? scheme.primaryContainer : null,
            padding: const EdgeInsets.symmetric(
              horizontal: kSpace12,
              vertical: kSpace6,
            ),
            child: Row(
              children: [
                if (showTags) ...[
                  _roleTag(entry.role, scheme),
                  const SizedBox(width: kSpace8),
                ],
                Expanded(
                  child: Text(
                    entry.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: isSelected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _roleTag(String role, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kSpace6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kRadius6),
      ),
      child: Text(
        role,
        style: Theme.of(
          context,
        ).textTheme.labelXs?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// A clear "nothing matched" row, never an empty void.
  Widget _emptyState(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace16,
      ),
      child: Text(
        'No matching messages',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// The corpus, in ascending item order, narrowed by the current query.
  ///
  /// `searchAll` off → only the user's own messages (`context.positions`).
  /// `searchAll` on → every row, each tagged with its role.
  List<_PaletteEntry> _filtered({required bool searchAll}) {
    final navContext = widget.context;
    final entries = <_PaletteEntry>[];
    if (searchAll) {
      for (var position = 0; position < navContext.items.length; position++) {
        final item = navContext.items[position];
        final text = _entryText(item);
        if (text.isEmpty) continue;
        entries.add(
          _PaletteEntry(position: position, role: _roleFor(item), text: text),
        );
      }
    } else {
      for (var i = 0; i < navContext.positions.length; i++) {
        entries.add(
          _PaletteEntry(
            position: navContext.positions[i],
            role: 'you',
            text: navContext.textAt(i),
          ),
        );
      }
    }
    final needle = _query.text.trim().toLowerCase();
    if (needle.isEmpty) return entries;
    return entries
        .where((e) => e.text.toLowerCase().contains(needle))
        .toList(growable: false);
  }

  /// The role tag for [item] — one of "you" / "agent" / "tool".
  String _roleFor(ChatItem item) => switch (item) {
    UserMessageItem() => 'you',
    ToolCallItem() => 'tool',
    _ => 'agent',
  };

  /// The searchable text for [item]. Tool calls fall back to their name when
  /// they carry no summary or result yet, so a call is never a blank row.
  String _entryText(ChatItem item) => switch (item) {
    UserMessageItem(:final text) => text,
    AgentMessageItem(:final text) => text,
    ThinkingItem(:final text) => text,
    ErrorItem(:final message) => message,
    AgentMediaItem(:final alt) => alt ?? 'image',
    ToolCallItem() =>
      item.summary ??
          (item.resultText.isNotEmpty ? item.resultText : item.name),
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final results = _filtered(
      searchAll: ref.read(paletteOptionsProvider).searchAll,
    );
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1, results);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1, results);
      return KeyEventResult.handled;
    }
    // Enter / Escape are one-shot: ignore auto-repeat so a held key does not
    // jump-and-close or re-close repeatedly.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (results.isNotEmpty) {
        _commitEntry(results[_selected.clamp(0, results.length - 1)]);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Moves the highlight and *previews* it — the transcript jumps but the panel
  /// stays open, so the arrows scrub the list.
  void _move(int delta, List<_PaletteEntry> results) {
    if (results.isEmpty) return;
    final next = (_selected + delta).clamp(0, results.length - 1);
    setState(() => _selected = next);
    widget.context.jumper.jumpToItem(results[next].position);
  }

  /// Jumps to [entry] and closes — the commit gesture (Enter or a tap).
  void _commitEntry(_PaletteEntry entry) {
    widget.context.jumper.jumpToItem(entry.position);
    _close();
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      if (_open) {
        _query.clear();
        _selected = 0;
      }
    });
  }

  void _close() => setState(() => _open = false);
}
