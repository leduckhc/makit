// Unit tests for [ProfileScopedPrefs] (SPEC-profiles D11).
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/prefs/profile_scoped_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SharedPreferences> raw() => SharedPreferences.getInstance();

  group('ProfileScopedPrefs', () {
    test('a namespaced scope prefixes every accessor', () async {
      final prefs = await raw();
      final scope = ProfileScopedPrefs(prefs, 'a1b2c3d4.');

      await scope.setString('host', 'h');
      await scope.setInt('port', 7813);
      await scope.setBool('lan', true);
      await scope.setStringList('list', ['a', 'b']);

      // Visible through the scope by the bare key...
      expect(scope.getString('host'), 'h');
      expect(scope.getInt('port'), 7813);
      expect(scope.getBool('lan'), isTrue);
      expect(scope.getStringList('list'), ['a', 'b']);
      // ...and stored under the prefixed key.
      expect(prefs.getString('a1b2c3d4.host'), 'h');
      expect(prefs.getInt('a1b2c3d4.port'), 7813);
      // The bare key must NOT be written: that is the legacy profile's slot.
      expect(prefs.getString('host'), isNull);
    });

    test('the legacy (empty) scope reads and writes bare keys', () async {
      final prefs = await raw();
      final scope = ProfileScopedPrefs(prefs, '');
      await scope.setInt('desktop_server_port', 7777);
      expect(prefs.getInt('desktop_server_port'), 7777);
      expect(scope.getInt('desktop_server_port'), 7777);
    });

    // The point of the whole class: two profiles must not see each other.
    test('two scopes are mutually invisible', () async {
      final prefs = await raw();
      final a = ProfileScopedPrefs(prefs, 'aaa.');
      final b = ProfileScopedPrefs(prefs, 'bbb.');

      await a.setInt('port', 7801);
      await b.setInt('port', 7802);

      expect(a.getInt('port'), 7801);
      expect(b.getInt('port'), 7802);
    });

    test('the legacy scope does not see a namespaced profile key', () async {
      final prefs = await raw();
      await ProfileScopedPrefs(prefs, 'dev.').setInt('port', 7801);
      expect(ProfileScopedPrefs(prefs, '').getInt('port'), isNull);
    });

    test('containsKey and remove respect the scope', () async {
      final prefs = await raw();
      final scope = ProfileScopedPrefs(prefs, 'x.');
      await scope.setString('k', 'v');
      expect(scope.containsKey('k'), isTrue);
      expect(prefs.containsKey('k'), isFalse);

      expect(await scope.remove('k'), isTrue);
      expect(scope.containsKey('k'), isFalse);
    });

    test('keys() strips the prefix and hides other scopes', () async {
      final prefs = await raw();
      await ProfileScopedPrefs(prefs, 'mine.').setString('a', '1');
      await ProfileScopedPrefs(prefs, 'mine.').setString('b', '2');
      await ProfileScopedPrefs(prefs, 'other.').setString('c', '3');

      final mine = ProfileScopedPrefs(prefs, 'mine.').keys();
      expect(mine, {'a', 'b'});
      expect(mine, isNot(contains('c')));
    });

    test(
      'clearScope removes only this profile and reports the count',
      () async {
        final prefs = await raw();
        final mine = ProfileScopedPrefs(prefs, 'mine.');
        final other = ProfileScopedPrefs(prefs, 'other.');
        await mine.setString('a', '1');
        await mine.setString('b', '2');
        await other.setString('c', '3');

        expect(await mine.clearScope(), 2);
        expect(mine.keys(), isEmpty);
        expect(other.getString('c'), '3');
      },
    );

    // Guard: an unscoped view cannot tell one profile's keys from another's, so
    // wiping through it would take everything — including the legacy profile.
    test('clearScope refuses to run on an unscoped view', () async {
      final prefs = await raw();
      await ProfileScopedPrefs(prefs, '').setString('keepme', 'v');
      expect(await ProfileScopedPrefs(prefs, '').clearScope(), -1);
      expect(prefs.getString('keepme'), 'v');
    });

    test('unscoped named constructor is the identity scope', () async {
      final prefs = await raw();
      final scope = ProfileScopedPrefs.unscoped(prefs);
      expect(scope.prefix, '');
      await scope.setString('theme', 'dark');
      expect(prefs.getString('theme'), 'dark');
    });

    test('a missing key reads null through every accessor', () async {
      final scope = ProfileScopedPrefs(await raw(), 'p.');
      expect(scope.getString('nope'), isNull);
      expect(scope.getInt('nope'), isNull);
      expect(scope.getBool('nope'), isNull);
      expect(scope.getStringList('nope'), isNull);
      expect(scope.containsKey('nope'), isFalse);
    });
  });
}
