import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key/value secret store used by [ConnectionController] to persist the
/// paired-server record (host, port, fingerprint, bearer).
///
/// Two implementations back this abstraction:
///  - [KeychainSecureStore] — iOS Keychain / Android Keystore via
///    `flutter_secure_storage`. The default on every platform except macOS.
///  - [FileSecureStore] — a file under Application Support, used on macOS to
///    avoid the login-keychain password prompt. The desktop app ships ad-hoc
///    signed ("Sign to Run Locally"), so the file-based keychain re-prompts on
///    every rebuild because the item's ACL is bound to an unstable code
///    signature. A file store trades that away for weaker at-rest protection.
abstract interface class SecureStore {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String? value});
  Future<void> delete({required String key});
}

/// [SecureStore] backed by the OS keychain/keystore via `flutter_secure_storage`.
class KeychainSecureStore implements SecureStore {
  const KeychainSecureStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String? value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

/// [SecureStore] backed by a single JSON file. Used on macOS where the ad-hoc
/// signed desktop app would otherwise trigger a login-password prompt on every
/// keychain access.
class FileSecureStore implements SecureStore {
  FileSecureStore(this._file);

  final File _file;

  Future<Map<String, dynamic>> _load() async {
    if (!await _file.exists()) return <String, dynamic>{};
    final raw = await _file.readAsString();
    if (raw.isEmpty) return <String, dynamic>{};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _save(Map<String, dynamic> data) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(data), flush: true);
    // Best-effort: restrict to the current user. No stdlib chmod on File.
    try {
      await Process.run('chmod', ['600', _file.path]);
    } catch (_) {
      // Non-fatal: the file still lives in the user's Application Support dir.
    }
  }

  @override
  Future<String?> read({required String key}) async {
    final data = await _load();
    return data[key] as String?;
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    final data = await _load();
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
    await _save(data);
  }

  @override
  Future<void> delete({required String key}) async {
    final data = await _load();
    data.remove(key);
    await _save(data);
  }
}

/// Platform-appropriate [SecureStore]: [FileSecureStore] on macOS, otherwise
/// [KeychainSecureStore] over the default [FlutterSecureStorage].
SecureStore defaultSecureStore() {
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '.';
    final path =
        '$home/Library/Application Support/dev.getmakit.app/secure_store.json';
    return FileSecureStore(File(path));
  }
  return const KeychainSecureStore(FlutterSecureStorage());
}
