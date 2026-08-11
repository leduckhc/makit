/// SPEC-46 D12 — the doc preview **widget** (never a route), so it renders
/// identically inside a bottom sheet (P1), a modal from a chat card (P2), and a
/// split pane (P3). Build it as a route and P3 rewrites P1.
///
/// Markdown is rendered with the same `flutter_markdown_plus` approach as
/// `chat_message.dart` (a code-block builder + the repo type scale), NOT a
/// second markdown style. Two additions earn their keep (mockup Card 6): the
/// front-matter strip (`**Status:** … · **Priority:** … · **Branch:** …`
/// becomes real chips) and a reader-width toggle. Internal doc links resolve
/// in-preview; external links go to `url_launcher`. For `kind == html` there is
/// NO in-app render in P1 (D8) — the primary action is *Publish & open*.
library;

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../status/status_providers.dart';
import '../../store/docs.dart';
import '../../store/connection.dart';
import '../../store/store.dart';
import 'doc_vocabulary.dart';
import 'publish_sheet.dart';

/// The front-matter chip strip, keyed for tests.
const Key kDocFrontMatter = ValueKey('doc-front-matter');

/// The reader-width toggle button, keyed for tests.
const Key kDocReaderWidthToggle = ValueKey('doc-reader-width-toggle');

/// The local "Open in browser" action (D8 rev 2), keyed for tests.
const Key kDocOpenLocalButton = ValueKey('doc-open-local');

/// The publish action — primary for a remote client, secondary for a local one.
const Key kDocPublishButton = ValueKey('doc-publish');

/// Comfortable measure for prose when the reader-width toggle is on.
const double _kReaderWidth = 680;

/// Whether a tapped link stays in the preview or leaves the app.
enum DocLinkKind { internal, external }

/// A classified link target from the markdown body.
class DocLinkTarget {
  const DocLinkTarget(this.kind, this.value);
  final DocLinkKind kind;

  /// The original href (a relPath for internal, the URL for external).
  final String value;
}

/// Classify a markdown link href (mockup Card 6: internal doc links resolve
/// in-preview, external links go to `url_launcher`). A link with any URI scheme
/// (`http`, `https`, `mailto`, …) is external; a relative path that ends in
/// `.md`/`.html` is an internal doc link; anything else falls back to external
/// rather than being silently swallowed.
DocLinkTarget resolveDocLink(String href) {
  final uri = Uri.tryParse(href);
  if (uri != null && uri.hasScheme) {
    return DocLinkTarget(DocLinkKind.external, href);
  }
  final path = href.split('#').first.split('?').first.toLowerCase();
  if (path.endsWith('.md') || path.endsWith('.html')) {
    return DocLinkTarget(DocLinkKind.internal, href);
  }
  return DocLinkTarget(DocLinkKind.external, href);
}

/// One parsed front-matter field, e.g. `(label: 'Status', value: 'Draft (P1)')`.
typedef DocFrontMatterField = ({String label, String value});

/// The result of stripping the leading `**Status:** …` line from markdown.
class DocFrontMatter {
  const DocFrontMatter(this.fields);
  final List<DocFrontMatterField> fields;
}

/// Drop blank lines from both ends without touching indentation, so a body that
/// opens with an indented code block keeps it.
String _stripBlankEdges(String s) =>
    s.replaceFirst(RegExp(r'^\n+'), '').replaceFirst(RegExp(r'\n+$'), '');

/// Splits the `**Status:** … · **Priority:** … · **Branch:** …` line off
/// [markdown], returning the parsed fields plus the markdown either side of it:
/// [lead] is what came before (in this repo, the `# H1`) and [body] what came
/// after. Keeping them apart lets the caller render the strip **where the line
/// actually sat** — under the title, as the source file and mockup Card 6 both
/// have it — instead of hoisting it above the heading.
///
/// Absent-when-unstated (D14): no such line yields a null front-matter, an empty
/// [lead], and the body unchanged.
({DocFrontMatter? front, String lead, String body}) parseDocFrontMatter(
  String markdown,
) {
  final lines = markdown.split('\n');
  final idx = lines.indexWhere((l) => l.trimLeft().startsWith('**Status:**'));
  if (idx < 0) return (front: null, lead: '', body: markdown);

  final fields = <DocFrontMatterField>[];
  final fieldRe = RegExp(r'\*\*(.+?):\*\*\s*(.+)');
  for (final segment in lines[idx].split('·')) {
    final m = fieldRe.firstMatch(segment.trim());
    if (m == null) continue;
    fields.add((
      label: m.group(1)!.trim(),
      value: m.group(2)!.trim().replaceAll('`', ''),
    ));
  }
  if (fields.isEmpty) return (front: null, lead: '', body: markdown);

  return (
    front: DocFrontMatter(fields),
    lead: _stripBlankEdges(lines.take(idx).join('\n')),
    body: _stripBlankEdges(lines.skip(idx + 1).join('\n')),
  );
}

/// The preview widget (D12). Pure of provider reads so it is pumpable in any
/// container. Markdown is supplied via [markdown] (loaded by the host surface);
/// null renders a spinner. HTML never renders in-app (D8).
class DocPreview extends StatefulWidget {
  const DocPreview({
    super.key,
    required this.doc,
    this.markdown,
    this.markdownError,
    this.onPublish,
    this.onOpenLocal,
    this.onOpenInternal,
    this.onExternalLink,
  });

  final DocInfo doc;

  /// The markdown text, when loaded. Null → spinner (md) / ignored (html).
  final String? markdown;

  /// The markdown read error, when the load fails.
  final String? markdownError;

  /// Publish & open — the html primary action for a REMOTE client (D9/D15), and
  /// the secondary "Share to a device…" for a local one.
  final VoidCallback? onPublish;

  /// Open on the host (D8 rev 2). Non-null only for a local client, where the
  /// file needs no serving; its presence is what makes the notice local.
  final VoidCallback? onOpenLocal;

  /// Internal doc link tapped — the host re-targets the preview at [relPath].
  final void Function(String relPath)? onOpenInternal;

  /// External link tapped; defaults to `url_launcher` when null.
  final void Function(Uri uri)? onExternalLink;

  @override
  State<DocPreview> createState() => _DocPreviewState();
}

class _DocPreviewState extends State<DocPreview> {
  bool _readerWidth = false;

  Future<void> _openExternal(Uri uri) async {
    if (widget.onExternalLink != null) {
      widget.onExternalLink!(uri);
      return;
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _onTapLink(String text, String? href, String title) {
    if (href == null || href.isEmpty) return;
    final target = resolveDocLink(href);
    switch (target.kind) {
      case DocLinkKind.internal:
        widget.onOpenInternal?.call(target.value);
      case DocLinkKind.external:
        final uri = Uri.tryParse(href);
        if (uri != null) _openExternal(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          doc: widget.doc,
          readerWidth: _readerWidth,
          onToggleReaderWidth: widget.doc.kind == DocKind.md
              ? () => setState(() => _readerWidth = !_readerWidth)
              : null,
        ),
        const Divider(height: 1),
        Flexible(child: _content(context)),
      ],
    );
  }

  Widget _content(BuildContext context) {
    if (widget.doc.kind == DocKind.html) {
      // The one place locality is decided (D8 rev 2). Publishing works
      // everywhere, so it is always in the list — primary for a client that
      // cannot open the file itself, demoted for one that can.
      final openLocal = widget.onOpenLocal;
      final publish = _DocAction(
        key: kDocPublishButton,
        label: openLocal == null ? 'Publish & open' : 'Share to a device\u2026',
        icon: PhosphorIconsLight.shareNetwork,
        onPressed: widget.onPublish,
      );
      return _HtmlNotice(
        blurb: openLocal == null
            ? 'Publish it to your tailnet and open it with full fidelity \u2014 '
                  'real Safari, real JS, print-to-PDF.'
            : 'This file is on this machine \u2014 opening it needs no server.',
        actions: [
          if (openLocal != null)
            _DocAction(
              key: kDocOpenLocalButton,
              label: 'Open in browser',
              icon: PhosphorIconsLight.browser,
              onPressed: openLocal,
            ),
          publish,
        ],
      );
    }
    if (widget.markdownError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(kSpace32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                PhosphorIcons.warning,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: kSpace16),
              Text(
                'Could not read',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: kSpace8),
              Text(
                widget.markdownError!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final markdown = widget.markdown;
    if (markdown == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(kSpace32),
          child: CircularProgressIndicator(),
        ),
      );
    }
    final parsed = parseDocFrontMatter(markdown);
    final styleSheet = _docStyleSheet(context);
    final builders = {'code': _DocCodeBuilder(context)};
    final body = SingleChildScrollView(
      padding: const EdgeInsets.all(kSpace16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The title leads, then the strip, then the rest — the order the file
          // itself is written in.
          if (parsed.lead.isNotEmpty)
            MarkdownBody(
              data: parsed.lead,
              selectable: true,
              styleSheet: styleSheet,
              onTapLink: _onTapLink,
              builders: builders,
            ),
          if (parsed.front != null) _FrontMatterChips(front: parsed.front!),
          MarkdownBody(
            data: parsed.body,
            selectable: true,
            styleSheet: styleSheet,
            onTapLink: _onTapLink,
            builders: builders,
          ),
        ],
      ),
    );
    if (!_readerWidth) return body;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kReaderWidth),
        child: body,
      ),
    );
  }
}

/// The preview toolbar: the title + relPath, and (markdown only) the
/// reader-width toggle.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.doc,
    required this.readerWidth,
    required this.onToggleReaderWidth,
  });

  final DocInfo doc;
  final bool readerWidth;
  final VoidCallback? onToggleReaderWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpace16, kSpace10, kSpace8, kSpace10),
      child: Row(
        children: [
          Icon(
            doc.kind == DocKind.html
                ? PhosphorIconsLight.code
                : PhosphorIconsLight.fileText,
            size: 18,
            color: docKindColor(doc.kind),
          ),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  doc.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  doc.relPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontFamily: kMonoFontFamily,
                  ),
                ),
              ],
            ),
          ),
          if (onToggleReaderWidth != null)
            IconButton(
              key: kDocReaderWidthToggle,
              tooltip: 'Reader width',
              isSelected: readerWidth,
              onPressed: onToggleReaderWidth,
              icon: const Icon(PhosphorIconsLight.textAlignLeft, size: 18),
            ),
        ],
      ),
    );
  }
}

/// The front-matter chips (D14 / mockup Card 6): each parsed `Label: value`
/// pair as a compact pill, with the docStatus tint on the Status value.
class _FrontMatterChips extends StatelessWidget {
  const _FrontMatterChips({required this.front});
  final DocFrontMatter front;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      key: kDocFrontMatter,
      padding: const EdgeInsets.only(bottom: kSpace12),
      child: Wrap(
        spacing: kSpace6,
        runSpacing: kSpace6,
        children: [
          for (final f in front.fields)
            _FrontMatterChip(
              field: f,
              tone: f.label.toLowerCase() == 'status'
                  ? docStatusTone(cs, f.value)
                  : (fill: cs.surfaceContainerHigh, text: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _FrontMatterChip extends StatelessWidget {
  const _FrontMatterChip({required this.field, required this.tone});
  final DocFrontMatterField field;
  final ({Color fill, Color text}) tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.fill,
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      // Two Text widgets (not RichText) so the value is findable and readable
      // by a screen reader as its own run.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${field.label}: ',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            field.value,
            style: theme.textTheme.labelSmall?.copyWith(
              color: tone.text,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// D8: HTML is not rendered in-app in P1. The primary action is *Publish &
/// open*, which mints a tailnet grant and opens it in a real browser.
/// D8 rev 2: HTML is not rendered in-app in P1 — but *where the viewer is*
/// decides how it opens. On the machine holding the file, hand it to the OS; on
/// another device, mint a tailnet grant and open that.
/// One way to get an HTML document in front of the user.
class _DocAction {
  const _DocAction({
    required this.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final Key key;
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
}

/// D8 rev 2: HTML is not rendered in-app in P1 — *where the viewer is* decides
/// how it opens. Rather than branch on locality in the widget tree, the caller's
/// two situations are modelled as an ordered action list: the first is primary,
/// the rest are secondary. The notice then renders a list and has no conditional
/// of its own, which is what stops "is this local?" from being re-asked at every
/// line of the layout.
class _HtmlNotice extends StatelessWidget {
  const _HtmlNotice({required this.blurb, required this.actions});

  /// Why this document opens the way it does.
  final String blurb;

  /// Primary first. Never empty.
  final List<_DocAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final [primary, ...secondary] = actions;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kSpace32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsLight.browser, size: 44, color: cs.outline),
            const SizedBox(height: kSpace12),
            Text(
              'HTML renders in a real browser, not in-app.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: kSpace4),
            Text(
              blurb,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: kSpace16),
            FilledButton.icon(
              key: primary.key,
              onPressed: primary.onPressed,
              icon: Icon(primary.icon, size: 16),
              label: Text(primary.label),
            ),
            for (final a in secondary) ...[
              const SizedBox(height: kSpace8),
              TextButton.icon(
                key: a.key,
                onPressed: a.onPressed,
                icon: Icon(a.icon, size: 16),
                label: Text(a.label),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens the preview as a bottom sheet (P1 container, D12). Loads markdown text
/// via `docs.read` on demand; HTML shows the publish notice with no read.
Future<void> showDocPreviewSheet(BuildContext context, DocInfo doc) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: SafeArea(child: _DocPreviewSheet(doc: doc)),
      ),
    );

/// The sheet body: loads the markdown (for md) and re-targets on internal link
/// taps, keeping one preview surface (mockup rule 2).
class _DocPreviewSheet extends ConsumerStatefulWidget {
  const _DocPreviewSheet({required this.doc});
  final DocInfo doc;

  @override
  ConsumerState<_DocPreviewSheet> createState() => _DocPreviewSheetState();
}

class _DocPreviewSheetState extends ConsumerState<_DocPreviewSheet> {
  late DocInfo _doc = widget.doc;
  Future<String>? _markdownFuture;

  @override
  void initState() {
    super.initState();
    _loadIfMarkdown();
  }

  void _loadIfMarkdown() {
    if (_doc.kind != DocKind.md) {
      _markdownFuture = null;
      return;
    }
    _markdownFuture = ref
        .read(storeControllerProvider.notifier)
        .readDoc(_doc.worktreePath, _doc.relPath);
  }

  void _openInternal(String relPath) {
    // Resolve within the same worktree, re-selecting by (worktreePath, relPath)
    // — the snapshot may not hold the target, so build a lightweight DocInfo.
    final snapshot = ref.read(docsProvider);
    final match = snapshot?.docs.firstWhere(
      (d) =>
          d.worktreePath == _doc.worktreePath &&
          d.relPath == _normalise(relPath),
      orElse: () => _stubFor(relPath),
    );
    setState(() {
      _doc = match ?? _stubFor(relPath);
      _loadIfMarkdown();
    });
  }

  String _normalise(String relPath) {
    // Resolve `../` against the current doc's directory so a sibling link finds
    // its snapshot entry.
    final baseDir = _doc.relPath.contains('/')
        ? _doc.relPath.substring(0, _doc.relPath.lastIndexOf('/'))
        : '';
    final joined = baseDir.isEmpty ? relPath : '$baseDir/$relPath';
    final parts = <String>[];
    for (final seg in joined.split('/')) {
      if (seg == '.' || seg.isEmpty) continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return parts.join('/');
  }

  DocInfo _stubFor(String relPath) {
    final rp = _normalise(relPath);
    return DocInfo(
      key: '${_doc.worktreePath}:$rp',
      relPath: rp,
      title: rp.split('/').last,
      kind: rp.toLowerCase().endsWith('.html') ? DocKind.html : DocKind.md,
      bytes: 0,
      modifiedAt: 0,
      worktreePath: _doc.worktreePath,
    );
  }

  Future<void> _publish() => showPublishSheet(
    context,
    worktreePath: _doc.worktreePath,
    relPath: _doc.relPath,
    title: _doc.title,
  );

  /// D8 rev 2: hand the file to the host's opener. Failure is stated — the
  /// server's reason surfaces in the Activity record rather than a silent no-op.
  Future<void> _openLocal() async {
    try {
      await ref
          .read(storeControllerProvider.notifier)
          .openDoc(_doc.worktreePath, _doc.relPath);
    } catch (e) {
      if (!mounted) return;
      ref
          .read(statusCenterProvider)
          .failure('Could not open: $e', source: 'docs.open');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only a local client gets the direct path; everyone else publishes.
    final isLocal = ref.watch(connectionControllerProvider).serverIsLocal;
    if (_doc.kind == DocKind.html) {
      return DocPreview(
        doc: _doc,
        onPublish: _publish,
        onOpenLocal: isLocal ? _openLocal : null,
        onOpenInternal: _openInternal,
      );
    }
    return FutureBuilder<String>(
      future: _markdownFuture,
      builder: (context, snap) {
        String? markdown;
        String? error;
        if (snap.hasData) {
          markdown = snap.data;
        } else if (snap.hasError) {
          error = snap.error.toString();
        }
        return DocPreview(
          doc: _doc,
          markdown: markdown,
          markdownError: error,
          onPublish: _publish,
          onOpenLocal: isLocal ? _openLocal : null,
          onOpenInternal: _openInternal,
        );
      },
    );
  }
}

// ── Markdown rendering, following chat_message.dart's approach ──────────────

MarkdownStyleSheet _docStyleSheet(BuildContext context) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final mono = theme.textTheme.bodyMedium?.mono;
  // Unlike the transcript, a spec's headings ARE meaningful structure, so keep
  // a modest heading scale rather than flattening every level to bold body.
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyMedium,
    code: mono,
    h1: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    h2: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    h3: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
    blockquoteDecoration: BoxDecoration(
      color: cs.surfaceContainerHigh,
      border: Border(left: BorderSide(color: cs.primary, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    a: TextStyle(color: cs.primary, decoration: TextDecoration.underline),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: cs.outlineVariant)),
    ),
  );
}

/// Fenced code blocks with syntax highlighting — the same builder shape as
/// `chat_message.dart`'s `_CodeBlockBuilder` (reused approach, not a second
/// style).
class _DocCodeBuilder extends MarkdownElementBuilder {
  _DocCodeBuilder(this.context);
  final BuildContext context;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final className = element.attributes['class'];
    var language = '';
    if (className != null && className.startsWith('language-')) {
      language = className.substring('language-'.length);
    }
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    final isBlock = className != null || code.contains('\n');
    if (!isBlock) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      final bg = dark ? const Color(0xFF33363E) : const Color(0xFFEBECF0);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: kSpace4, vertical: 1),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          code,
          style: preferredStyle?.mono.copyWith(
            backgroundColor: Colors.transparent,
          ),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: kSpace6),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF282C34) : const Color(0xFFF0F1F4),
        borderRadius: BorderRadius.circular(kRadius8),
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: HighlightView(
          code,
          language: language.isEmpty ? 'plaintext' : language,
          theme: dark ? atomOneDarkTheme : githubTheme,
          padding: const EdgeInsets.all(12),
          textStyle:
              (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
                  .mono,
        ),
      ),
    );
  }
}
