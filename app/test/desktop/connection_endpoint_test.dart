import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/connection_endpoint.dart';

void main() {
  test('loopback and empty hosts render as localhost', () {
    expect(formatEndpoint('127.0.0.1', 7788), 'localhost:7788');
    expect(formatEndpoint('', 7788), 'localhost:7788');
    expect(formatEndpoint(null, 7788), 'localhost:7788');
    expect(formatEndpoint('::1', 7788), 'localhost:7788');
  });

  test('non-loopback host is shown verbatim', () {
    expect(formatEndpoint('100.119.58.97', 7788), '100.119.58.97:7788');
  });

  test('no port means nothing to show', () {
    expect(formatEndpoint('127.0.0.1', null), isNull);
    expect(formatEndpoint(null, null), isNull);
  });
}
