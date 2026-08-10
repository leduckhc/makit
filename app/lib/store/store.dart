import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../transport/codec.dart';
import '../transport/protocol.dart';
import '../transport/ws_client.dart';
import 'cached_commands.dart';
import 'connection.dart';
import 'docs.dart';
import 'metrics.dart';
import 'models.dart';
import 'ports.dart';

class ProjectsState {
  ProjectsState(this.projects);
  final List<Project> projects;
}

class ReposState {
  ReposState(this.repos);
  final List<RepoInfo> repos;

  RepoInfo? byId(String id) => repos.firstWhereOrNull((r) => r.id == id);

  /// The open PR for the worktree at [worktreePath] across all repos, or null
  /// when there is none (or [worktreePath] is null). Backs the PR pill wherever
  /// a worktree is shown (chat composer bar, harness picker).
  PullRequest? prForWorktreePath(String? worktreePath) {
    if (worktreePath == null) return null;
    for (final repo in repos) {
      for (final w in repo.worktrees) {
        if (w.path == worktreePath) return w.pr;
      }
    }
    return null;
  }

  /// The worktree at [worktreePath] together with the repo that owns it, or
  /// null when no repo has it.
  ///
  /// One lookup instead of one per field: the composer's next-step bar needs the
  /// PR, the three sync counts, the branch, the repo id *and* whether it is the
  /// primary checkout. Walking the repo list once per field was both wasteful
  /// and easy to get inconsistent — six independent scans can straddle a
  /// snapshot swap and end up describing two different worktrees.
  ({RepoInfo repo, Worktree worktree})? locateWorktree(String? worktreePath) {
    if (worktreePath == null) return null;
    for (final repo in repos) {
      for (final w in repo.worktrees) {
        if (w.path == worktreePath) return (repo: repo, worktree: w);
      }
    }
    return null;
  }
}

class SessionsState {
  SessionsState(this.sessions);
  final List<Session> sessions;

  List<Session> forProject(String projectId) =>
      sessions.where((s) => s.projectId == projectId && !s.archived).toList()
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
    required this.usage,
    this.githubBudget,
    this.metrics = const [],
    this.ports,
    this.docs,
    this.sessionsLoaded = false,
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
    usage: const {},
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

  /// Per-session context-window + cost snapshot from `session.usage` (SPEC-37).
  /// Absent until the agent reports its first reading; pi only reports at all
  /// when the `makit-pi-usage` extension is installed.
  final Map<String, SessionUsage> usage;

  /// Latest GitHub API budget snapshot (SPEC-32), or null until the first
  /// `github.budget` frame arrives. A fresh client renders an `unknown` icon
  /// while this is null.
  final GithubBudget? githubBudget;

  /// Bounded ring of performance samples (SPEC-37), oldest first. Capped at
  /// [_metricsCap]; empty until the first `metrics.sample` frame.
  final List<MetricsSample> metrics;

  /// Latest host-wide ports snapshot (SPEC-41), or null before the first
  /// `ports.snapshot` frame. Latest-wins: a snapshot replaces the last one
  /// wholesale (it is the complete picture, not a delta).
  final PortsSnapshot? ports;

  /// Latest host-wide docs snapshot (SPEC-46), or null before the first
  /// `docs.snapshot` frame. Latest-wins: a snapshot replaces the last one
  /// wholesale (it is the complete picture, not a delta).
  final DocsSnapshot? docs;

  /// Whether a `sessions.snapshot` has been received. Distinguishes "the server
  /// has no sessions" from "we haven't heard from the server yet", which an
  /// empty [sessions] list alone cannot.
  final bool sessionsLoaded;

  StoreState copyWith({
    List<Project>? projects,
    List<RepoInfo>? repos,
    List<Session>? sessions,
    Map<String, List<SessionEvent>>? events,
    Map<String, int>? cursors,
    Map<String, List<SlashCmd>>? commands,
    Map<String, SessionMeta>? meta,
    Map<String, ActionError>? actionErrors,
    Map<String, SessionUsage>? usage,
    GithubBudget? githubBudget,
    List<MetricsSample>? metrics,
    PortsSnapshot? ports,
    DocsSnapshot? docs,
    bool? sessionsLoaded,
  }) => StoreState(
    projects: projects ?? this.projects,
    repos: repos ?? this.repos,
    sessions: sessions ?? this.sessions,
    events: events ?? this.events,
    cursors: cursors ?? this.cursors,
    commands: commands ?? this.commands,
    meta: meta ?? this.meta,
    actionErrors: actionErrors ?? this.actionErrors,
    usage: usage ?? this.usage,
    githubBudget: githubBudget ?? this.githubBudget,
    metrics: metrics ?? this.metrics,
    ports: ports ?? this.ports,
    docs: docs ?? this.docs,
    sessionsLoaded: sessionsLoaded ?? this.sessionsLoaded,
  );
}

/// Max metrics samples retained (30 min at 1 Hz). Drop-oldest beyond this.
const int _metricsCap = 1800;

/// Trim [list] to the trailing [_metricsCap] samples (drop-oldest).
List<MetricsSample> _boundedMetrics(List<MetricsSample> list) =>
    list.length <= _metricsCap ? list : list.sublist(list.length - _metricsCap);

/// Pure state transition: fold a decoded wire frame into a new [StoreState].
/// No I/O, no logging, no side effects — this is what the reducer test locks
/// in. `_onFrame` is just `decode → reduce`.
StoreState reduce(StoreState state, Decoded decoded) => switch (decoded) {
  ProjectsSnapshot(:final projects) => state.copyWith(projects: projects),
  ReposSnapshot(:final repos) => state.copyWith(repos: repos),
  GithubBudgetFrame(:final budget) => state.copyWith(githubBudget: budget),
  // `history` replaces the ring (backfill on watch); a lone sample appends.
  MetricsSampleFrame(:final sample, :final history) => state.copyWith(
    metrics: _boundedMetrics(
      history != null ? [...history, sample] : [...state.metrics, sample],
    ),
  ),
  // Latest-wins: a ports snapshot is the whole picture, so it replaces the
  // last one wholesale rather than merging (SPEC-41, like `metrics` history).
  PortsSnapshotFrame(:final snapshot) => state.copyWith(ports: snapshot),
  // Latest-wins: a docs snapshot is the whole picture (SPEC-46 D11).
  DocsSnapshotFrame(:final snapshot) => state.copyWith(docs: snapshot),
  SessionsSnapshot(:final sessions) => state.copyWith(
    sessions: sessions,
    sessionsLoaded: true,
  ),
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

  // session.usage updates the context-usage indicator, not chat (SPEC-37).
  // Latest-wins by whole-snapshot replacement: every update carries the complete
  // picture, so merging would resurrect a reading the agent stopped sending.
  if (ev.kind == EventKind.sessionUsage) {
    final usage = Map<String, SessionUsage>.from(state.usage);
    usage[ev.sessionId] = SessionUsage.fromJson(
      Map<String, dynamic>.from(ev.payload),
    );
    return state.copyWith(usage: usage, cursors: cursors);
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
      // Switching servers invalidates everything cached: repos, sessions and
      // transcripts all belonged to the old desktop. Snapshots replace wholesale
      // once they arrive, but until then the list would still show the previous
      // server's repos — and if the new one is unreachable, indefinitely, with
      // taps dispatching against sessions that live somewhere else.
      //
      // Keyed on the active server, not on the socket: a reconnect to the *same*
      // server must keep its data, or every network blip would blank the screen.
      //
      // Any change of identity counts, including to and from null. Requiring
      // both sides to be non-null skipped exactly the transitions that matter:
      // unpair (A -> null) left A's repos cached, and pairing a different
      // desktop afterwards (null -> C) skipped too, so C inherited A's list.
      final prevId = prev?.activeServer?.id;
      final nextId = next.activeServer?.id;
      if (prevId != nextId) {
        _subscribed.clear();
        _awaitingReplay.clear();
        _replayBuffer.clear();
        _historyLoaded.clear();
        _fullReplay.clear();
        _watchingGithubBudget = false;
        state = StoreState.empty();
        // SPEC-45 D9: the per-(agent, project) command cache belonged to the old
        // desktop too. Project ids are host-local, so keeping it would offer one
        // machine's skills under another's project of the same name — and unlike
        // the rest of this state, that cache is persisted, so it would survive a
        // restart as well.
        //
        // `prevId != null` only: boot activates null -> the persisted server,
        // which is a change of identity by the same test but not a change of
        // *machine* — the cache was written by the server being restored. Clearing
        // there wiped the blob on every launch, before a pane could read it, which
        // is exactly the emptiness persisting it was meant to prevent.
        //
        // Deferred to a microtask, unlike the assignment above: this listener
        // runs inside Riverpod's refresh pass, and writing to *another* provider
        // there is what `desktop_session_prune.dart` documents as poisoning the
        // graph for the rest of the process. Safe today (nothing in the graph
        // watches this cache during a connection change — only widgets do), but
        // the failure mode is bad enough not to leave standing on that.
        //
        // `mounted` because the container can be disposed between scheduling and
        // running (app teardown right after a switch or unpair), and a disposed
        // StateNotifier throws on assignment.
        if (prevId != null) {
          final cache = _ref.read(cachedCommandsControllerProvider.notifier);
          Future.microtask(() {
            if (cache.mounted) unawaited(cache.clearAll());
          });
        }
      }

      final wasConnected = prev?.wsState == WsState.connected;
      final nowConnected = next.wsState == WsState.connected;
      if (!wasConnected && nowConnected) {
        for (final sid in _subscribed) {
          _sendSub(sid);
        }
        // Same reason, same fix, for the budget panel's fast-cadence watch: the
        // server drops per-client watchers on disconnect, so an open panel would
        // silently fall back to the slow 60s cadence with no way back short of
        // closing and reopening it.
        if (_watchingGithubBudget) unawaited(watchGithubBudget(true));
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

  /// Sessions whose full history this client holds (a `fromSeq = 0` replay
  /// completed). Only those may `sub` incrementally from their cursor.
  ///
  /// The cursor alone cannot decide that: the server auto-mirrors every
  /// session's events to every authed client, subscribed or not (see
  /// `SubscriptionHub.fanout`), and [reduceEvent] advances the cursor for each
  /// one. So a session streaming in the background drags this client's cursor to
  /// its head while the store holds nothing but the tail — and subbing from that
  /// cursor replayed *zero* events, losing the history and, with it, the
  /// one-shot `session.meta` / `session.commands` the agent emits at spawn: no
  /// model selector, no slash commands, transcript starting mid-conversation.
  final Set<String> _historyLoaded = <String>{};

  /// Sessions whose in-flight `sub` asked for the whole history, so the flush
  /// replaces their tail-only slice instead of folding into it (the cursor would
  /// otherwise reject every replayed event as already-seen).
  final Set<String> _fullReplay = <String>{};

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
    if (decoded is SessionEventFrame) _cacheCommands(decoded.event);
  }

  /// SPEC-45 D4: mirror a session's advertised commands into the per-(agent,
  /// project) cache, so the sessionless starter pane for that project can offer
  /// the same palette.
  ///
  /// Driven by the event, not by watching the reduced `commands` map: a diff of
  /// that map would run on every streamed token, while `session.commands`
  /// arrives a handful of times per session.
  void _cacheCommands(SessionEvent ev) {
    if (ev.kind != EventKind.sessionCommands) return;
    final commands = state.commands[ev.sessionId];
    if (commands == null || commands.isEmpty) return;
    final session = state.sessions.firstWhereOrNull(
      (s) => s.id == ev.sessionId,
    );
    // No session means no (agent, project) to key by. Dropping the palette is
    // the only honest option — a guessed key would offer one harness's commands
    // under another's name.
    if (session == null) return;
    final agent = session.agent.isNotEmpty
        ? session.agent
        : (session.pendingAgent ?? '');
    if (agent.isEmpty) return;
    unawaited(
      _ref
          .read(cachedCommandsControllerProvider.notifier)
          .record(
            agent: agent,
            projectId: session.projectId,
            commands: commands,
          ),
    );
  }

  /// Apply the buffered replay for [sessionId] in a single state assignment,
  /// then resume immediate folding for its live events.
  void _flushReplay(String sessionId) {
    _awaitingReplay.remove(sessionId);
    final buffered = _replayBuffer.remove(sessionId);
    final full = _fullReplay.remove(sessionId);
    if (!full && (buffered == null || buffered.isEmpty)) return;
    var next = state;
    if (full) {
      _historyLoaded.add(sessionId);
      // Start this session from an empty slice: the replay is its whole log, and
      // whatever the auto-mirror left here sits at seqs the cursor would now use
      // to reject the replay. Dropping it first closes the hole without
      // duplicating the tail (the replay carries those events too).
      next = next.copyWith(
        events: Map<String, List<SessionEvent>>.from(next.events)
          ..remove(sessionId),
        cursors: Map<String, int>.from(next.cursors)..remove(sessionId),
      );
    }
    final events = buffered ?? const <SessionEvent>[];
    for (final e in events) {
      next = reduceEvent(next, e);
    }
    state = next;
    for (final e in events) {
      _cacheCommands(e);
    }
  }

  /// Currently-subscribed sessionIds. We replay these on every reconnect.
  final Set<String> _subscribed = <String>{};

  void subscribeSession(String sessionId) {
    _subscribed.add(sessionId);
    // A cold, resumable session (the server restarted while we were away) has no
    // live agent process. Ask the server to bring it back BEFORE subscribing so
    // the first message lands on a live agent instead of a `session.error`
    // (SPEC-29). A non-resumable cold session just replays as read-only history.
    final session = state.sessions.firstWhereOrNull((s) => s.id == sessionId);
    if (session != null &&
        session.resumable &&
        session.status == SessionStatus.exited) {
      unawaited(_reattachThenSub(sessionId));
      return;
    }
    _sendSub(sessionId);
  }

  /// Re-attach a cold resumable session to its live agent, then subscribe.
  /// A failed re-attach (offline / history-only) still falls through to `sub`
  /// so the transcript renders read-only rather than showing nothing.
  Future<void> _reattachThenSub(String sessionId) async {
    try {
      await _ref.read(connectionControllerProvider.notifier).request(
        MsgType.cmd,
        {'kind': 'session.attach', 'sessionId': sessionId},
      );
    } catch (_) {
      // History-only or transport error — show what we have.
    }
    _sendSub(sessionId);
  }

  void _sendSub(String sessionId) {
    // Include the last-seen seq so the server replays only newer events on
    // reconnect instead of the whole history — but only once we hold that
    // history contiguously, or the cursor an auto-mirrored session advanced for
    // us would suppress the replay entirely (see [_historyLoaded]).
    final loaded = _historyLoaded.contains(sessionId);
    final fromSeq = loaded ? (state.cursors[sessionId] ?? 0) : 0;
    if (!loaded) _fullReplay.add(sessionId);
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

  void appendOptimisticMessage(
    String sessionId,
    String text, {
    List<MediaAttachmentRef> attachments = const [],
  }) {
    // Replay events have not advanced the public cursor yet, so assigning the
    // next seq here could collide with buffered history. The command still goes
    // to the server; its real user.message echo is ordered after the sub ack and
    // appears once [_flushReplay] has installed the replay cursor.
    if (_awaitingReplay.contains(sessionId)) return;
    // A pending (draft) session promotes on its first message: the server
    // creates the worktree + agent, whose startup emits session.commands /
    // status events BEFORE the user.message echo. Those events consume seqs, so
    // the optimistic bubble's guessed seq (cursor+1) no longer matches the
    // echo's seq and the reducer can't dedup them — the first message would
    // render twice. Skip the optimistic bubble here (as with replay above); the
    // echo renders it once, ordered after the startup events.
    final idx = state.sessions.indexWhere((s) => s.id == sessionId);
    if (idx >= 0 && state.sessions[idx].pending) return;
    // SPEC-35: while the agent is working, the next seq belongs to ITS stream.
    // The message is about to be steered into the running turn (echoed a moment
    // later, with a seq we cannot guess) or queued (echoed only when it is
    // finally delivered, or never if cancelled) — so a bubble at cursor+1 would
    // advance the cursor past a real event and the reducer would drop it. The
    // queue chip above the composer is the feedback here, not a chat bubble.
    //
    // `status != idle` is NOT sufficient: `Session.sendUserMessage` enqueues
    // whenever a queue exists or a flush is in flight, *whatever* the status —
    // so an idle session with messages still pending queues this one too, and a
    // bubble here would be a lie that also eats the next real seq.
    if (idx >= 0 &&
        (state.sessions[idx].status != SessionStatus.idle ||
            state.sessions[idx].queued.isNotEmpty)) {
      return;
    }
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
        payload: {
          'text': text,
          // SPEC-33: the optimistic copy MUST carry the attachments too. The
          // server's echo arrives with the same seq and is dropped by the
          // reducer's idempotency guard, so THIS payload is what gets rendered
          // — a bubble without its thumbnails would be permanent.
          if (attachments.isNotEmpty)
            'attachments': [for (final a in attachments) a.toEchoWire()],
        },
      ),
    );
  }

  void sendMessage(
    String sessionId,
    String text, {
    List<MediaAttachmentRef> attachments = const [],
  }) {
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
              // Ids only (see `toWire`) — the bytes were uploaded to
              // `POST /media` first and the server resolves each id against its
              // store (SPEC-33 §3.3).
              if (attachments.isNotEmpty)
                'attachments': [for (final a in attachments) a.toWire()],
            },
          ),
        );
  }

  /// Cancel ONE pending mid-turn message (SPEC-35). Fire-and-forget: the
  /// authoritative queue arrives on the next sessions snapshot, and a message
  /// that flushed between the tap and this frame is simply gone.
  void cancelQueuedMessage(String sessionId, String id) {
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.cmd,
            id: 'qc-${DateTime.now().microsecondsSinceEpoch}',
            // `queuedId`, not `id`: [Envelope.toJson] spreads the body over the
            // frame, so a body key called `id` overwrites the request id above.
            body: {
              'kind': 'queue.cancel',
              'sessionId': sessionId,
              'queuedId': id,
            },
          ),
        );
  }

  /// Replace a pending mid-turn message's text (SPEC-38). Empty text cancels it
  /// server-side, so the caller does not need a second command for that case.
  void updateQueuedMessage(String sessionId, String id, String text) {
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.cmd,
            id: 'qu-${DateTime.now().microsecondsSinceEpoch}',
            body: {
              'kind': 'queue.update',
              'sessionId': sessionId,
              'queuedId': id,
              'text': text,
            },
          ),
        );
  }

  /// Send ONE pending message now (SPEC-39): the server interrupts the running
  /// turn so this message is delivered next, keeping the rest queued.
  ///
  /// Fire-and-forget like its siblings; a message that flushed between the tap
  /// and this frame is a no-op server-side, and deliberately does NOT abort the
  /// turn on the strength of a stale tap.
  void promoteQueuedMessage(String sessionId, String id) {
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.cmd,
            id: 'qp-${DateTime.now().microsecondsSinceEpoch}',
            body: {
              'kind': 'queue.promote',
              'sessionId': sessionId,
              'queuedId': id,
            },
          ),
        );
  }

  /// Apply a new send order to the pending messages (SPEC-38). The server treats
  /// `ids` as a hint, so a queue that flushed under the user cannot fail here.
  void reorderQueuedMessages(String sessionId, List<String> ids) {
    _ref
        .read(connectionControllerProvider.notifier)
        .send(
          Envelope(
            t: MsgType.cmd,
            id: 'qr-${DateTime.now().microsecondsSinceEpoch}',
            body: {'kind': 'queue.reorder', 'sessionId': sessionId, 'ids': ids},
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

  /// Spawn a fresh agent session in the given project, in the worktree the
  /// caller already resolved (creating it first when the user asked for a new
  /// branch or a PR). Resolves with the new session id once the server acks.
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    final picks = (configOptions != null && configOptions.isNotEmpty)
        ? configOptions.map((p) => p.toJson()).toList()
        : null;
    final ack = await _ref
        .read(connectionControllerProvider.notifier)
        .request(MsgType.cmd, {
          'kind': 'session.spawn',
          'projectId': projectId,
          'title': ?title,
          'agent': ?agent,
          'worktreePath': ?worktreePath,
          'branch': ?branch,
          'configOptions': ?picks,
        });
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

  /// Archive a session (SPEC-29): a soft, recoverable hide. The server drops it
  /// from the active `sessions.snapshot` (it stays resumable + restorable) and
  /// broadcasts a fresh snapshot so the list updates.
  Future<void> archiveSession(String sessionId) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.archive', 'sessionId': sessionId},
    );
  }

  /// Restore an archived session to the active list (SPEC-29).
  Future<void> unarchiveSession(String sessionId) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.unarchive', 'sessionId': sessionId},
    );
  }

  /// Fetch the archived sessions (SPEC-29). Not part of the active snapshot;
  /// loaded on demand for the "Show archived sessions" list.
  Future<List<Session>> listArchivedSessions() async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'session.listArchived'},
    );
    return WireCodec.decodeSessions(ack['sessions']) ?? const [];
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
  /// auto-generated branch off [baseBranch], or a slugified [branchName] when
  /// supplied. Returns the new worktree's path + branch; the caller then lands
  /// on it to pick a harness. The server broadcasts a repos.snapshot so the
  /// sidebar shows the new worktree.
  Future<({String path, String? branch})> createWorktree(
    String projectId, {
    String? baseBranch,
    String? branchName,
  }) async {
    final ack = await _ref
        .read(connectionControllerProvider.notifier)
        .request(MsgType.cmd, {
          'kind': 'worktree.create',
          'projectId': projectId,
          'baseBranch': ?baseBranch,
          'branchName': ?branchName,
        });
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

  /// Discard the worktree of a pull request that closed without merging: remove
  /// the worktree and delete the branch it held. No base branch to catch up,
  /// because nothing landed.
  ///
  /// Distinct from [removeWorktree], which keeps the branch — the sidebar and the
  /// mobile long-press use that one, and "remove this worktree" is a narrower
  /// request than "discard this dead line of work".
  /// [expectBranch] is the branch the confirm dialog told the user would be
  /// deleted; the server refuses if the worktree has moved to another one since.
  Future<WrapUpReport> discardWorktree(
    String projectId,
    String worktreePath, {
    String? expectBranch,
  }) async {
    final ack = await _ref
        .read(connectionControllerProvider.notifier)
        .request(MsgType.cmd, {
          'kind': 'worktree.discard',
          'projectId': projectId,
          'worktreePath': worktreePath,
          'expectBranch': ?expectBranch,
        });
    return WrapUpReport.fromJson(ack);
  }

  /// Tidy up after a pull request ended: remove the worktree, delete its
  /// branch, and fast-forward the branch the PR merged into.
  ///
  /// [baseBranch] is the PR's own `baseRefName`; pass null and the server falls
  /// back to the repo's default branch. Returns the server's report, because the
  /// base-branch leg is best-effort — the caller has to be able to tell "tidied
  /// and caught main up" from "tidied, main left alone because it had local
  /// commits".
  Future<WrapUpReport> wrapUpWorktree(
    String projectId,
    String worktreePath, {
    String? baseBranch,
    String? expectBranch,
  }) async {
    final ack = await _ref
        .read(connectionControllerProvider.notifier)
        .request(MsgType.cmd, {
          'kind': 'worktree.wrapUp',
          'projectId': projectId,
          'worktreePath': worktreePath,
          'baseBranch': ?baseBranch,
          'expectBranch': ?expectBranch,
        });
    return WrapUpReport.fromJson(ack);
  }

  /// Take the worktree's PR out of draft (`gh pr ready`).
  Future<void> markPrReady(String projectId, String worktreePath) =>
      _prMutation('pr.markReady', projectId, worktreePath);

  /// Merge the PR's base branch into its head on GitHub (`gh pr update-branch`).
  Future<void> updatePrBranch(String projectId, String worktreePath) =>
      _prMutation('pr.updateBranch', projectId, worktreePath);

  /// Land the PR with GitHub's squash strategy (`gh pr merge --squash`). Leaves
  /// the worktree in place — tidying up is [wrapUpWorktree]'s job.
  Future<void> squashMergePr(String projectId, String worktreePath) =>
      _prMutation('pr.squashMerge', projectId, worktreePath);

  Future<void> _prMutation(
    String kind,
    String projectId,
    String worktreePath,
  ) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': kind, 'projectId': projectId, 'worktreePath': worktreePath},
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

  /// Ask the server to re-read the GitHub quota (SPEC-32 §6.6). Cheap by
  /// design: it hits GitHub's `/rate_limit`, which is **exempt** from the rate
  /// limit, so checking the budget never spends it.
  ///
  /// Best-effort, like [refreshRepos]: an older server that predates
  /// `github.refresh` replies `err {unknown cmd}`, and a failed refresh must
  /// never surface as an error — the server re-broadcasts the budget on every
  /// level change anyway.
  Future<void> refreshGithubBudget() async {
    try {
      await _ref.read(connectionControllerProvider.notifier).request(
        MsgType.cmd,
        {'kind': 'github.refresh'},
      );
    } catch (_) {
      // Swallow: the budget refreshes itself on a 60s cadence regardless.
    }
  }

  /// Whether the budget panel is currently open here, so the watch can be
  /// re-issued on reconnect (the server forgets it, exactly like `sub`).
  bool _watchingGithubBudget = false;

  /// Tell the server whether this client has the budget panel open (SPEC-32
  /// §6.6). While it is, the server re-reads the exempt `/rate_limit` on a fast
  /// cadence and pushes every snapshot, so the live counters actually move —
  /// its idle broadcast only fires on a level/throttle change.
  ///
  /// Best-effort for the same reason as [refreshGithubBudget]: an older server
  /// replies `err {unknown cmd}`, and the panel must still render, just with the
  /// slower 60s cadence.
  Future<void> watchGithubBudget(bool watching) async {
    _watchingGithubBudget = watching;
    try {
      await _ref.read(connectionControllerProvider.notifier).request(
        MsgType.cmd,
        {'kind': 'github.watch', 'watching': watching},
      );
    } catch (_) {
      // Swallow: without the subscription the panel is stale, not broken.
    }
  }

  /// Pause or resume the server's background PR polling (SPEC-32 §6.6).
  ///
  /// Pausing stops only *background* work; user-initiated actions still draw on
  /// the reserve, and PR pills keep their last-known state (dimmed) rather than
  /// disappearing. Best-effort for the same reason as [refreshGithubBudget].
  Future<void> setGithubPollingPaused(bool paused) async {
    try {
      await _ref.read(connectionControllerProvider.notifier).request(
        MsgType.cmd,
        {'kind': 'github.pause', 'paused': paused},
      );
    } catch (_) {
      // Swallow: a failed pause leaves polling as it was, which is safe.
    }
  }

  /// SPEC-46 D7: read one markdown document's text over the WSS channel.
  /// Errors for `kind == "html"` server-side; the caller only invokes this for
  /// markdown. Throws on transport error or a server `err` so the preview can
  /// show the reason rather than a blank body.
  Future<String> readDoc(String worktreePath, String relPath) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'docs.read', 'worktreePath': worktreePath, 'relPath': relPath},
    );
    final text = ack['text'];
    if (text is! String) throw StateError('docs.read returned no text');
    return text;
  }

  /// SPEC-46 D9/D15: publish one document over the tailnet, returning the
  /// grant. Never invents a URL — a server `err` (no usable address,
  /// `tailscale serve` unavailable) throws with the stated reason so the share
  /// sheet degrades loudly instead of offering a dead link.
  Future<DocGrant> publishDoc(String worktreePath, String relPath) async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {
        'kind': 'docs.publish',
        'worktreePath': worktreePath,
        'relPath': relPath,
      },
    );
    final grantMap = ack['grant'];
    if (grantMap is! Map<String, dynamic>) {
      throw StateError('docs.publish returned an unusable grant shape');
    }
    final grant = DocGrant.fromJson(grantMap);
    if (grant == null) {
      throw StateError('docs.publish returned an unusable grant');
    }
    return grant;
  }

  /// SPEC-46 D9: revoke a publication by `grantId` (Stop sharing).
  Future<void> unpublishDoc(String grantId) async {
    await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'docs.unpublish', 'grantId': grantId},
    );
  }

  /// SPEC-46: list active publications, so the app can say "3 docs are shared".
  Future<List<DocGrant>> listDocGrants() async {
    final ack = await _ref.read(connectionControllerProvider.notifier).request(
      MsgType.cmd,
      {'kind': 'docs.grants'},
    );
    final raw = (ack['grants'] as List?) ?? const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => DocGrant.fromJson(Map<String, dynamic>.from(m)))
        .whereType<DocGrant>()
        .toList();
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

/// Latest GitHub API budget snapshot (SPEC-32), or null before any
/// `github.budget` frame has arrived. Safe to watch pre-connect — the footer
/// icon renders an `unknown`/dimmed state while this is null.
final githubBudgetProvider = Provider<GithubBudget?>((ref) {
  return ref.watch(storeControllerProvider).githubBudget;
});

final sessionsProvider = Provider<SessionsState>((ref) {
  final s = ref.watch(storeControllerProvider);
  return SessionsState(s.sessions);
});

/// Whether the server's session list has been received at least once (see
/// [StoreState.sessionsLoaded]).
final sessionsLoadedProvider = Provider<bool>(
  (ref) => ref.watch(storeControllerProvider).sessionsLoaded,
);

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

/// Pending mid-turn messages for a session (SPEC-35/36), in send order. Empty
/// for an unknown session, so callers never branch on null.
final queuedMessagesProvider = Provider.family<List<QueuedMessage>, String>((
  ref,
  sessionId,
) {
  final sessions = ref.watch(storeControllerProvider).sessions;
  for (final s in sessions) {
    if (s.id == sessionId) return s.queued;
  }
  return const [];
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

/// Latest context-window + cost snapshot for a session (SPEC-37), or null until
/// the agent reports one. Null must render as "unknown", not as an empty bar.
final sessionUsageProvider = Provider.family<SessionUsage?, String>((
  ref,
  sessionId,
) {
  final s = ref.watch(storeControllerProvider);
  return s.usage[sessionId];
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
