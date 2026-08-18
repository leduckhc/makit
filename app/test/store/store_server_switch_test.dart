// Switching servers must invalidate the cached store: repos, sessions and
// transcripts all belonged to the previous desktop. Snapshots replace wholesale
// when they arrive, but until then the list would show the old server's repos —
// indefinitely if the new one is unreachable.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/cached_commands.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

const _fpA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _fpB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _Transport implements Transport {
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  @override
  Future<void> connect(
    String url, {
    Map<String, dynamic> helloBody = const {},
    String? pinnedFingerprint,
  }) async => _state.add(WsState.connected);

  @override
  Future<void> close() async {}
  @override
  Stream<Envelope> get frames => _frames.stream;
  @override
  Stream<WsState> get state => _state.stream;
  @override
  void sendEnvelope(Envelope env) {}
  @override
  void forceReconnect() {}
}

class _Storage implements SecureStore {
  _Storage(this.data);
  final Map<String, String> data;
  @override
  Future<String?> read({required String key}) async => data[key];
  @override
  Future<void> write({required String key, required String? value}) async =>
      data[key] = value ?? '';
  @override
  Future<void> delete({required String key}) async => data.remove(key);
}

Map<String, dynamic> _srv(String host, String fp, String label) => {
  'host': host,
  'port': 8443,
  'fingerprint': fp,
  'bearer': 'bearer-$fp',
  'label': label,
};

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(
          _Storage({
            'paired_servers':
                '{"servers":[${_json(_srv('10.0.0.1', _fpA, 'work'))},'
                '${_json(_srv('10.0.0.2', _fpB, 'home'))}],'
                '"activeId":"$_fpA"}',
          }),
          transportFactory: _Transport.new,
          browseLan: ({Duration timeout = const Duration(seconds: 3)}) async =>
              [],
          rediscoverStall: const Duration(seconds: 30),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Pretend a snapshot from the currently-active server landed.
void _seedRepo(StoreController store, String name) {
  store.state = store.state.copyWith(
    repos: [
      RepoInfo(
        id: name,
        name: name,
        path: '/$name',
        pinned: false,
        lastActivityAt: 0,
        isGitRepo: true,
        defaultBranch: 'main',
        currentBranch: 'main',
        worktrees: const [],
      ),
    ],
  );
}

void main() {
  test('switching servers clears repos cached from the previous one', () async {
    final container = ProviderContainer(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(
            _Storage({
              'paired_servers':
                  '{"servers":[${_json(_srv('10.0.0.1', _fpA, 'work'))},'
                  '${_json(_srv('10.0.0.2', _fpB, 'home'))}],'
                  '"activeId":"$_fpA"}',
            }),
            transportFactory: _Transport.new,
            browseLan:
                ({Duration timeout = const Duration(seconds: 3)}) async => [],
            rediscoverStall: const Duration(seconds: 30),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    _seedRepo(store, 'lives-on-server-a');
    expect(container.read(reposProvider).repos, hasLength(1));

    await container.read(connectionControllerProvider.notifier).switchTo(_fpB);
    await Future<void>.delayed(Duration.zero);

    // B has sent nothing yet, so the honest answer is "nothing", not A's repo.
    expect(
      container.read(reposProvider).repos,
      isEmpty,
      reason: "server A's repos must not linger under server B",
    );
  });

  test('unpairing clears the desktop\'s cached repos', () async {
    final container = _container();
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    _seedRepo(store, 'lives-on-server-a');

    await container.read(connectionControllerProvider.notifier).unpair();
    await Future<void>.delayed(Duration.zero);

    // Nothing is paired, so there is no server those repos could belong to.
    expect(container.read(reposProvider).repos, isEmpty);
  });

  test(
    'arriving at a desktop from unpaired clears whatever was cached',
    () async {
      final container = _container();
      final conn = container.read(connectionControllerProvider.notifier);
      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      // Unpaired, but with stale rows still in the store — the state right after
      // an unpair that left data behind.
      await conn.unpair();
      _seedRepo(store, 'left-over-from-before');
      expect(container.read(reposProvider).repos, hasLength(1));

      // Now a server becomes active (what pairWith does on a successful
      // handshake). null -> C is the other half of the transition an
      // "both ids non-null" guard skipped.
      conn.state = MakitConnState(
        servers: [
          PairedServer(
            host: '10.0.0.9',
            port: 8443,
            fingerprint: _fpB,
            bearer: 'b',
            label: 'freshly paired',
          ),
        ],
        activeId: _fpB,
      );
      await Future<void>.delayed(Duration.zero);

      expect(container.read(reposProvider).repos, isEmpty);
    },
  );

  // SPEC-starter-pane-parity D9: the command cache is server-scoped state like everything else in
  // the store. Project ids are host-local (`RepoInfo(id: name…)`), so two
  // desktops with a same-named repo would otherwise serve each other's palettes
  // — and this cache is persisted, so it would outlive the switch.
  test("switching servers clears the previous desktop's command cache", () async {
    final container = _container();
    // The store owns "a server switch invalidates cached data", so it must exist
    // for the cache to be cleared — as it always does in the app, where boot
    // creates it before the socket connects.
    container.read(storeControllerProvider.notifier);
    final conn = container.read(connectionControllerProvider.notifier);
    // Settle on A first: the store clears on any change of server identity,
    // including the null -> A one that boot itself performs.
    await conn.switchTo(_fpA);
    await Future<void>.delayed(Duration.zero);

    await container
        .read(cachedCommandsControllerProvider.notifier)
        .record(
          agent: 'zed',
          projectId: 'makit',
          commands: const [
            SlashCmd(
              name: 'skill:only-on-server-a',
              description: '',
              source: 'skill',
            ),
          ],
        );
    expect(container.read(cachedCommandsControllerProvider), isNotEmpty);

    await conn.switchTo(_fpB);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(cachedCommandsControllerProvider),
      isEmpty,
      reason: "server A's palette must not be offered under server B",
    );
  });

  test('boot (null -> the persisted server) keeps the cached palette', () async {
    // The point of persisting the cache (`desktop_app.dart`) is that a relaunch
    // does not show an empty palette until a session has run. At boot the active
    // server goes null -> A, which is a change of identity by the same test as a
    // real switch — so clearing on it would wipe the blob on every launch, before
    // anything could read it.
    final container = ProviderContainer(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(
            _Storage({
              'paired_servers':
                  '{"servers":[${_json(_srv('10.0.0.1', _fpA, 'work'))}],'
                  '"activeId":"$_fpA"}',
            }),
            transportFactory: _Transport.new,
            browseLan:
                ({Duration timeout = const Duration(seconds: 3)}) async => [],
            rediscoverStall: const Duration(seconds: 30),
          ),
        ),
        // Seeded as `CachedCommandsController.load(prefs)` would at bootstrap,
        // before the socket comes up.
        cachedCommandsControllerProvider.overrideWith(
          (ref) => CachedCommandsController(null, {
            'zed\u0000makit': const [
              SlashCmd(name: 'skill:x', description: '', source: 'skill'),
            ],
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(cachedCommandsControllerProvider),
      isNotEmpty,
      reason: 'a relaunch must not throw away the palette it just loaded',
    );
  });

  test('reconnecting to the SAME server keeps its data', () async {
    final container = _container();
    final conn = container.read(connectionControllerProvider.notifier);
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);
    _seedRepo(store, 'lives-on-server-a');

    // A blip must not blank the screen: switchTo the already-active server is
    // the closest reachable stand-in for a reconnect.
    await conn.switchTo(_fpA);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(reposProvider).repos,
      hasLength(1),
      reason: 'clearing must key on the server, not on socket churn',
    );
  });
}

String _json(Map<String, dynamic> m) =>
    '{${m.entries.map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}').join(',')}}';
