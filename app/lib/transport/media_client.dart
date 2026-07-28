/// Fetching assistant display media (SPEC-22) from the desktop server.
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
import 'dart:io';
import 'dart:typed_data';

import 'pinned_http.dart';


/// A sha256, lowercase hex — the only id shape the route accepts.
final RegExp _mediaIdPattern = RegExp(r'^[a-f0-9]{64}$');

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
    if (!_mediaIdPattern.hasMatch(mediaId)) {
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
      if (res.statusCode != HttpStatus.ok && res.statusCode != HttpStatus.partialContent) {
        await res.drain<void>();
        throw MediaFetchException('HTTP ${res.statusCode}');
      }
      final chunks = await res.toList().timeout(_timeout);
      return Uint8List.fromList(chunks.expand((c) => c).toList(growable: false));
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
