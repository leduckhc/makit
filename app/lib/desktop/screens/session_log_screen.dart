/// Streaming session-log tail for the desktop control app.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../control/control_contract.dart';
import 'providers.dart';

/// Tails a single session's log, auto-scrolling to follow new lines.
///
/// Subscribes to `tailLogs(sessionId:, follow: true)` on the injected
/// [ControlClient]. Shows a "Connecting…" placeholder until the first line
/// arrives and a "Connection lost" state if the stream errors. Auto-scroll
/// pauses while the user has scrolled away from the bottom.
class SessionLogScreen extends ConsumerStatefulWidget {
  /// Creates a log tail for [sessionId].
  const SessionLogScreen({super.key, required this.sessionId});

  /// Identifier of the session whose log is tailed.
  final String sessionId;

  @override
  ConsumerState<SessionLogScreen> createState() => _SessionLogScreenState();
}

class _SessionLogScreenState extends ConsumerState<SessionLogScreen> {
  final _scroll = ScrollController();
  final _lines = <String>[];
  StreamSubscription<LogLine>? _sub;
  bool _errored = false;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _sub = ref
        .read(controlClientProvider)
        .tailLogs(sessionId: widget.sessionId, follow: true)
        .listen(
          _onLine,
          onError: (Object _) {
            if (mounted) setState(() => _errored = true);
          },
        );
  }

  void _onLine(LogLine line) {
    if (!mounted) return;
    setState(() => _lines.add(line.text));
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Re-enable auto-scroll only when the user is pinned to the bottom.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('Log · ${widget.sessionId}'),
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_errored) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, color: cs.error, size: 40),
            const SizedBox(height: 12),
            const Text('Connection lost'),
          ],
        ),
      );
    }
    if (_lines.isEmpty) {
      return const Center(child: Text('Connecting…'));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: _lines.length,
      itemBuilder: (context, i) => Text(
        _lines[i],
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
        ),
      ),
    );
  }
}
