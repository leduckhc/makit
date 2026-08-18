/// Fetching assistant display media (SPEC-assistant-display-media) from the desktop server.
///
/// Media is *not* carried on the WebSocket: session events are replayed in full
/// on every resume, so the event carries a `mediaId` descriptor and the bytes
/// come from `GET /media/<mediaId>` on the same TLS listener. Two consequences
/// shape this file:
///
/// - The server cert is self-signed and pinned, so the fetch must go through
///   [pinnedHttpClient]. Flutter's `Image.network` uses its own HTTP stack and
///   would reject the cert — that is why makit fetches bytes itself and renders
///   them with `Image.memory`.
/// - Auth is the paired-device bearer in a header, so no capability token ever
///   appears in a URL (which would be persisted in the replayed event log).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pinned_http.dart';
import 'protocol.dart';

/// Where (and with what credentials) media is fetched from.
class MediaEndpoint {
  const MediaEndpoint({required this.base, this.bearer, this.fingerprint});

  /// Origin of the server's HTTPS listener, e.g. `https://100.64.0.1:9787`.
  final String base;

  /// Paired-device bearer. Null in loopback dev mode, where the server trusts
  /// the local socket instead (`trustLoopback`).
  final String? bearer;

  /// DER-sha256 of the server's self-signed cert. Null for a plain-`http`
  /// endpoint (dev/tests); TLS without a fingerprint is never attempted.
  final String? fingerprint;

  Uri urlFor(String mediaId) {
    if (!isMediaId(mediaId)) {
      // The id is spliced into a URL path — refuse anything that isn't a hash
      // rather than escaping it and hoping.
      throw ArgumentError.value(mediaId, 'mediaId', 'not a sha256');
    }
    return Uri.parse('$base/media/$mediaId');
  }
}

/// The blob is gone (GC'd, or from a session whose media was cleaned up). A
/// normal outcome for old history — the UI shows a placeholder, not an error.
class MediaNotFoundException implements Exception {
  const MediaNotFoundException(this.mediaId);
  final String mediaId;
  @override
  String toString() => 'media not found: $mediaId';
}

/// The fetch failed (offline, unauthorized, TLS mismatch, malformed response).
class MediaFetchException implements Exception {
  const MediaFetchException(this.reason);
  final String reason;
  @override
  String toString() => 'media fetch failed: $reason';
}

/// Loads the bytes for a `mediaId`. Injected so widgets can be tested (and the
/// fake-server demo mode driven) without HTTP or TLS.
typedef MediaFetcher = Future<Uint8List> Function(String mediaId);

/// Fetch timeout. Generous enough for a multi-MB screenshot over Tailscale,
/// short enough that a dead server surfaces a placeholder instead of a
/// spinner that never resolves.
const _timeout = Duration(seconds: 20);

/// A [MediaFetcher] that pulls bytes from [endpoint] over the pinned client.
MediaFetcher httpMediaFetcher(MediaEndpoint endpoint) {
  return (String mediaId) async {
    final url = endpoint.urlFor(mediaId);
    final fp = endpoint.fingerprint;
    final client = fp != null && fp.isNotEmpty
        ? pinnedHttpClient(fp)
        : HttpClient();
    try {
      final req = await client.getUrl(url).timeout(_timeout);
      final bearer = endpoint.bearer;
      if (bearer != null && bearer.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      final res = await req.close().timeout(_timeout);
      if (res.statusCode == HttpStatus.notFound) {
        await res.drain<void>();
        throw MediaNotFoundException(mediaId);
      }
      if (res.statusCode != HttpStatus.ok &&
          res.statusCode != HttpStatus.partialContent) {
        await res.drain<void>();
        throw MediaFetchException('HTTP ${res.statusCode}');
      }
      final chunks = await res.toList().timeout(_timeout);
      return Uint8List.fromList(
        chunks.expand((c) => c).toList(growable: false),
      );
    } on MediaNotFoundException {
      rethrow;
    } on MediaFetchException {
      rethrow;
    } on TimeoutException {
      throw const MediaFetchException('timed out');
    } catch (e) {
      // SocketException, HandshakeException (fingerprint mismatch), etc. The
      // caller only needs "couldn't load"; the detail goes in the message.
      throw MediaFetchException('$e');
    } finally {
      client.close(force: true);
    }
  };
}

// ---------------------------------------------------------------------------
// Upload (SPEC-user-attachments) — the input half: the user's screenshot goes UP to the same
// content-addressed store the agent's media comes down from.
// ---------------------------------------------------------------------------

/// A stored blob, as `POST /media` describes it back to us.
class MediaDescriptor {
  const MediaDescriptor({
    required this.mediaId,
    required this.mime,
    required this.sizeBytes,
  });

  final String mediaId;
  final String mime;
  final int sizeBytes;

  static MediaDescriptor? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['mediaId'];
    final mime = json['mime'];
    final size = json['sizeBytes'];
    if (id is! String || !isMediaId(id)) return null;
    if (mime is! String || mime.isEmpty) return null;
    return MediaDescriptor(
      mediaId: id,
      mime: mime,
      sizeBytes: size is int ? size : 0,
    );
  }
}

/// The blob exceeds what the server will store (or what we will send).
class MediaTooLargeException implements Exception {
  const MediaTooLargeException(this.sizeBytes);
  final int sizeBytes;
  @override
  String toString() =>
      'attachment is too large (${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB); '
      'the limit is ${kMaxAttachmentBytes ~/ (1024 * 1024)} MB';
}

/// The type is not one makit stores. Also covers "no bytes to send".
class MediaUnsupportedTypeException implements Exception {
  const MediaUnsupportedTypeException(this.mime);
  final String mime;
  @override
  String toString() => 'attachments of type "$mime" are not supported';
}

/// Mirrors the server's `DEFAULT_MAX_MEDIA_BYTES` (`media/store.ts`). Checked
/// locally so a too-big screenshot fails before it is uploaded, not after.
const int kMaxAttachmentBytes = 24 * 1024 * 1024;

/// Mirrors the server's `MEDIA_MIME_ALLOWLIST`. Deliberately excludes SVG (it
/// can carry script) and every non-image type — see `media/store.ts`.
const Set<String> kAttachmentMimes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/bmp',
};

/// The mime for a picked file's name, or null when it isn't a supported image.
///
/// Extension-based on purpose: the picker gives us a name, and guessing from
/// bytes would let an unsupported type through to a server that will only
/// reject it. Null means "refuse in the UI with a clear message".
String? mimeForFilename(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return switch (name.substring(dot + 1).toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    _ => null,
  };
}

/// Uploads bytes and resolves with the stored blob's descriptor.
typedef MediaUploader =
    Future<MediaDescriptor> Function(Uint8List bytes, String mime);

/// A [MediaUploader] that POSTs to [endpoint] over the pinned client.
///
/// Same trust and auth story as [httpMediaFetcher] — the pinned client plus a
/// bearer header — because it is the same route on the same listener. Size and
/// type are checked here first: the server enforces them too (it must; a client
/// check is not a control), but failing locally saves a pointless multi-MB
/// upload over a phone connection.
MediaUploader httpMediaUploader(MediaEndpoint endpoint) {
  return (Uint8List bytes, String mime) async {
    if (bytes.isEmpty || !kAttachmentMimes.contains(mime)) {
      throw MediaUnsupportedTypeException(mime);
    }
    if (bytes.length > kMaxAttachmentBytes) {
      throw MediaTooLargeException(bytes.length);
    }
    final fp = endpoint.fingerprint;
    final client = fp != null && fp.isNotEmpty
        ? pinnedHttpClient(fp)
        : HttpClient();
    try {
      final req = await client
          .postUrl(Uri.parse('${endpoint.base}/media'))
          .timeout(_timeout);
      req.headers.contentType = ContentType.parse(mime);
      // Explicit length: the server refuses chunked uploads (it has no size to
      // admit them under) — see `media/route.ts`.
      req.contentLength = bytes.length;
      final bearer = endpoint.bearer;
      if (bearer != null && bearer.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      req.add(bytes);
      final res = await req.close().timeout(_uploadTimeout);
      if (res.statusCode == HttpStatus.requestEntityTooLarge) {
        await res.drain<void>();
        throw MediaTooLargeException(bytes.length);
      }
      if (res.statusCode == HttpStatus.unsupportedMediaType) {
        await res.drain<void>();
        throw MediaUnsupportedTypeException(mime);
      }
      if (res.statusCode != HttpStatus.created) {
        await res.drain<void>();
        throw MediaFetchException('HTTP ${res.statusCode}');
      }
      final body = await res.transform(utf8.decoder).join().timeout(_timeout);
      final descriptor = MediaDescriptor.tryParse(jsonDecode(body) as Object?);
      if (descriptor == null) {
        // A 201 we cannot parse is a failure: returning a half-empty descriptor
        // would put an unusable id into a `send.message`.
        throw const MediaFetchException('malformed upload response');
      }
      return descriptor;
    } on MediaTooLargeException {
      rethrow;
    } on MediaUnsupportedTypeException {
      rethrow;
    } on MediaFetchException {
      rethrow;
    } on TimeoutException {
      throw const MediaFetchException('upload timed out');
    } catch (e) {
      throw MediaFetchException('$e');
    } finally {
      client.close(force: true);
    }
  };
}

/// Longer than a fetch: a multi-MB upload over Tailscale on a phone is slower
/// than pulling a thumbnail back down.
const _uploadTimeout = Duration(seconds: 60);
