/// Glue between the composer's attachment UI and the pieces that do the work
/// (SPEC-33): the pickers/clipboard on one side, the upload notifier on the
/// other.
///
/// Exists so the mobile session screen and the desktop chat pane share one
/// behaviour instead of two near-copies — the bug class SPEC-33 §4.1 was written
/// to avoid (an attachment that works on one surface and silently doesn't on the
/// other).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:ulid/ulid.dart';

import '../../store/composer_attachments.dart';
import '../../store/media.dart';
import 'attachment_sources.dart';

/// Reads the staged attachments for [key].
List<ComposerAttachment> attachmentsFor(WidgetRef ref, String key) =>
    ref.watch(composerAttachmentsProvider)[key] ?? const [];

/// Whether the paperclip should be live. False when nothing is paired (no
/// uploader) — the composer then shows an inert clip with a reason.
///
/// Watches the endpoint provider directly rather than the attachments notifier:
/// the UI must rebuild when a server is (dis)connected, while the notifier must
/// NOT be rebuilt by that change (it holds staged bytes and in-flight uploads).
bool canAttach(WidgetRef ref) => ref.watch(mediaUploaderProvider) != null;

/// Stage + upload one picked/pasted image.
Future<void> stageAttachment(
  WidgetRef ref,
  String key, {
  required PickedImage image,
}) => ref
    .read(composerAttachmentsProvider.notifier)
    .add(
      key: key,
      localId: Ulid().toString(),
      bytes: image.bytes,
      mime: image.mime,
      name: image.name,
    );

void removeAttachment(WidgetRef ref, String key, String localId) =>
    ref.read(composerAttachmentsProvider.notifier).remove(key, localId);

void retryAttachment(WidgetRef ref, String key, String localId) =>
    ref.read(composerAttachmentsProvider.notifier).retry(key, localId);

/// Descriptors for the wire, then clear — called around a successful send.
List<({String mediaId, String mime, String name})> takeAttachmentsForSend(
  WidgetRef ref,
  String key,
) {
  final notifier = ref.read(composerAttachmentsProvider.notifier);
  final wire = notifier.wireFor(key);
  // Only the sent (ready) ones are dropped: a failed chip stays visible with its
  // retry rather than disappearing unexplained (see `clearSent`).
  notifier.clearSent(key);
  return wire;
}

/// Show the attach menu and stage whatever the user picks.
///
/// Photo library / camera on phones; a file dialog on desktop. A picked file
/// that is not a supported image is reported inline rather than uploaded and
/// rejected by the server.
Future<void> showAttachMenu(
  BuildContext context,
  WidgetRef ref,
  String key, {
  RelativeRect? position,
}) async {
  // Resolved BEFORE the awaits below. The picker (and the sheet) can outlive the
  // composer — a desktop worktree switch or pane split disposes it — and using a
  // `WidgetRef` after its element unmounts throws. The provider is deliberately
  // not autoDispose precisely so the staging still lands in that case, so hold
  // the notifier rather than bailing out.
  final notifier = ref.read(composerAttachmentsProvider.notifier);
  final source = supportsPhotoPickers
      ? await showModalBottomSheet<AttachSource>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(PhosphorIconsLight.image),
                  title: const Text('Photo library'),
                  onTap: () => Navigator.pop(ctx, AttachSource.photoLibrary),
                ),
                ListTile(
                  leading: const Icon(PhosphorIconsLight.camera),
                  title: const Text('Take photo'),
                  onTap: () => Navigator.pop(ctx, AttachSource.camera),
                ),
                ListTile(
                  leading: const Icon(PhosphorIconsLight.folder),
                  title: const Text('Choose file…'),
                  onTap: () => Navigator.pop(ctx, AttachSource.file),
                ),
              ],
            ),
          ),
        )
      // Desktop: no gallery/camera worth offering, so skip the menu entirely
      // and open the file dialog on the first click.
      : AttachSource.file;
  if (source == null) return;

  // The pickers throw for real reasons: a denied camera/photo-library
  // permission, a plugin channel error, an unreadable file, or an oversized one.
  // Both call sites discard this future, so an uncaught error here would surface
  // as an unhandled async error and the user would just see nothing happen.
  final PickedImage? image;
  try {
    image = await pickImage(source);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_pickFailureMessage(e))));
    }
    return;
  }
  // Cancelled, or an unsupported type. `pickImage` collapses both to null and
  // the dialogs already filter to supported image types, so an unsupported pick
  // is close to unreachable; neither case warrants a message.
  if (image == null) return;
  await notifier.add(
    key: key,
    localId: Ulid().toString(),
    bytes: image.bytes,
    mime: image.mime,
    name: image.name,
  );
}

/// Turn a picker failure into something worth showing a person.
String _pickFailureMessage(Object error) => switch (error) {
  AttachmentTooLargeException() => error.toString(),
  // A PlatformException here is nearly always a denied permission; its raw
  // message is plugin jargon, so say the useful part instead.
  PlatformException() =>
    'Could not open the picker — check makit\'s photo and '
        'camera permissions in Settings.',
  _ => 'Could not attach that image.',
};
