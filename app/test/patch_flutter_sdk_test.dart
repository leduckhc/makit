// Tests for tool/patch_flutter_sdk.sh, the in-place Flutter SDK patcher.
// See FLUTTER-BUMP-HANDOUT.md section 5.
//
// The script must survive an SDK bump.
// Its most dangerous failure is not a crash.
// It is a report of success after doing nothing.
// Flutter 3.47.0 moved the #182400 call site one level deeper.
// The literal anchor then did not match, and the script said "already patched".
// The unpatched bug next appears as hundreds of SkSL lines in a macOS build.
// Every case below pins a report that a reader can tell apart from the others.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The #182400 call site as it appears in Flutter 3.44.9 — the `else` block is
/// 8 spaces deep.
const _shader344 = r'''
class ShaderCompiler {
  Future<bool> compileShader() async {
      if (!retryResult.succeeded) {
        _logger.printError('impellerc failure: ${retryResult.stderr}');
        return false;
      } else {
        _logger.printError(
          'warning: Shader `${input.path}` is incompatible with SkSL. This '
          'shader will not load when running with the Skia backend.',
        );
        _logger.printError('impellerc failure: ${result.stderr}');
      }
    return true;
  }
}
''';

/// The same call site in Flutter 3.47.0, one level deeper (10 spaces).
/// The logic is the same. Only the indentation differs.
/// This is the case that silently did nothing.
const _shader347 = r'''
class ShaderCompiler {
  Future<bool> compileShader() async {
    if (needsRetry) {
        if (!retryResult.succeeded) {
          _logger.printError('impellerc failure: ${retryResult.stderr}');
          return false;
        } else {
          _logger.printError(
            'warning: Shader `${input.path}` is incompatible with SkSL. This '
            'shader will not load when running with the Skia backend.',
          );
          _logger.printError('impellerc failure: ${result.stderr}');
        }
    }
    return true;
  }
}
''';

/// A possible future refactor: the warning is gone.
/// Upstream may fix it another way, or move it.
/// The patch then has nothing to attach to, and must say so.
const _shaderRefactored = r'''
class ShaderCompiler {
  Future<bool> compileShader() async {
    if (!result.succeeded) {
      _logger.printError('impellerc failure: ${result.stderr}');
      return false;
    }
    return true;
  }
}
''';

const _windowClasses = [
  '_WindowCreationRequest',
  '_Size',
  '_Offset',
  '_Rect',
  '_Constraints',
];

String _windowFile({List<String> classes = _windowClasses}) {
  final buf = StringBuffer("import 'dart:ffi';\n\n");
  for (final name in classes) {
    buf.writeln('final class $name extends Struct {');
    buf.writeln('  @Int64()');
    buf.writeln('  external int value;');
    buf.writeln('}');
    buf.writeln();
  }
  return buf.toString();
}

void main() {
  // Tests run with CWD = app/, and the script is bash-only, so POSIX
  // separators are correct here.
  final script = '${Directory.current.path}/tool/patch_flutter_sdk.sh';

  late Directory sdk;
  late File windowFile;
  late File shaderFile;

  setUp(() {
    sdk = Directory.systemTemp.createTempSync('fake_flutter_sdk');
    windowFile = File(
      '${sdk.path}/packages/flutter/lib/src/widgets/_window_macos.dart',
    )..createSync(recursive: true);
    shaderFile = File(
      '${sdk.path}/packages/flutter_tools/lib/src/build_system/tools/'
      'shader_compiler.dart',
    )..createSync(recursive: true);
    windowFile.writeAsStringSync(_windowFile());
    shaderFile.writeAsStringSync(_shader344);
  });

  tearDown(() => sdk.deleteSync(recursive: true));

  ProcessResult run() => Process.runSync(
    'bash',
    [script],
    environment: {'FLUTTER_ROOT': sdk.path},
  );

  group('#182400 — SkSL stderr dump', () {
    test('patches the 3.44.9 call site', () {
      final r = run();
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(
        shaderFile.readAsStringSync(),
        contains(r"_logger.printTrace('impellerc failure: ${result.stderr}');"),
      );
    });

    test('patches the 3.47.0 call site, which is nested one level deeper', () {
      shaderFile.writeAsStringSync(_shader347);
      final r = run();
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final out = shaderFile.readAsStringSync();
      expect(
        out,
        contains(r"_logger.printTrace('impellerc failure: ${result.stderr}');"),
        reason: 'indentation must not decide whether the patch applies',
      );
      // The other two printError call sites are unrelated and must survive.
      expect(
        out,
        contains(
          r"_logger.printError('impellerc failure: ${retryResult.stderr}');",
        ),
        reason: 'only the call site after the Skia warning may be downgraded',
      );
    });

    test('keeps the concise one-line warning', () {
      final r = run();
      // Both guards matter.
      // A script that failed before it touched the fixture leaves the warning.
      // The test would then pass for the one reason it must rule out.
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(
        r.stdout,
        contains('[182400] silenced'),
        reason: 'the warning only survived something if the patch ran',
      );
      expect(
        shaderFile.readAsStringSync(),
        contains('is incompatible with SkSL'),
      );
    });

    test('is idempotent, and says so', () {
      run();
      final afterFirst = shaderFile.readAsStringSync();
      final r = run();
      expect(r.exitCode, 0);
      expect(r.stdout, contains('[182400] already patched'));
      expect(shaderFile.readAsStringSync(), afterFirst);
    });

    test(
      'fails loudly when the anchor is gone, rather than claiming success',
      () {
        shaderFile.writeAsStringSync(_shaderRefactored);
        final r = run();
        expect(
          r.exitCode,
          isNot(0),
          reason:
              'an unapplied patch must not exit 0 — §5 says stop and '
              're-derive, which nobody does if the script prints OK',
        );
        expect(
          '${r.stdout}${r.stderr}',
          contains('182400'),
          reason: 'the report must name which fix stopped applying',
        );
        expect(
          r.stdout,
          isNot(contains('[182400] already patched')),
          reason: '"already patched" on an unpatched file is the actual bug',
        );
      },
    );
  });

  group('#188060 — AOT windowing structs', () {
    test('patches all five structs', () {
      final r = run();
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains('patched 5 class(es)'));
      final out = windowFile.readAsStringSync();
      for (final name in _windowClasses) {
        expect(
          out,
          contains("@pragma('vm:entry-point')\nfinal class $name"),
          reason: '$name must be force-retained against the tree-shaker',
        );
      }
    });

    test('is idempotent', () {
      run();
      final afterFirst = windowFile.readAsStringSync();
      final r = run();
      expect(r.exitCode, 0);
      expect(r.stdout, contains('patched 0 class(es)'));
      expect(windowFile.readAsStringSync(), afterFirst);
    });

    test('distinguishes a renamed struct from an already-patched one', () {
      // Upstream renames _Rect.
      // A report of "patched 4; 1 already patched" would read like a clean run.
      windowFile.writeAsStringSync(
        _windowFile(
          classes: const [
            '_WindowCreationRequest',
            '_Size',
            '_Offset',
            '_Constraints',
          ],
        ),
      );
      final r = run();
      expect(
        r.exitCode,
        isNot(0),
        reason: 'a struct that no longer exists means the AOT crash is back',
      );
      expect('${r.stdout}${r.stderr}', contains('_Rect'));
    });
  });

  group('SDK layout', () {
    // The failure must name the absent file.
    // A typo in the script also exits non-zero.
    // Each patch target has its own test, so neither branch can rot.
    for (final (label, victim) in [
      ('shader_compiler.dart', () => shaderFile),
      ('_window_macos.dart', () => windowFile),
    ]) {
      test('fails, naming the file, when $label is missing', () {
        victim().deleteSync();
        final r = run();
        expect(
          r.exitCode,
          isNot(0),
          reason: 'a missing file means the patch did not apply',
        );
        expect(
          '${r.stdout}${r.stderr}',
          contains('$label not found'),
          reason: 'the report must name the file that moved',
        );
      });
    }
  });
}
