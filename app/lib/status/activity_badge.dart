/// The way in: a bell with an unread count, tinted by the loudest thing you have
/// not read yet.
///
/// Two flavours because the two surfaces have different chrome — the phone's home
/// bar is Liquid Glass circles, the desktop sidebar footer is plain 32 px icon
/// buttons — but both read the same [statusBadgeProvider] and paint the same
/// count pill, so a severity can never look different in the two places.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import '../ui/widgets/pr_tone.dart' show inkOn;
import 'activity_view.dart';
import 'status_event.dart';
import 'status_providers.dart';
import 'status_tone.dart';

/// Key for the anchored Activity panel, so tests assert its presence and its
/// position without reaching for copy.
const Key kActivityPopover = ValueKey('activity-popover');

/// Width of the Activity panel, in both containers.
const double kActivityPanelWidth = 420;

/// Preferred height. The popover shrinks below this when the window is short;
/// the list scrolls inside either way.
const double _kActivityPanelHeight = 520;

/// Keeps the panel off the window edges when the anchor sits near one.
const double _kActivityPanelMargin = 8;

/// Below this the panel is useless, so it stops shrinking and scrolls instead.
const double _kActivityPanelMinHeight = 220;

/// A filled bell means "there is something here"; the tint says how bad.
IconData _bellFor(int unread) =>
    unread == 0 ? PhosphorIconsLight.bell : PhosphorIconsFill.bell;

String _tooltipFor(int unread) =>
    unread == 0 ? 'Activity' : 'Activity — $unread unread';

/// Desktop flavour: a plain icon button for the sidebar footer.
class ActivityBadge extends ConsumerWidget {
  const ActivityBadge({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badge = ref.watch(statusBadgeProvider).value;
    final unread = badge?.unread ?? 0;
    final worst = badge?.worst;
    final cs = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          tooltip: _tooltipFor(unread),
          icon: Icon(
            _bellFor(unread),
            size: 18,
            color: worst == null ? null : statusColor(cs, worst),
          ),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: onTap,
        ),
        if (unread > 0)
          Positioned(
            top: 2,
            right: 0,
            child: IgnorePointer(
              child: ActivityCountPill(unread: unread, worst: worst),
            ),
          ),
      ],
    );
  }
}

/// Phone flavour: an unread dot hung off whatever control leads to Activity.
///
/// The home bar cannot afford a fifth glass circle — four plus the connection
/// chip already fill a 320 pt bar, and a phone has no screen to spend on
/// permanent chrome (the same reasoning that keeps the message navigator off
/// mobile, `docs/UX.md` §3). So Activity lives one tap deeper, in Settings, and
/// the signal rides the Settings button: nothing when there is nothing to say.
class ActivityUnreadDot extends ConsumerWidget {
  const ActivityUnreadDot({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badge = ref.watch(statusBadgeProvider).value;
    final unread = badge?.unread ?? 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (unread > 0)
          Positioned(
            top: 2,
            right: 2,
            child: IgnorePointer(
              child: ActivityCountPill(unread: unread, worst: badge?.worst),
            ),
          ),
      ],
    );
  }
}

/// The count itself. Public so both flavours (and their tests) share one pill.
class ActivityCountPill extends StatelessWidget {
  const ActivityCountPill({super.key, required this.unread, this.worst});

  final int unread;
  final StatusSeverity? worst;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fill = worst == null ? cs.outline : statusColor(cs, worst!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      constraints: const BoxConstraints(minWidth: 13),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(kRadius6),
        // A hairline in the surface colour keeps the pill legible where it
        // overlaps the glyph's own strokes.
        border: Border.all(color: cs.surface),
      ),
      child: Text(
        unread > 9 ? '9+' : '$unread',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelXs?.copyWith(
          fontSize: 9,
          height: 1.3,
          color: inkOn(cs, fill),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The panel itself — chrome plus the one [ActivityView]. Both containers (the
/// bell's anchored popover and [showActivityDialog]) render this, so the two
/// can never drift into two different Activity panels.
class _ActivityPanel extends StatelessWidget {
  const _ActivityPanel({
    required this.height,
    required this.onClose,
    this.onOpenSession,
  });

  final double height;
  final VoidCallback onClose;
  final void Function(String sessionId)? onOpenSession;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: kActivityPopover,
      color: cs.surfaceContainerLowest,
      elevation: 8,
      borderRadius: BorderRadius.circular(kRadius12),
      child: Container(
        width: kActivityPanelWidth,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(color: cs.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(
                left: kSpace16,
                top: kSpace10,
                right: kSpace8,
                bottom: kSpace4,
              ),
              child: Row(
                children: [
                  Text(
                    'Activity',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(PhosphorIconsLight.x, size: 15),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Expanded(child: ActivityView(onOpenSession: onOpenSession)),
          ],
        ),
      ),
    );
  }
}

/// The bell plus its anchored panel: the house pattern from
/// [GithubBudgetButton] — an [OverlayPortal] tied to the icon, a full-bleed
/// outside-tap barrier and an `Esc` binding.
///
/// It hangs BELOW the bell (the bell is top chrome now, beside the sidebar
/// fold button) and is left-aligned to it, then clamped into the window so a
/// narrow window cannot push the panel off-screen.
class ActivityPopoverButton extends StatefulWidget {
  const ActivityPopoverButton({super.key, this.onOpenSession});

  /// Forwarded to [ActivityView]: tapping a row navigates to its session.
  final void Function(String sessionId)? onOpenSession;

  @override
  State<ActivityPopoverButton> createState() => _ActivityPopoverButtonState();
}

class _ActivityPopoverButtonState extends State<ActivityPopoverButton> {
  final _anchorKey = GlobalKey();
  final _controller = OverlayPortalController();
  bool _open = false;

  void _toggle() => setState(() {
    _open ? _controller.hide() : _controller.show();
    _open = !_open;
  });

  void _close() {
    if (!_open) return;
    setState(() {
      _controller.hide();
      _open = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: _overlay,
      child: KeyedSubtree(
        key: _anchorKey,
        child: ActivityBadge(onTap: _toggle),
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

    // Left-aligned to the bell, then clamped inside the window. `clamp` needs
    // lo <= hi, which fails on a window narrower than the panel — fall back to
    // the margin there.
    final maxLeft =
        overlaySize.width - kActivityPanelWidth - _kActivityPanelMargin;
    final left = maxLeft <= _kActivityPanelMargin
        ? _kActivityPanelMargin
        : topLeft.dx.clamp(_kActivityPanelMargin, maxLeft);

    // Hangs below the bell, never taller than the room underneath it.
    final top = topLeft.dy + anchor.size.height + kSpace6;
    final height = math.max(
      _kActivityPanelMinHeight,
      math.min(
        _kActivityPanelHeight,
        overlaySize.height - top - _kActivityPanelMargin,
      ),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _close,
            },
            child: Focus(
              autofocus: true,
              child: _ActivityPanel(
                height: height,
                onClose: _close,
                onOpenSession: (id) {
                  _close();
                  widget.onOpenSession?.call(id);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The anchorless container, still used by the toast tap (`desktop_app.dart`),
/// which opens Activity from a global navigator context with no bell to anchor
/// to. Same [_ActivityPanel] inside.
Future<void> showActivityDialog(
  BuildContext context, {
  void Function(String sessionId)? onOpenSession,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.20),
  builder: (context) => Align(
    alignment: Alignment.topRight,
    child: Padding(
      padding: const EdgeInsets.only(top: kSpace32, right: kSpace16),
      child: LayoutBuilder(
        builder: (context, constraints) => _ActivityPanel(
          height: math.max(
            _kActivityPanelMinHeight,
            math.min(_kActivityPanelHeight, constraints.maxHeight),
          ),
          onClose: () => Navigator.of(context).pop(),
          onOpenSession: onOpenSession,
        ),
      ),
    ),
  ),
);
