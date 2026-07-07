import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../store/models.dart';
import 'slash_palette.dart';

/// Composer = input bar with slash-command palette + voice (stub) + send.
///
/// Two visual states:
/// - **Compact** (unfocused): `[+] [1-line field] [mic] [send?]`.
/// - **Expanded** (focused): full-width 3-line field on top, with
///   `[+] … [mic] [send?]` in an action row beneath it.
///
/// Tapping into the field expands it; losing focus collapses it back to the
/// 1-line compact form (text is preserved). The send button fades in only
/// while the field is non-empty.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    this.commands = const [],
    this.glass = false,
  });
  final void Function(String text) onSend;
  final List<SlashCmd> commands;

  /// When true, drop the opaque background/border — a [GlassSurface] parent
  /// provides the surface, so the composer must be transparent.
  final bool glass;
  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
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
    setState(() => _showSlash = false);
  }

  void _onSlashPicked(String cmd) {
    _ctrl.text = '$cmd ';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() => _showSlash = false);
  }

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
              child: _isFocused ? _buildExpanded(cs) : _buildCompact(cs),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact: `[+] [field] [mic] [send?]` on a single row.
  Widget _buildCompact(ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildPlus(),
        Expanded(child: _buildField()),
        _buildMic(),
        _buildSendSlot(),
      ],
    );
  }

  /// Expanded: full-width 3-line field, then `[+] … [mic] [send?]` beneath.
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
              _buildPlus(),
              const Spacer(),
              _buildMic(),
              // Reserve the send button's footprint so the mic doesn't jump
              // when the send button fades in/out.
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

  Widget _buildMic() {
    return const IconButton(
      icon: Icon(Icons.mic_none),
      tooltip: 'Voice input',
      // Disabled until M6 (voice dictation); avoids misleading enabled no-op.
      onPressed: null,
    );
  }

  /// Send button that fades in only when the field is non-empty. Fades rather
  /// than scales so it stays laid out at full size (and thus hit-testable)
  /// the moment text appears.
  Widget _buildSendSlot() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: _hasText
          ? IconButton.filled(
              key: const ValueKey('send'),
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Send',
              onPressed: _send,
            )
          : const SizedBox.shrink(key: ValueKey('empty')),
    );
  }

  Widget _buildField() {
    return Shortcuts(
      shortcuts: const {
        // ⌘+Enter (macOS) and Ctrl+Enter (Windows/Linux/desktop) both send.
        SingleActivator(LogicalKeyboardKey.enter, meta: true): _SendIntent(),
        SingleActivator(LogicalKeyboardKey.enter, control: true): _SendIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SendIntent: CallbackAction<_SendIntent>(
            onInvoke: (_) {
              _send();
              return null;
            },
          ),
        },
        child: TextField(
          key: _fieldKey, // stable element across compact↔expanded reparenting
          controller: _ctrl,
          focusNode: _focus,
          // Compact = exactly 1 line; expanded = fixed 3 lines (scrolls past).
          minLines: _isFocused ? 3 : 1,
          maxLines: _isFocused ? 3 : 1,
          textCapitalization: TextCapitalization.sentences,
          // In expanded mode (3 lines), newline is just a line break.
          // In compact mode (1 line), return key submits the message.
          textInputAction: _isFocused
              ? TextInputAction.newline
              : TextInputAction.send,
          onSubmitted: (text) {
            // Only submit on TextInputAction.send (compact mode).
            if (!_isFocused) {
              _send();
            }
          },
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
    _focus.dispose();
    super.dispose();
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}
