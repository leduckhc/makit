/// TLS pinning for makit's self-signed server cert.
///
/// The desktop server serves both the WebSocket and the `/media` blob route
/// from one self-signed certificate, so every client-side HTTP stack that talks
/// to it needs the same trust decision: accept exactly the cert whose DER
/// sha256 matches the fingerprint captured at pairing time, and nothing else.
/// Lives in one place so the check can't drift between transports.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

/// An [HttpClient] that trusts **only** the cert matching [fingerprint].
///
/// `withTrustedRoots: false` removes the OS trust store, so a valid CA-signed
/// cert for the same host is rejected too — the fingerprint is the whole
/// identity check.
HttpClient pinnedHttpClient(String fingerprint) {
  final expected = fingerprint.toLowerCase();
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
  client.badCertificateCallback =
      (X509Certificate cert, String host, int port) {
        return hexSha256(cert.der) == expected;
      };
  return client;
}

/// Lowercase hex sha256 of [bytes] — the form fingerprints are exchanged in.
String hexSha256(Uint8List bytes) => sha256
    .convert(bytes)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
