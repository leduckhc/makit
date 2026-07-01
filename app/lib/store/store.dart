import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../transport/protocol.dart';
import '../transport/ws_client.dart';
import 'connection.dart';
import 'models.dart';

class ProjectsState {
  ProjectsState(this.projects);
  final List<Project> projects;
}

class SessionsState {
  SessionsState(this.sessions);
  final List<Session> sessions;

  List<Session> forProject(String projectId) =>
      sessions.where((s) => s.projectId == projectId).toList()
        ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));

  Session? byId(String id) => sessions.firstWhereOrNull((s) => s.id == id);
}

/// Holds the rolling event log per session + the highest seq we've seen.
class EventsState {
  EventsState(this.events, this.cursors);
  final Map<String, List<SessionEvent>> events;
  final Map<String, int> cursors;

  List<SessionEvent> forSession(String id) => events[id] ?? const [];
}

class StoreController extends StateNotifier<_StoreSnapshot> {
  StoreController(this._ref) : super(_StoreSnapshot.empty()) {
    _sub = _ref
        .read(connectionControllerProvider.notifier)
        .incoming
        .listen(_onFrame);

    // Re-issue every active `sub` whenever the WS reconnects. The server
    // forgets per-client subscriptions on disconnect, so without this the
    // app stops receiving `session.event` updates after any reconnect
    // (server restart, hot restart, network blip) until the user manually
    // navigates back into the session screen.
    _ref.listen<PinoConnState>(connectionControllerProvider, (prev, next) {
      final wasConnected = prev?.wsState == WsState.connected;
      final nowConnected = next.wsState == WsState.connected;
      debugPrint('[pino] connState ${prev?.wsState}→${next.wsState} subs=${_subscribed.length}');
      if (!wasConnected && nowConnected) {
        debugPrint('[pino] reconnect: replaying ${_subscribed.length} sub(s)');
        for (final sid in _subscribed) {
          _sendSub(sid);
        }
      }
    });

    // Kick off a subscribe-all once connected. Fake server pushes snapshots
    // on hello.
    _ref
        .read(connectionControllerProvider.notifier)
        .send(Envelope(t: MsgType.hello, id: 'boot', body: {}));
  }

  final Ref _ref;
  StreamSubscription<Envelope>? _sub;

  void _onFrame(Envelope env) {
    if (env.t != MsgType.event) return;
    final kind = env.body['kind'] as String?;

    switch (kind) {
      case 'projects.snapshot':
        final list = (env.body['projects'] as List)
            .cast<Map<String, dynamic>>()
            .map(
              (j) => Project(
                id: j['id'] as String,
                name: j['name'] as String,
                path: j['path'] as String,
                pinned: j['pinned'] as bool? ?? false,
                lastActivityAt: (j['lastActivityAt'] as num?)?.toInt() ?? 0,
              ),
            )
            .toList();
        state = state.copyWith(projects: list);
      case 'sessions.snapshot':
        final list = (env.body['sessions'] as List)
            .cast<Map<String, dynamic>>()
            .map(
              (j) => Session(
                id: j['id'] as String,
                projectId: j['projectId'] as String,
                agent: j['agent'] as String,
                title: j['title'] as String? ?? '',
                status: parseStatus(j['status'] as String? ?? 'idle'),
                policy: parsePolicy(j['policy'] as String? ?? 'ask-on-risky'),
                lastActivityAt: (j['lastActivityAt'] as num?)?.toInt() ?? 0,
                lastPreview: j['lastPreview'] as String? ?? '',
              ),
            )
            .toList();
        state = state.copyWith(sessions: list);
      case 'session.event':
        final ev = SessionEvent.fromJson(
          Map<String, dynamic>.from(env.body['event'] as Map),
        );
        if (ev == null) return;
        _appendEvent(ev);
    }
  }

  void _appendEvent(SessionEvent ev) {
    debugPrint('[pino] _appendEvent: session=${ev.sessionId} kind=${ev.kind.wire} seq=${ev.seq}');
    final cursors = Map<String, int>.from(state.cursors);
    final lastSeen = cursors[ev.sessionId] ?? 0;
    // Idempotency: drop if this seq (or a later one) was already processed.
    // The cursor tracks the max seq seen across ALL events — including
    // session.commands, which isn't stored in the chat list — so the client's
    // seq space stays aligned with the server's. Without this, the optimistic
    // user bubble (seq N) and the server's user.message echo (also seq N) get
    // different seqs and both render as duplicate bubbles.
    if (lastSeen >= ev.seq) {
      debugPrint('[pino] _appendEvent drop: seq=${ev.seq} <= cursor=$lastSeen');
      return;
    }
    cursors[ev.sessionId] = ev.seq;

    // session.commands updates the slash palette, not the chat list.
    if (ev.kind == EventKind.sessionCommands) {
      final raw = (ev.payload['commands'] as List?) ?? const [];
      final list = raw
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => SlashCmd.fromJson(Map<String, dynamic>.from(m)))
          .whereType<SlashCmd>()
          .toList();
      final commands = Map<String, List<SlashCmd>>.from(state.commands);
      commands[ev.sessionId] = list;
      state = state.copyWith(commands: commands, cursors: cursors);
      return;
    }

    final events = Map<String, List<SessionEvent>>.from(state.events);
    final list = List<SessionEvent>.from(events[ev.sessionId] ?? const []);
    list.add(ev);
    events[ev.sessionId] = list;

    // Bubble up session-level status / preview.
    var sessions = state.sessions;
    final idx = sessions.indexWhere((s) => s.id == ev.sessionId);
    if (idx >= 0) {
      final cur = sessions[idx];
      SessionStatus? newStatus;
      String? newPreview;
      if (ev.kind == EventKind.sessionStatus) {
        newStatus = parseStatus(ev.payload['status'] as String? ?? '');
      } else if (ev.kind == EventKind.userMessage ||
          ev.kind == EventKind.agentMessage) {
        newPreview = ev.payload['text'] as String?;
      } else if (ev.kind == EventKind.approvalRequest) {
        newStatus = SessionStatus.awaitingApproval;
        newPreview = 'Approval required: ${ev.payload['tool'] ?? 'tool'}';
      }
      sessions = [...sessions];
      sessions[idx] = cur.copyWith(
        status: newStatus,
        lastPreview: newPreview,
        lastActivityAt: ev.ts,
      );
    }

    state = state.copyWith(
      events: events,
      cursors: cursors,
      sessions: sessions,
    );
  }

  /// Currently-subscribed sessionIds. We replay these on every reconnect.
  final Set<String> _subscribed = <String>{};

  void subscribeSession(String sessionId) {
    _subscribed.add(sessionId);
    _sendSub(sessionId);
  }

  void _sendSub(String sessionId) {
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.sub,
            id: 's-$sessionId',
            body: {'sessionId': sessionId},
          ),
        );
  }

  void appendOptimisticMessage(String sessionId, String text) {
    // Inject a local user bubble immediately so the input doesn't feel hung.
    // The optimistic event takes the next seq after the cursor; the server's
    // user.message echo arrives with the SAME seq (the server assigns seqs in
    // emission order, and the user message is the next thing it emits) and is
    // dropped by _appendEvent's idempotency guard — so the optimistic bubble
    // is the single rendered user message, seamlessly "confirmed" by the echo.
    final lastSeen = state.cursors[sessionId] ?? 0;
    debugPrint('[pino] appendOptimisticMessage sid=${sessionId.substring(0, 8)} text="$text" seq=${lastSeen + 1}');
    _appendEvent(SessionEvent(
      seq: lastSeen + 1,
      sessionId: sessionId,
      ts: DateTime.now().millisecondsSinceEpoch,
      kind: EventKind.userMessage,
      payload: {'text': text},
    ));
  }

  void sendMessage(String sessionId, String text) {
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.cmd,
            id: 'm-${DateTime.now().microsecondsSinceEpoch}',
            body: {
              'kind': 'send.message',
              'sessionId': sessionId,
              'text': text,
            },
          ),
        );
  }

  /// Spawn a fresh agent session in the given project. Resolves with the new
  /// session id once the server acks.
  Future<String> spawnSession(String projectId, {String? title}) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {
        'kind': 'session.spawn',
        'projectId': projectId,
        'title': ?title,
      },
    );
    final sid = ack['sessionId'] as String?;
    if (sid == null) throw StateError('server did not return sessionId');
    return sid;
  }

  void approve(String sessionId, String callId, {required bool ok}) {
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.cmd,
            id: 'a-${DateTime.now().microsecondsSinceEpoch}',
            body: {
              'kind': ok ? 'approve' : 'deny',
              'sessionId': sessionId,
              'callId': callId,
            },
          ),
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

class _StoreSnapshot {
  _StoreSnapshot({
    required this.projects,
    required this.sessions,
    required this.events,
    required this.cursors,
    required this.commands,
  });

  factory _StoreSnapshot.empty() => _StoreSnapshot(
    projects: const [],
    sessions: const [],
    events: const {},
    cursors: const {},
    commands: const {},
  );

  final List<Project> projects;
  final List<Session> sessions;
  final Map<String, List<SessionEvent>> events;
  final Map<String, int> cursors;

  /// Per-session list of slash commands advertised by the agent.
  final Map<String, List<SlashCmd>> commands;

  _StoreSnapshot copyWith({
    List<Project>? projects,
    List<Session>? sessions,
    Map<String, List<SessionEvent>>? events,
    Map<String, int>? cursors,
    Map<String, List<SlashCmd>>? commands,
  }) => _StoreSnapshot(
    projects: projects ?? this.projects,
    sessions: sessions ?? this.sessions,
    events: events ?? this.events,
    cursors: cursors ?? this.cursors,
    commands: commands ?? this.commands,
  );
}

final storeControllerProvider =
    StateNotifierProvider<StoreController, _StoreSnapshot>(
      (ref) => StoreController(ref),
    );

final projectsProvider = Provider<ProjectsState>((ref) {
  final s = ref.watch(storeControllerProvider);
  return ProjectsState(s.projects);
});

final sessionsProvider = Provider<SessionsState>((ref) {
  final s = ref.watch(storeControllerProvider);
  return SessionsState(s.sessions);
});

final eventsProvider = Provider<EventsState>((ref) {
  final s = ref.watch(storeControllerProvider);
  return EventsState(s.events, s.cursors);
});

final chatItemsProvider = Provider.family<List<ChatItem>, String>((
  ref,
  sessionId,
) {
  final events = ref.watch(eventsProvider).forSession(sessionId);
  debugPrint('[pino] chatItemsProvider($sessionId) raw events: ${events.length}');
  final items = foldEvents(events);
  debugPrint('[pino] chatItemsProvider($sessionId) computed ${items.length} items (first: ${items.isEmpty ? "none" : items.first.runtimeType})');
  return items;
});

/// Slash commands advertised by the agent for a given session.
final commandsProvider = Provider.family<List<SlashCmd>, String>((
  ref,
  sessionId,
) {
  final s = ref.watch(storeControllerProvider);
  return s.commands[sessionId] ?? const [];
});
