/// Ships buffered [LogRecord]s to the server over the WSS `client.log` command,
/// so an iOS device's logs (crashes included) can be read on the Mac without
/// the user copy-pasting.
///
/// Policy: **manual send is primary** — the Diagnostics screen's "Send to
/// server" button flushes the whole buffer. Error-level records additionally
/// trigger a *debounced* auto-flush, so a crash ships its surrounding context
/// on its own. We never stream every line: that would be noisy, battery-hungry,
/// and risk a feedback loop where "send failed" logs trigger more sends.
library;

import 'dart:async';

import '../transport/protocol.dart';
import 'log.dart';

/// Sends one already-built `client.log` command body. Returns when the server
/// acks; throws on error/timeout (the uploader treats that as "try again
/// later"). Injected so the transport stays a seam and tests need no socket.
typedef LogUploadSender = Future<void> Function(Map<String, dynamic> body);

/// The pure wire shape for a `client.log` command: the kind, the sender's
/// platform + optional app version, and the records. The server derives the
/// device identity from the authed connection, so it is not sent here.
Map<String, dynamic> clientLogBody({
  required String platform,
  String? appVersion,
  required List<LogRecord> records,
}) => {
  'kind': CmdKind.clientLog.wire,
  'platform': platform,
  'appVersion': ?appVersion,
  'records': records.map((r) => r.toJson()).toList(),
};

/// Batches and uploads [MakitLog] records via a [LogUploadSender].
class LogUploader {
  LogUploader({
    required MakitLog log,
    required LogUploadSender send,
    required this.platform,
    this.appVersion,
    this.maxRecordsPerUpload = 500,
    this.autoFlushDelay = const Duration(seconds: 3),
  }) : _log = log,
       _send = send {
    _removeSink = log.addSink(_Forwarder(this));
  }

  final MakitLog _log;
  final LogUploadSender _send;

  /// `ios` / `android` / `macos` — a coarse origin label for the server log.
  final String platform;

  /// Optional app version string; omitted from the wire when null.
  final String? appVersion;

  /// Never ship more than this many records in one upload (cap the payload).
  final int maxRecordsPerUpload;

  /// Debounce window between an error record and the auto-flush it schedules.
  final Duration autoFlushDelay;

  void Function()? _removeSink;
  Timer? _debounce;
  bool _sending = false;

  void _onRecord(LogRecord record) {
    if (record.level == LogLevel.error) {
      _debounce?.cancel();
      _debounce = Timer(autoFlushDelay, () {
        unawaited(flush());
      });
    }
  }

  /// Send a snapshot of the current buffer (most-recent [maxRecordsPerUpload]).
  /// Concurrent calls collapse: a flush already in flight is a no-op. Returns
  /// true if anything was sent.
  Future<bool> flush() async {
    if (_sending) return false;
    final all = _log.records;
    if (all.isEmpty) return false;
    final batch = all.length > maxRecordsPerUpload
        ? all.sublist(all.length - maxRecordsPerUpload)
        : all;
    _sending = true;
    try {
      await _send(
        clientLogBody(
          platform: platform,
          appVersion: appVersion,
          records: batch,
        ),
      );
      return true;
    } finally {
      _sending = false;
    }
  }

  void dispose() {
    _debounce?.cancel();
    _removeSink?.call();
    _removeSink = null;
  }
}

/// Adapts [LogUploader] to the [LogSink] interface without leaking the sink
/// method onto the uploader's public surface.
class _Forwarder implements LogSink {
  _Forwarder(this._uploader);
  final LogUploader _uploader;
  @override
  void add(LogRecord record) => _uploader._onRecord(record);
}
