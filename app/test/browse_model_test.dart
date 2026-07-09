import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

void main() {
  group('FolderEntry.fromJson', () {
    test('maps a valid entry', () {
      final e = FolderEntry.fromJson({
        'name': 'makit',
        'path': '/Users/le/Work/makit',
        'isRepo': true,
      });
      expect(e, isNotNull);
      expect(e!.name, 'makit');
      expect(e.path, '/Users/le/Work/makit');
      expect(e.isRepo, isTrue);
    });

    test('defaults isRepo to false when missing or non-bool', () {
      expect(
        FolderEntry.fromJson({'name': 'a', 'path': '/a'})!.isRepo,
        isFalse,
      );
      expect(
        FolderEntry.fromJson({
          'name': 'a',
          'path': '/a',
          'isRepo': 'yes',
        })!.isRepo,
        isFalse,
      );
    });

    test('returns null when name or path is missing or wrong-typed', () {
      expect(FolderEntry.fromJson({'path': '/a'}), isNull);
      expect(FolderEntry.fromJson({'name': 'a'}), isNull);
      expect(FolderEntry.fromJson({'name': 1, 'path': '/a'}), isNull);
      expect(FolderEntry.fromJson({'name': 'a', 'path': 2}), isNull);
      expect(FolderEntry.fromJson({}), isNull);
    });
  });

  group('BrowseResult.fromJson', () {
    test('parses path, parent, and entries', () {
      final r = BrowseResult.fromJson({
        'path': '/Users/le/Work',
        'parent': '/Users/le',
        'entries': [
          {'name': 'makit', 'path': '/Users/le/Work/makit', 'isRepo': true},
          {'name': 'notes', 'path': '/Users/le/Work/notes', 'isRepo': false},
        ],
      });
      expect(r.path, '/Users/le/Work');
      expect(r.parent, '/Users/le');
      expect(r.entries, hasLength(2));
      expect(r.entries.first.isRepo, isTrue);
      expect(r.entries[1].name, 'notes');
    });

    test('parent is null at the filesystem root', () {
      final r = BrowseResult.fromJson({
        'path': '/',
        'entries': const <Map<String, dynamic>>[],
      });
      expect(r.path, '/');
      expect(r.parent, isNull);
      expect(r.entries, isEmpty);
    });

    test('non-string parent becomes null', () {
      final r = BrowseResult.fromJson({
        'path': '/x',
        'parent': 42,
        'entries': const <Map<String, dynamic>>[],
      });
      expect(r.parent, isNull);
    });

    test('skips malformed entries instead of throwing', () {
      final r = BrowseResult.fromJson({
        'path': '/x',
        'parent': '/',
        'entries': [
          {'name': 'ok', 'path': '/x/ok'},
          {'name': 'bad'}, // missing path -> skipped
          'not-a-map', // wrong type -> skipped
          {'path': '/x/nope'}, // missing name -> skipped
        ],
      });
      expect(r.entries, hasLength(1));
      expect(r.entries.single.name, 'ok');
    });

    test('missing path falls back to empty and never throws', () {
      final r = BrowseResult.fromJson({});
      expect(r.path, '');
      expect(r.parent, isNull);
      expect(r.entries, isEmpty);
    });

    test('non-list entries yields empty list', () {
      final r = BrowseResult.fromJson({'path': '/x', 'entries': 'nope'});
      expect(r.entries, isEmpty);
    });
  });
}
