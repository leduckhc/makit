import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shortcuts/key_chord.dart';
import '../../store/models.dart';
import 'slash_palette.dart';

/// Composer = input bar with slash-command palette + send.
///
/// Two visual states:
/// - **Compact** (unfocused): `[+] [1-line field] [send?]`.
/// - **Expanded** (focused, or always on desktop): an auto-growing multiline
///   field on top (grows with the caret up to 10 lines, then scrolls), with a
///   footer row beneath it: `[footerActions…] … [+] [send?]`.
///
/// On mobile the field is compact until focused, then expands to the full
/// form; losing focus collapses it back to the 1-line compact form (text is
/// preserved). On desktop [alwaysExpanded] keeps the full form up permanently.
/// The send button fades in only while the field is non-empty.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    this.onCancel,
    this.running = false,
    this.commands = const [],
    this.glass = false,
    this.sendChord,
    this.newlineChord,
    this.focusNode,
    this.footerActions = const <Widget>[],
    this.alwaysExpanded = false,
  });
  final void Function(String text) onSend;

  /// Leading controls placed on the left of the footer action row when the
  /// composer is in its full (expanded) form — e.g. the model + thinking
  /// selectors. Each may render nothing (a shrunk box) when it has no data.
  final List<Widget> footerActions;

  /// When true the composer is permanently in its full form (multiline field +
  /// footer), regardless of focus. Desktop sets this; mobile leaves it false so
  /// the field collapses to a one-liner when unfocused.
  final bool alwaysExpanded;

  /// The chord that sends the message. Null uses the built-in default
  /// (⌘/Ctrl+Enter), which keeps mobile behavior unchanged.
  final KeyChord? sendChord;

  /// The chord that inserts a newline instead of sending. When [sendChord]
  /// claims a key the field would otherwise use for line breaks (e.g. plain
  /// Enter), callers must supply a matching [newlineChord] — leaving it null
  /// lets the send activator capture that key, making the field's native
  /// Return-inserts-newline behavior unreachable. Null is safe only when
  /// [sendChord] does not take over the newline key.
  final KeyChord? newlineChord;

  /// An externally-owned focus node for the text field. When provided, the
  /// caller controls focus (e.g. a global "focus composer" shortcut) and is
  /// responsible for disposing it. Null makes the composer own its node.
  final FocusNode? focusNode;

  /// Called when the user taps the cancel (stop) button while a turn is
  /// running and the input is empty. Null disables the cancel affordance.
  final VoidCallback? onCancel;

  /// Whether the agent is mid-turn. Drives the cancel button: when true and
  /// the field is empty, the trailing slot shows a stop button instead of
  /// nothing.
  final bool running;
  final List<SlashCmd> commands;

  /// When true, drop the opaque background/border — a [GlassSurface] parent
  /// provides the surface, so the composer must be transparent.
  final bool glass;
  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _ctrl = TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  final _fieldKey = GlobalKey(); // stable element across compact↔expanded swap
  bool _showSlash = false;
  bool _hasText = false;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerChanged);
    _focus.addListener(_onFocusChanged);
  }

  void _onControllerChanged() {
    final hasText = _ctrl.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _onFocusChanged() {
    final focused = _focus.hasFocus;
    if (focused != _isFocused) setState(() => _isFocused = focused);
  }

  void _onChanged(String value) {
    // Show palette while the user is typing the command name itself
    // (everything up to the first whitespace).
    final showSlash = value.startsWith('/') && !value.contains(RegExp(r'\s'));
    // Always rebuild while the palette is (or becomes) open so the filter
    // prop on SlashPalette reflects the latest text.
    setState(() => _showSlash = showSlash);
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _ctrl.clear();
    // Dismiss the composer + keyboard so focus returns to the chat content.
    _focus.unfocus();
    setState(() => _showSlash = false);
  }

  void _onSlashPicked(String cmd) {
    _ctrl.text = '$cmd ';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() => _showSlash = false);
  }

  /// Whether to show the full (multiline + footer) form: always on desktop,
  /// otherwise only while the field is focused.
  bool get _expanded => widget.alwaysExpanded || _isFocused;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showSlash)
            SlashPalette(
              filter: _ctrl.text,
              commands: widget.commands,
              onPick: _onSlashPicked,
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            decoration: widget.glass
                ? null
                : BoxDecoration(
                    color: cs.surface,
                    border: Border(top: BorderSide(color: cs.outlineVariant)),
                  ),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: _expanded ? _buildExpanded(cs) : _buildCompact(cs),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact: `[+] [field] [send?]` on a single row.
  Widget _buildCompact(ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildPlus(),
        Expanded(child: _buildField()),
        _buildSendSlot(),
      ],
    );
  }

  /// Expanded: auto-growing multiline field, then a footer row with the
  /// caller's [Composer.footerActions] on the left (model/thinking selectors)
  /// and `[+] [send?]` on the right.
  Widget _buildExpanded(ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildField(),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              for (final action in widget.footerActions)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: action,
                ),
              const Spacer(),
              _buildPlus(),
              // Reserve the send button's footprint so the layout doesn't
              // jump when the send button fades in/out.
              SizedBox(width: 48, child: _buildSendSlot()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlus() {
    return const IconButton(
      icon: Icon(Icons.add_circle_outline),
      tooltip: 'Add attachment',
      // Disabled until M6 (@-mention picker); avoids misleading enabled no-op.
      onPressed: null,
    );
  }

  /// Trailing slot. Priority: non-empty text → green send arrow; else if a
  /// turn is running → stop/cancel button; else nothing. Fades between states.
  Widget _buildSendSlot() {
    final Widget child;
    if (_hasText) {
      child = IconButton.filled(
        key: const ValueKey('send'),
        icon: const Icon(Icons.arrow_upward),
        tooltip: 'Send',
        onPressed: _send,
      );
    } else if (widget.running && widget.onCancel != null) {
      child = IconButton.filled(
        key: const ValueKey('cancel'),
        icon: const Icon(Icons.stop),
        tooltip: 'Cancel turn',
        onPressed: widget.onCancel,
      );
    } else {
      child = const SizedBox.shrink(key: ValueKey('empty'));
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: child,
    );
  }

  Map<ShortcutActivator, Intent> _shortcuts() {
    final sendChord = widget.sendChord;
    if (sendChord == null) {
      // Default (mobile + un-configured): ⌘+Enter and Ctrl+Enter both send.
      return const {
        SingleActivator(LogicalKeyboardKey.enter, meta: true): _SendIntent(),
        SingleActivator(LogicalKeyboardKey.enter, control: true): _SendIntent(),
      };
    }
    return {
      sendChord.toActivator(): const _SendIntent(),
      if (widget.newlineChord != null)
        widget.newlineChord!.toActivator(): const _NewlineIntent(),
    };
  }

  void _insertNewline() {
    final value = _ctrl.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    final text = value.text.replaceRange(start, end, '\n');
    _ctrl.value = value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }

  Widget _buildField() {
    return Shortcuts(
      shortcuts: _shortcuts(),
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SendIntent: CallbackAction<_SendIntent>(
            onInvoke: (_) {
              _send();
              return null;
            },
          ),
          _NewlineIntent: CallbackAction<_NewlineIntent>(
            onInvoke: (_) {
              _insertNewline();
              return null;
            },
          ),
        },
        child: TextField(
          key: _fieldKey, // stable element across compact↔expanded reparenting
          controller: _ctrl,
          focusNode: _focus,
          // Compact = exactly 1 line; expanded auto-grows with the caret up to
          // 10 lines, then scrolls internally.
          minLines: 1,
          maxLines: _expanded ? 10 : 1,
          textCapitalization: TextCapitalization.sentences,
          // Return behavior is driven by _shortcuts(): unconfigured (mobile)
          // keeps the native Return-inserts-newline action, with sending via
          // the send button or ⌘/Ctrl+Enter; when sendChord/newlineChord are
          // configured (desktop), Return itself may send instead.
          textInputAction: TextInputAction.newline,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            hintText: 'Message …',
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerChanged);
    _focus.removeListener(_onFocusChanged);
    _ctrl.dispose();
    // Only dispose a focus node we created; an injected one is caller-owned.
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _NewlineIntent extends Intent {
  const _NewlineIntent();
}
