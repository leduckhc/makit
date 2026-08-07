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
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../store/ports.dart';
import 'ports_glyph.dart';
import 'ports_vocabulary.dart';

/// Key for the popover panel, so tests assert its presence without copy.
const Key kPortsPopover = ValueKey('ports-popover');

/// Dwell before a hover opens the popover. 350 ms so sliding the pointer across
/// a list of worktrees opens nothing; deliberately below the tooltip's 500 ms
/// so the two never race.
const int _kHoverOpenMs = 350;

/// Grace after leaving both the glyph and the panel before closing, so a
/// diagonal overshoot into the gap is forgiven.
const int _kHoverCloseMs = 150;

/// Fixed popover width; the overlay math needs it up front to keep the panel on
/// screen (same reason as the budget popover).
const double _kPopoverWidth = 320;

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
    _open = true;
    widget.onOpenChanged?.call(true);
  }

  void _hide() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    if (!_open) return;
    _controller.hide();
    _open = false;
    _pinned = false;
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
    _overGlyph = true;
    _closeTimer?.cancel();
    if (_open) return;
    _openTimer?.cancel();
    _openTimer = Timer(const Duration(milliseconds: _kHoverOpenMs), () {
      if (_overGlyph) _show();
    });
  }

  void _onGlyphExit() {
    _overGlyph = false;
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
    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: _overlay,
      child: MouseRegion(
        onEnter: (_) => _onGlyphEnter(),
        onExit: (_) => _onGlyphExit(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
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

    // Prefer right-aligned to the glyph (the control edge), then clamp inside
    // the window — the same load-bearing clamp the budget popover documents.
    final preferredLeft = topLeft.dx + anchor.size.width - _kPopoverWidth;
    final maxLeft = overlaySize.width - _kPopoverWidth - _kPopoverMargin;
    final left = maxLeft <= _kPopoverMargin
        ? _kPopoverMargin
        : preferredLeft.clamp(_kPopoverMargin, maxLeft);
    // Open downward, just under the glyph.
    final top = topLeft.dy + anchor.size.height + kSpace6;

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
          top: top,
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
  });

  final String branch;
  final List<PortInfo> ports;
  final int nowMs;

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
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(color: cs.outlineVariant),
        ),
        padding: const EdgeInsets.symmetric(vertical: kSpace8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kSpace12,
                kSpace4,
                kSpace12,
                kSpace8,
              ),
              child: Row(
                children: [
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
            for (final port in ports) _PortRow(port: port, nowMs: nowMs),
            // The popover's own instructions: hover opens it, but the buttons
            // are only safe to rely on once pinned, and neither the pin nor Esc
            // is discoverable from the glyph.
            Container(
              key: kPortsPopoverHint,
              margin: const EdgeInsets.only(top: kSpace8),
              padding: const EdgeInsets.fromLTRB(
                kSpace12,
                kSpace6,
                kSpace12,
                kSpace2,
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

class _PortRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final uptime = portUptimeLabel(port.startedAt, nowMs: nowMs);
    final hasUrl = port.openUrl != null;
    // Both truncated tokens on this row own the same sentence: the full argv.
    // The panel is a fixed 320 pt, so line 2 always ellipses and line 1 does
    // too for any absolute-path argv[0] — without this the row is unreadable
    // with no way to read it (spec §3, one string per token).
    final commandSentence = portPidCommandLabel(port.pid, port.command);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${port.port}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: kMonoFontFamily,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: kSpace8),
              Flexible(
                child: Tooltip(
                  message: commandSentence,
                  child: Text(
                    portCommandToken(port.command),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: kMonoFontFamily,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: kSpace8),
              Tooltip(
                message: portHealthTooltip(port.health, nowMs: nowMs),
                child: Text(
                  portHealthPill(port.health),
                  style: theme.textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: kSpace8),
              Tooltip(
                message: portReachTooltip(port.reach),
                child: Text(
                  portReachPill(port.reach),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: kSpace2),
          Tooltip(
            message: commandSentence,
            child: Text(
              [commandSentence, if (uptime.isNotEmpty) uptime].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontFamily: kMonoFontFamily,
              ),
            ),
          ),
          if (hasUrl) ...[
            const SizedBox(height: kSpace6),
            Row(
              children: [
                _ActionButton(
                  icon: PhosphorIconsLight.arrowSquareOut,
                  label: 'Open',
                  primary: true,
                  onTap: () => _open(context),
                ),
                const SizedBox(width: kSpace6),
                _ActionButton(
                  icon: PhosphorIconsLight.copy,
                  label: 'Copy URL',
                  onTap: () => _copy(context),
                ),
              ],
            ),
          ],
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
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = primary ? cs.onPrimary : cs.onSurfaceVariant;
    final bg = primary ? cs.primary : cs.surfaceContainerHighest;
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
