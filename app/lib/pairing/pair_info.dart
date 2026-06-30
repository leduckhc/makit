/// Parsed pino://pair?... URL.
class PairInfo {
  const PairInfo({
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.token,
  });

  final String host;
  final int port;
  final String fingerprint;
  final String token;

  String get wssUrl => 'wss://$host:$port';

  static PairInfo? tryParse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'pino' || uri.host != 'pair') return null;
    final host = uri.queryParameters['host'];
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final fp = uri.queryParameters['fp'];
    final t = uri.queryParameters['t'];
    if (host == null || port == null || fp == null || t == null) return null;
    return PairInfo(host: host, port: port, fingerprint: fp, token: t);
  }
}
