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
  final server = ref.watch(connectionProvider).server;
  if (server != null) {
    return MediaEndpoint(
      // Same host:port as the WS — the blob route lives on that listener.
      base: 'https://${server.host}:${server.port}',
      bearer: server.bearer,
      fingerprint: server.fingerprint,
    );
  }
  if (_wsUrl.isNotEmpty) {
    final ws = Uri.parse(_wsUrl);
    // No bearer in this mode: the server trusts the loopback socket
    // (`trustLoopback` in server/src/media/route.ts).
    return MediaEndpoint(
      base: 'https://${ws.host}:${ws.port}',
      fingerprint: _wsFp.isEmpty ? null : _wsFp,
    );
  }
  return null;
});

/// Loads media bytes, or null when there is no endpoint to load them from.
final mediaFetcherProvider = Provider<MediaFetcher?>((ref) {
  final endpoint = ref.watch(mediaEndpointProvider);
  return endpoint == null ? null : httpMediaFetcher(endpoint);
});
