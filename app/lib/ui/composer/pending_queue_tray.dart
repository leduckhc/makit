// The queue tray (mockup variant C) — the compact alternative to the ghost
// bubbles of `pending_queue.dart`.
//
// Same queue, same commands, different reading. The bubbles say "this is what
// you will have said"; the tray says "this is a work list you are managing", so
// it stacks tight rows with the actions always visible instead of a
// conversation-shaped column. The tray is also where **promote** lives — the
// third thing makit could always do to a turn (interrupt) but never surfaced per
// message: send THIS one now, keep the rest queued.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'slash_palette.dart';

/// A compact strip of pending messages with per-row actions.
class PendingQueueTray extends StatelessWidget {
  /// Creates the tray.
  const PendingQueueTray({
    super.key,
    required this.queued,
    required this.commands,
    required this.onEdit,
    required this.onReorder,
    required this.onCancel,
    required this.onPromote,
  });

  /// The pending messages, next-to-send first.
  final List<QueuedMessage> queued;

  /// Agent commands offered by the editor's slash palette.
  final List<SlashCmd> commands;

  /// Commit new text for one message. Empty text cancels it, server-side.
  final void Function(String id, String text) onEdit;

  /// Ask for a new whole order (a hint the server may partially apply).
  final ValueChanged<List<String>> onReorder;

  /// Drop one message.
  final ValueChanged<String> onCancel;

  /// Interrupt the running turn so one message is delivered next.
  final ValueChanged<String> onPromote;

  void _move(int i, int delta) {
    final ids = queued.map((q) => q.id).toList();
    final to = i + delta;
    if (to < 0 || to >= ids.length) return;
    final id = ids.removeAt(i);
    ids.insert(to, id);
    onReorder(ids);
  }

  @override
  Widget build(BuildContext context) {
    if (queued.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(
        left: kSpace8,
        right: kSpace8,
        bottom: kSpace4,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(color: cs.outlineVariant),
        ),
        padding: const EdgeInsets.symmetric(vertical: kSpace4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(
                left: kSpace8,
                right: kSpace8,
                bottom: kSpace2,
              ),
              child: Text(
                queued.length == 1
                    ? '1 message waiting'
                    : '${queued.length} messages waiting',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            for (var i = 0; i < queued.length; i++)
              TrayRow(
                key: ValueKey(queued[i].id),
                message: queued[i],
                position: i,
                total: queued.length,
                commands: commands,
                onEdit: (text) => onEdit(queued[i].id, text),
                onCancel: () => onCancel(queued[i].id),
                onPromote: () => onPromote(queued[i].id),
                onMove: (delta) => _move(i, delta),
              ),
          ],
        ),
      ),
    );
  }
}

/// One row of the tray: order controls, the text (tap to edit), ⤒ promote, ✕.
class TrayRow extends StatefulWidget {
  /// Creates a tray row.
  const TrayRow({
    super.key,
    required this.message,
    required this.position,
    required this.total,
    required this.commands,
    required this.onEdit,
    required this.onCancel,
    required this.onPromote,
    required this.onMove,
  });

  /// The pending message this row stands for.
  final QueuedMessage message;

  /// 0-based position in the queue.
  final int position;

  /// How many messages are pending.
  final int total;

  /// Agent commands for the editor's palette.
  final List<SlashCmd> commands;

  /// Commit edited text.
  final ValueChanged<String> onEdit;

  /// Drop this message.
  final VoidCallback onCancel;

  /// Send this one now (interrupt).
  final VoidCallback onPromote;

  /// Move by [delta] places.
  final ValueChanged<int> onMove;

  @override
  State<TrayRow> createState() => _TrayRowState();
}

class _TrayRowState extends State<TrayRow> {
  TextEditingController? _ctrl;
  FocusNode? _focus;
  bool _showSlash = false;

  void _startEditing() {
    setState(() {
      _ctrl = TextEditingController(text: widget.message.text);
      _focus = FocusNode()..requestFocus();
    });
  }

  void _stopEditing({bool commit = false}) {
    final text = _ctrl?.text ?? '';
    _ctrl?.dispose();
    _focus?.dispose();
    setState(() {
      _ctrl = null;
      _focus = null;
      _showSlash = false;
    });
    // Commit last: an empty text is a cancel server-side, and this row is gone
    // by the time the snapshot comes back either way.
    if (commit) widget.onEdit(text);
  }

  void _pickSlash(String cmd) {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    ctrl.text = '$cmd ';
    ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    setState(() => _showSlash = false);
    _focus?.requestFocus();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    _focus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final editing = _ctrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (editing && _showSlash)
          Padding(
            padding: const EdgeInsets.only(
              left: kSpace8,
              right: kSpace8,
              bottom: kSpace4,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(kRadius12),
              child: SlashPalette(
                filter: _ctrl!.text,
                commands: widget.commands,
                // Agent commands only: a client command would run now, and this
                // message runs later (SPEC-36).
                includeBuiltins: false,
                onPick: _pickSlash,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace4,
            vertical: kSpace2,
          ),
          child: Row(
            children: [
              _TrayIcon(
                icon: PhosphorIconsLight.arrowUp,
                tooltip: 'Send this sooner',
                onTap: widget.position > 0 ? () => widget.onMove(-1) : null,
              ),
              _TrayIcon(
                icon: PhosphorIconsLight.arrowDown,
                tooltip: 'Send this later',
                onTap: widget.position < widget.total - 1
                    ? () => widget.onMove(1)
                    : null,
              ),
              const SizedBox(width: kSpace4),
              Expanded(
                child: editing
                    ? TextField(
                        controller: _ctrl,
                        focusNode: _focus,
                        autofocus: true,
                        style: TextStyle(fontSize: 13, color: cs.onSurface),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onChanged: (t) {
                          final show = t.startsWith('/') && !t.contains(' ');
                          if (show != _showSlash) {
                            setState(() => _showSlash = show);
                          }
                        },
                        onSubmitted: (_) => _stopEditing(commit: true),
                      )
                    : GestureDetector(
                        onTap: _startEditing,
                        child: Text(
                          widget.message.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: cs.onSurface),
                        ),
                      ),
              ),
              const SizedBox(width: kSpace4),
              // Promote is the only destructive-adjacent action here: it aborts
              // the turn in flight. Labelled as what it costs, not as "now".
              _TrayIcon(
                icon: PhosphorIconsLight.arrowLineUp,
                tooltip: 'Stop the current turn and send this now',
                onTap: editing ? null : widget.onPromote,
              ),
              _TrayIcon(
                icon: PhosphorIconsLight.x,
                tooltip: 'Cancel this message',
                onTap: editing ? () => _stopEditing() : widget.onCancel,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TrayIcon extends StatelessWidget {
  const _TrayIcon({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(icon, size: 14),
    tooltip: tooltip,
    onPressed: onTap,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
    padding: EdgeInsets.zero,
  );
}
