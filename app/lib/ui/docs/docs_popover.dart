/// SPEC-46 desktop popover (mockup Card 2 right frame) — hover previews, click
/// pins. The house pattern is `ports_popover.dart`: an [OverlayPortal] anchored
/// to the glyph, an outside-tap barrier and an `Esc` binding, plus the hover
/// discipline the mockup specifies — a [kDocsHoverOpenMs] dwell before opening
/// (sliding down a list of worktrees fires nothing), a pointer bridge over the
/// panel, a grace period after leaving both, and a click that **pins** it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/docs.dart';
import 'doc_glyph.dart';
import 'doc_row.dart';

/// Key for the popover panel, so tests assert its presence without copy.
const Key kDocsPopover = ValueKey('docs-popover');

/// The popover's search field, keyed for tests.
const Key kDocsPopoverSearch = ValueKey('docs-popover-search');

/// Rows shown before the list scrolls. A dozen fills the popover without
/// growing it to the window's height, and keeps the anchor row in view.
const int kDocsPopoverVisibleRows = 12;

/// Approximate row height, used only to cap the panel. The list itself lets
/// rows size naturally — a fixed `itemExtent` overflows as soon as a row grows
/// (an extra badge, a wrapped chip line).
const double kDocsPopoverRowHeight = 84;

/// Header + search field + padding above the list — subtracted from the
/// available height so the list never pushes the chrome off-screen.
const double kDocsPopoverChromeHeight = 96;

/// Dwell before a hover opens the popover — 350 ms so sliding the pointer
/// across worktrees opens nothing; deliberately below [kTooltipDwell] so the
/// two never race (matches `ports_popover.dart`).
const int kDocsHoverOpenMs = 350;

const int _kHoverCloseMs = 150;
const double _kPopoverWidth = 360;
const double _kPopoverMargin = kSpace8;

/// The tappable glyph target, keyed by type so tests can drive it without a
/// pointer simulation.
class DocsGlyphAnchorTapTarget extends StatelessWidget {
  const DocsGlyphAnchorTapTarget({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// A docs glyph that opens the docs popover on hover/click. Wraps [DocsGlyph].
class DocsPopover extends StatefulWidget {
  const DocsPopover({
    super.key,
    required this.branch,
    required this.docs,
    required this.onOpenDoc,
    this.glyphSize = 14,
    this.onOpenChanged,
  });

  final String branch;
  final List<DocInfo> docs;

  /// A doc row was tapped — the host opens the preview surface (D12).
  final void Function(DocInfo doc) onOpenDoc;
  final double glyphSize;

  /// Fires true when the popover opens and false when it closes, so the host
  /// row can latch its hover state.
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<DocsPopover> createState() => _DocsPopoverState();
}

class _DocsPopoverState extends State<DocsPopover> {
  final _anchorKey = GlobalKey();
  final _controller = OverlayPortalController();

  bool _open = false;
  bool _pinned = false;
  bool _overGlyph = false;
  bool _overPanel = false;
  Timer? _openTimer;
  Timer? _closeTimer;

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  void _show() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    if (_open) return;
    _controller.show();
    setState(() => _open = true);
    widget.onOpenChanged?.call(true);
  }

  void _hide() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    if (!_open) return;
    _controller.hide();
    setState(() {
      _open = false;
      _pinned = false;
    });
    widget.onOpenChanged?.call(false);
  }

  void _scheduleClose() {
    if (_pinned) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: _kHoverCloseMs), () {
      if (!_overGlyph && !_overPanel && !_pinned) _hide();
    });
  }

  void _onGlyphEnter() {
    setState(() => _overGlyph = true);
    _closeTimer?.cancel();
    if (_open) return;
    _openTimer?.cancel();
    _openTimer = Timer(const Duration(milliseconds: kDocsHoverOpenMs), () {
      if (_overGlyph) _show();
    });
  }

  void _onGlyphExit() {
    setState(() => _overGlyph = false);
    _openTimer?.cancel();
    _scheduleClose();
  }

  void _onTap() {
    if (_open && _pinned) {
      _hide();
      return;
    }
    setState(() => _pinned = true);
    _show();
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: _overlay,
      child: MouseRegion(
        onEnter: (_) => _onGlyphEnter(),
        onExit: (_) => _onGlyphExit(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: DocsGlyphAnchorTapTarget(
            child: KeyedSubtree(
              key: _anchorKey,
              child: DocsGlyph(
                count: widget.docs.length,
                size: widget.glyphSize,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    final anchor = _anchorKey.currentContext?.findRenderObject();
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (anchor is! RenderBox || overlayBox is! RenderBox || !anchor.hasSize) {
      return const SizedBox.shrink();
    }
    final overlaySize = overlayBox.size;
    final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlayBox);
    final anchorRect = Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      anchor.size.width,
      anchor.size.height,
    );

    final maxLeft = overlaySize.width - _kPopoverWidth - _kPopoverMargin;
    final rightOfGlyph = anchorRect.right + kSpace6;
    final leftOfGlyph = anchorRect.left - _kPopoverWidth - kSpace6;
    final double left;
    if (rightOfGlyph <= maxLeft) {
      left = rightOfGlyph;
    } else if (leftOfGlyph >= _kPopoverMargin) {
      left = leftOfGlyph;
    } else {
      left = maxLeft <= _kPopoverMargin
          ? _kPopoverMargin
          : rightOfGlyph.clamp(_kPopoverMargin, maxLeft);
    }

    final growsDown = anchorRect.center.dy <= overlaySize.height / 2;
    final maxHeight = growsDown
        ? overlaySize.height - anchorRect.top - _kPopoverMargin
        : (anchorRect.bottom - _kPopoverMargin).clamp(0.0, double.infinity);

    return Stack(
      children: [
        if (_pinned)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hide,
            ),
          ),
        Positioned(
          left: left,
          top: growsDown ? anchorRect.top : null,
          bottom: growsDown
              ? null
              : (overlaySize.height - anchorRect.bottom).clamp(
                  _kPopoverMargin,
                  double.infinity,
                ),
          child: MouseRegion(
            onEnter: (_) {
              _overPanel = true;
              _closeTimer?.cancel();
            },
            onExit: (_) {
              _overPanel = false;
              _scheduleClose();
            },
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _hide,
              },
              child: Focus(
                autofocus: true,
                child: _DocsPopoverPanel(
                  branch: widget.branch,
                  docs: widget.docs,
                  maxHeight: maxHeight,
                  onOpenDoc: (d) {
                    _hide();
                    widget.onOpenDoc(d);
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The popover panel: a header (branch + count), a search field, and a lazily
/// built, height-capped list of [DocRow]s.
class _DocsPopoverPanel extends StatefulWidget {
  const _DocsPopoverPanel({
    required this.branch,
    required this.docs,
    required this.maxHeight,
    required this.onOpenDoc,
  });

  final String branch;
  final List<DocInfo> docs;
  final double maxHeight;
  final void Function(DocInfo doc) onOpenDoc;

  @override
  State<_DocsPopoverPanel> createState() => _DocsPopoverPanelState();
}

class _DocsPopoverPanelState extends State<_DocsPopoverPanel> {
  String _query = '';

  /// Title-or-path match, the same rule the Docs screen's search uses.
  List<DocInfo> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.docs;
    return widget.docs
        .where(
          (d) =>
              d.title.toLowerCase().contains(q) ||
              d.relPath.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final visible = _visible;
    // A repo can hold hundreds of docs, so cap the list at a readable dozen and
    // scroll the rest rather than growing the popover to the window's height.
    final listHeight = (kDocsPopoverVisibleRows * kDocsPopoverRowHeight).clamp(
      0.0,
      widget.maxHeight - kDocsPopoverChromeHeight,
    );
    return Material(
      key: kDocsPopover,
      color: cs.surfaceContainerLow,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(kRadius12),
      child: Container(
        width: _kPopoverWidth,
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kSpace12,
                kSpace8,
                kSpace12,
                kSpace8,
              ),
              child: Row(
                children: [
                  Icon(
                    PhosphorIconsLight.fileText,
                    size: 14,
                    color: cs.primary,
                  ),
                  const SizedBox(width: kSpace6),
                  Expanded(
                    child: Text(
                      widget.branch,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    // While filtering, show the match count against the total so
                    // an empty result is obviously a filter, not an empty repo.
                    _query.trim().isEmpty
                        ? (widget.docs.length == 1
                              ? '1 doc'
                              : '${widget.docs.length} docs')
                        : '${visible.length} of ${widget.docs.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSpace8, 0, kSpace8, kSpace8),
              child: TextField(
                key: kDocsPopoverSearch,
                autofocus: true,
                style: theme.textTheme.bodySmall,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search titles and paths',
                  prefixIcon: const Icon(
                    PhosphorIconsLight.magnifyingGlass,
                    size: 14,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: kSpace8,
                    vertical: kSpace6,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(kRadius8),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kSpace12,
                  0,
                  kSpace12,
                  kSpace12,
                ),
                child: Text(
                  'No docs match “${_query.trim()}”.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              )
            else
              SizedBox(
                height: listHeight,
                // Lazy: a 600-doc worktree must not build 600 rows to show 12.
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: visible.length,
                  itemBuilder: (context, i) => DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: cs.outlineVariant),
                      ),
                    ),
                    child: DocRow(
                      doc: visible[i],
                      nowMs: nowMs,
                      onTap: () => widget.onOpenDoc(visible[i]),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
