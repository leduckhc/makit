/// SPEC-41 desktop popover — hover previews, click pins.
///
/// House pattern is [GithubBudgetButton]: an [OverlayPortal] anchored to the
/// glyph, an outside-tap barrier and an `Esc` [CallbackShortcuts] binding. On
/// top of that this adds the hover discipline the mockup specifies:
///   • [_kHoverOpenMs] dwell before opening (sliding down eight worktrees fires
///     nothing);
///   • a MouseRegion over the panel so travelling into the buttons never
///     dismisses it (the pointer bridge);
///   • [_kHoverCloseMs] of grace after leaving both, so a diagonal overshoot is
///     forgiven;
///   • a click **pins** it until Esc / outside-click / a second click — which
///     is what makes the buttons keyboard-reachable rather than a hover trap.
///
/// [onOpenChanged] lets the host row keep its hover latch true while the
/// popover owns the pointer (the `_portsOpen` flag the sidebar needs, or the
/// `…` snaps back to a diff pill under the cursor).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../store/ports.dart';
import 'port_kill_confirm.dart';
import 'port_token_pill.dart';
import 'ports_glyph.dart';
import 'ports_vocabulary.dart';

/// Key for the popover panel, so tests assert its presence without copy.
const Key kPortsPopover = ValueKey('ports-popover');

/// Dwell before a hover opens the popover. 350 ms so sliding the pointer across
/// a list of worktrees opens nothing; deliberately below [kTooltipDwell] so the
/// two never race (public so a test can pin that ordering).
const int kPortsHoverOpenMs = 350;

/// Grace after leaving both the glyph and the panel before closing, so a
/// diagonal overshoot into the gap is forgiven.
const int _kHoverCloseMs = 150;

/// Fixed popover width. 360 pt, not 320: line 2 carries pid, age and the args,
/// and the mockup (§2a) sizes the panel so that sentence mostly fits rather than
/// sizing it small and then blaming the truncation on the content.
const double _kPopoverWidth = 360;

/// Width of a row's leading port-number column, which gives every row the same
/// hanging indent so the numbers scan as a column (mockup 104 `.lead`).
///
/// 44 pt, not the mockup's 34: a 5-digit port (`49004`, and the mockup's own
/// example) does not fit 34 pt in tabular mono, and it matches mobile sheet 1's
/// existing lead width.
const double _kPortNumberColumn = 44;

/// Diameter cap for the pointer-feedback circle behind the glyph (mockup §5
/// rules table). The mockup's 18 pt is an upper BOUND — "small enough not to
/// touch the age text or the row edge" — and on the desktop sub-row the fixed
/// 16 pt line clamps it to 16, which satisfies that rationale strictly better.
/// The `…` menu beside it gets this for free from [IconButton]; the glyph is a
/// bare [GestureDetector], so it has to paint its own.
const double _kHoverCircle = 18;

/// The hover circle, keyed so a test asserts the affordance rather than a colour.
const Key kPortsGlyphHoverCircle = ValueKey('ports-glyph-hover');

/// Minimum breathing room between the popover and the window edges.
const double _kPopoverMargin = kSpace8;

/// A glyph that opens the ports popover on hover/click. Wraps [PortsGlyph].
/// The pinned popover's full-screen outside-tap dismisser. Keyed so a test can
/// assert its PRESENCE, not merely the dismissal it enables — in the sidebar an
/// unrelated ancestor rebuild also re-runs `overlayChildBuilder`, so only a
/// direct assertion in isolation can prove the pin installed it.
const Key kPortsPopoverBarrier = Key('portsPopoverBarrier');

/// The footer strip that names the pin, the keyboard walk and the dismiss —
/// mockup §2a. Keyed so the test asserts the affordance, not its wording.
const Key kPortsPopoverHint = Key('portsPopoverHint');

class PortsPopover extends StatefulWidget {
  const PortsPopover({
    super.key,
    required this.state,
    required this.count,
    required this.branch,
    required this.ports,
    required this.nowMs,
    this.glyphSize = 14,
    this.onOpenChanged,
  });

  final PortsGlyphState state;
  final int count;
  final String branch;
  final List<PortInfo> ports;

  /// Injected clock so "probed N s ago" is deterministic in tests.
  final int nowMs;
  final double glyphSize;

  /// Fires true when the popover opens (hover or pin) and false when it closes,
  /// so the host row can latch its hover state.
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<PortsPopover> createState() => _PortsPopoverState();
}

class _PortsPopoverState extends State<PortsPopover> {
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
    // setState: the hover circle is painted from this flag.
    setState(() => _overGlyph = true);
    _closeTimer?.cancel();
    if (_open) return;
    _openTimer?.cancel();
    _openTimer = Timer(const Duration(milliseconds: kPortsHoverOpenMs), () {
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
    // setState so the overlay child rebuilds: on the hover-then-click path the
    // popover is already open, so [_show] early-returns and the `if (_pinned)`
    // outside-tap barrier — built while `_pinned` was still false — would never
    // be installed. Flipping `_pinned` under setState re-runs overlayChildBuilder.
    setState(() => _pinned = true);
    _show();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Painted while the pointer is on the glyph AND while the popover owns it,
    // so a pinned popover still shows which control opened it.
    final lit = _overGlyph || _open;
    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: _overlay,
      child: MouseRegion(
        onEnter: (_) => _onGlyphEnter(),
        onExit: (_) => _onGlyphExit(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: Center(
            child: Container(
              key: kPortsGlyphHoverCircle,
              width: _kHoverCircle,
              height: _kHoverCircle,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: lit
                    ? cs.onSurface.withValues(alpha: 0.10)
                    : Colors.transparent,
              ),
              // The anchor stays the GLYPH, not the circle, so the popover's 6 pt
              // gap is measured from the icon the user is actually pointing at.
              child: Center(
                child: KeyedSubtree(
                  key: _anchorKey,
                  child: PortsGlyph(
                    state: widget.state,
                    count: widget.count,
                    size: widget.glyphSize,
                  ),
                ),
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

    // BESIDE the glyph, not below it. The glyph lives on a sidebar row's
    // sub-row, so a downward panel covers the sidebar — including the very row
    // whose ports you opened it to read. To the right there is a chat pane with
    // nothing to hide. Preference order: right of the glyph, then left of it
    // (a right-docked sidebar, or a narrow window), then clamped on-screen.
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

    // Vertically the panel is aligned to its row and grows AWAY from the nearer
    // edge: pinning only the top would run a tall panel off the bottom, which
    // is exactly where a sidebar's last worktree row sits. Deciding by which
    // half the glyph is in avoids needing the panel's height up front (the
    // overlay lays out after this runs).
    final growsDown = anchorRect.center.dy <= overlaySize.height / 2;
    // Cap the height based on the direction the panel grows. Downward: space
    // below the glyph. Upward: space above it, clamped to a safe margin.
    final maxHeight = growsDown
        ? overlaySize.height - anchorRect.top - _kPopoverMargin
        : (anchorRect.bottom - _kPopoverMargin).clamp(0.0, double.infinity);

    return Stack(
      children: [
        // Outside-tap dismiss, active only when pinned (a hover popover closes
        // on pointer-out, so a barrier then would swallow row clicks).
        if (_pinned)
          Positioned.fill(
            key: kPortsPopoverBarrier,
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
                child: _PortsPopoverPanel(
                  branch: widget.branch,
                  ports: widget.ports,
                  nowMs: widget.nowMs,
                  maxHeight: maxHeight,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The popover panel: a header (branch + count) and one row per port, each with
/// its facts and — only when the port answered HTTP — Open + Copy URL.
class _PortsPopoverPanel extends StatelessWidget {
  const _PortsPopoverPanel({
    required this.branch,
    required this.ports,
    required this.nowMs,
    required this.maxHeight,
  });

  final String branch;
  final List<PortInfo> ports;
  final int nowMs;

  /// Ceiling from the overlay, so a long list scrolls rather than running off
  /// the window edge the panel is pinned away from.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      key: kPortsPopover,
      color: cs.surfaceContainerLow,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(kRadius12),
      child: Container(
        width: _kPopoverWidth,
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(color: cs.outlineVariant),
        ),
        padding: EdgeInsets.zero,
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
                  Icon(PhosphorIconsLight.plug, size: 14, color: cs.primary),
                  const SizedBox(width: kSpace6),
                  Expanded(
                    child: Text(
                      branch,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    ports.length == 1
                        ? '1 listening'
                        : '${ports.length} listening',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final port in ports)
                      _PortRow(port: port, nowMs: nowMs),
                  ],
                ),
              ),
            ),
            // The popover's own instructions: hover opens it, but the buttons
            // are only safe to rely on once pinned, and neither the pin nor Esc
            // is discoverable from the glyph.
            Container(
              key: kPortsPopoverHint,
              padding: const EdgeInsets.fromLTRB(
                kSpace12,
                kSpace6,
                kSpace12,
                kSpace8,
              ),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: cs.outlineVariant)),
              ),
              child: Text(
                'Click to pin · Tab to reach buttons · Esc closes',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PortRow extends ConsumerWidget {
  const _PortRow({required this.port, required this.nowMs});

  final PortInfo port;
  final int nowMs;

  Future<void> _open(BuildContext context) async {
    final url = port.openUrl;
    if (url == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = Uri.tryParse(url);
    try {
      if (uri == null) throw const FormatException('bad url');
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Could not open the port')),
        );
      }
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not open the port')),
      );
    }
  }

  Future<void> _copy(BuildContext context) async {
    final url = port.openUrl;
    if (url == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: url));
    messenger?.showSnackBar(const SnackBar(content: Text('URL copied')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasUrl = port.openUrl != null;
    // SPEC-43 D8: `Kill` is offered for a port whose identity can be verified
    // (D1) — including one that never answered HTTP, which is exactly the
    // wedged-dev-server case the feature targets.
    final killable = portIsKillable(port);
    // Line 1's token and line 2 both truncate, and both are saying the same
    // thing: the full argv. One tooltip, both places (spec §3).
    final commandSentence = portPidCommandLabel(port.pid, port.command);
    return Container(
      // A hairline per row, including the first, so the header and three ports
      // read as four bands instead of one blob (mockup 103).
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kPortNumberColumn,
            child: Text(
              '${port.port}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: kMonoFontFamily,
                fontWeight: FontWeight.w600,
                // Tabular figures so a column of ports lines up digit-for-digit.
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: kSpace10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Tooltip(
                        message: commandSentence,
                        child: Text(
                          portCommandToken(port.command),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: kMonoFontFamily,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: kSpace6),
                    PortTokenPill(
                      label: portHealthPill(port.health),
                      sentence: portHealthTooltip(port.health, nowMs: nowMs),
                      tone: portHealthTone(port.health),
                      showDot: true,
                    ),
                    const SizedBox(width: kSpace6),
                    PortTokenPill(
                      label: portReachPill(port.reach),
                      sentence: portReachTooltip(port.reach),
                      tone: portReachTone(port.reach),
                    ),
                  ],
                ),
                const SizedBox(height: kSpace2),
                Tooltip(
                  message: commandSentence,
                  child: Text(
                    portProcessLine(
                      port.pid,
                      port.command,
                      startedAt: port.startedAt,
                      nowMs: nowMs,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontFamily: kMonoFontFamily,
                    ),
                  ),
                ),
                if (hasUrl || killable) ...[
                  const SizedBox(height: kSpace6),
                  // A Wrap, not a Row: three buttons plus a long port row do not
                  // always fit 360 pt, and a RenderFlex overflow would clip the
                  // last one — which is the destructive one.
                  Wrap(
                    spacing: kSpace6,
                    runSpacing: kSpace6,
                    children: [
                      if (hasUrl) ...[
                        _ActionButton(
                          icon: PhosphorIconsLight.arrowSquareOut,
                          label: 'Open',
                          primary: true,
                          onTap: () => _open(context),
                        ),
                        _ActionButton(
                          icon: PhosphorIconsLight.copy,
                          label: 'Copy URL',
                          onTap: () => _copy(context),
                        ),
                      ],
                      // LAST in the group, always (mockup §2a: "the pin makes it
                      // reachable, not one-click"), and it confirms even here —
                      // a pinned popover is not a permission.
                      if (killable)
                        _ActionButton(
                          icon: PhosphorIconsLight.stopCircle,
                          label: portKillLabel,
                          danger: true,
                          onTap: () => confirmAndKillPort(context, ref, port),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A 24 pt popover action button (above the 20 pt pointer-target floor). No
/// tooltip — its label is the tooltip (spec §3).
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  /// Destructive: an error-tinted wash, so the one button that signals a process
  /// never reads like Open or Copy (SPEC-43 D8).
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = danger
        ? cs.error
        : primary
        ? cs.onPrimary
        : cs.onSurfaceVariant;
    final bg = danger
        ? cs.errorContainer
        : primary
        ? cs.primary
        : cs.surfaceContainerHighest;
    return InkWell(
      borderRadius: BorderRadius.circular(kRadius8),
      onTap: onTap,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: kSpace10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(kRadius8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: kSpace6),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
