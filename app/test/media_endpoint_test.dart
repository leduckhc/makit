import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/media.dart';

/// The desktop (macOS) app self-pairs with its own daemon over loopback
/// (`LoopbackPairing` in desktop_app.dart), so it holds a real [PairedServer]
/// exactly like the phone — just with host `127.0.0.1`. These tests pin that
/// the media endpoint is derived from it, since a null endpoint would silently
/// degrade every image to a placeholder on desktop only.
PairedServer _server({String host = '127.0.0.1'}) => PairedServer(
  host: host,
  port: 9787,
  fingerprint: 'ab12cd34',
  bearer: 'device-bearer',
  label: 'Mac',
);

ProviderContainer _container(MakitConnState state) {
  final container = ProviderContainer(
    overrides: [connectionProvider.overrideWithValue(state)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'a loopback self-paired desktop gets a pinned, bearer-authed endpoint',
    () {
      final c = _container(MakitConnState(server: _server()));
      final endpoint = c.read(mediaEndpointProvider)!;

      expect(endpoint.base, 'https://127.0.0.1:9787');
      expect(endpoint.bearer, 'device-bearer');
      expect(endpoint.fingerprint, 'ab12cd34');
      // Same origin as the WS, which is where the /media route is attached.
      expect(
        endpoint.urlFor('a' * 64).toString(),
        'https://127.0.0.1:9787/media/${'a' * 64}',
      );
      expect(c.read(mediaFetcherProvider), isNotNull);
    },
  );

  test('a phone paired over Tailscale/LAN derives the same shape', () {
    final c = _container(MakitConnState(server: _server(host: '100.64.0.7')));
    expect(c.read(mediaEndpointProvider)!.base, 'https://100.64.0.7:9787');
  });

  test('no paired server → no fetcher, so media degrades to a placeholder', () {
    final c = _container(MakitConnState());
    expect(c.read(mediaEndpointProvider), isNull);
    expect(c.read(mediaFetcherProvider), isNull);
  });

  group('dev MAKIT_WS_URL override (no pairing)', () {
    // The media origin must keep the socket's transport security instead of
    // assuming TLS, so a plaintext override fails the same way for both.
    test('wss:// derives an https origin, ws:// derives http', () {
      expect(
        mediaEndpointFor(
          server: null,
          devWsUrl: 'wss://127.0.0.1:7777',
          devFingerprint: 'ab12',
        )!.base,
        'https://127.0.0.1:7777',
      );
      expect(
        mediaEndpointFor(server: null, devWsUrl: 'ws://127.0.0.1:7777')!.base,
        'http://127.0.0.1:7777',
      );
    });

    test('carries the pinned fingerprint and never a bearer', () {
      final e = mediaEndpointFor(
        server: null,
        devWsUrl: 'wss://127.0.0.1:7777',
        devFingerprint: 'ab12',
      )!;
      expect(e.fingerprint, 'ab12');
      // --no-auth dev mode: the server trusts the loopback socket instead.
      expect(e.bearer, isNull);
    });

    test(
      'an unsupported, portless or unparseable override yields no endpoint',
      () {
        for (final url in [
          'file:///tmp/x',
          'wss://127.0.0.1',
          'not a url',
          '::::',
        ]) {
          expect(
            mediaEndpointFor(server: null, devWsUrl: url),
            isNull,
            reason: url,
          );
        }
      },
    );

    test('a paired server wins over the dev override', () {
      expect(
        mediaEndpointFor(
          server: _server(),
          devWsUrl: 'ws://10.0.0.1:1234',
        )!.base,
        'https://127.0.0.1:9787',
      );
    });
  });
}
