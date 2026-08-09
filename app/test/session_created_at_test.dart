import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/codec.dart';

/// SPEC-47 D12: `SessionDTO.createdAt?` on the wire maps to a **nullable**
/// `Session.createdAt`. Absent → null (never a fabricated epoch-0 age).
void main() {
  Session decodeOne(Map<String, dynamic> j) =>
      WireCodec.decodeSessions([j])!.single;

  test('createdAt is parsed when present', () {
    final s = decodeOne({
      'id': 's1',
      'projectId': 'p1',
      'agent': 'pi',
      'createdAt': 1700000000000,
    });
    expect(s.createdAt, 1700000000000);
  });

  test('createdAt is null when absent (not zero)', () {
    final s = decodeOne({'id': 's1', 'projectId': 'p1', 'agent': 'pi'});
    expect(s.createdAt, isNull);
  });

  test('a non-numeric createdAt decodes to null rather than throwing', () {
    final s = decodeOne({
      'id': 's1',
      'projectId': 'p1',
      'agent': 'pi',
      'createdAt': 'nonsense',
    });
    expect(s.createdAt, isNull);
  });

  test('copyWith preserves createdAt', () {
    final s = decodeOne({
      'id': 's1',
      'projectId': 'p1',
      'agent': 'pi',
      'createdAt': 42,
    });
    expect(s.copyWith(title: 'x').createdAt, 42);
  });
}
