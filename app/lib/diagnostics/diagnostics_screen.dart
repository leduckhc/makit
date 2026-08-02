/// On-device diagnostics viewer: a live tail of [MakitLog], with a level
/// filter, copy-to-clipboard, "send to server", and clear. This is the screen
/// that makes an iOS crash legible in the field — the framework assertions and
/// asset-load failures that otherwise vanish into an unreachable console show
/// up here, and can be shipped to the Mac with one tap.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import 'diagnostics_providers.dart';
import 'log.dart';

class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key, this.showSendToServer = true});

  /// Whether to offer "send to server" (mobile client only). The desktop
  /// control app runs beside the server, so shipping its own logs to itself is
  /// meaningless — and reading the mobile connection provider there would be a
  /// side effect we don't want.
  final bool showSendToServer;

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  final _scroll = ScrollController();
  final _records = <LogRecord>[];
  StreamSubscription<LogRecord>? _sub;
  LogLevel _filter = LogLevel.debug;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final log = ref.read(makitLogProvider);
    _records.addAll(log.records);
    _sub = log.stream.listen(_onRecord);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  void _onRecord(LogRecord record) {
    if (!mounted) return;
    setState(() => _records.add(record));
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  void _jumpToBottom() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _autoScroll =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 8;
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    unawaited(_sub?.cancel());
    super.dispose();
  }

  List<LogRecord> get _visible =>
      _records.where((r) => r.level.index >= _filter.index).toList();

  Future<void> _copyAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final text = _visible.map((r) => r.toLine()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      SnackBar(content: Text('Copied ${_visible.length} lines')),
    );
  }

  Future<void> _sendToServer() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final sent = await ref.read(logUploaderProvider).flush();
      messenger.showSnackBar(
        SnackBar(
          content: Text(sent ? 'Logs sent to server' : 'Nothing to send'),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Send failed: not connected ($e)')),
      );
    }
  }

  void _clear() {
    ref.read(makitLogProvider).clear();
    setState(_records.clear);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(PhosphorIconsLight.arrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Diagnostics'),
        actions: [
          PopupMenuButton<LogLevel>(
            tooltip: 'Minimum level',
            icon: const Icon(PhosphorIconsLight.funnel),
            initialValue: _filter,
            onSelected: (l) => setState(() => _filter = l),
            itemBuilder: (_) => [
              for (final l in LogLevel.values)
                PopupMenuItem(value: l, child: Text(l.wire)),
            ],
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(PhosphorIconsLight.copy),
            onPressed: _visible.isEmpty ? null : _copyAll,
          ),
          if (widget.showSendToServer)
            IconButton(
              tooltip: 'Send to server',
              icon: const Icon(PhosphorIconsLight.paperPlaneTilt),
              onPressed: _records.isEmpty ? null : _sendToServer,
            ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(PhosphorIconsLight.trash),
            onPressed: _records.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: _visible.isEmpty
          ? const Center(child: Text('No logs yet'))
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(kSpace12),
              itemCount: _visible.length,
              itemBuilder: (context, i) => _LogLineTile(record: _visible[i]),
            ),
    );
  }
}

class _LogLineTile extends StatelessWidget {
  const _LogLineTile({required this.record});
  final LogRecord record;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (record.level) {
      LogLevel.debug => cs.outline,
      LogLevel.info => cs.onSurfaceVariant,
      LogLevel.warn => kStatusWarning,
      LogLevel.error => cs.error,
    };
    final base =
        (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).mono;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: SelectableText(
        record.toLine(),
        style: base.copyWith(color: color, height: 1.35),
      ),
    );
  }
}
