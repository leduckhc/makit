/// The pending-message queue (SPEC-38) — messages you sent while the agent was
/// busy that could not be steered into the running turn.
///
/// Each one renders as a **ghost bubble**: dashed, right-aligned, in the
/// conversation's own column, because it looks like the message it will become.
/// A bubble can be edited in place (with the slash palette), moved earlier or
/// later in the queue, or dropped.
///
/// This widget is deliberately callback-driven: `PendingQueueSlot` owns the store
/// wiring, so this file has one widget, one set of tests, and no store import.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../session/chat_metrics.dart';
import 'slash_palette.dart';

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
    required this.onPromote,
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

  /// Interrupt the running turn so one message is delivered next (SPEC-39).
  final ValueChanged<String> onPromote;

  @override
  Widget build(BuildContext context) {
    if (queued.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(
        left: kSpace8,
        right: kSpace8,
        bottom: kSpace4,
      ),
      // Bounded, and scrollable past the bound.
      //
      // On the phone the composer is a floating overlay, so the queue floats over
      // the transcript: unbounded, it would cover the conversation one bubble at
      // a time. Growing the transcript's bottom padding instead is not an option
      // — that is the reversed list's LEADING pad, and changing it mid-session
      // shifts what the user is reading (SPEC-21 anchoring; measured 36px in the
      // anchor tests when I tried). So the queue takes at most a third of the
      // viewport and scrolls internally. NOT `reverse: true`: the children are
      // oldest-first, so a reversed viewport opens at the BOTTOM — the last
      // message queued — and scrolls the next-to-send one off the top, which is
      // the opposite of what matters.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height / 3,
        ),
        child: SingleChildScrollView(
          child: Column(
            // Right, like the sent user bubbles these become: the queue is the
            // user's own column, and the hollow outline (not the side) is what
            // says "not sent yet".
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < queued.length; i++)
                PendingBubble(
                  // Keyed by the server-assigned id so element reuse cannot pair
                  // a bubble (or an open editor) with a different message as the
                  // queue drains or reorders.
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
    required this.onPromote,
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

  /// Send this one now: the server interrupts the running turn (SPEC-39).
  final VoidCallback onPromote;

  /// Move by `-1` (sooner) or `+1` (later).
  final ValueChanged<int> onMove;

  @override
  State<PendingBubble> createState() => _PendingBubbleState();
}

class _PendingBubbleState extends State<PendingBubble> {
  /// True once ⤒ has been tapped for this message.
  ///
  /// Promote interrupts the running turn, so a double-tap would abort twice —
  /// the second time against whatever turn the flush had just started. The
  /// server ignores a stale id, but it cannot tell a stale id from a second
  /// deliberate promote, so the guard belongs here. It lives for the lifetime of
  /// this bubble, which the queue snapshot replaces as soon as the promote
  /// lands.
  bool _promoted = false;
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
                  // SPEC-38: agent commands only — client commands run now, and
                  // this message runs later.
                  includeBuiltins: false,
                  onPick: _pickSlash,
                ),
              ),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            child: Container(
              decoration: BoxDecoration(
                // HOLLOW on purpose: same column, same shape and same corner
                // notch as ChatBubble.user, but no fill. That single difference
                // is what separates "waiting to send" from "already sent" —
                // filling it made a pending message read as a sent one.
                border: Border.all(
                  color: editing ? cs.primary : cs.outlineVariant,
                  width: 1,
                ),
                // Notched corner on the right, matching ChatBubble.user.
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(kChatRadiusLarge),
                  topRight: Radius.circular(kChatRadiusLarge),
                  bottomLeft: Radius.circular(kChatRadiusLarge),
                  bottomRight: Radius.circular(4),
                ),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: kSpace8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                            ),
                            onSubmitted: (_) => _commit(),
                          )
                        : InkWell(
                            onTap: _startEdit,
                            child: Text(
                              widget.message.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface,
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
                  // ONE tight group, all four the same size, no gaps: ↑↓ used to
                  // sit on the far side of the text from ⤒✕, so on any message
                  // longer than a word the controls read as two unrelated pairs.
                  if (!editing) ...[
                    _BubbleAction(
                      icon: PhosphorIconsLight.caretUp,
                      tooltip: 'Send this sooner',
                      onTap: widget.position > 0
                          ? () => widget.onMove(-1)
                          : null,
                    ),
                    _BubbleAction(
                      icon: PhosphorIconsLight.caretDown,
                      tooltip: 'Send this later',
                      onTap: widget.position < widget.total - 1
                          ? () => widget.onMove(1)
                          : null,
                    ),
                    // Hidden (not disabled) while editing: the server has not
                    // seen the new text, so promoting would interrupt the turn
                    // to deliver the OLD message.
                    _BubbleAction(
                      icon: PhosphorIconsLight.arrowLineUp,
                      tooltip: 'Stop the current turn and send this now',
                      onTap: _promoted
                          ? null
                          : () {
                              setState(() => _promoted = true);
                              widget.onPromote();
                            },
                    ),
                  ],
                  _BubbleAction(
                    icon: editing
                        ? PhosphorIconsLight.check
                        : PhosphorIconsLight.x,
                    tooltip: editing ? 'Done' : 'Cancel this message',
                    onTap: editing ? _commit : widget.onCancel,
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

/// One control inside a ghost bubble: ↑, ↓, ⤒ or ✕.
///
/// All four are the same 26px box so the group reads as a group. **Known
/// tradeoff:** that is under the 44px platform minimum for a touch target. A
/// ghost bubble has to read as the message it will become (SPEC-38), and 44px
/// boxes made it more than twice the height of the sent bubble. The text itself
/// is a full-height target for the primary action (edit), and every action here
/// is reversible.
///
/// Buttons, not a drag handle, for reordering (SPEC-38 decision 6): both
/// placements sit inside or beside a scrollable, where a drag fights the
/// scroller on a phone.
class _BubbleAction extends StatelessWidget {
  const _BubbleAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;

  /// Null renders the control dimmed and inert (e.g. ↑ on the first message).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          child: Center(
            child: Icon(
              icon,
              size: 12,
              color: onTap == null ? cs.outlineVariant : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
