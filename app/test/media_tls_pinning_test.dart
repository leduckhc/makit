import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/transport/media_client.dart';
import 'package:makit/transport/pinned_http.dart';

/// TLS pinning is the security boundary for BOTH transports: makit's server
/// presents a self-signed cert, so `withTrustedRoots: false` + a DER-sha256
/// fingerprint match is the entire identity check (see pinned_http.dart).
///
/// This exercises it against a real `HttpServer.bindSecure` over a throwaway
/// self-signed cert in `test/fixtures/tls/` (generated with openssl, valid for
/// 100 years, private key intentionally public — it guards nothing). It covers
/// the case a WS-only test cannot: a plain HTTPS GET, which is how media loads
/// on both the phone and the macOS desktop app.
void main() {
  late HttpServer server;
  late String fingerprint;

  setUp(() async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/tls/cert.pem')
      ..usePrivateKey('test/fixtures/tls/key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((req) async {
      if (req.headers.value(HttpHeaders.authorizationHeader) != 'Bearer tok') {
        req.response.statusCode = 401;
      } else {
        req.response.headers.contentType = ContentType('image', 'png');
        req.response.write('pinned-ok');
      }
      await req.response.close();
    });
    // The fingerprint the app would have captured at pairing time.
    final der = File('test/fixtures/tls/cert.pem').readAsStringSync();
    final b64 = der
        .split('\n')
        .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
        .join();
    fingerprint = hexSha256(base64Decode(b64));
  });

  tearDown(() => server.close(force: true));

  MediaEndpoint endpoint({String? fp, String? bearer = 'tok'}) => MediaEndpoint(
    base: 'https://127.0.0.1:${server.port}',
    bearer: bearer,
    fingerprint: fp ?? fingerprint,
  );

  test(
    'the pinned client accepts a self-signed cert whose fingerprint matches',
    () async {
      final bytes = await httpMediaFetcher(endpoint())('a' * 64);
      expect(utf8.decode(bytes), 'pinned-ok');
    },
  );

  test(
    'it rejects a mismatching fingerprint instead of trusting the cert',
    () async {
      // The failure mode this guards: dropping `badCertificateCallback` (or
      // returning true from it) would make every cert acceptable.
      await expectLater(
        httpMediaFetcher(endpoint(fp: 'f' * 64))('a' * 64),
        throwsA(isA<MediaFetchException>()),
      );
    },
  );

  test(
    'it still enforces the bearer over a correctly pinned connection',
    () async {
      // Pinning authenticates the *server*; the bearer authenticates the device.
      await expectLater(
        httpMediaFetcher(endpoint(bearer: null))('a' * 64),
        throwsA(isA<MediaFetchException>()),
      );
    },
  );

  test('an unpinned client rejects the same cert (no OS trust for it)', () async {
    // Sanity check on the fixture: the cert really is untrusted, so the passing
    // test above proves pinning did the work rather than OS trust.
    final endpointNoFp = MediaEndpoint(
      base: 'https://127.0.0.1:${server.port}',
      bearer: 'tok',
    );
    await expectLater(
      httpMediaFetcher(endpointNoFp)('a' * 64),
      throwsA(isA<MediaFetchException>()),
    );
  });
}
