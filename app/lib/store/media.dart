/// Providers for assistant display media (SPEC-22).
///
/// The endpoint is derived from the paired server (or the loopback dev
/// override), so no widget needs to know how makit is connected — a media row
/// just asks for a [MediaFetcher] and renders a placeholder when there is none
/// (unpaired, or the fake-data demo mode).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/media_client.dart';
import 'connection.dart';

/// Dev override, mirroring `connection.dart`: `--dart-define=MAKIT_WS_URL=…`
/// connects without pairing, so there is no [PairedServer] to derive from.
const _wsUrl = String.fromEnvironment('MAKIT_WS_URL');
const _wsFp = String.fromEnvironment('MAKIT_FP');

/// Where media is fetched from, or null when nothing is paired/attached.
final mediaEndpointProvider = Provider<MediaEndpoint?>((ref) {
  return mediaEndpointFor(
    server: ref.watch(connectionProvider).server,
    devWsUrl: _wsUrl,
    devFingerprint: _wsFp,
  );
});

/// Pure derivation of the media endpoint, so both inputs are testable (the
/// dart-defines above are compile-time constants a test cannot set).
///
/// A paired server wins; otherwise the dev override is used. The media origin
/// keeps the WS override's transport security — `wss:` → `https:`, `ws:` →
/// `http:` — rather than assuming TLS: makit's server only ever serves `wss`
/// today, so an `ws:` override is already unusable for the socket, and silently
/// pointing media at `https` would hide that instead of failing the same way.
MediaEndpoint? mediaEndpointFor({
  required PairedServer? server,
  String devWsUrl = '',
  String devFingerprint = '',
}) {
  if (server != null) {
    return MediaEndpoint(
      // Same host:port as the WS — the blob route lives on that listener.
      base: 'https://${server.host}:${server.port}',
      bearer: server.bearer,
      fingerprint: server.fingerprint,
    );
  }
  if (devWsUrl.isEmpty) return null;
  final ws = Uri.tryParse(devWsUrl);
  final scheme = switch (ws?.scheme) {
    'wss' || 'https' => 'https',
    'ws' || 'http' => 'http',
    _ =>
      null, // unsupported/unparseable override → no media rather than a guess
  };
  if (ws == null || scheme == null || !ws.hasPort) return null;
  // No bearer in this mode: the server trusts the loopback socket
  // (`trustLoopback` in server/src/media/route.ts).
  return MediaEndpoint(
    base: '$scheme://${ws.host}:${ws.port}',
    fingerprint: devFingerprint.isEmpty ? null : devFingerprint,
  );
}

/// Loads media bytes, or null when there is no endpoint to load them from.
final mediaFetcherProvider = Provider<MediaFetcher?>((ref) {
  final endpoint = ref.watch(mediaEndpointProvider);
  return endpoint == null ? null : httpMediaFetcher(endpoint);
});

/// Uploads attachment bytes, or null when there is no endpoint to upload to
/// (unpaired, or fake-data mode) — the composer disables attaching in that case
/// rather than staging an upload that can never run.
final mediaUploaderProvider = Provider<MediaUploader?>((ref) {
  final endpoint = ref.watch(mediaEndpointProvider);
  return endpoint == null ? null : httpMediaUploader(endpoint);
});
