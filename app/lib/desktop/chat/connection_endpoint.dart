/// Formats the server connection endpoint for display in the desktop UI.
///
/// The desktop chat client connects over loopback, so a bound host of
/// `127.0.0.1` (or an empty/absent host) is shown as `localhost`. Returns
/// `null` when there is no port to show (not yet connected).
library;

String? formatEndpoint(String? host, int? port) {
  if (port == null) return null;
  final h =
      (host == null || host.isEmpty || host == '127.0.0.1' || host == '::1')
      ? 'localhost'
      : host;
  return '$h:$port';
}
