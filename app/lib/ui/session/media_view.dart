/// Rendering assistant display media (SPEC-22) — the images and GIFs an agent
/// produced (a screenshot tool, a `read` of a PNG, a file it referenced in
/// prose). This is the thing a terminal-based agent client structurally cannot
/// do, so it renders inline in the transcript rather than as a link.
///
/// Bytes are fetched through [MakitMediaImage] (the pinned HTTP client — see
/// `media_client.dart`) and handed to Flutter's decoder, which means GIFs
/// animate and Flutter's own `ImageCache` dedupes a blob across rebuilds and
/// list recycling without a caching dependency.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../store/chat_items.dart';
import '../../store/media.dart';
import '../../transport/media_client.dart';

/// URI scheme the server rewrites local image paths to (mirrors
/// `MEDIA_URI_SCHEME` in server/src/media/local.ts). Kept here because the
/// markdown image builder is the only consumer.
const String kMediaUriScheme = 'makit-media';

/// Tallest an inline thumbnail may be. A full-page screenshot is often ten
/// times the viewport height; capping keeps the transcript scannable, and a tap
/// opens the real thing.
const double kMediaThumbMaxHeight = 280;

/// An [ImageProvider] backed by a [MediaFetcher].
///
/// Identity is the `mediaId` alone: it is a content hash, so the bytes can
/// never change and a fetcher rebuilt by Riverpod must not invalidate the
/// cached decode.
@immutable
class MakitMediaImage extends ImageProvider<MakitMediaImage> {
  const MakitMediaImage(this.mediaId, this.fetch);

  final String mediaId;
  final MediaFetcher fetch;

  @override
  Future<MakitMediaImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<MakitMediaImage>(this);

  @override
  ImageStreamCompleter loadImage(
    MakitMediaImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      debugLabel: 'makit-media:${key.mediaId}',
    );
  }

  Future<ui.Codec> _load(
    MakitMediaImage key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await key.fetch(key.mediaId);
    if (bytes.isEmpty) throw const MediaFetchException('empty body');
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is MakitMediaImage && other.mediaId == mediaId;

  @override
  int get hashCode => mediaId.hashCode;
}

/// Inline media row: a capped thumbnail that opens fullscreen on tap.
class AgentMediaView extends ConsumerWidget {
  const AgentMediaView({super.key, required this.item});

  final AgentMediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fetch = ref.watch(mediaFetcherProvider);
    // No endpoint (unpaired, or fake-data mode): say so instead of spinning.
    if (fetch == null) {
      return MediaPlaceholder(label: item.alt ?? item.mime);
    }
    return Semantics(
      image: true,
      label: item.alt ?? 'image',
      child: GestureDetector(
        onTap: () => _openFullscreen(context, item, fetch),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadius12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: kMediaThumbMaxHeight),
            child: _MediaImage(item: item, thumbnail: true, fetch: fetch),
          ),
        ),
      ),
    );
  }
}

/// The decoded image, with the loading/failed states both resolved to
/// same-shaped placeholders so a row never jumps or spins forever.
class _MediaImage extends StatelessWidget {
  const _MediaImage({
    required this.item,
    required this.fetch,
    this.thumbnail = false,
  });

  final AgentMediaItem item;
  final MediaFetcher fetch;

  /// Inline (capped) rendering rather than the fullscreen view.
  final bool thumbnail;

  @override
  Widget build(BuildContext context) {
    // Decode thumbnails at the row's pixel width instead of full resolution.
    // A 3024x1964 retina screenshot costs ~24MB of RGBA decoded natively but
    // ~3.6MB at a 1180px-wide target, and the thumbnail can never show more
    // detail than the row is wide. `allowUpscaling: false` keeps a small image
    // at its own resolution rather than inflating the decode.
    //
    // Known residual cost: an extreme aspect ratio (a 1280x26313 full-page
    // capture) is still ~114MB at row width, because bounding its height too
    // would decode a ~13px-wide strip and smear it across the row. Fixing that
    // properly needs the server-side thumbnail SPEC-22 sketches
    // (`thumbMediaId`), which is out of scope here.
    final full = MakitMediaImage(item.mediaId, fetch);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final ImageProvider provider = thumbnail && width.isFinite
            ? ResizeImage(
                full,
                width: (width * MediaQuery.devicePixelRatioOf(context)).round(),
                allowUpscaling: false,
                policy: ResizeImagePolicy.fit,
              )
            : full;
        return _buildImage(provider);
      },
    );
  }

  Widget _buildImage(ImageProvider provider) {
    return Image(
      image: provider,
      // Thumbnails scale to the row's width and let the height overflow into
      // the caller's clip: a full-page screenshot then reads as its top strip
      // instead of the ~14px-wide sliver `contain` would shrink it to. The
      // tradeoff is that a very small image is upscaled to the row width; the
      // event carries no dimensions to distinguish the two, and markdown-inline
      // media carries none at all, so one rule serves both paths.
      fit: thumbnail ? BoxFit.fitWidth : BoxFit.contain,
      alignment: thumbnail ? Alignment.topCenter : Alignment.center,
      width: thumbnail ? double.infinity : null,
      // GIFs animate through the default multi-frame path; nothing to opt into.
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return MediaPlaceholder(label: item.alt ?? item.mime, loading: true);
      },
      errorBuilder: (context, error, stack) =>
          MediaPlaceholder(label: _failureLabel(item, error)),
    );
  }
}

String _failureLabel(AgentMediaItem item, Object error) {
  final name = item.alt ?? item.mime;
  // A GC'd blob is expected for old history; anything else is a real failure.
  return error is MediaNotFoundException ? '$name — no longer stored' : name;
}

/// Stand-in for media that is loading, gone, or unreachable. Quiet by design:
/// an outlined tile with the description, never an image-shaped surprise.
class MediaPlaceholder extends StatelessWidget {
  const MediaPlaceholder({
    super.key,
    required this.label,
    this.loading = false,
  });

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace10,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kRadius12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            loading ? Icons.image_outlined : Icons.broken_image_outlined,
            size: kPillIconSize + 3,
            color: cs.outline,
          ),
          const SizedBox(width: kSpace8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

void _openFullscreen(
  BuildContext context,
  AgentMediaItem item,
  MediaFetcher fetch,
) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (_, _, _) => _FullscreenMedia(item: item, fetch: fetch),
    ),
  );
}

/// Fullscreen view: pinch/pan the real pixels over a dimmed scrim.
class _FullscreenMedia extends StatelessWidget {
  const _FullscreenMedia({required this.item, required this.fetch});

  final AgentMediaItem item;
  final MediaFetcher fetch;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 8,
              child: Center(
                child: _MediaImage(item: item, fetch: fetch),
              ),
            ),
          ),
          Positioned(
            top: kSpace8,
            right: kSpace8,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.close),
                color: Colors.white,
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
