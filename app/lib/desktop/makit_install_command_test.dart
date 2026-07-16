// Test for the documented makit CLI installer one-liner.
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/desktop_app.dart';

void main() {
  test('makitInstallCommand is the documented curl installer', () {
    expect(makitInstallCommand, startsWith('curl'));
    expect(makitInstallCommand, contains('install.sh'));
  });
}
