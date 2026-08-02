/// Sources of attachment bytes (SPEC-33): the system clipboard and the file /
/// photo pickers.
///
/// Isolated behind plain functions so the composer and its tests never touch a
/// plugin: every platform channel this feature needs lives here.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../transport/media_client.dart';

/// Bytes plus the metadata needed to upload and label them.
typedef PickedImage = ({Uint8List bytes, String mime, String name});

/// A picked file is bigger than makit will store. Thrown (not returned as null)
/// so the caller can tell it apart from a cancelled pick and say why.
class AttachmentTooLargeException implements Exception {
  const AttachmentTooLargeException(this.sizeBytes);
  final int sizeBytes;
  @override
  String toString() =>
      'that image is ${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB — the '
      'limit is ${kMaxAttachmentBytes ~/ (1024 * 1024)} MB';
}

/// How long to wait for the platform clipboard before giving up (see
/// [readClipboardImage]).
const Duration _clipboardTimeout = Duration(seconds: 5);

/// Reads an image off the system clipboard, or null when there is none.
///
/// Flutter's own `Clipboard` is text-only, hence `super_clipboard`. It reports
/// macOS TIFF and Windows DIB as PNG for us, so one format check covers every
/// platform. Returns null (never throws) on an unsupported platform or an empty
/// clipboard, so ⌘V falls through to a normal text paste.
Future<PickedImage?> readClipboardImage() async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return null; // platform without clipboard support
  try {
    final reader = await clipboard.read();
    if (!reader.canProvide(Formats.png)) return null;
    // Bounded: `getFile` is callback-based, and a channel that invokes neither
    // the value callback nor `onError` would leave ⌘V doing nothing at all —
    // not even the text paste the composer falls back to.
    final bytes = await _readFile(
      reader,
      Formats.png,
    ).timeout(_clipboardTimeout, onTimeout: () => null);
    if (bytes == null || bytes.isEmpty) return null;
    return (bytes: bytes, mime: 'image/png', name: 'pasted.png');
  } catch (e) {
    // A clipboard we cannot read is a text paste, not an error dialog.
    debugPrint('[makit] clipboard image read failed: $e');
    return null;
  }
}

/// `getFile` is callback-shaped; adapt it to a future.
Future<Uint8List?> _readFile(
  ClipboardReader reader,
  SimpleFileFormat format,
) async {
  final done = Completer<Uint8List?>();
  reader.getFile(
    format,
    (file) async {
      try {
        final stream = file.getStream();
        // BytesBuilder, not List<int>: a growable int list boxes every element, so a
        // ~24 MB screenshot would cost an order of magnitude more memory and
        // then be copied again on the way to a Uint8List.
        final builder = BytesBuilder(copy: false);
        await for (final chunk in stream) {
          builder.add(chunk);
          // Stop just past the cap. The bytes are still returned so the normal
          // upload path reports "too large to send" on the chip, exactly as it
          // does for an oversized picked file — a silently ignored ⌘V would be
          // the worst of the three outcomes.
          if (builder.length > kMaxAttachmentBytes) break;
        }
        if (!done.isCompleted) done.complete(builder.takeBytes());
      } catch (_) {
        if (!done.isCompleted) done.complete(null);
      }
    },
    onError: (_) {
      if (!done.isCompleted) done.complete(null);
    },
  );
  return done.future;
}

/// Where a picked image came from — the entries in the paperclip menu.
enum AttachSource { photoLibrary, camera, file }

/// True where the camera/photo-library entries make sense.
bool get supportsPhotoPickers => Platform.isIOS || Platform.isAndroid;

/// Runs the picker for [source]. Null when the user cancelled **or** when the
/// file is not a supported image type — the two are not distinguished, because
/// both dialogs already filter to the supported extensions, which makes the
/// second case close to unreachable. Neither produces a message.
Future<PickedImage?> pickImage(AttachSource source) async {
  switch (source) {
    case AttachSource.photoLibrary:
    case AttachSource.camera:
      final picked = await ImagePicker().pickImage(
        source: source == AttachSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
      );
      if (picked == null) return null;
      return _fromPath(picked.path, picked.name);
    case AttachSource.file:
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Images',
            extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
            // UTIs/mime types so the macOS dialog filters correctly, not just
            // by extension.
            uniformTypeIdentifiers: [
              'public.png',
              'public.jpeg',
              'com.compuserve.gif',
              'org.webmproject.webp',
              'com.microsoft.bmp',
            ],
            mimeTypes: [
              'image/png',
              'image/jpeg',
              'image/gif',
              'image/webp',
              'image/bmp',
            ],
          ),
        ],
      );
      if (file == null) return null;
      return _fromPath(file.path, file.name);
  }
}

Future<PickedImage?> _fromPath(String path, String name) async {
  final mime = mimeForFilename(name) ?? mimeForFilename(path);
  // An unsupported type is refused here rather than uploaded and 415'd.
  if (mime == null) return null;
  final file = File(path);
  // `length()` before `readAsBytes()`: the dialogs filter by extension, not size,
  // and loading a 200 MB image into memory just to have the uploader reject it
  // can take a phone down first.
  final length = await file.length();
  if (length > kMaxAttachmentBytes) {
    throw AttachmentTooLargeException(length);
  }
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  return (bytes: bytes, mime: mime, name: name);
}
