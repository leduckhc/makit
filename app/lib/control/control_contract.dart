/// Control-socket contract consumed by the SPEC-03 desktop screens.
///
/// The desktop UI talks to the pino daemon through the abstract
/// [ControlClient] defined here. Stream A supplies a concrete implementation
/// backed by the SPEC-01 control socket; tests and widget previews use the
/// in-memory `FakeControlClient`. The screens never import the transport
/// directly — they depend only on this contract, keeping the UI layer
/// decoupled from the wire protocol.
library;

/// Abstract control-plane client used by the desktop screens.
///
/// Every method maps to a single control-socket verb. Implementations must
/// surface transport failures as thrown exceptions (for the request/response
/// methods) or as stream errors (for [tailLogs]).
abstract class ControlClient {
  /// Fetches a one-shot snapshot of daemon status.
  Future<StatusData> status();

  /// Mints a fresh pairing token, optionally overriding its lifetime in
  /// milliseconds via [ttlMs].
  Future<PairMintData> pairMint({int? ttlMs});

  /// Returns the currently-active pairing token, or `null` when none is live.
  Future<PairCurrentData?> pairCurrent();

  /// Lists every device currently paired with the daemon.
  Future<List<DeviceInfo>> devicesList();

  /// Revokes the device with [id]. Resolves to `true` when a device was
  /// actually removed.
  Future<bool> devicesRevoke(String id);

  /// Lists sessions known to the daemon.
  Future<List<SessionDto>> sessionsList();

  /// Requests a graceful daemon shutdown.
  Future<void> serverStop();

  /// Tails the daemon log.
  ///
  /// [lines] bounds the initial backfill; [follow] keeps the stream open for
  /// live lines; [sessionId] scopes the tail to a single session when set.
  Stream<LogLine> tailLogs({
    int? lines,
    bool follow = false,
    String? sessionId,
  });
}

/// Immutable snapshot of daemon status.
class StatusData {
  /// Creates a status snapshot.
  const StatusData({
    required this.pid,
    required this.uptimeMs,
    required this.host,
    required this.port,
    required this.fingerprint,
    required this.advertiseHost,
    required this.pairedDevices,
    required this.runningSessions,
    required this.version,
  });

  /// OS process id of the running daemon.
  final int pid;

  /// Milliseconds elapsed since the daemon started.
  final int uptimeMs;

  /// Host the daemon binds to.
  final String host;

  /// TCP port the daemon listens on.
  final int port;

  /// SHA-256 fingerprint of the daemon's pinned TLS certificate.
  final String fingerprint;

  /// Host advertised over mDNS for LAN discovery.
  final String advertiseHost;

  /// Count of devices currently paired.
  final int pairedDevices;

  /// Count of sessions currently running.
  final int runningSessions;

  /// Daemon version string.
  final String version;

  /// Parses a [StatusData] from its wire JSON representation.
  factory StatusData.fromJson(Map<String, dynamic> json) => StatusData(
    pid: json['pid'] as int,
    uptimeMs: json['uptimeMs'] as int,
    host: json['host'] as String,
    port: json['port'] as int,
    fingerprint: json['fingerprint'] as String,
    advertiseHost: json['advertiseHost'] as String,
    pairedDevices: json['pairedDevices'] as int,
    runningSessions: json['runningSessions'] as int,
    version: json['version'] as String,
  );

  /// Serialises this snapshot to its wire JSON representation.
  Map<String, dynamic> toJson() => {
    'pid': pid,
    'uptimeMs': uptimeMs,
    'host': host,
    'port': port,
    'fingerprint': fingerprint,
    'advertiseHost': advertiseHost,
    'pairedDevices': pairedDevices,
    'runningSessions': runningSessions,
    'version': version,
  };
}

/// A freshly minted pairing token and its QR payload.
class PairMintData {
  /// Creates minted pairing data.
  const PairMintData({
    required this.url,
    required this.token,
    required this.expiresAt,
    required this.fingerprint,
  });

  /// `pino://` deep-link URL encoded into the QR code.
  final String url;

  /// Opaque bearer token the mobile client redeems.
  final String token;

  /// Absolute expiry as milliseconds since the Unix epoch.
  final int expiresAt;

  /// SHA-256 fingerprint of the daemon's pinned TLS certificate.
  final String fingerprint;

  /// Parses [PairMintData] from wire JSON.
  factory PairMintData.fromJson(Map<String, dynamic> json) => PairMintData(
    url: json['url'] as String,
    token: json['token'] as String,
    expiresAt: json['expiresAt'] as int,
    fingerprint: json['fingerprint'] as String,
  );

  /// Serialises to wire JSON.
  Map<String, dynamic> toJson() => {
    'url': url,
    'token': token,
    'expiresAt': expiresAt,
    'fingerprint': fingerprint,
  };
}

/// The currently-active pairing token, if one is live.
class PairCurrentData {
  /// Creates current pairing data.
  const PairCurrentData({
    required this.url,
    required this.token,
    required this.expiresAt,
  });

  /// `pino://` deep-link URL encoded into the QR code.
  final String url;

  /// Opaque bearer token the mobile client redeems.
  final String token;

  /// Absolute expiry as milliseconds since the Unix epoch.
  final int expiresAt;

  /// Parses [PairCurrentData] from wire JSON.
  factory PairCurrentData.fromJson(Map<String, dynamic> json) =>
      PairCurrentData(
        url: json['url'] as String,
        token: json['token'] as String,
        expiresAt: json['expiresAt'] as int,
      );

  /// Serialises to wire JSON.
  Map<String, dynamic> toJson() => {
    'url': url,
    'token': token,
    'expiresAt': expiresAt,
  };
}

/// A device paired with the daemon.
class DeviceInfo {
  /// Creates device info.
  const DeviceInfo({
    required this.id,
    required this.label,
    required this.pairedAt,
    required this.lastSeenAt,
    required this.connected,
  });

  /// Stable device identifier.
  final String id;

  /// Human-readable device label (e.g. "iPhone 15").
  final String label;

  /// When the device paired, as milliseconds since the Unix epoch.
  final int pairedAt;

  /// When the device was last seen, as milliseconds since the Unix epoch.
  final int lastSeenAt;

  /// Whether the device currently holds a live connection.
  final bool connected;

  /// Parses [DeviceInfo] from wire JSON.
  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    id: json['id'] as String,
    label: json['label'] as String,
    pairedAt: json['pairedAt'] as int,
    lastSeenAt: json['lastSeenAt'] as int,
    connected: json['connected'] as bool,
  );

  /// Serialises to wire JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'pairedAt': pairedAt,
    'lastSeenAt': lastSeenAt,
    'connected': connected,
  };
}

/// A session known to the daemon, as surfaced to the desktop UI.
class SessionDto {
  /// Creates a session DTO.
  const SessionDto({
    required this.id,
    required this.title,
    required this.status,
    required this.projectId,
    required this.lastActivityAt,
  });

  /// Stable session identifier.
  final String id;

  /// Human-readable session title.
  final String title;

  /// Session lifecycle state (e.g. `running`, `done`, `error`).
  final String status;

  /// Owning project identifier.
  final String projectId;

  /// Last activity timestamp, as milliseconds since the Unix epoch.
  final int lastActivityAt;

  /// Parses [SessionDto] from wire JSON.
  factory SessionDto.fromJson(Map<String, dynamic> json) => SessionDto(
    id: json['id'] as String,
    title: json['title'] as String,
    status: json['status'] as String,
    projectId: json['projectId'] as String,
    lastActivityAt: json['lastActivityAt'] as int,
  );

  /// Serialises to wire JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'status': status,
    'projectId': projectId,
    'lastActivityAt': lastActivityAt,
  };
}

/// A single line of daemon log output.
class LogLine {
  /// Creates a log line.
  const LogLine({required this.text});

  /// The raw log text (without a trailing newline).
  final String text;

  /// Parses [LogLine] from wire JSON.
  factory LogLine.fromJson(Map<String, dynamic> json) =>
      LogLine(text: json['text'] as String);

  /// Serialises to wire JSON.
  Map<String, dynamic> toJson() => {'text': text};
}
