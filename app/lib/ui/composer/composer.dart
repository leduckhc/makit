import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../shortcuts/key_chord.dart';
import '../../store/composer_attachments.dart';
import '../../store/models.dart';
import 'attachment_chips.dart';
import 'slash_palette.dart';

/// Everything the composer needs to accept images (SPEC-33), built once per
/// surface by `composerAttachments()` in `attachment_controller.dart`.
///
/// A single object because attachments are a single capability: six independent
/// optional callbacks let a caller wire up half of it, and made every consumer
/// re-derive "can this composer attach?" from whichever nullables it happened to
/// hold.
@immutable
class ComposerAttachmentsApi {
  /// Bundles the staged images and the four things a composer does with them.
  const ComposerAttachmentsApi({
    required this.staged,
    required this.remove,
    required this.retry,
    required this.readClipboardImage,
    required this.stagePasted,
    this.pick,
  });

  /// Images staged for the next message, newest last. Rendered as a chip strip
  /// above the field; an unsettled (uploading) one blocks sending.
  final List<ComposerAttachment> staged;

  /// Opens the attachment picker. **Null means nothing can be staged right now**
  /// (nothing paired, so nowhere to upload): the paperclip stays visible but
  /// inert with a tooltip that says why, and ⌘V is left to the field. Already
  /// staged images stay removable/retryable — they must never strand invisibly.
  final VoidCallback? pick;

  /// Remove / retry a staged attachment by its `localId`.
  final ValueChanged<String> remove;
  final ValueChanged<String> retry;

  /// Reads an image off the system clipboard, or null when there is none.
  /// Injected so the composer stays testable and platform-free.
  final Future<({Uint8List bytes, String mime, String name})?> Function()
  readClipboardImage;

  /// Stages a pasted image. Called only when [readClipboardImage] yielded one;
  /// otherwise the paste falls through to the field's normal text paste.
  final void Function(({Uint8List bytes, String mime, String name}) image)
  stagePasted;
}

/// The hairline under [Composer.header], separating the caption from the field.
const Key kComposerHeaderRuleKey = ValueKey('composer-header-rule');

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
    this.footerTrailing,
    this.header,
    this.alwaysExpanded = false,
    this.initialText,
    this.onDraftChanged,
    this.enabled = true,
    this.disabledHint,
    this.attachments,
    this.clientCommands = true,
  });
  final void Function(String text) onSend;

  /// Everything this composer needs to handle images (SPEC-33), or **null when
  /// it is not attachment-aware at all** (the free-text answer composers): the
  /// paperclip is then inert, no chips are shown and ⌘V is left to the field.
  ///
  /// One object rather than a handful of optional callbacks, so the composer
  /// never has to re-derive "am I attachment-capable" from several nullables
  /// that could disagree, and so the two surfaces cannot wire it up differently.
  final ComposerAttachmentsApi? attachments;

  /// When false, the composer is inert: the field + send are replaced by a
  /// muted [disabledHint] bar. Used while a session is awaiting an inline
  /// answer (SPEC-25) so the user resolves the question above instead of
  /// sending a normal message.
  final bool enabled;

  /// Hint shown in place of the field when [enabled] is false.
  final String? disabledHint;

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
  ///
  /// These SHARE the row's free space (each is `Flexible`), so labels ellipsize
  /// instead of overflowing. A control that has a fixed size does not belong
  /// here — see [footerTrailing].
  final List<Widget> footerActions;

  /// A fixed-size control pinned to the right of [footerActions], before `[+]`
  /// — the context-usage ring (SPEC-37) is the only caller today.
  ///
  /// It exists because [footerActions] entries are `Flexible`, and `Flexible`
  /// defaults to `FlexFit.loose`: a child is *allowed* its share, lays out at
  /// its natural size, and whatever it leaves over is **not redistributed**. A
  /// 36pt ring passed as a second action therefore reserved half the row and
  /// wasted it: the config pill's label was cut to 65.5pt of the 187.5pt it
  /// wanted (`anthropic/Cl…`), codex's to 29.8pt (`gpt…`), and a session with
  /// several options overflowed the row outright (SPEC-40).
  ///
  /// Singular by design: one control is all any surface needs, and a caller
  /// wanting two can wrap them. Must be intrinsically sized — nothing here is
  /// given flex, so a wide child eats the pills' room.
  final Widget? footerTrailing;

  /// A single row on the composer's **top edge**, inside the box and above a
  /// hairline — the PR next-step bar (SPEC-38) is the only caller.
  ///
  /// Inside rather than a sibling above, per the mockup's §5 "inside the
  /// composer": at this weight it reads as a caption on the box you are typing
  /// into, which is what it is — most of its actions put text there.
  ///
  /// Rendered regardless of [enabled]: a locked field does not make "push" or
  /// "wrap up" any less valid, and hiding it mid-ask would take the worktree's
  /// only status line with it.
  ///
  /// Must be intrinsically sized in the vertical: it is not given flex, and the
  /// box grows to fit it.
  final Widget? header;

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

  /// Whether the palette also offers the built-in **client** commands
  /// (`/cancel`, `/model`, `/compact`, …).
  ///
  /// False for a composer whose send path cannot run them: they are intercepted
  /// by `handleClientCommand`, which needs a `sessionId`, so the sessionless
  /// starter pane would send the literal text `/model` to a brand-new agent.
  /// Same reason the queue editor excludes them (SPEC-38): a command that acts
  /// *now* has no meaning in a message that is not sent now, or has nowhere to
  /// act. Agent commands are unaffected.
  final bool clientCommands;

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
  /// Anchors the slash palette to the composer box: it floats in the app's
  /// [Overlay] instead of sitting in this Column, so opening it never resizes
  /// the transcript above (desktop) or the bottom stack (mobile).
  final _paletteLink = LayerLink();
  final _paletteController = OverlayPortalController();
  final _boxKey = GlobalKey(); // composer box, measured to cap palette height
  bool _showSlash = false;

  /// Highlighted row in the palette, driven by ↑/↓ and picked by Tab.
  int _slashIndex = 0;
  bool _hasText = false;

  /// Which send-slot child is current, and how many times it has changed.
  ///
  /// The switcher below keys its child on the *serial*, not on the state, so a
  /// state the user returns to (send → cancel → send while a turn starts and
  /// ends under their typing) never collides with its own outgoing copy — which
  /// handed the switcher's Stack two children with one key and tripped
  /// Flutter's `Duplicate keys found` assertion.
  String? _sendSlotId;
  int _sendSlotSerial = 0;
  bool _isFocused = false;

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
    // A popover anchored to a composer the user has just left (on mobile it
    // collapses back to one line) would hang over the transcript with nothing
    // to type into.
    if (!focused && _showSlash) {
      setState(() => _showSlash = false);
      _syncPalette();
    }
  }

  void _onChanged(String value) {
    // Show palette while the user is typing the command name itself
    // (everything up to the first whitespace).
    final showSlash = value.startsWith('/') && !value.contains(RegExp(r'\s'));
    // Always rebuild while the palette is (or becomes) open so the matches and
    // the overlay's position reflect the latest text.
    setState(() {
      _showSlash = showSlash;
      // The match list changed under the highlight; start from the best match.
      _slashIndex = 0;
    });
    _syncPalette();
  }

  /// Mirrors [_showSlash] onto the overlay. Called after the `setState`s that
  /// flip it, never during build (the controller mutates the portal's state).
  void _syncPalette() {
    if (_showSlash && !_paletteController.isShowing) {
      _paletteController.show();
    } else if (!_showSlash && _paletteController.isShowing) {
      _paletteController.hide();
    }
  }

  /// The commands the palette is currently showing, in its order — shared with
  /// the palette so Tab can never pick a different row than the highlighted one.
  List<SlashCmd> get _slashMatches => filterSlashCommands(
    _ctrl.text,
    widget.commands,
    includeBuiltins: widget.clientCommands,
  );

  /// [_slashIndex] clamped to [count] rows. The agent can re-push a shorter
  /// command list with no keystroke to reset the raw index, which would leave
  /// the palette with nothing highlighted while Tab still committed a row. Both
  /// readers go through here so they cannot disagree.
  int _selectedIndex(int count) =>
      count == 0 ? 0 : _slashIndex.clamp(0, count - 1);

  /// ↑/↓ move the highlight (wrapping), Tab picks it, Esc dismisses. Handled
  /// here, above the field, so these keys reach the palette before the text
  /// field's caret movement and the app's Tab focus traversal claim them.
  KeyEventResult _onPaletteKey(FocusNode _, KeyEvent event) {
    if (!_showSlash) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _showSlash = false);
      _syncPalette();
      return KeyEventResult.handled;
    }
    final matches = _slashMatches;
    if (matches.isEmpty) return KeyEventResult.ignored;
    final index = _selectedIndex(matches.length);
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _slashIndex = (index + 1) % matches.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _slashIndex = (index - 1 + matches.length) % matches.length,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      _onSlashPicked(matches[index].invocation);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Whether there is something to send: text, or at least one stored image.
  /// An upload still in flight blocks sending outright — the server would
  /// reject a `mediaId` it has not stored yet, losing the whole turn.
  bool get _canSend {
    if (_staged.any((a) => a.status == AttachmentStatus.uploading)) {
      return false;
    }
    return _hasText || _staged.any((a) => a.isReady);
  }

  /// Images staged for the next message, newest last. Empty when this composer
  /// is not attachment-aware.
  List<ComposerAttachment> get _staged =>
      widget.attachments?.staged ?? const [];

  /// The attachments API, but only while it can actually take a *new* image.
  /// The single gate for the paperclip and the ⌘V claim: a composer that cannot
  /// stage must not claim the field's native paste.
  ///
  /// Note this is not the same as [Composer.attachments] being non-null: a
  /// session with staged images but nowhere left to upload to still shows (and
  /// can remove/retry) its chips, so those never strand invisibly.
  ComposerAttachmentsApi? get _staging {
    final api = widget.attachments;
    return api == null || api.pick == null ? null : api;
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (!_canSend) return;
    widget.onSend(text);
    _ctrl.clear();
    // Dismiss the composer + keyboard so focus returns to the chat content.
    _focus.unfocus();
    setState(() => _showSlash = false);
    _syncPalette();
  }

  void _onSlashPicked(String cmd) {
    _ctrl.text = '$cmd ';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() => _showSlash = false);
    _syncPalette();
    // Restore focus: when the palette row is tapped (on desktop), the
    // pointer-down outside the TextField unfocuses it before onTap fires.
    // Re-focus here so the user can continue typing immediately.
    _focus.requestFocus();
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
      child: LayoutBuilder(
        // The composer's own width, handed to the overlaid palette so the
        // popover lines up with the box it belongs to.
        builder: (context, constraints) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Shown even when the composer is disabled (awaiting an inline
            // answer): the attachments still exist and may still be uploading, so
            // hiding them would strand un-removable, invisible work.
            if (_staged.isNotEmpty)
              AttachmentChips(
                attachments: _staged,
                onRemove: widget.attachments!.remove,
                onRetry: widget.attachments!.retry,
              ),
            OverlayPortal(
              controller: _paletteController,
              overlayChildBuilder: (ctx) =>
                  _buildPalette(ctx, constraints.maxWidth),
              child: CompositedTransformTarget(
                link: _paletteLink,
                child: Container(
                  key: _boxKey,
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
                  decoration: widget.glass
                      ? null
                      : BoxDecoration(color: cs.surface),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      decoration: BoxDecoration(
                        color: boxColor,
                        borderRadius: BorderRadius.circular(kRadius16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: kSpace4,
                        vertical: kSpace4,
                      ),
                      child: _buildBox(cs),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The slash palette, floating in the [Overlay] with its bottom edge pinned
  /// to the top of the composer box.
  ///
  /// Its height is capped to the space actually free above the composer (which
  /// already excludes the keyboard, since the composer sits above it) — the old
  /// half-the-screen cap ignored the keyboard and the safe area and pushed the
  /// first, best-matching rows off the top of the screen on a phone.
  ///
  /// Two ceilings, because "don't cover the bar" and "stay on screen" are not
  /// equally important. Normally the popover also clears the mobile floating
  /// glass bar, which it renders *above* (it is in the app's [Overlay]). When
  /// that leaves less than one row, it may cover the bar — briefly, while
  /// picking a command — but it must never cross the hard ceiling and go
  /// off-screen, and when even that has no room for a row it does not render.
  Widget _buildPalette(BuildContext ctx, double width) {
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    // No measurement, no popover: a guessed height is how the old code pushed
    // rows off-screen. Unreachable in practice — the palette only opens into an
    // already-laid-out composer — so there is nothing to fall back for.
    if (box == null || !box.hasSize) return const SizedBox.shrink();
    final media = MediaQuery.of(ctx);
    final composerTop = box.localToGlobal(Offset.zero).dy;
    final onScreen = composerTop - media.padding.top - kSpace8;
    if (onScreen < kSlashRowHeight) return const SizedBox.shrink();
    final belowTopBar = onScreen - kToolbarHeight;
    final maxHeight = math.min(
      kSlashPaletteMaxHeight,
      math.max(belowTopBar, kSlashRowHeight),
    );
    return Align(
      // The overlay lays its children out tightly to the whole screen; aligning
      // loosens that so the popover below can size to its own content and
      // honour the width/height caps (and so the follower anchors to the
      // popover's own bottom edge, not the screen's).
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _paletteLink,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(0, -kSpace4),
        child: SizedBox(
          width: width,
          child: SlashPalette(
            matches: _slashMatches,
            selectedIndex: _selectedIndex(_slashMatches.length),
            maxHeight: maxHeight,
            onPick: _onSlashPicked,
          ),
        ),
      ),
    );
  }

  /// The box's contents: the optional [Composer.header] on the top edge above a
  /// hairline, then the field (or the inert bar while disabled).
  Widget _buildBox(ColorScheme cs) {
    final body = !widget.enabled
        ? _buildDisabled(cs)
        : (_expanded ? _buildExpanded(cs) : _buildCompact(cs));
    final header = widget.header;
    if (header == null) return body;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 3 + kSpace2 above the hairline and 5 below it: the gap reads as even
        // because the bar's own row has a little ink-free space under its text,
        // while the field below starts immediately.
        Padding(
          padding: const EdgeInsets.fromLTRB(kSpace2, 0, kSpace2, 3),
          child: header,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kSpace2, kSpace2, kSpace2, 5),
          child: Container(
            key: kComposerHeaderRuleKey,
            height: 1,
            color: cs.onSurface.withValues(alpha: 0.07),
          ),
        ),
        body,
      ],
    );
  }

  /// Inert bar shown while [Composer.enabled] is false (awaiting an inline
  /// answer): a muted hint in place of the field + send.
  Widget _buildDisabled(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace12,
      ),
      child: Row(
        children: [
          Icon(PhosphorIconsLight.chatCircleDots, size: 16, color: cs.primary),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Text(
              widget.disabledHint ?? 'Answer the question above to continue…',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
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
              // Natural width, no flex: see [Composer.footerTrailing]. The 6pt
              // gap before it comes from the last action's own right padding,
              // and the gap after is flush like [+] → send.
              ?widget.footerTrailing,
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
    final pick = _staging?.pick;
    return IconButton(
      icon: const Icon(PhosphorIconsLight.paperclip),
      // Two different disabled reasons, and only one is the user's to fix. An
      // attachment-aware session with nowhere to upload is a connectivity gap; a
      // composer with no attachments API at all (the free-text answer composer)
      // will never take an image, so telling that user to connect is a promise
      // makit cannot keep.
      tooltip: pick != null
          ? 'Attach an image'
          : widget.attachments == null
          ? 'Attachments are not available here'
          : 'Connect to your makit server to attach images',
      onPressed: pick,
    );
  }

  /// ⌘V/Ctrl+V: image first, otherwise the field's OWN paste. Never swallow a
  /// text paste.
  Future<void> _handlePaste() async {
    final api = _staging;
    if (api == null) {
      await _pasteText();
      return;
    }
    final image = await api.readClipboardImage();
    // The clipboard read is async: this composer may be gone by now (a desktop
    // worktree switch or pane split disposes it), and touching `_ctrl` or the
    // callbacks after that throws "used after being disposed".
    if (!mounted) return;
    if (image == null) {
      await _pasteText();
      return;
    }
    api.stagePasted(image);
  }

  /// Text paste, done by hand.
  ///
  /// **Known tradeoff, deliberate.** Where ⌘V *is* claimed (only composers that
  /// can attach images — see `_staging`), whether the clipboard holds an
  /// image is knowable only asynchronously, so the field's native paste never
  /// runs and this stands in for it — without undo-stack or platform IME paste
  /// behaviour. Handing the intent back to the framework is not available here:
  /// `EditableText` registers its `PasteTextIntent` handler in an `Actions` map
  /// *below* the `TextField`, so `Actions.invoke` from any context we hold
  /// cannot resolve it (verified — it throws "Unable to find an action for an
  /// Intent with type PasteTextIntent"). Reaching the `EditableTextState` would
  /// mean walking the element tree, which is worse than this.
  Future<void> _pasteText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    // Disposed while reading the clipboard → `_ctrl` may be gone.
    if (!mounted || text == null || text.isEmpty) return;
    final value = _ctrl.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    _ctrl.value = value.copyWith(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
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
    final String slotId;
    if (_canSend) {
      slotId = 'send';
      child = IconButton.filled(
        key: const ValueKey('send'),
        icon: const Icon(PhosphorIconsLight.arrowUp),
        iconSize: iconSize,
        style: compact,
        tooltip: 'Send',
        onPressed: _send,
      );
    } else if (widget.running && widget.onCancel != null) {
      slotId = 'cancel';
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
      slotId = 'send-disabled';
      child = IconButton.filled(
        key: const ValueKey('send-disabled'),
        icon: const Icon(PhosphorIconsLight.arrowUp),
        iconSize: iconSize,
        style: compact,
        tooltip: 'Send',
        onPressed: null,
      );
    }
    // Bumped here rather than in a setState path because the slot is derived
    // from three independent inputs (text, `running`, attachments); the guard
    // keeps it idempotent, so a rebuild that changes nothing changes no key and
    // starts no crossfade.
    if (slotId != _sendSlotId) {
      _sendSlotId = slotId;
      _sendSlotSerial += 1;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      // The child's own key stays `send` / `cancel` / `send-disabled` so callers
      // and tests can still find the button by key; only the switcher's own
      // child identity carries the serial.
      child: KeyedSubtree(
        key: ValueKey('send-slot-$_sendSlotSerial'),
        child: child,
      ),
    );
  }

  Map<ShortcutActivator, Intent> _shortcuts() {
    // ⌘V is claimed ONLY where an image paste is possible. Claiming it
    // everywhere would replace the field's native paste (undo stack, platform IME
    // behaviour) in composers that gain nothing from it — the free-text answer
    // composers, and any session that cannot attach.
    final paste = _staging != null
        ? const {
            SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                _PasteIntent(),
            SingleActivator(LogicalKeyboardKey.keyV, control: true):
                _PasteIntent(),
          }
        : const <ShortcutActivator, Intent>{};
    final sendChord = widget.sendChord;
    if (sendChord == null) {
      // Default (mobile + un-configured): ⌘+Enter and Ctrl+Enter both send.
      return {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            const _SendIntent(),
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            const _SendIntent(),
        ...paste,
      };
    }
    return {
      sendChord.toActivator(): const _SendIntent(),
      if (widget.newlineChord != null)
        widget.newlineChord!.toActivator(): const _NewlineIntent(),
      ...paste,
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
    return Focus(
      // Palette keys only; this node never takes focus itself, it just sits in
      // the field's focus chain so it sees keys first.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onPaletteKey,
      child: Shortcuts(
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
            _PasteIntent: CallbackAction<_PasteIntent>(
              onInvoke: (_) {
                unawaited(_handlePaste());
                return null;
              },
            ),
          },
          child: ScrollConfiguration(
            // Hide the input's scrollbar; the field still scrolls once it grows
            // past its max line count.
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
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
                contentPadding: EdgeInsets.symmetric(
                  horizontal: kSpace8,
                  vertical: kSpace10,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
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

class _PasteIntent extends Intent {
  const _PasteIntent();
}
