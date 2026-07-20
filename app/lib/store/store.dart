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

class ReposState {
  ReposState(this.repos);
  final List<RepoInfo> repos;

  RepoInfo? byId(String id) => repos.firstWhereOrNull((r) => r.id == id);
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
    required this.repos,
    required this.sessions,
    required this.events,
    required this.cursors,
    required this.commands,
    required this.meta,
    required this.actionErrors,
  });

  factory StoreState.empty() => StoreState(
    projects: const [],
    repos: const [],
    sessions: const [],
    events: const {},
    cursors: const {},
    commands: const {},
    meta: const {},
    actionErrors: const {},
  );

  final List<Project> projects;
  final List<RepoInfo> repos;
  final List<Session> sessions;
  final Map<String, List<SessionEvent>> events;
  final Map<String, int> cursors;

  /// Per-session list of slash commands advertised by the agent.
  final Map<String, List<SlashCmd>> commands;

  /// Per-session model + thinking-level snapshot from `session.meta`.
  final Map<String, SessionMeta> meta;

  /// Last action error per session, from `session.action_error`. Used to
  /// surface transient error snackbars without adding chat items.
  final Map<String, ActionError> actionErrors;

  StoreState copyWith({
    List<Project>? projects,
    List<RepoInfo>? repos,
    List<Session>? sessions,
    Map<String, List<SessionEvent>>? events,
    Map<String, int>? cursors,
    Map<String, List<SlashCmd>>? commands,
    Map<String, SessionMeta>? meta,
    Map<String, ActionError>? actionErrors,
  }) => StoreState(
    projects: projects ?? this.projects,
    repos: repos ?? this.repos,
    sessions: sessions ?? this.sessions,
    events: events ?? this.events,
    cursors: cursors ?? this.cursors,
    commands: commands ?? this.commands,
    meta: meta ?? this.meta,
    actionErrors: actionErrors ?? this.actionErrors,
  );
}

/// Pure state transition: fold a decoded wire frame into a new [StoreState].
/// No I/O, no logging, no side effects — this is what the reducer test locks
/// in. `_onFrame` is just `decode → reduce`.
StoreState reduce(StoreState state, Decoded decoded) => switch (decoded) {
  ProjectsSnapshot(:final projects) => state.copyWith(projects: projects),
  ReposSnapshot(:final repos) => state.copyWith(repos: repos),
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
    meta[ev.sessionId] = SessionMeta.fromJson(
      Map<String, dynamic>.from(ev.payload),
    );
    return state.copyWith(meta: meta, cursors: cursors);
  }

  // session.action_error carries a transient error from the pi extension.
  // Store the latest per-session so the UI can surface it as a snackbar.
  if (ev.kind == EventKind.sessionActionError) {
    final errors = Map<String, ActionError>.from(state.actionErrors);
    errors[ev.sessionId] = ActionError(
      seq: ev.seq,
      action: ev.payload['action'] as String? ?? 'action',
      reason: ev.payload['reason'] as String? ?? 'unknown error',
    );
    return state.copyWith(actionErrors: errors, cursors: cursors);
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
    _ref.listen<MakitConnState>(connectionControllerProvider, (prev, next) {
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

  /// Sessions whose initial `sub` replay is still streaming in (between the
  /// `sub` send and its matching `ack`). Their events are buffered in
  /// [_replayBuffer] and applied as a single batch on the ack, so the reversed
  /// transcript lands directly at the newest message instead of visibly racing
  /// through history top->bottom as each replayed event arrives.
  final Set<String> _awaitingReplay = <String>{};
  final Map<String, List<SessionEvent>> _replayBuffer =
      <String, List<SessionEvent>>{};

  /// Decode the frame through [WireCodec], then fold it via the pure [reduce].
  /// Unrecognized / malformed frames decode to null (WireCodec logs a warning)
  /// and are dropped — never throw.
  void _onFrame(Envelope env) {
    // A `sub` ack (id `s-<sessionId>`) marks the end of that session's history
    // replay: flush its buffered events in one state update.
    if (env.t == MsgType.ack && env.id.startsWith('s-')) {
      final sid = env.id.substring(2);
      if (_awaitingReplay.contains(sid)) _flushReplay(sid);
      return;
    }
    if (env.t != MsgType.event) return;
    final decoded = WireCodec.decode(env);
    if (decoded == null) return;
    // While a session's initial replay is still streaming, buffer its events
    // rather than folding each one (which would churn the reversed transcript).
    if (decoded is SessionEventFrame &&
        _awaitingReplay.contains(decoded.event.sessionId)) {
      (_replayBuffer[decoded.event.sessionId] ??= <SessionEvent>[]).add(
        decoded.event,
      );
      return;
    }
    state = reduce(state, decoded);
  }

  /// Apply the buffered replay for [sessionId] in a single state assignment,
  /// then resume immediate folding for its live events.
  void _flushReplay(String sessionId) {
    _awaitingReplay.remove(sessionId);
    final buffered = _replayBuffer.remove(sessionId);
    if (buffered == null || buffered.isEmpty) return;
    var next = state;
    for (final e in buffered) {
      next = reduceEvent(next, e);
    }
    state = next;
  }

  /// Currently-subscribed sessionIds. We replay these on every reconnect.
  final Set<String> _subscribed = <String>{};

  void subscribeSession(String sessionId) {
    _subscribed.add(sessionId);
    _sendSub(sessionId);
  }

  void _sendSub(String sessionId) {
    // Include the last-seen seq so the server replays only newer events on
    // reconnect instead of the whole history. `reduceEvent` still dedups, so
    // fromSeq=0 (fresh sub) stays correct.
    final fromSeq = state.cursors[sessionId] ?? 0;
    // Arm replay buffering so the events the server is about to stream back are
    // applied as one batch on the ack (see [_onFrame]). Re-arming resets any
    // in-flight buffer; the server re-replays from `fromSeq` so nothing is lost.
    _awaitingReplay.add(sessionId);
    _replayBuffer[sessionId] = <SessionEvent>[];
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.sub,
            id: 's-$sessionId',
            body: {'sessionId': sessionId, 'fromSeq': fromSeq},
          ),
        );
  }

  void appendOptimisticMessage(String sessionId, String text) {
    // Replay events have not advanced the public cursor yet, so assigning the
    // next seq here could collide with buffered history. The command still goes
    // to the server; its real user.message echo is ordered after the sub ack and
    // appears once [_flushReplay] has installed the replay cursor.
    if (_awaitingReplay.contains(sessionId)) return;
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
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? baseBranch,
    String? worktreePath,
    String? branch,
  }) async {
    final ack = await _ref
        .read(connectionControllerProvider.notifier)
        .request(MsgType.cmd, {
          'kind': 'session.spawn',
          'projectId': projectId,
          'title': ?title,
          'agent': ?agent,
          'baseBranch': ?baseBranch,
          'worktreePath': ?worktreePath,
          'branch': ?branch,
        });
    final sid = ack['sessionId'] as String?;
    if (sid == null) throw StateError('server did not return sessionId');
    return sid;
  }

  /// Spawn a new session that shares the SAME worktree as [sourceSessionId]
  /// (the split-pane flow). When the source already runs in a real worktree the
  /// new session binds to it; when the source is still an un-started draft both
  /// are linked to one virtual worktree that materializes on the first message.
  Future<String> spawnLinkedSession(String sourceSessionId) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.spawnLinked', 'sourceSessionId': sourceSessionId},
    );
    final sid = ack['sessionId'] as String?;
    if (sid == null) throw StateError('server did not return sessionId');
    return sid;
  }

  /// Fetch the agents this host can spawn (for the new-session picker).
  /// Returns an empty list on any failure so the caller falls back to default.
  Future<List<AgentDescriptor>> fetchAgents() async {
    try {
      final ack = await _ref
          .read(connectionControllerProvider.notifier)
          .request(MsgType.cmd, {'kind': 'agents.list'});
      final raw = ack['agents'];
      if (raw is! List) return const [];
      final out = <AgentDescriptor>[];
      for (final m in raw) {
        if (m is Map) {
          final d = AgentDescriptor.fromJson(Map<String, dynamic>.from(m));
          if (d != null) out.add(d);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Quit a session: kill its agent process and drop it server-side. The
  /// server broadcasts a fresh sessions.snapshot so the list updates.
  Future<void> killSession(String sessionId) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.kill', 'sessionId': sessionId},
    );
  }

  /// Set the harness a still-pending draft will start with. The server
  /// broadcasts a fresh sessions.snapshot so the draft's [Session.pendingAgent]
  /// updates.
  Future<void> setSessionAgent(String sessionId, String agent) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.setAgent', 'sessionId': sessionId, 'agent': agent},
    );
  }

  /// Create a new worktree up front (the + New worktree flow) with an
  /// auto-generated branch off [baseBranch]. Returns the new worktree's path +
  /// branch; the caller then lands on it to pick a harness. The server
  /// broadcasts a repos.snapshot so the sidebar shows the new worktree.
  Future<({String path, String? branch})> createWorktree(
    String projectId, {
    String? baseBranch,
  }) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {
        'kind': 'worktree.create',
        'projectId': projectId,
        'baseBranch': ?baseBranch,
      },
    );
    final path = ack['path'] as String?;
    if (path == null) throw StateError('server did not return a worktree path');
    return (path: path, branch: ack['branch'] as String?);
  }

  /// List the open PRs for a repo (the "New worktree from PR" picker). The
  /// server already returns [] when `gh` is unavailable/unauthenticated, so an
  /// empty result means "no open PRs"; a thrown error means the request itself
  /// failed (dropped connection, timeout) and the caller surfaces it distinctly.
  Future<List<OpenPr>> listOpenPrs(String projectId) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'pr.list', 'projectId': projectId},
    );
    final raw = (ack['prs'] as List?) ?? const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => OpenPr.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Create a worktree that checks out an existing PR's head branch. Returns
  /// the new worktree's path + branch.
  Future<({String path, String? branch})> createWorktreeFromPr(
    String projectId,
    int prNumber,
  ) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {
        'kind': 'worktree.createFromPr',
        'projectId': projectId,
        'prNumber': prNumber,
      },
    );
    final path = ack['path'] as String?;
    if (path == null) throw StateError('server did not return a worktree path');
    return (path: path, branch: ack['branch'] as String?);
  }

  /// Rename a worktree's checked-out branch. The server refuses when the branch
  /// has an open PR; that surfaces as a thrown error the caller can show.
  Future<void> renameBranch(
    String projectId,
    String worktreePath,
    String newName,
  ) async {
    await _ref
        .read(connectionControllerProvider.notifier)
        .request(MsgType.cmd, {
          'kind': 'branch.rename',
          'projectId': projectId,
          'worktreePath': worktreePath,
          'newName': newName,
        });
  }

  /// Remove a worktree (kills its sessions, then `git worktree remove --force`).
  Future<void> removeWorktree(String projectId, String worktreePath) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {
        'kind': 'worktree.remove',
        'projectId': projectId,
        'worktreePath': worktreePath,
      },
    );
  }

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

  /// Attach (resume) a prior pi session. Resolves with the makit session id
  /// once the server has backfilled its transcript and resumed it.
  Future<String> attachSession(String projectId, String piSessionId) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {
        'kind': 'session.attach',
        'projectId': projectId,
        'piSessionId': piSessionId,
      },
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
  /// once the server acks; the fresh `repos.snapshot` updates the home screen.
  Future<String> addProject(String path) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'project.add', 'path': path},
    );
    final id = ack['projectId'] as String?;
    if (id == null) throw StateError('server did not return projectId');
    unawaited(refreshRepos());
    return id;
  }

  /// Remove a project from makit. The server broadcasts a fresh snapshot that
  /// drops the project (and its sessions) from the store.
  Future<void> removeProject(String id) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'project.remove', 'projectId': id},
    );
    unawaited(refreshRepos());
  }

  /// Ask the server to recompute + rebroadcast the repo snapshot (git/gh
  /// intelligence). Used by pull-to-refresh on the home screen and as a
  /// belt-and-suspenders retrigger after project add/remove.
  ///
  /// Best-effort: the server already broadcasts a fresh `repos.snapshot` on
  /// add/remove/spawn/kill, so this is an optional optimization. A failure —
  /// e.g. an older server that predates `repo.refresh` and replies with
  /// `err {unknown cmd}`, or a transient error — must never bubble up and turn
  /// a successful add/remove (or a pull-to-refresh gesture) into an error.
  Future<void> refreshRepos() async {
    try {
      await _ref.read(connectionControllerProvider.notifier).request(
        MsgType.cmd,
        {'kind': 'repo.refresh'},
      );
    } catch (_) {
      // Swallow: the repo snapshot is refreshed by the server on its own for
      // the operations that call this.
    }
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

/// The harnesses this host can spawn, used by the harness picker cards.
///
/// Re-fetched on every socket-state change. A persisted worktree can build the
/// picker at boot (SPEC-20) BEFORE the WS connects; fetching then sends into a
/// dead socket and — since a [FutureProvider] caches its first result — would
/// otherwise pin an empty list forever, leaving every worktree stuck on the
/// "host default harness" fallback. Watching [WsState] makes the provider
/// re-run (and fetch for real) as soon as the host is reachable, so the cards
/// appear on connect / reconnect.
final agentsProvider = FutureProvider<List<AgentDescriptor>>((ref) {
  ref.watch(connectionProvider.select((c) => c.wsState));
  return ref.read(storeControllerProvider.notifier).fetchAgents();
});

final projectsProvider = Provider<ProjectsState>((ref) {
  final s = ref.watch(storeControllerProvider);
  return ProjectsState(s.projects);
});

final reposProvider = Provider<ReposState>((ref) {
  final s = ref.watch(storeControllerProvider);
  return ReposState(s.repos);
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

/// Last action error for a session (or null if none has arrived). Changes
/// whenever `session.action_error` is received so callers can use
/// [ProviderScope.listen] to trigger a snackbar.
final sessionActionErrorProvider = Provider.family<ActionError?, String>((
  ref,
  sessionId,
) {
  final s = ref.watch(storeControllerProvider);
  return s.actionErrors[sessionId];
});
