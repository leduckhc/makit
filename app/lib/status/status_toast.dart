/// The transient view of the activity record: a small card that fades in at the
/// top, says what happened, and offers the one thing a `SnackBar` never could —
/// the machine detail, on the clipboard.
///
/// Mounted once, above the Navigator (`MaterialApp.builder`), beside
/// `SrvRequestHandler`. Nothing here owns state that matters: dismissing a toast
/// or missing it entirely loses nothing, because the [StatusCenter] holds the
/// record (SPEC-48 D5).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import 'status_center.dart';
import 'status_event.dart';
import 'status_providers.dart';
import 'status_tone.dart';
import 'toast_queue.dart';

/// Widest a toast gets. Beyond this the eye has to travel to read a one-liner,
/// and on desktop the card would start competing with the transcript.
const double kToastMaxWidth = 380;

/// Clearance above the first toast, per shell: the phone's floating glass bar and
/// the desktop's title strip both occupy the top edge, and a toast that covers the
/// controls you might reach for is the snackbar-on-the-composer mistake upside
/// down.
const double kToastInsetPhone = 60;
const double kToastInsetDesktop = 40;

class StatusToastLayer extends ConsumerStatefulWidget {
  const StatusToastLayer({
    super.key,
    required this.child,
    this.onOpen,
    this.topInset = kToastInsetPhone,
  });

  final Widget child;

  /// See [kToastInsetPhone] / [kToastInsetDesktop].
  final double topInset;

  /// Where a tap goes — the Activity surface, or the event's session when it has
  /// one. Injected because the phone (router) and the desktop (panes + popover)
  /// answer that differently; null makes the card non-tappable while copy and
  /// dismiss keep working.
  final void Function(StatusEvent event)? onOpen;

  @override
  ConsumerState<StatusToastLayer> createState() => _StatusToastLayerState();
}

class _StatusToastLayerState extends ConsumerState<StatusToastLayer> {
  final ToastQueue _queue = ToastQueue();
  final Map<String, Timer> _timers = <String, Timer>{};

  /// Ids whose dwell is paused because the user is reading them (SPEC-49 D4).
  final Set<String> _held = <String>{};
  StreamSubscription<StatusChange>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(statusCenterProvider).changes.listen(_onChange);
  }

  void _onChange(StatusChange change) {
    if (!mounted) return;
    switch (change) {
      // Silent posts are history, not news: the surface already showed the user
      // the thing (SPEC-48 D7).
      case StatusPosted(silent: true):
        return;
      case StatusPosted(:final event):
        setState(() => _queue.push(event));
        // Restart the clock on every post: a repeat that just bumped the count
        // is news again, and deserves the full dwell.
        _timers.remove(event.id)?.cancel();
        _timers[event.id] = Timer(
          toastDwell(event.severity),
          () => _dismiss(event.id),
        );
      // Opening Activity means the user has now seen all of this; leaving the
      // toasts up would be telling them twice.
      case StatusReadAll():
      case StatusCleared():
        _cancelAll();
        setState(_queue.clear);
    }
  }

  void _dismiss(String id) {
    _timers.remove(id)?.cancel();
    _held.remove(id);
    if (!mounted) return;
    setState(() => _queue.dismiss(id));
  }

  /// Attention arrived at or left the card for [id]. Holding cancels its dwell;
  /// releasing restarts the **whole** dwell rather than the remainder, because a
  /// notice you looked away from is news again (SPEC-49 D4) — the same judgement
  /// a coalesced repeat already gets above.
  void _setHeld(StatusEvent event, bool held) {
    if (held) {
      _held.add(event.id);
      _timers.remove(event.id)?.cancel();
      return;
    }
    if (!_held.remove(event.id)) return;
    _timers.remove(event.id)?.cancel();
    _timers[event.id] = Timer(
      toastDwell(event.severity),
      () => _dismiss(event.id),
    );
  }

  void _cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _held.clear();
  }

  @override
  void dispose() {
    _cancelAll();
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _queue.visible;
    final overflow = _queue.overflow;
    return Stack(
      children: [
        widget.child,
        // Top-anchored: the snackbar's bottom slot sits on the composer, the one
        // control DESIGN.md protects (SPEC-48 D6).
        Positioned(
          top: 0,
          right: 0,
          left: 0,
          child: SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: EdgeInsets.only(
                  top: widget.topInset,
                  left: kSpace12,
                  right: kSpace12,
                  bottom: kSpace12,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: kToastMaxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final e in visible)
                        Padding(
                          key: ValueKey(e.id),
                          padding: const EdgeInsets.only(bottom: kSpace8),
                          child: StatusToastCard(
                            event: e,
                            onDismiss: () => _dismiss(e.id),
                            onAttention: (held) => _setHeld(e, held),
                            onOpen: widget.onOpen == null
                                ? null
                                : () => widget.onOpen!(e),
                          ),
                        ),
                      if (overflow > 0)
                        _OverflowChip(
                          count: overflow,
                          onTap: widget.onOpen == null || visible.isEmpty
                              ? null
                              : () => widget.onOpen!(visible.first),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One toast. Public so tests (and the Activity list's empty-state preview) can
/// find it by type.
class StatusToastCard extends StatefulWidget {
  const StatusToastCard({
    super.key,
    required this.event,
    required this.onDismiss,
    this.onOpen,
    this.onAttention,
  });

  final StatusEvent event;
  final VoidCallback onDismiss;
  final VoidCallback? onOpen;

  /// Called when the user's attention enters or leaves this card (pointer hover
  /// or keyboard focus). The layer owns the dwell timers, so it is the layer
  /// that pauses them — the card only reports what it observes (SPEC-49 D4).
  final void Function(bool held)? onAttention;

  @override
  State<StatusToastCard> createState() => _StatusToastCardState();
}

class _StatusToastCardState extends State<StatusToastCard> {
  bool _copied = false;
  bool _held = false;
  Timer? _copyReset;

  @override
  void dispose() {
    _copyReset?.cancel();
    super.dispose();
  }

  /// Hover or focus means "I am reading this": hold the notice open and show the
  /// whole payload. Deliberately **not** driven by pointer-down — on touch that
  /// competes with the tap that copies, and an iPad runs the desktop shell
  /// (`main.dart` `_WorkspaceShellApp`), so both input models reach this widget.
  void _setHeld(bool held) {
    if (_held == held) return;
    setState(() => _held = held);
    widget.onAttention?.call(held);
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: widget.event.toClipboardText()),
    );
    if (!mounted) return;
    // In place, not a second toast: confirming a copy by posting an event you
    // could then copy is a hall of mirrors (SPEC-49 D6).
    setState(() => _copied = true);
    _copyReset?.cancel();
    _copyReset = Timer(
      const Duration(milliseconds: 1200),
      () => mounted ? setState(() => _copied = false) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final e = widget.event;
    final tone = statusColor(cs, e.severity);
    return Semantics(
      liveRegion: true,
      label: _copied
          ? 'Copied'
          : '${statusSeverityLabel(e.severity)}: ${e.displayTitle}',
      // Assistive tech gets the action by name, not just a tappable rectangle:
      // a notice whose whole point is "you can re-read this" must not be
      // pointer-only (SPEC-49 D2).
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        const CustomSemanticsAction(label: 'Copy'): _copy,
      },
      child: MouseRegion(
        onEnter: (_) => _setHeld(true),
        onExit: (_) => _setHeld(false),
        child: Material(
          color: cs.surfaceContainerHigh,
          elevation: 3,
          shadowColor: Colors.black.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(kRadius12),
          child: InkWell(
            // The whole card copies. Copy is the one thing that cannot be done
            // any other way, and the 13 px glyph this replaces was the smallest
            // target on the card at the worst moment (SPEC-49 D1, D7).
            onTap: _copy,
            onFocusChange: _setHeld,
            borderRadius: BorderRadius.circular(kRadius12),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadius12),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(kRadius12),
              // The severity stripe wants the card's full height, which a Column
              // of unbounded height cannot give a `stretch` Row — so measure it.
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The severity stripe — colour, not a shouty fill.
                    Container(width: 3, color: tone),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: kSpace10,
                          vertical: kSpace8,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: kSpace2),
                              child: Icon(
                                _copied
                                    ? PhosphorIconsLight.checkCircle
                                    : statusGlyph(e.severity),
                                size: 15,
                                color: _copied ? cs.primary : tone,
                              ),
                            ),
                            const SizedBox(width: kSpace8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _copied ? 'Copied' : e.displayTitle,
                                    style: text.bodyMedium,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (e.hasDetail)
                                    _held
                                        // Held: the whole payload, selectable,
                                        // because the tail of a stack trace is
                                        // the part worth reading (SPEC-49 D5).
                                        ? SelectableText(
                                            e.detail!.trimRight(),
                                            style: text.labelSmall
                                                ?.copyWith(
                                                  color: cs.onSurfaceVariant,
                                                )
                                                .mono,
                                          )
                                        : Text(
                                            e.detail!.trim().split('\n').first,
                                            style: text.labelSmall
                                                ?.copyWith(
                                                  color: cs.onSurfaceVariant,
                                                )
                                                .mono,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                ],
                              ),
                            ),
                            if (widget.onOpen != null)
                              _ToastIconButton(
                                tooltip: 'Open',
                                icon: PhosphorIconsLight.caretRight,
                                onPressed: widget.onOpen!,
                              ),
                            _ToastIconButton(
                              tooltip: 'Dismiss',
                              icon: PhosphorIconsLight.x,
                              onPressed: widget.onDismiss,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastIconButton extends StatelessWidget {
  const _ToastIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: 14),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    // Without `shrinkWrap` the theme pads every icon button to a 48 pt tap
    // target, which made a one-line toast 57 pt tall. 32 pt matches the desktop
    // sidebar's icon buttons and still takes a thumb.
    style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    onPressed: onPressed,
  );
}

class _OverflowChip extends StatelessWidget {
  const _OverflowChip({required this.count, this.onTap});

  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(kRadius8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius8),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace8,
            vertical: kSpace4,
          ),
          child: Text(
            '+$count more',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
