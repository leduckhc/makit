/// SPEC-46 Option D (mockup Card 5) — publish a doc to the tailnet and share
/// one URL. The share sheet shows the capability URL, a QR, the reach pill
/// (`tailnet`/`lan`), the expiry, and Copy link / Open / **Stop sharing**.
///
/// D15 (degrade loudly): if publishing fails, the sheet shows the stated reason
/// — never a dead URL. A publish button that yields an unreachable link is
/// worse than a disabled one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../store/docs.dart';
import '../../store/store.dart';
import '../widgets/sheet_header.dart';
import 'doc_vocabulary.dart';

/// The degrade-loudly error panel (D15), keyed for tests.
const Key kPublishError = ValueKey('publish-error');

/// Opens the publish/share sheet, publishing [relPath] on mount and revoking on
/// Stop sharing.
Future<void> showPublishSheet(
  BuildContext context, {
  required String worktreePath,
  required String relPath,
  required String title,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => SafeArea(
    child: _PublishSheet(
      worktreePath: worktreePath,
      relPath: relPath,
      title: title,
    ),
  ),
);

/// The stateful opener: publishes on mount, then renders [PublishSheetBody]
/// with the grant or the failure reason.
class _PublishSheet extends ConsumerStatefulWidget {
  const _PublishSheet({
    required this.worktreePath,
    required this.relPath,
    required this.title,
  });

  final String worktreePath;
  final String relPath;
  final String title;

  @override
  ConsumerState<_PublishSheet> createState() => _PublishSheetState();
}

class _PublishSheetState extends ConsumerState<_PublishSheet> {
  DocGrant? _grant;
  String? _error;
  Timer? _tick;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _publish();
  }

  Future<void> _publish() async {
    try {
      final grant = await ref
          .read(storeControllerProvider.notifier)
          .publishDoc(widget.worktreePath, widget.relPath);
      if (!mounted) return;
      setState(() {
        _grant = grant;
        _error = null;
        _nowMs = DateTime.now().millisecondsSinceEpoch;
      });
      _startTicking();
    } catch (e) {
      if (!mounted) return;
      // D15: surface the stated reason, never a fabricated URL.
      setState(() {
        _grant = null;
        _error = e is StateError ? e.message : '$e';
      });
    }
  }

  Future<void> _stop() async {
    final grant = _grant;
    final navigator = Navigator.of(context);
    if (grant != null) {
      try {
        await ref
            .read(storeControllerProvider.notifier)
            .unpublishDoc(grant.grantId);
      } catch (_) {
        // Best-effort: the grant expires on its own TTL regardless.
      }
    }
    if (mounted) navigator.maybePop();
  }

  Future<void> _open() async {
    final url = _grant?.url;
    if (url == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = Uri.tryParse(url);
    try {
      if (uri == null) throw const FormatException('bad url');
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Could not open the link')),
        );
      }
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not open the link')),
      );
    }
  }

  /// Re-read the clock every 30s while a grant is live, so the expiry pill counts
  /// down. `nowMs` was otherwise frozen at the build that first showed the grant,
  /// leaving the pill reading "30 min" until the sheet was reopened.
  void _startTicking() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || _grant == null) return;
      setState(() => _nowMs = DateTime.now().millisecondsSinceEpoch);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PublishSheetBody(
    title: widget.title,
    relPath: widget.relPath,
    grant: _grant,
    error: _error,
    nowMs: _nowMs,
    onStop: _stop,
    onOpen: _open,
  );
}

/// The share-sheet body. Pure (data in, no provider read) so it is directly
/// pumpable: a null grant AND null error is the in-flight state (spinner); an
/// error shows the reason (D15); a grant shows the URL, QR and actions.
class PublishSheetBody extends StatelessWidget {
  const PublishSheetBody({
    super.key,
    required this.title,
    required this.relPath,
    required this.grant,
    required this.error,
    required this.nowMs,
    required this.onStop,
    required this.onOpen,
  });

  final String title;
  final String relPath;
  final DocGrant? grant;

  /// The stated failure reason (D15); mutually exclusive with [grant].
  final String? error;
  final int nowMs;
  final VoidCallback onStop;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: title),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSpace16, 0, kSpace16, kSpace8),
            child: Text(
              relPath,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFamily: kMonoFontFamily,
              ),
            ),
          ),
          const Divider(height: 1),
          _content(context),
          const SizedBox(height: kSpace16),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (error != null) return _ErrorPanel(reason: error!);
    final grant = this.grant;
    if (grant == null) {
      return const Padding(
        padding: EdgeInsets.all(kSpace32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return _GrantPanel(
      grant: grant,
      nowMs: nowMs,
      onStop: onStop,
      onOpen: onOpen,
    );
  }
}

class _GrantPanel extends StatelessWidget {
  const _GrantPanel({
    required this.grant,
    required this.nowMs,
    required this.onStop,
    required this.onOpen,
  });

  final DocGrant grant;
  final int nowMs;
  final VoidCallback onStop;
  final VoidCallback onOpen;

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: grant.url));
    messenger?.showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(kSpace16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The pairing QR renderer, reused (mockup Card 5). White quiet
              // zone so a camera reads it in dark mode.
              Container(
                padding: const EdgeInsets.all(kSpace6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(kRadius8),
                ),
                child: QrImageView(
                  data: grant.url,
                  size: 96,
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(width: kSpace12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Link · capability URL',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: kSpace4),
                    SelectableText(
                      grant.url,
                      style: theme.textTheme.bodySmall?.mono,
                    ),
                    const SizedBox(height: kSpace8),
                    Wrap(
                      spacing: kSpace6,
                      runSpacing: kSpace4,
                      children: [
                        _ReachPill(reach: grant.reach),
                        _ExpiryPill(expiresAt: grant.expiresAt, nowMs: nowMs),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: kSpace16),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => _copy(context),
                icon: const Icon(PhosphorIconsLight.copy, size: 16),
                label: const Text('Copy link'),
              ),
              const SizedBox(width: kSpace8),
              OutlinedButton.icon(
                onPressed: onOpen,
                icon: const Icon(PhosphorIconsLight.arrowSquareOut, size: 16),
                label: const Text('Open'),
              ),
              const Spacer(),
              TextButton(
                onPressed: onStop,
                style: TextButton.styleFrom(foregroundColor: cs.error),
                child: const Text('Stop sharing'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// D15 — the honest failure. Shows the server's stated reason; renders no URL,
/// no QR, no Stop-sharing, because nothing is shared.
class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.reason});
  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      key: kPublishError,
      margin: const EdgeInsets.all(kSpace16),
      padding: const EdgeInsets.all(kSpace12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(kRadius12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            PhosphorIconsLight.warning,
            size: 18,
            color: cs.onErrorContainer,
          ),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Could not publish',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: cs.onErrorContainer,
                  ),
                ),
                const SizedBox(height: kSpace2),
                Text(
                  reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The reach pill — `tailnet` (cool) or `lan` (warm), reflecting what actually
/// bound (D15). Never invented.
class _ReachPill extends StatelessWidget {
  const _ReachPill({required this.reach});
  final DocReach reach;

  @override
  Widget build(BuildContext context) {
    final label = switch (reach) {
      DocReach.tailnet => 'tailnet',
      DocReach.lan => 'lan',
    };
    final color = switch (reach) {
      DocReach.tailnet => kDocMdColor,
      DocReach.lan => kStatusWarning,
    };
    return _Pill(
      label: label,
      fill: color.withValues(alpha: 0.15),
      text: color,
    );
  }
}

/// The expiry pill — "expires N min" (D9's 30-minute TTL). Absent when the TTL
/// is already spent rather than a fabricated countdown.
class _ExpiryPill extends StatelessWidget {
  const _ExpiryPill({required this.expiresAt, required this.nowMs});
  final int expiresAt;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mins = (expiresAt - nowMs) ~/ (60 * 1000);
    final label = mins > 0 ? 'expires $mins min' : 'expired';
    return _Pill(
      label: label,
      fill: cs.surfaceContainerHigh,
      text: cs.onSurfaceVariant,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.fill, required this.text});
  final String label;
  final Color fill;
  final Color text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kSpace8, vertical: 2),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(kRadius8),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelXs?.copyWith(color: text, fontWeight: FontWeight.w700),
      ),
    );
  }
}
