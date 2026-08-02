import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/composer_attachments.dart';
import 'package:makit/transport/media_client.dart';

final _bytes = Uint8List.fromList([1, 2, 3]);

/// An uploader the test drives: each call parks until it is completed or failed.
class _FakeUploader {
  final List<Completer<MediaDescriptor>> calls = [];
  int get count => calls.length;

  MediaUploader get fn => (Uint8List bytes, String mime) {
    final c = Completer<MediaDescriptor>();
    calls.add(c);
    return c.future;
  };

  void succeed(int i, {String id = 'a'}) => calls[i].complete(
    MediaDescriptor(mediaId: id * 64, mime: 'image/png', sizeBytes: 3),
  );
  void fail(int i, Object e) => calls[i].completeError(e);
}

void main() {
  test('an added attachment is staged as uploading, then ready', () async {
    final up = _FakeUploader();
    final a = ComposerAttachments(() => up.fn);

    final pending = a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/png',
      name: 'shot.png',
    );

    expect(a.forKey('s1').single.status, AttachmentStatus.uploading);
    // Cannot send while bytes are in flight: the server would reject an id that
    // does not exist yet.
    expect(a.isSettled('s1'), isFalse);
    expect(a.wireFor('s1'), isEmpty);

    up.succeed(0);
    await pending;

    expect(a.forKey('s1').single.status, AttachmentStatus.ready);
    expect(a.isSettled('s1'), isTrue);
    expect(a.wireFor('s1'), [
      (mediaId: 'a' * 64, mime: 'image/png', name: 'shot.png'),
    ]);
  });

  test('a failed upload keeps the bytes and a readable reason', () async {
    final up = _FakeUploader();
    final a = ComposerAttachments(() => up.fn);
    final pending = a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/png',
      name: 'x.png',
    );
    up.fail(0, const MediaTooLargeException(999));
    await pending;

    final att = a.forKey('s1').single;
    expect(att.status, AttachmentStatus.failed);
    expect(att.error, 'too large to send');
    // Bytes survive so a retry does not make the user pick the file again.
    expect(att.bytes, _bytes);
    expect(
      a.isSettled('s1'),
      isTrue,
      reason: 'failed is settled, just unsendable',
    );
    expect(a.wireFor('s1'), isEmpty);
  });

  test('retry re-uploads the same bytes and can succeed', () async {
    final up = _FakeUploader();
    final a = ComposerAttachments(() => up.fn);
    final first = a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/png',
      name: 'x.png',
    );
    up.fail(0, Exception('offline'));
    await first;
    expect(a.forKey('s1').single.status, AttachmentStatus.failed);

    final second = a.retry('s1', 'l1');
    expect(a.forKey('s1').single.status, AttachmentStatus.uploading);
    up.succeed(1);
    await second;

    expect(a.forKey('s1').single.isReady, isTrue);
    expect(up.count, 2);
  });

  test('removing an attachment mid-upload does not resurrect it', () async {
    // The user changed their mind while the bytes were on the wire. A late
    // success must not put a chip back on screen.
    final up = _FakeUploader();
    final a = ComposerAttachments(() => up.fn);
    final pending = a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/png',
      name: 'x.png',
    );
    a.remove('s1', 'l1');
    expect(a.forKey('s1'), isEmpty);

    up.succeed(0);
    await pending;

    expect(a.forKey('s1'), isEmpty);
  });

  test('attachments are scoped per composer key', () async {
    final up = _FakeUploader();
    final a = ComposerAttachments(() => up.fn);
    final p1 = a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/png',
      name: 'a.png',
    );
    final p2 = a.add(
      key: 's2',
      localId: 'l2',
      bytes: _bytes,
      mime: 'image/png',
      name: 'b.png',
    );
    up.succeed(0, id: 'a');
    up.succeed(1, id: 'b');
    await Future.wait([p1, p2]);

    expect(a.forKey('s1').single.name, 'a.png');
    expect(a.forKey('s2').single.name, 'b.png');
    a.clear('s1');
    expect(a.forKey('s1'), isEmpty);
    expect(
      a.forKey('s2'),
      hasLength(1),
      reason: 'the other session is untouched',
    );
  });

  test('clear after send drops the staged list entirely', () async {
    final up = _FakeUploader();
    final a = ComposerAttachments(() => up.fn);
    final pending = a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/png',
      name: 'a.png',
    );
    up.succeed(0);
    await pending;

    a.clear('s1');
    expect(a.forKey('s1'), isEmpty);
    expect(a.isSettled('s1'), isTrue);
  });

  test(
    'a send keeps failed attachments staged and drops only the sent ones',
    () async {
      // A failed image must not vanish when the user sends their text: the chip and
      // its retry are the only signal that it was not delivered.
      final up = _FakeUploader();
      final a = ComposerAttachments(() => up.fn);
      final ok = a.add(
        key: 's1',
        localId: 'ok',
        bytes: _bytes,
        mime: 'image/png',
        name: 'ok.png',
      );
      final bad = a.add(
        key: 's1',
        localId: 'bad',
        bytes: _bytes,
        mime: 'image/png',
        name: 'bad.png',
      );
      up.succeed(0);
      up.fail(1, Exception('offline'));
      await Future.wait([ok, bad]);

      expect(a.wireFor('s1').single.name, 'ok.png');
      a.clearSent('s1');

      final left = a.forKey('s1');
      expect(left.single.localId, 'bad');
      expect(left.single.status, AttachmentStatus.failed);
      expect(left.single.bytes, _bytes, reason: 'retry needs the bytes');
    },
  );

  test(
    'the uploader is resolved per upload, so a reconnect cannot strand one',
    () async {
      // The notifier must NOT capture the uploader: if it did, the provider would
      // have to watch the endpoint, and a reconnect would rebuild the notifier and
      // discard staged attachments mid-flight.
      MediaUploader? current;
      final a = ComposerAttachments(() => current);
      final first = a.add(
        key: 's1',
        localId: 'l1',
        bytes: _bytes,
        mime: 'image/png',
        name: 'a.png',
      );
      await first;
      expect(
        a.forKey('s1').single.status,
        AttachmentStatus.failed,
        reason: 'no endpoint yet',
      );

      // A server appears. Retrying uses the NEW uploader without rebuilding.
      final up = _FakeUploader();
      current = up.fn;
      final retry = a.retry('s1', 'l1');
      up.succeed(0);
      await retry;
      expect(a.forKey('s1').single.isReady, isTrue);
    },
  );

  test('with no uploader, attaching fails loudly instead of hanging', () async {
    // Unpaired / fake-data mode: a chip stuck on a spinner forever would be the
    // worst outcome.
    final a = ComposerAttachments(() => null);

    await a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/png',
      name: 'a.png',
    );

    final att = a.forKey('s1').single;
    expect(att.status, AttachmentStatus.failed);
    expect(att.error, contains('not connected'));
  });

  test('the wire descriptors carry the REAL mime, not an assumed png', () async {
    // The optimistic bubble (which wins the seq-collision dedup against the
    // server echo) renders from these records, so a hardcoded mime would make a
    // JPEG render as a PNG forever.
    final up = _FakeUploader();
    final a = ComposerAttachments(() => up.fn);
    final pending = a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/jpeg',
      name: 'photo.jpg',
    );
    up.succeed(0);
    await pending;

    expect(a.wireFor('s1'), [
      (mediaId: 'a' * 64, mime: 'image/jpeg', name: 'photo.jpg'),
    ]);
  });

  test('two staged attachments both reach the wire, in order', () async {
    final up = _FakeUploader();
    final a = ComposerAttachments(() => up.fn);
    final p1 = a.add(
      key: 's1',
      localId: 'l1',
      bytes: _bytes,
      mime: 'image/png',
      name: '1.png',
    );
    final p2 = a.add(
      key: 's1',
      localId: 'l2',
      bytes: _bytes,
      mime: 'image/png',
      name: '2.png',
    );
    up.succeed(0, id: 'a');
    up.succeed(1, id: 'b');
    await Future.wait([p1, p2]);

    expect(a.wireFor('s1'), [
      (mediaId: 'a' * 64, mime: 'image/png', name: '1.png'),
      (mediaId: 'b' * 64, mime: 'image/png', name: '2.png'),
    ]);
  });
}
