/// Composer attachment state (SPEC-33) — the images staged for the next
/// message, and their upload lifecycle.
///
/// Held app-wide and keyed by session (deliberately **not** `autoDispose`, like
/// `composerDraftsProvider`) so an in-flight upload survives the composer widget
/// being disposed and recreated: switching a desktop worktree or splitting a
/// pane must not silently lose the screenshot the user just pasted.
///
/// The bytes live here, not only on the server, for two reasons: the chip strip
/// shows a local thumbnail before (and without) any round trip, and a failed
/// upload can be retried without asking the user to pick the file again.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/legacy.dart';

import '../transport/media_client.dart';
import 'media.dart';

/// Where an attachment is in its journey to the server.
enum AttachmentStatus {
  /// Bytes are on the wire; the message cannot be sent yet.
  uploading,

  /// Stored — `mediaId` is set and can be named in `send.message`.
  ready,

  /// Upload failed; `error` explains it and the user can retry.
  failed,
}

/// One staged attachment.
class ComposerAttachment {
  const ComposerAttachment({
    required this.localId,
    required this.bytes,
    required this.mime,
    required this.name,
    this.status = AttachmentStatus.uploading,
    this.mediaId,
    this.error,
  });

  /// Client-side identity, stable across status changes (the `mediaId` is not
  /// known until the upload lands, and two different files can be staged at
  /// once, so neither name nor bytes can key the list).
  final String localId;
  final Uint8List bytes;
  final String mime;

  /// Display name — also sent as a hint, never used as a path by the server.
  final String name;
  final AttachmentStatus status;

  /// Server-assigned content hash. Non-null exactly when [status] is ready.
  final String? mediaId;
  final String? error;

  bool get isReady => status == AttachmentStatus.ready && mediaId != null;

  /// Note the asymmetry: `status`/`mediaId` are preserved when omitted, but
  /// `error` is **cleared** unless passed. Both transitions out of `failed`
  /// (retry, then success) want the stale reason gone, so that is the useful
  /// default — but it is easy to misread, hence this note.
  ComposerAttachment copyWith({
    AttachmentStatus? status,
    String? mediaId,
    String? error,
  }) => ComposerAttachment(
    localId: localId,
    bytes: bytes,
    mime: mime,
    name: name,
    status: status ?? this.status,
    mediaId: mediaId ?? this.mediaId,
    error: error,
  );
}

/// Attachments staged per composer key (a session id, or a pre-start key —
/// whatever the composer already uses for its draft text).
class ComposerAttachments
    extends StateNotifier<Map<String, List<ComposerAttachment>>> {
  ComposerAttachments(this._resolveUploader) : super(const {});

  /// Resolves the current uploader, or null when nothing is paired/attached.
  ///
  /// A *resolver*, not a captured `MediaUploader`: capturing one would mean the
  /// provider has to `watch` the endpoint, so a reconnect or re-pair would
  /// rebuild this notifier and discard every staged attachment while in-flight
  /// uploads wrote into the dead instance. The notifier is deliberately
  /// long-lived (see the library doc), so it resolves the uploader per upload
  /// instead.
  final MediaUploader? Function() _resolveUploader;

  bool get canAttach => _resolveUploader() != null;

  List<ComposerAttachment> forKey(String key) => state[key] ?? const [];

  /// Whether [key] is safe to send: no upload still in flight.
  bool isSettled(String key) =>
      !forKey(key).any((a) => a.status == AttachmentStatus.uploading);

  /// The descriptors to hand to the send path — ready ones only.
  ///
  /// Carries the real `mime` even though the wire does not need it (the server
  /// resolves the id against its own store): the app's OPTIMISTIC bubble is the
  /// copy that survives the seq-collision dedup, so it has to render with the
  /// true type rather than an assumed one.
  List<({String mediaId, String mime, String name})> wireFor(String key) => [
    for (final a in forKey(key))
      if (a.isReady) (mediaId: a.mediaId!, mime: a.mime, name: a.name),
  ];

  /// Stage [bytes] under [localId] and upload them. Completes when the upload
  /// settles (ready or failed) — [localId] is supplied by the caller, not
  /// returned.
  Future<void> add({
    required String key,
    required String localId,
    required Uint8List bytes,
    required String mime,
    required String name,
  }) async {
    _put(
      key,
      ComposerAttachment(
        localId: localId,
        bytes: bytes,
        mime: mime,
        name: name,
      ),
    );
    await _upload1(key, localId);
  }

  /// Retry a failed upload with the bytes we still hold.
  Future<void> retry(String key, String localId) async {
    final current = forKey(key).firstWhere(
      (a) => a.localId == localId,
      orElse: () => throw StateError('no attachment $localId'),
    );
    if (current.status == AttachmentStatus.uploading) return;
    _replace(
      key,
      localId,
      current.copyWith(status: AttachmentStatus.uploading),
    );
    await _upload1(key, localId);
  }

  void remove(String key, String localId) {
    final list = forKey(key);
    final next = list.where((a) => a.localId != localId).toList();
    if (next.length == list.length) return;
    _set(key, next);
  }

  /// Drop everything for [key].
  void clear(String key) {
    if (!state.containsKey(key)) return;
    state = Map.of(state)..remove(key);
  }

  /// Drop only the attachments that were actually sent, keeping failed ones
  /// staged — called after a send.
  ///
  /// A message can be sent while an attachment is `failed` (only an *in-flight*
  /// upload blocks sending), and only ready ones reach the wire. Clearing the
  /// whole list there would make the failed image vanish with no explanation and
  /// no way to retry it; keeping the chip is the honest outcome, and the user can
  /// retry and send again. Blocking the send instead would trap someone who just
  /// wants to send their text.
  void clearSent(String key) {
    final kept = forKey(key).where((a) => !a.isReady).toList();
    _set(key, kept);
  }

  Future<void> _upload1(String key, String localId) async {
    final upload = _resolveUploader();
    final staged = forKey(key).where((a) => a.localId == localId).firstOrNull;
    if (staged == null) return;
    if (upload == null) {
      _replace(
        key,
        localId,
        staged.copyWith(
          status: AttachmentStatus.failed,
          error: 'not connected to a makit server',
        ),
      );
      return;
    }
    try {
      final d = await upload(staged.bytes, staged.mime);
      // The user may have removed it (or sent the message) mid-upload; don't
      // resurrect an attachment that is no longer staged.
      if (!forKey(key).any((a) => a.localId == localId)) return;
      _replace(
        key,
        localId,
        staged.copyWith(status: AttachmentStatus.ready, mediaId: d.mediaId),
      );
    } catch (e) {
      if (!forKey(key).any((a) => a.localId == localId)) return;
      _replace(
        key,
        localId,
        staged.copyWith(status: AttachmentStatus.failed, error: _messageFor(e)),
      );
    }
  }

  /// Exception → something a person can act on.
  static String _messageFor(Object e) => switch (e) {
    MediaTooLargeException() => 'too large to send',
    MediaUnsupportedTypeException() => 'this file type is not supported',
    _ => 'upload failed — tap to retry',
  };

  void _put(String key, ComposerAttachment a) => _set(key, [...forKey(key), a]);

  void _replace(String key, String localId, ComposerAttachment next) =>
      _set(key, [
        for (final a in forKey(key))
          if (a.localId == localId) next else a,
      ]);

  void _set(String key, List<ComposerAttachment> list) {
    if (list.isEmpty) {
      clear(key);
      return;
    }
    state = {...state, key: list};
  }
}

final composerAttachmentsProvider =
    StateNotifierProvider<
      ComposerAttachments,
      Map<String, List<ComposerAttachment>>
    >(
      // `read`, not `watch`: see `_resolveUploader`. Widgets that need to react
      // to the endpoint appearing/disappearing watch `mediaUploaderProvider`
      // directly (see `canAttach` in ui/composer/attachment_controller.dart).
      (ref) => ComposerAttachments(() => ref.read(mediaUploaderProvider)),
    );
