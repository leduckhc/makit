// Switching servers must invalidate the cached store: repos, sessions and
// transcripts all belonged to the previous desktop. Snapshots replace wholesale
// when they arrive, but until then the list would show the old server's repos —
// indefinitely if the new one is unreachable.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

    // Pretend server A's snapshot landed.
    store.state = store.state.copyWith(
      repos: const [
        RepoInfo(
          id: 'a-only',
          name: 'lives-on-server-a',
          path: '/a',
          pinned: false,
          lastActivityAt: 0,
          isGitRepo: true,
          defaultBranch: 'main',
          currentBranch: 'main',
          worktrees: [],
        ),
      ],
    );
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
}

String _json(Map<String, dynamic> m) =>
    '{${m.entries.map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}').join(',')}}';
