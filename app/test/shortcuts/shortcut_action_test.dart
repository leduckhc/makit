// SPEC-30 decision 16 — the index↔action mapping for the nine group-switch
// shortcuts. Guards against off-by-one drift in switchGroupAtIndex / groupIndex,
// which keymap.dart and keymap_scope.dart consume.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/shortcuts/shortcut_action.dart';

void main() {
  group('switchGroupAtIndex', () {
    test('returns null below range', () {
      expect(ShortcutAction.switchGroupAtIndex(-1), isNull);
    });

    test('maps 0..8 to the 1st..9th group-switch actions', () {
      expect(ShortcutAction.switchGroupAtIndex(0), ShortcutAction.switchGroup1);
      expect(ShortcutAction.switchGroupAtIndex(8), ShortcutAction.switchGroup9);
    });

    test('returns null at the tenth group and beyond', () {
      expect(ShortcutAction.switchGroupAtIndex(9), isNull);
      expect(ShortcutAction.switchGroupAtIndex(100), isNull);
    });
  });

  group('groupIndex', () {
    test('is the 0-based index for each group-switch action', () {
      expect(ShortcutAction.switchGroup1.groupIndex, 0);
      expect(ShortcutAction.switchGroup5.groupIndex, 4);
      expect(ShortcutAction.switchGroup9.groupIndex, 8);
    });

    test('is null for a non-group action', () {
      expect(ShortcutAction.newSession.groupIndex, isNull);
    });

    test('round-trips with switchGroupAtIndex for every valid index', () {
      for (var i = 0; i < 9; i++) {
        expect(ShortcutAction.switchGroupAtIndex(i)!.groupIndex, i);
      }
    });
  });
}
