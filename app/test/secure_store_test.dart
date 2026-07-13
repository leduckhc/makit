import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/secure_store.dart';

void main() {
  group('FileSecureStore', () {
    late Directory dir;
    late FileSecureStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('makit_secure_store_test');
      store = FileSecureStore(File('${dir.path}/nested/secure_store.json'));
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('read returns null before anything is written', () async {
      expect(await store.read(key: 'paired_server'), isNull);
    });

    test('write then read round-trips a value', () async {
      await store.write(key: 'paired_server', value: '{"host":"1.2.3.4"}');
      expect(await store.read(key: 'paired_server'), '{"host":"1.2.3.4"}');
    });

    test('write persists across store instances (same file)', () async {
      await store.write(key: 'k', value: 'v');
      final reopened = FileSecureStore(
        File('${dir.path}/nested/secure_store.json'),
      );
      expect(await reopened.read(key: 'k'), 'v');
    });

    test('write with null value removes the key', () async {
      await store.write(key: 'k', value: 'v');
      await store.write(key: 'k', value: null);
      expect(await store.read(key: 'k'), isNull);
    });

    test('delete removes the key', () async {
      await store.write(key: 'k', value: 'v');
      await store.delete(key: 'k');
      expect(await store.read(key: 'k'), isNull);
    });
  });
}
