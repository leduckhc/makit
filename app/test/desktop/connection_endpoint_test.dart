import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/connection_endpoint.dart';

void main() {
  test('loopback and empty hosts render as localhost', () {
    expect(formatEndpoint('127.0.0.1', 8787), 'localhost:8787');
    expect(formatEndpoint('', 8787), 'localhost:8787');
    expect(formatEndpoint(null, 8787), 'localhost:8787');
    expect(formatEndpoint('::1', 8787), 'localhost:8787');
  });

  test('non-loopback host is shown verbatim', () {
    expect(formatEndpoint('100.119.58.97', 8787), '100.119.58.97:8787');
  });

  test('no port means nothing to show', () {
    expect(formatEndpoint('127.0.0.1', null), isNull);
    expect(formatEndpoint(null, null), isNull);
  });
}
