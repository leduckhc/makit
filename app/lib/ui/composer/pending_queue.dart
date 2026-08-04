/// The pending-message queue (SPEC-36) — messages you sent while the agent was
/// busy that could not be steered into the running turn.
///
/// Each one renders as a **ghost bubble**: dashed, right-aligned, in the
/// conversation's own column, because it looks like the message it will become.
/// A bubble can be edited in place (with the slash palette), moved earlier or
/// later in the queue, or dropped.
///
/// This widget is deliberately **placement-agnostic** and callback-driven: the
/// same instance is mounted either in the composer column or inside the
/// transcript's trailer row, decided by
/// [PendingQueuePlacement]. Keeping the store out of it means one widget, one
/// set of tests, and no `desktop/` import from shared `ui/`.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../session/chat_metrics.dart';
import 'slash_palette.dart';

/// Where the pending queue is rendered.
enum PendingQueuePlacement {
  /// Directly above the composer field — always visible, never scrolls away.
  pinned,

  /// At the end of the transcript (its trailer row), in the conversation flow —
  /// scrolls with the conversation, so it can leave the viewport.
  inline,
}

/// A stack of [PendingBubble]s, oldest (next to send) first.
class PendingQueue extends StatelessWidget {
  /// Creates the pending queue.
  const PendingQueue({
    super.key,
    required this.queued,
    required this.commands,
    required this.onEdit,
    required this.onReorder,
    required this.onCancel,
  });

  /// Pending messages, in send order.
  final List<QueuedMessage> queued;

  /// The agent's commands, for the editor's slash palette. Client commands are
  /// excluded by the palette itself — see [SlashPalette.includeBuiltins].
  final List<SlashCmd> commands;

  /// Commit new text for a message. Empty text means cancel; the caller maps
  /// that to `queue.update`, which the server treats as a cancel.
  final void Function(String id, String text) onEdit;

  /// Apply a new full send order.
  final ValueChanged<List<String>> onReorder;

  /// Drop one message.
  final ValueChanged<String> onCancel;

  @override
  Widget build(BuildContext context) {
    if (queued.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(
        left: kSpace8,
        right: kSpace8,
        bottom: kSpace4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < queued.length; i++)
            PendingBubble(
              // Keyed by the server-assigned id so element reuse cannot pair a
              // bubble (or an open editor) with a different message as the
              // queue drains or reorders.
              key: ValueKey(queued[i].id),
              message: queued[i],
              position: i,
              total: queued.length,
              commands: commands,
              onEdit: (text) => onEdit(queued[i].id, text),
              onCancel: () => onCancel(queued[i].id),
              onMove: (delta) => _move(i, delta),
            ),
        ],
      ),
    );
  }

  /// Swap the message at [i] with its neighbour and emit the whole new order.
  /// The server takes the full list (a hint, tolerant of a queue that flushed
  /// underneath), so there is no index-based command to get wrong.
  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= queued.length) return;
    final ids = queued.map((q) => q.id).toList();
    final moved = ids.removeAt(i);
    ids.insert(j, moved);
    onReorder(ids);
  }
}

/// One pending message: ghost bubble, order controls, and an inline editor.
class PendingBubble extends StatefulWidget {
  /// Creates a pending-message bubble.
  const PendingBubble({
    super.key,
    required this.message,
    required this.position,
    required this.total,
    required this.commands,
    required this.onEdit,
    required this.onCancel,
    required this.onMove,
  });

  /// The pending message.
  final QueuedMessage message;

  /// Zero-based position in the queue, for the caption.
  final int position;

  /// Queue length, for the caption.
  final int total;

  /// Agent commands for the editor's palette.
  final List<SlashCmd> commands;

  /// Commit edited text ('' = cancel).
  final ValueChanged<String> onEdit;

  /// Drop this message.
  final VoidCallback onCancel;

  /// Move by `-1` (sooner) or `+1` (later).
  final ValueChanged<int> onMove;

  @override
  State<PendingBubble> createState() => _PendingBubbleState();
}

class _PendingBubbleState extends State<PendingBubble> {
  TextEditingController? _ctrl;
  final _focus = FocusNode();
  bool _showSlash = false;

  @override
  void dispose() {
    _ctrl?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(() {
      _ctrl = TextEditingController(text: widget.message.text)
        ..addListener(_onChanged);
      _showSlash = false;
    });
    _focus.requestFocus();
  }

  void _onChanged() {
    final text = _ctrl!.text;
    final show = text.startsWith('/') && !text.contains(RegExp(r'\s'));
    if (show != _showSlash) setState(() => _showSlash = show);
  }

  void _commit() {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    final text = ctrl.text.trim();
    setState(() {
      _ctrl = null;
      _showSlash = false;
    });
    ctrl.dispose();
    // An emptied draft is a cancel: a blank pending message is not a thing.
    if (text.isEmpty) {
      widget.onCancel();
      return;
    }
    if (text != widget.message.text) widget.onEdit(text);
  }

  void _pickSlash(String cmd) {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    ctrl.text = '$cmd ';
    ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    setState(() => _showSlash = false);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final editing = _ctrl != null;
    final caption = widget.position == 0
        ? 'sends next · 1 of ${widget.total}'
        : 'then · ${widget.position + 1} of ${widget.total}';

    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editing && _showSlash)
            Padding(
              padding: const EdgeInsets.only(bottom: kSpace4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(kRadius12),
                child: SlashPalette(
                  filter: _ctrl!.text,
                  commands: widget.commands,
                  // SPEC-36: agent commands only — client commands run now, and
                  // this message runs later.
                  includeBuiltins: false,
                  onPick: _pickSlash,
                ),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.86,
            ),
            child: Container(
              decoration: BoxDecoration(
                // Dashed is not a Flutter border style; a dimmed outline plus
                // the transparent fill carries the same "not sent yet" reading.
                border: Border.all(
                  color: editing ? cs.primary : cs.outlineVariant,
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(kChatRadiusLarge),
                  topRight: Radius.circular(kChatRadiusLarge),
                  bottomLeft: Radius.circular(kChatRadiusLarge),
                  bottomRight: Radius.circular(4),
                ),
              ),
              padding: const EdgeInsets.only(left: kSpace8, right: kSpace2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _OrderControls(
                    canMoveUp: widget.position > 0,
                    canMoveDown: widget.position < widget.total - 1,
                    onMove: widget.onMove,
                  ),
                  const SizedBox(width: kSpace4),
                  Flexible(
                    child: editing
                        ? TextField(
                            controller: _ctrl,
                            focusNode: _focus,
                            autofocus: true,
                            style: TextStyle(fontSize: 13, color: cs.onSurface),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: kSpace8,
                              ),
                            ),
                            onSubmitted: (_) => _commit(),
                          )
                        : InkWell(
                            onTap: _startEdit,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: kSpace8,
                              ),
                              child: Text(
                                widget.message.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                  ),
                  if ((widget.message.attachmentCount ?? 0) > 0) ...[
                    Icon(
                      PhosphorIconsLight.paperclip,
                      size: 12,
                      color: cs.onSurfaceVariant,
                    ),
                    Text(
                      '${widget.message.attachmentCount}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                  IconButton(
                    onPressed: editing ? _commit : widget.onCancel,
                    tooltip: editing ? 'Done' : 'Cancel this message',
                    visualDensity: VisualDensity.compact,
                    iconSize: 14,
                    icon: Icon(
                      editing ? PhosphorIconsLight.check : PhosphorIconsLight.x,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: kSpace2, right: kSpace4),
            child: Text(
              caption,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: cs.outline),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ↑ / ↓ order controls. Buttons rather than a drag handle on purpose
/// (SPEC-36 decision 6): both placements sit inside or beside a scrollable, and
/// on a phone a drag there fights the scroller.
class _OrderControls extends StatelessWidget {
  const _OrderControls({
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMove,
  });

  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget arrow(IconData icon, bool enabled, int delta, String tip) => Tooltip(
      message: tip,
      child: InkWell(
        onTap: enabled ? () => onMove(delta) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSpace2),
            child: Icon(
              icon,
              size: 11,
              color: enabled ? cs.onSurfaceVariant : cs.outlineVariant,
            ),
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        arrow(PhosphorIconsLight.caretUp, canMoveUp, -1, 'Send this sooner'),
        arrow(PhosphorIconsLight.caretDown, canMoveDown, 1, 'Send this later'),
      ],
    );
  }
}
