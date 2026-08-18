/// Attachment chips (SPEC-user-attachments) — the strip above the composer field showing what
/// will be sent with the next message.
///
/// One chip per staged image: thumbnail, name, and a state that is legible at a
/// glance — spinner while uploading, error text with tap-to-retry when it
/// failed, plain when it is stored and ready. The `✕` removes it.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/composer_attachments.dart';
import '../widgets/pulse_spinner.dart';

/// Horizontal, wrapping row of [AttachmentChip]s.
class AttachmentChips extends StatelessWidget {
  const AttachmentChips({
    super.key,
    required this.attachments,
    required this.onRemove,
    required this.onRetry,
  });

  final List<ComposerAttachment> attachments;
  final ValueChanged<String> onRemove;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(
        left: kSpace8,
        right: kSpace8,
        bottom: kSpace4,
      ),
      child: Wrap(
        spacing: kSpace4,
        runSpacing: kSpace4,
        children: [
          for (final a in attachments)
            AttachmentChip(
              // Keyed by the stable localId: without it, element reuse can pair
              // a chip's element with a different attachment as the list grows
              // or shrinks, flashing one chip's spinner/thumbnail on another.
              key: ValueKey(a.localId),
              attachment: a,
              onRemove: () => onRemove(a.localId),
              onRetry: () => onRetry(a.localId),
            ),
        ],
      ),
    );
  }
}

/// One staged attachment.
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({
    super.key,
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
  });

  final ComposerAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final failed = attachment.status == AttachmentStatus.failed;
    final uploading = attachment.status == AttachmentStatus.uploading;
    return Semantics(
      label: failed
          ? '${attachment.name}: ${attachment.error ?? 'failed'}'
          : attachment.name,
      button: failed,
      // Exposed to assistive tech, which cannot reach an InkWell's gesture.
      onTap: failed ? onRetry : null,
      child: InkWell(
        // InkWell, not GestureDetector: it is focusable, so a keyboard-only
        // desktop user can reach retry with Tab and fire it with Enter/Space.
        // Only a failed chip is activatable — activating one mid-upload should do
        // nothing rather than queue a second upload of the same bytes.
        onTap: failed ? onRetry : null,
        borderRadius: BorderRadius.circular(kRadius8),
        child: Container(
          padding: const EdgeInsets.only(right: kSpace4),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(kRadius8),
            border: failed ? Border.all(color: cs.error) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _thumb(
                cs,
                uploading: uploading,
                failed: failed,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              ),
              const SizedBox(width: kSpace4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Text(
                      failed
                          ? (attachment.error ?? 'failed')
                          : _sizeLabel(attachment.bytes.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: failed ? cs.error : cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(PhosphorIconsLight.x),
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
                tooltip: 'Remove attachment',
                onPressed: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The image itself, with the upload state drawn over it. Local bytes, so the
  /// thumbnail is there instantly and does not depend on the upload landing.
  Widget _thumb(
    ColorScheme cs, {
    required bool uploading,
    required bool failed,
    required double devicePixelRatio,
  }) {
    // Decode at the size actually drawn. Without this, `Image.memory` decodes at
    // full resolution and parks that bitmap in the image cache — a 24 MB photo
    // (the attachment cap) is hundreds of MB of RGBA for a 36px square.
    final decodeEdge = (_thumbEdge * devicePixelRatio).round();
    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(
        left: Radius.circular(kRadius8),
      ),
      child: SizedBox.square(
        dimension: _thumbEdge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              attachment.bytes,
              fit: BoxFit.cover,
              cacheWidth: decodeEdge,
              cacheHeight: decodeEdge,
              // A picker can hand us bytes the decoder rejects; a grey tile is
              // a better answer than a red error widget inside the composer.
              errorBuilder: (_, _, _) =>
                  ColoredBox(color: cs.surfaceContainerHigh),
            ),
            if (uploading)
              ColoredBox(
                color: cs.scrim.withValues(alpha: 0.45),
                // Labelled: the chip's Semantics is the file name, so without
                // this the upload is a purely visual state.
                child: const Center(
                  child: PulseSpinner(size: 16, semanticsLabel: 'uploading'),
                ),
              ),
            if (failed)
              ColoredBox(
                color: cs.scrim.withValues(alpha: 0.45),
                child: Center(
                  child: Icon(
                    PhosphorIconsLight.arrowClockwise,
                    size: 16,
                    color: cs.onError,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Edge of the chip's square thumbnail, in logical pixels.
const double _thumbEdge = 36;

String _sizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
