/// Riverpod wiring for the diagnostics logger: exposes the process-wide
/// [MakitLog] and its server uploader to the UI.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/connection.dart';
import '../transport/protocol.dart';
import 'app_log.dart';
import 'log.dart';
import 'log_uploader.dart';

/// The shared logger, for widgets that render/observe it.
final makitLogProvider = Provider<MakitLog>((ref) => appLog);

/// The server uploader, bound to the current connection's request path. Sends
/// a `client.log` `cmd` and resolves when the server acks (or throws on
/// timeout, which the uploader treats as "retry later").
final logUploaderProvider = Provider<LogUploader>((ref) {
  final conn = ref.read(connectionControllerProvider.notifier);
  final uploader = LogUploader(
    log: ref.watch(makitLogProvider),
    platform: diagnosticPlatformLabel(),
    send: (body) => conn.request(MsgType.cmd, body),
  );
  ref.onDispose(uploader.dispose);
  return uploader;
});
