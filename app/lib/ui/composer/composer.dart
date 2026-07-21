import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

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
/// The send button is always shown; it's disabled (grayish) while the field is
/// empty and enabled once there's text.
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
    this.controller,
    this.footerActions = const <Widget>[],
    this.alwaysExpanded = false,
    this.initialText,
    this.onDraftChanged,
  });
  final void Function(String text) onSend;

  /// Text to seed the field with when the composer first mounts — used to
  /// restore a half-typed draft after the composer is disposed and recreated
  /// (e.g. a desktop worktree switch or pane split). Null/empty starts blank.
  final String? initialText;

  /// Called with the field's full text on every change (typing, slash-pick,
  /// newline insert, and the clear that follows a send). Callers persist this
  /// to restore [initialText] on a later mount; the post-send empty string
  /// lets them prune the stored draft.
  final ValueChanged<String>? onDraftChanged;

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

  /// An externally-owned text controller. When provided, a sibling widget (e.g.
  /// the PR-actions split button) can inject text into the field, and the
  /// caller owns disposal. Null makes the composer own its controller. When
  /// provided empty, it is still seeded from [initialText].
  final TextEditingController? controller;

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
  late final TextEditingController _ctrl =
      widget.controller ?? TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  final _fieldKey = GlobalKey(); // stable element across compact↔expanded swap
  bool _showSlash = false;
  bool _hasText = false;
  bool _isFocused = false;
  // A one-time nudge (once per app session) shown when the composer first
  // gains focus, hinting that '/' opens the command palette. Auto-dismisses.
  static bool _slashTipSeen = false;
  bool _showSlashTip = false;
  Timer? _slashTipTimer;

  @override
  void initState() {
    super.initState();
    // Restore any persisted draft, placing the caret at the end so the user
    // resumes where they left off. Guard on empty so an injected controller
    // that already carries text (a live draft) is never clobbered.
    final seed = widget.initialText ?? '';
    if (seed.isNotEmpty && _ctrl.text.isEmpty) {
      _ctrl.text = seed;
      _ctrl.selection = TextSelection.collapsed(offset: seed.length);
      _hasText = seed.trim().isNotEmpty;
    }
    _ctrl.addListener(_onControllerChanged);
    _focus.addListener(_onFocusChanged);
  }

  void _onControllerChanged() {
    final hasText = _ctrl.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    widget.onDraftChanged?.call(_ctrl.text);
  }

  void _onFocusChanged() {
    final focused = _focus.hasFocus;
    if (focused != _isFocused) setState(() => _isFocused = focused);
    if (focused && !_slashTipSeen) {
      _slashTipSeen = true;
      setState(() => _showSlashTip = true);
      _slashTipTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _showSlashTip = false);
      });
    }
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
    // One coherent, static box behind the whole composer (field + footer
    // controls). Uses the M3 `surfaceContainerHigh` tonal step so it reads as a
    // raised input panel against the scaffold surface, painted by a plain
    // Container so it never shifts on hover. Glass surfaces supply their own
    // backdrop, so stay transparent there.
    final boxColor = widget.glass
        ? Colors.transparent
        : cs.surfaceContainerHigh;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showSlashTip && !_showSlash) _buildSlashTip(cs),
          if (_showSlash)
            SlashPalette(
              filter: _ctrl.text,
              commands: widget.commands,
              onPick: _onSlashPicked,
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            decoration: widget.glass ? null : BoxDecoration(color: cs.surface),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: Container(
                decoration: BoxDecoration(
                  color: boxColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: _expanded ? _buildExpanded(cs) : _buildCompact(cs),
              ),
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
              // The selectors share the row's free space and shrink (their
              // labels ellipsize) rather than overflowing on narrow widths.
              // Expanded here also stands in for the trailing Spacer, pushing
              // [+]/send to the right when the actions are short or absent.
              Expanded(
                child: Row(
                  children: [
                    for (final action in widget.footerActions)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: action,
                        ),
                      ),
                  ],
                ),
              ),
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
      icon: Icon(PhosphorIconsLight.paperclip),
      tooltip: 'Attachments coming in v2',
      // Disabled until v2 (@-mention picker); avoids misleading enabled no-op.
      onPressed: null,
    );
  }

  /// Transient one-time nudge shown the first time the composer gains focus,
  /// hinting that '/' opens the command palette. Auto-dismisses after 4s.
  Widget _buildSlashTip(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            "Tip: type '/' to see commands",
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// Trailing slot. Priority: non-empty text → filled send arrow; else if a
  /// turn is running → stop/cancel button; else a disabled (grayish) send
  /// arrow. Fades between states.
  Widget _buildSendSlot() {
    final cs = Theme.of(context).colorScheme;
    // Compact footprint: a 36px circle with a 18px glyph, tighter than the
    // Material default (40px circle / 24px icon) which read oversized on phone.
    const double iconSize = 18;
    final compact = IconButton.styleFrom(
      fixedSize: const Size.square(36),
      minimumSize: const Size.square(36),
      padding: EdgeInsets.zero,
    );
    final Widget child;
    if (_hasText) {
      child = IconButton.filled(
        key: const ValueKey('send'),
        icon: const Icon(PhosphorIconsLight.arrowUp),
        iconSize: iconSize,
        style: compact,
        tooltip: 'Send',
        onPressed: _send,
      );
    } else if (widget.running && widget.onCancel != null) {
      child = IconButton.filled(
        key: const ValueKey('cancel'),
        icon: const Icon(PhosphorIconsLight.stop),
        iconSize: iconSize,
        // Stop is destructive → error red from the design system.
        style: compact.copyWith(
          backgroundColor: WidgetStatePropertyAll(cs.error),
          foregroundColor: WidgetStatePropertyAll(cs.onError),
        ),
        tooltip: 'Cancel turn',
        onPressed: widget.onCancel,
      );
    } else {
      // Empty input, not running: show a disabled (grayish) send button so the
      // affordance stays visible. onPressed: null gives the disabled styling.
      child = IconButton.filled(
        key: const ValueKey('send-disabled'),
        icon: const Icon(PhosphorIconsLight.arrowUp),
        iconSize: iconSize,
        style: compact,
        tooltip: 'Send',
        onPressed: null,
      );
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
        child: ScrollConfiguration(
          // Hide the input's scrollbar; the field still scrolls once it grows
          // past its max line count.
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: TextField(
            key:
                _fieldKey, // stable element across compact↔expanded reparenting
            controller: _ctrl,
            focusNode: _focus,
            // Compact = exactly 1 line; expanded starts 3 rows tall and
            // auto-grows with the caret up to a max, then scrolls internally.
            // The max is trimmed to 6 lines on narrow viewports (<600px) so the
            // composer can't eat the transcript on small windows/phones.
            minLines: _expanded ? 3 : 1,
            maxLines: _expanded
                ? (MediaQuery.of(context).size.width < 600 ? 6 : 10)
                : 1,
            textCapitalization: TextCapitalization.sentences,
            // Return behavior is driven by _shortcuts(): unconfigured (mobile)
            // keeps the native Return-inserts-newline action, with sending via
            // the send button or ⌘/Ctrl+Enter; when sendChord/newlineChord are
            // configured (desktop), Return itself may send instead.
            textInputAction: TextInputAction.newline,
            onChanged: _onChanged,
            // Transparent: the shared composer box supplies the background, so
            // the field, selectors, [+] and send all sit on one static surface.
            decoration: const InputDecoration(
              hintText: 'Message…',
              filled: false,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _slashTipTimer?.cancel();
    _ctrl.removeListener(_onControllerChanged);
    _focus.removeListener(_onFocusChanged);
    // Only dispose objects we created; injected ones are caller-owned.
    if (widget.controller == null) _ctrl.dispose();
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
