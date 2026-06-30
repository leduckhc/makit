import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// One server advertisement found via mDNS.
class DiscoveredServer {
  DiscoveredServer({
    required this.name,
    required this.host,
    required this.port,
    required this.fingerprint,
  });

  final String name;
  final String host;
  final int port;
  final String fingerprint;
}

/// Browse `_pino._tcp.local` for ~3 seconds and return what we find.
///
/// We don't subscribe long-term in M1 — the pairing screen calls this once
/// when entered and again on pull-to-refresh.
Future<List<DiscoveredServer>> browseLan({Duration timeout = const Duration(seconds: 3)}) async {
  final client = MDnsClient(rawDatagramSocketFactory: (dynamic host, int port, {bool reuseAddress = true, bool reusePort = false, int ttl = 1}) {
    return RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: false, ttl: ttl);
  });
  try {
    await client.start();
  } catch (_) {
    return const [];
  }

  final results = <DiscoveredServer>[];
  final deadline = DateTime.now().add(timeout);

  try {
    const type = '_pino._tcp.local';
    await for (final ptr in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(type))) {
      if (DateTime.now().isAfter(deadline)) break;
      String? host;
      int? port;
      String? fingerprint;
      String name = ptr.domainName;

      await for (final srv in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))) {
        port = srv.port;
        // Resolve target hostname to IPv4.
        await for (final ip in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target))) {
          host = ip.address.address;
          break;
        }
        break;
      }

      await for (final txt in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(ptr.domainName))) {
        for (final line in txt.text.split('\n')) {
          final eq = line.indexOf('=');
          if (eq <= 0) continue;
          final key = line.substring(0, eq).toLowerCase();
          final value = line.substring(eq + 1);
          if (key == 'fp') fingerprint = value;
        }
        break;
      }

      if (host != null && port != null && fingerprint != null) {
        results.add(DiscoveredServer(name: name, host: host, port: port, fingerprint: fingerprint));
      }
    }
  } catch (_) {
    // Ignore — return whatever we got.
  } finally {
    client.stop();
  }

  return results;
}
