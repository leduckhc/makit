/// Typed data model for the pino control-plane protocol (SPEC-01 / SPEC-03).
///
/// A Dart port of the frozen NDJSON contract in
/// `server/src/daemon/protocol.ts`. The desktop app speaks this protocol over
/// the local unix-domain control socket (`~/.pino/control.sock`) to drive a
/// *running* daemon without restarting it.
///
/// Every payload factory is defensive: malformed JSON yields `null` rather than
/// throwing, because the socket is an untrusted local boundary. Parsing lives
/// in `control_codec.dart`; this file holds the value types.
library;

import 'package:pino/store/models.dart'
    show
        ApprovalPolicy,
        PaneInfo,
        SessionStatus,
        parsePolicy,
        parseStatus;

/// The v1 control verbs. Frozen — mirrors `CONTROL_VERBS` in `protocol.ts`.
enum ControlVerb {
  /// Daemon health + summary counters.
  status,

  /// Mint a fresh pairing token + `pino://` URL.
  pairMint,

  /// The active unexpired pairing token, if any.
  pairCurrent,

  /// List paired devices.
  devicesList,

  /// Revoke a paired device by id.
  devicesRevoke,

  /// List running sessions.
  sessionsList,

  /// Ask the daemon to shut down.
  serverStop,

  /// Stream (or dump) the daemon log tail.
  logsTail;

  /// The on-the-wire verb string (e.g. `pair.mint`).
  String get wire => switch (this) {
    ControlVerb.status => 'status',
    ControlVerb.pairMint => 'pair.mint',
    ControlVerb.pairCurrent => 'pair.current',
    ControlVerb.devicesList => 'devices.list',
    ControlVerb.devicesRevoke => 'devices.revoke',
    ControlVerb.sessionsList => 'sessions.list',
    ControlVerb.serverStop => 'server.stop',
    ControlVerb.logsTail => 'logs.tail',
  };

  /// Reverse of [wire]; `null` for an unknown verb string.
  static ControlVerb? fromWire(String s) {
    for (final v in ControlVerb.values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Small typed-JSON helpers (defensive scalar extraction).
// ---------------------------------------------------------------------------

int? _int(Object? v) => v is num ? v.toInt() : null;
String? _str(Object? v) => v is String ? v : null;
bool? _bool(Object? v) => v is bool ? v : null;

// ---------------------------------------------------------------------------
// Per-verb `data` payloads.
// ---------------------------------------------------------------------------

/// `status` result: daemon health + summary counters.
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

  /// Daemon process id.
  final int pid;

  /// Milliseconds the daemon has been running.
  final int uptimeMs;

  /// Bound host.
  final String host;

  /// Bound port.
  final int port;

  /// TLS certificate fingerprint (sha256 hex).
  final String fingerprint;

  /// Host advertised over mDNS for LAN discovery.
  final String advertiseHost;

  /// Number of currently paired devices.
  final int pairedDevices;

  /// Number of currently running sessions.
  final int runningSessions;

  /// Daemon version string.
  final String version;

  /// Parses [json] into a [StatusData], or `null` on a bad shape.
  static StatusData? fromJson(Object? json) {
    if (json is! Map) return null;
    final pid = _int(json['pid']);
    final uptimeMs = _int(json['uptimeMs']);
    final host = _str(json['host']);
    final port = _int(json['port']);
    final fingerprint = _str(json['fingerprint']);
    final advertiseHost = _str(json['advertiseHost']);
    final pairedDevices = _int(json['pairedDevices']);
    final runningSessions = _int(json['runningSessions']);
    final version = _str(json['version']);
    if (pid == null ||
        uptimeMs == null ||
        host == null ||
        port == null ||
        fingerprint == null ||
        advertiseHost == null ||
        pairedDevices == null ||
        runningSessions == null ||
        version == null) {
      return null;
    }
    return StatusData(
      pid: pid,
      uptimeMs: uptimeMs,
      host: host,
      port: port,
      fingerprint: fingerprint,
      advertiseHost: advertiseHost,
      pairedDevices: pairedDevices,
      runningSessions: runningSessions,
      version: version,
    );
  }

  /// Serializes to a wire-compatible JSON map.
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

/// `pair.mint` result: a fresh pairing token + the `pino://` URL that carries it.
class PairMintData {
  /// Creates a mint result.
  const PairMintData({
    required this.url,
    required this.token,
    required this.expiresAt,
    required this.fingerprint,
  });

  /// The `pino://` pairing URL (encodes host, token, and fingerprint).
  final String url;

  /// The raw pairing token.
  final String token;

  /// Epoch-ms expiry.
  final int expiresAt;

  /// TLS certificate fingerprint (sha256 hex).
  final String fingerprint;

  /// Parses [json] into a [PairMintData], or `null` on a bad shape.
  static PairMintData? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = _str(json['url']);
    final token = _str(json['token']);
    final expiresAt = _int(json['expiresAt']);
    final fingerprint = _str(json['fingerprint']);
    if (url == null ||
        token == null ||
        expiresAt == null ||
        fingerprint == null) {
      return null;
    }
    return PairMintData(
      url: url,
      token: token,
      expiresAt: expiresAt,
      fingerprint: fingerprint,
    );
  }

  /// Serializes to a wire-compatible JSON map.
  Map<String, dynamic> toJson() => {
    'url': url,
    'token': token,
    'expiresAt': expiresAt,
    'fingerprint': fingerprint,
  };
}

/// `pair.current` result: the active unexpired token (or `null` if none).
class PairCurrentData {
  /// Creates a current-token result.
  const PairCurrentData({
    required this.url,
    required this.token,
    required this.expiresAt,
  });

  /// The `pino://` pairing URL.
  final String url;

  /// The raw pairing token.
  final String token;

  /// Epoch-ms expiry.
  final int expiresAt;

  /// Parses [json] into a [PairCurrentData], or `null` on a bad shape (which
  /// also covers the "no active token" case, where the server sends `null`).
  static PairCurrentData? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = _str(json['url']);
    final token = _str(json['token']);
    final expiresAt = _int(json['expiresAt']);
    if (url == null || token == null || expiresAt == null) return null;
    return PairCurrentData(url: url, token: token, expiresAt: expiresAt);
  }

  /// Serializes to a wire-compatible JSON map.
  Map<String, dynamic> toJson() => {
    'url': url,
    'token': token,
    'expiresAt': expiresAt,
  };
}

/// One paired device (an entry of `devices.list`).
class DeviceInfo {
  /// Creates a device record.
  const DeviceInfo({
    required this.id,
    required this.label,
    required this.pairedAt,
    required this.lastSeenAt,
    required this.connected,
  });

  /// Stable device id.
  final String id;

  /// Human-readable device label.
  final String label;

  /// Epoch-ms of first pairing.
  final int pairedAt;

  /// Epoch-ms of the last observed activity.
  final int lastSeenAt;

  /// Whether the device is connected right now.
  final bool connected;

  /// Parses [json] into a [DeviceInfo], or `null` on a bad shape.
  static DeviceInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _str(json['id']);
    final label = _str(json['label']);
    final pairedAt = _int(json['pairedAt']);
    final lastSeenAt = _int(json['lastSeenAt']);
    final connected = _bool(json['connected']);
    if (id == null ||
        label == null ||
        pairedAt == null ||
        lastSeenAt == null ||
        connected == null) {
      return null;
    }
    return DeviceInfo(
      id: id,
      label: label,
      pairedAt: pairedAt,
      lastSeenAt: lastSeenAt,
      connected: connected,
    );
  }

  /// Serializes to a wire-compatible JSON map.
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'pairedAt': pairedAt,
    'lastSeenAt': lastSeenAt,
    'connected': connected,
  };
}

/// `devices.list` result.
class DevicesListData {
  /// Creates a device-list result.
  const DevicesListData({required this.devices});

  /// The paired devices (malformed entries are dropped defensively).
  final List<DeviceInfo> devices;

  /// Parses [json] into a [DevicesListData], or `null` on a bad shape.
  static DevicesListData? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['devices'];
    if (raw is! List) return null;
    final devices = <DeviceInfo>[];
    for (final entry in raw) {
      final device = DeviceInfo.fromJson(entry);
      if (device != null) devices.add(device);
    }
    return DevicesListData(devices: devices);
  }

  /// Serializes to a wire-compatible JSON map.
  Map<String, dynamic> toJson() => {
    'devices': devices.map((d) => d.toJson()).toList(),
  };
}

/// `devices.revoke` result.
class DevicesRevokeData {
  /// Creates a revoke result.
  const DevicesRevokeData({required this.removed});

  /// Whether a matching device was actually removed.
  final bool removed;

  /// Parses [json] into a [DevicesRevokeData], or `null` on a bad shape.
  static DevicesRevokeData? fromJson(Object? json) {
    if (json is! Map) return null;
    final removed = _bool(json['removed']);
    if (removed == null) return null;
    return DevicesRevokeData(removed: removed);
  }

  /// Serializes to a wire-compatible JSON map.
  Map<String, dynamic> toJson() => {'removed': removed};
}

/// One session (an entry of `sessions.list`). Ports `SessionDTO` from
/// `server/src/protocol.ts`.
class ControlSession {
  /// Creates a session record.
  const ControlSession({
    required this.id,
    required this.projectId,
    required this.agent,
    required this.title,
    required this.status,
    required this.policy,
    required this.lastActivityAt,
    required this.lastPreview,
    this.pane,
  });

  /// Stable session id.
  final String id;

  /// Owning project id.
  final String projectId;

  /// Backing agent (e.g. `pi`, `codex`, `claude`).
  final String agent;

  /// Human-readable title.
  final String title;

  /// Current lifecycle status.
  final SessionStatus status;

  /// Approval policy in force.
  final ApprovalPolicy policy;

  /// Epoch-ms of the last activity.
  final int lastActivityAt;

  /// A short preview of the latest output.
  final String lastPreview;

  /// Set when this session runs in a multiplexer pane (SPEC-05).
  final PaneInfo? pane;

  /// Parses [json] into a [ControlSession], or `null` on a bad shape.
  static ControlSession? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _str(json['id']);
    final projectId = _str(json['projectId']);
    final agent = _str(json['agent']);
    if (id == null || projectId == null || agent == null) return null;
    final rawPane = json['pane'];
    return ControlSession(
      id: id,
      projectId: projectId,
      agent: agent,
      title: _str(json['title']) ?? '',
      status: parseStatus(_str(json['status']) ?? ''),
      policy: parsePolicy(_str(json['policy']) ?? ''),
      lastActivityAt: _int(json['lastActivityAt']) ?? 0,
      lastPreview: _str(json['lastPreview']) ?? '',
      pane: rawPane is Map
          ? PaneInfo.fromJson(Map<String, dynamic>.from(rawPane))
          : null,
    );
  }
}

/// `sessions.list` result.
class SessionsListData {
  /// Creates a session-list result.
  const SessionsListData({required this.sessions});

  /// The running sessions (malformed entries are dropped defensively).
  final List<ControlSession> sessions;

  /// Parses [json] into a [SessionsListData], or `null` on a bad shape.
  static SessionsListData? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['sessions'];
    if (raw is! List) return null;
    final sessions = <ControlSession>[];
    for (final entry in raw) {
      final session = ControlSession.fromJson(entry);
      if (session != null) sessions.add(session);
    }
    return SessionsListData(sessions: sessions);
  }
}

/// `server.stop` result.
class ServerStopData {
  /// Creates a server-stop ack.
  const ServerStopData({required this.stopping});

  /// Always `true`; the daemon is shutting down.
  final bool stopping;

  /// Parses [json] into a [ServerStopData], or `null` on a bad shape.
  static ServerStopData? fromJson(Object? json) {
    if (json is! Map) return null;
    if (_bool(json['stopping']) != true) return null;
    return const ServerStopData(stopping: true);
  }

  /// Serializes to a wire-compatible JSON map.
  Map<String, dynamic> toJson() => {'stopping': true};
}

/// One frame of a `logs.tail` stream: either a [LogLine] or the terminal
/// [LogDone] marker.
sealed class LogChunk {
  const LogChunk();

  /// Parses [json] into a [LogChunk], or `null` if it is neither shape.
  static LogChunk? fromJson(Object? json) {
    if (json is! Map) return null;
    if (_bool(json['done']) == true) return const LogDone();
    final line = _str(json['line']);
    if (line != null) return LogLine(line);
    return null;
  }
}

/// A single streamed log line (`logs.tail`).
class LogLine extends LogChunk {
  /// Creates a log-line chunk.
  const LogLine(this.line);

  /// The log line text (no trailing newline).
  final String line;
}

/// Terminal chunk for a non-follow `logs.tail`, marking the backlog complete.
class LogDone extends LogChunk {
  /// Creates a done marker.
  const LogDone();
}

// ---------------------------------------------------------------------------
// Response envelope.
// ---------------------------------------------------------------------------

/// A decoded control response envelope: an ok result carrying typed `data`
/// ([ControlOk]) or an error ([ControlErr]). Correlated to a request by [id].
sealed class ControlResponse<T> {
  const ControlResponse(this.id);

  /// The request id this response answers.
  final String id;

  /// Decodes a raw envelope map, applying [parseData] to the `data` field.
  ///
  /// Returns `null` if the envelope itself is malformed (missing/non-string
  /// `id`, non-bool `ok`, or an error without a string `error`). [parseData]
  /// only shapes the `data` of an ok response and never rejects the envelope.
  static ControlResponse<T>? fromJson<T>(
    Object? json,
    T? Function(Object? data) parseData,
  ) {
    if (json is! Map) return null;
    final id = json['id'];
    final ok = json['ok'];
    if (id is! String || ok is! bool) return null;
    if (!ok) {
      final error = json['error'];
      if (error is! String) return null;
      return ControlErr<T>(id, error);
    }
    return ControlOk<T>(id, parseData(json['data']));
  }
}

/// A successful control response with (optionally) typed [data].
class ControlOk<T> extends ControlResponse<T> {
  /// Creates an ok response.
  const ControlOk(super.id, this.data);

  /// The parsed payload, or `null` when the verb carries no data.
  final T? data;
}

/// A failed control response carrying the server's [error] message.
class ControlErr<T> extends ControlResponse<T> {
  /// Creates an error response.
  const ControlErr(super.id, this.error);

  /// The server-provided error string.
  final String error;
}

/// Thrown by the control client when a request fails: an error response, a
/// closed socket with in-flight requests, or a malformed payload.
class ControlException implements Exception {
  /// Creates a control exception with a human-readable [message].
  const ControlException(this.message);

  /// Description of what went wrong.
  final String message;

  @override
  String toString() => 'ControlException: $message';
}
