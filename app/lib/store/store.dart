import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../transport/codec.dart';
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

/// Immutable store snapshot. All mutation flows through the pure [reduce]
/// function so the reducer can be tested in isolation from the transport.
class StoreState {
  StoreState({
    required this.projects,
    required this.sessions,
    required this.events,
    required this.cursors,
    required this.commands,
    required this.meta,
  });

  factory StoreState.empty() => StoreState(
    projects: const [],
    sessions: const [],
    events: const {},
    cursors: const {},
    commands: const {},
    meta: const {},
  );

  final List<Project> projects;
  final List<Session> sessions;
  final Map<String, List<SessionEvent>> events;
  final Map<String, int> cursors;

  /// Per-session list of slash commands advertised by the agent.
  final Map<String, List<SlashCmd>> commands;

  /// Per-session model + thinking-level snapshot from `session.meta`.
  final Map<String, SessionMeta> meta;

  StoreState copyWith({
    List<Project>? projects,
    List<Session>? sessions,
    Map<String, List<SessionEvent>>? events,
    Map<String, int>? cursors,
    Map<String, List<SlashCmd>>? commands,
    Map<String, SessionMeta>? meta,
  }) => StoreState(
    projects: projects ?? this.projects,
    sessions: sessions ?? this.sessions,
    events: events ?? this.events,
    cursors: cursors ?? this.cursors,
    commands: commands ?? this.commands,
    meta: meta ?? this.meta,
  );
}

/// Pure state transition: fold a decoded wire frame into a new [StoreState].
/// No I/O, no logging, no side effects — this is what the reducer test locks
/// in. `_onFrame` is just `decode → reduce`.
StoreState reduce(StoreState state, Decoded decoded) => switch (decoded) {
  ProjectsSnapshot(:final projects) => state.copyWith(projects: projects),
  SessionsSnapshot(:final sessions) => state.copyWith(sessions: sessions),
  SessionEventFrame(:final event) => reduceEvent(state, event),
};

/// Fold a single [SessionEvent] into the store, preserving the seq-cursor
/// idempotency semantics exactly.
///
/// Idempotency: drop if this seq (or a later one) was already processed. The
/// cursor tracks the max seq seen across ALL events — including
/// session.commands, which isn't stored in the chat list — so the client's seq
/// space stays aligned with the server's. Without this, the optimistic user
/// bubble (seq N) and the server's user.message echo (also seq N) get different
/// seqs and both render as duplicate bubbles.
StoreState reduceEvent(StoreState state, SessionEvent ev) {
  final lastSeen = state.cursors[ev.sessionId] ?? 0;
  if (lastSeen >= ev.seq) return state;

  final cursors = Map<String, int>.from(state.cursors);
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
    return state.copyWith(commands: commands, cursors: cursors);
  }

  // session.meta updates the model/thinking indicator + /model picker, not chat.
  if (ev.kind == EventKind.sessionMeta) {
    final meta = Map<String, SessionMeta>.from(state.meta);
    meta[ev.sessionId] = SessionMeta.fromJson(Map<String, dynamic>.from(ev.payload));
    return state.copyWith(meta: meta, cursors: cursors);
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
    }
    sessions = [...sessions];
    sessions[idx] = cur.copyWith(
      status: newStatus,
      lastPreview: newPreview,
      lastActivityAt: ev.ts,
    );
  }

  return state.copyWith(events: events, cursors: cursors, sessions: sessions);
}

class StoreController extends StateNotifier<StoreState> {
  StoreController(this._ref) : super(StoreState.empty()) {
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
      if (!wasConnected && nowConnected) {
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

  /// Decode the frame through [WireCodec], then fold it via the pure [reduce].
  /// Unrecognized / malformed frames decode to null (WireCodec logs a warning)
  /// and are dropped — never throw.
  void _onFrame(Envelope env) {
    if (env.t != MsgType.event) return;
    final decoded = WireCodec.decode(env);
    if (decoded == null) return;
    state = reduce(state, decoded);
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
    // dropped by the reducer's idempotency guard — so the optimistic bubble is
    // the single rendered user message, seamlessly "confirmed" by the echo.
    final lastSeen = state.cursors[sessionId] ?? 0;
    state = reduceEvent(
      state,
      SessionEvent(
        seq: lastSeen + 1,
        sessionId: sessionId,
        ts: DateTime.now().millisecondsSinceEpoch,
        kind: EventKind.userMessage,
        payload: {'text': text},
      ),
    );
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

  /// Run a built-in control action (e.g. `compact`, `thinking`) on the session.
  /// Unlike [sendMessage] this is not a user turn — the server relays it to the
  /// hosting pi extension's SDK calls; nothing is sent to the LLM as a prompt.
  void sendSessionAction(
    String sessionId,
    String action, {
    Map<String, dynamic>? args,
  }) {
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.cmd,
            id: 'a-${DateTime.now().microsecondsSinceEpoch}',
            body: {
              'kind': 'session.action',
              'sessionId': sessionId,
              'action': action,
              'args': ?args,
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

  /// Quit a session: kill its agent process and drop it server-side. The
  /// server broadcasts a fresh sessions.snapshot so the list updates.
  Future<void> killSession(String sessionId) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.kill', 'sessionId': sessionId},
    );
  }

  /// List a project's prior on-disk pi sessions (newest first).
  Future<List<PiSessionMeta>> listPiSessions(String projectId) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.list', 'projectId': projectId},
    );
    final raw = (ack['sessions'] as List?) ?? const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => PiSessionMeta.fromJson(Map<String, dynamic>.from(m)))
        .whereType<PiSessionMeta>()
        .toList();
  }

  /// Attach (resume) a prior pi session. Resolves with the pino session id
  /// once the server has backfilled its transcript and resumed it.
  Future<String> attachSession(String projectId, String piSessionId) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.attach', 'projectId': projectId, 'piSessionId': piSessionId},
    );
    final sid = ack['sessionId'] as String?;
    if (sid == null) throw StateError('server did not return sessionId');
    return sid;
  }

  /// Browse the server's filesystem for candidate project folders. Pass null
  /// for the server's default/home dir. Resolves with the resolved dir, its
  /// parent, and child directories.
  Future<BrowseResult> browse(String? path) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'project.browse', 'path': ?path},
    );
    return BrowseResult.fromJson(ack);
  }

  /// Register a new project rooted at [path]. Resolves with the new project id
  /// once the server acks; the fresh `projects.snapshot` updates the store.
  Future<String> addProject(String path) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'project.add', 'path': path},
    );
    final id = ack['projectId'] as String?;
    if (id == null) throw StateError('server did not return projectId');
    return id;
  }

  /// Remove a project from pino. The server broadcasts a fresh snapshot that
  /// drops the project (and its sessions) from the store.
  Future<void> removeProject(String id) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'project.remove', 'projectId': id},
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final storeControllerProvider =
    StateNotifierProvider<StoreController, StoreState>(
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
  return foldEvents(events);
});

/// Slash commands advertised by the agent for a given session.
final commandsProvider = Provider.family<List<SlashCmd>, String>((
  ref,
  sessionId,
) {
  final s = ref.watch(storeControllerProvider);
  return s.commands[sessionId] ?? const [];
});

/// Current model + thinking level + selectable models for a session (or null
/// until the host pushes `session.meta`).
final sessionMetaProvider = Provider.family<SessionMeta?, String>((
  ref,
  sessionId,
) {
  final s = ref.watch(storeControllerProvider);
  return s.meta[sessionId];
});
