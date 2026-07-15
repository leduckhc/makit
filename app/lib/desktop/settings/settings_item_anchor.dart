/// Deep-link target for settings search results.
///
/// When a search result is chosen the nav pane records the item id here; the
/// owning section wraps the matching row in a [SettingsItemAnchor] which scrolls
/// it into view and briefly highlights it. Kept as a provider (rather than
/// threading a parameter through every section) so only the sections that
/// bother to anchor a row need to react.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

/// The id of the settings item a search deep-link is pointing at, or `null`
/// when the user navigated by section (no specific item to reveal).
final settingsTargetItemProvider = StateProvider<String?>((_) => null);

/// Wraps a settings row so that, when [itemId] becomes the active
/// [settingsTargetItemProvider] target, the row is scrolled into view and
/// briefly highlighted. A no-op the rest of the time.
class SettingsItemAnchor extends ConsumerStatefulWidget {
  /// Wraps [child], reacting when [itemId] is the deep-link target.
  const SettingsItemAnchor({
    required this.itemId,
    required this.child,
    super.key,
  });

  /// The item id this anchor represents (matches `SettingsItem.id`).
  final String itemId;

  /// The row content.
  final Widget child;

  @override
  ConsumerState<SettingsItemAnchor> createState() => _SettingsItemAnchorState();
}

class _SettingsItemAnchorState extends ConsumerState<SettingsItemAnchor> {
  /// How long the highlight tint takes to fade out after the row is revealed.
  static const Duration _highlightFade = Duration(milliseconds: 1200);

  /// Peak tint opacity applied over the accent colour.
  static const double _highlightAlpha = 0.14;

  /// Bumped on each reveal so the fade animation restarts even when the same
  /// item is deep-linked twice.
  int _revealSeq = 0;

  /// The target value this anchor has already reacted to, so a rebuild while
  /// still targeted doesn't re-trigger the scroll/highlight on every frame.
  String? _handledTarget;

  void _maybeReveal(String? target) {
    if (target != widget.itemId || _handledTarget == target) return;
    _handledTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  Future<void> _reveal() async {
    if (!mounted) return;
    await Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 300),
      alignment: 0.1,
    );
    if (!mounted) return;
    setState(() => _revealSeq++);
  }

  @override
  Widget build(BuildContext context) {
    _maybeReveal(ref.watch(settingsTargetItemProvider));
    final cs = Theme.of(context).colorScheme;
    // A one-shot fade from the accent tint to transparent on each reveal. Using
    // an implicit tween (not a manual Timer) keeps the widget free of pending
    // timers when it is disposed mid-fade.
    return TweenAnimationBuilder<double>(
      key: ValueKey<int>(_revealSeq),
      tween: Tween<double>(begin: _revealSeq == 0 ? 0 : 1, end: 0),
      duration: _highlightFade,
      builder: (context, t, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: _highlightAlpha * t),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}
