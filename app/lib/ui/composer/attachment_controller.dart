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

import '../../store/chat_items.dart';
import '../../store/composer_attachments.dart';
import '../../store/media.dart';
import '../../store/store.dart';
import '../widgets/sheet_header.dart';
import 'attachment_sources.dart';
import 'composer.dart';

/// Wires one session's composer to the attachment machinery — the whole
/// capability in one call, so neither surface can wire up a different half of it.
///
/// [pick] is null (an inert paperclip, no ⌘V claim) when there is nowhere to
/// upload to or the session is gone. The staged chips are handed over either way:
/// unpairing mid-stage must not hide images the next send would still carry.
///
/// Must be called from a `build`: it watches the staged list, the uploader and
/// the session.
ComposerAttachmentsApi composerAttachments(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) => _attachments(
  context,
  ref,
  key: sessionId,
  // Only real precondition: somewhere to upload to (SPEC-33 §3.4), and a session
  // to upload for. NOT a recorded worktree — the server materialises into the
  // agent's cwd, and the default repo-root session legitimately has
  // `worktreePath == null`, so gating on it would disable the paperclip for the
  // commonest case.
  canStage: ref.watch(sessionsProvider).byId(sessionId) != null,
);

/// The same capability for a composer whose session does not exist yet — the
/// starter pane's first message (SPEC-45 D6/D7).
///
/// [draftKey] is that pane's staging key (built by `starterDraftKey`), so the
/// images survive the pane being recreated exactly as its draft text does. The
/// live-pane session check is deliberately absent: it asks "is there a session
/// to upload *for*", which has no meaning before one exists, and `POST /media`
/// is content-addressed and session-independent. A reachable server is the whole
/// precondition (D7).
ComposerAttachmentsApi draftAttachments(
  BuildContext context,
  WidgetRef ref,
  String draftKey,
) => _attachments(context, ref, key: draftKey, canStage: true);

/// Shared body of the two entry points: [canStage] is the caller's extra
/// precondition, always AND-ed with "there is somewhere to upload to".
ComposerAttachmentsApi _attachments(
  BuildContext context,
  WidgetRef ref, {
  required String key,
  required bool canStage,
}) {
  // The uploader is watched through `mediaUploaderProvider`, NOT through the
  // attachments notifier: the paperclip must rebuild when a server is
  // (dis)connected, while the notifier must not be rebuilt by that change (it
  // holds staged bytes and in-flight uploads).
  final canUpload = ref.watch(mediaUploaderProvider) != null && canStage;
  // Read lazily inside the callbacks: they fire long after this build.
  ComposerAttachments notifier() =>
      ref.read(composerAttachmentsProvider.notifier);
  return ComposerAttachmentsApi(
    staged: ref.watch(composerAttachmentsProvider)[key] ?? const [],
    pick: canUpload ? () => _showAttachMenu(context, notifier(), key) : null,
    remove: (localId) => notifier().remove(key, localId),
    retry: (localId) => notifier().retry(key, localId),
    readClipboardImage: readClipboardImage,
    stagePasted: (image) => _stage(notifier(), key, image),
  );
}

/// Stage + upload one picked/pasted image. The one place a staged attachment's
/// client id is minted.
///
/// Takes the notifier, not a `WidgetRef`: the picker path calls this *after*
/// awaiting a sheet and a plugin, by which time the composer's element may be
/// gone and `ref.read` would throw.
Future<void> _stage(
  ComposerAttachments notifier,
  String key,
  PickedImage image,
) => notifier.add(
  key: key,
  localId: Ulid().toString(),
  bytes: image.bytes,
  mime: image.mime,
  name: image.name,
);

/// Descriptors for the wire, then clear — called around a successful send.
List<MediaAttachmentRef> takeAttachmentsForSend(WidgetRef ref, String key) =>
    takeAttachmentsFrom(ref.read(composerAttachmentsProvider.notifier), key);

/// Same, from a notifier captured **before** an await.
///
/// The starter pane takes its images only once the spawn has landed (SPEC-45
/// D6), by which time its element may be gone — and a `WidgetRef.read` after
/// that throws. Same reason [_stage] takes a notifier.
List<MediaAttachmentRef> takeAttachmentsFrom(
  ComposerAttachments notifier,
  String key,
) {
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
///
/// Takes the [notifier] rather than a `WidgetRef` because the sheet and the
/// picker outlive the composer — a desktop worktree switch or pane split disposes
/// it — and using a `WidgetRef` after its element unmounts throws. The provider
/// is deliberately not autoDispose precisely so the staging still lands in that
/// case, so hold the notifier rather than bailing out.
Future<void> _showAttachMenu(
  BuildContext context,
  ComposerAttachments notifier,
  String key,
) async {
  final source = supportsPhotoPickers
      ? await showModalBottomSheet<AttachSource>(
          context: context,
          // Drag handle + header, like every other sheet in the app.
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHeader(title: 'Attach an image'),
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
  // The caller discards this future, so an uncaught error here would surface as
  // an unhandled async error and the user would just see nothing happen.
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
  await _stage(notifier, key, image);
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
