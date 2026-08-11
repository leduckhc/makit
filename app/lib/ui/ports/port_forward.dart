/// `Forward & open` (SPEC-44 P4b) — hand a loopback dev server to the phone's
/// own browser.
///
/// **The one thing only makit can do**: a `127.0.0.1` dev server is invisible from
/// your phone, and makit already holds a device-authenticated channel to the
/// machine it runs on — so it can carry that port over the connection it already
/// has, without binding anything new on the host.
///
/// The consumer is the **system browser**, not an in-app WebView. That is a
/// deliberate revision of SPEC-44 D2, and the reasons are worth keeping written
/// down:
///
///  * An in-app WebView would need a loopback HTTP proxy running *inside the app*
///    (a WebView uses the OS network stack, so it can neither pin makit's
///    self-signed cert nor attach the bearer). On iOS the app is suspended
///    seconds after backgrounding — which is exactly when a browser takes over —
///    so that proxy cannot survive the hand-off it exists to serve.
///  * Going straight to the desktop deletes the whole apparatus: no
///    `webview_flutter`, no in-app HTTP server, no countdown UI. `url_launcher`
///    is already a dependency.
///
/// The cost, stated plainly to the user before they tap: the URL is the
/// credential (a browser cannot send a header), and the cert is self-signed, so
/// the browser will ask them to proceed once. Both are bounded — the grant is
/// unguessable, dies in 30 minutes, is reaped a minute after the preview goes
/// quiet, and every proxied response carries `Referrer-Policy: no-referrer` so
/// the previewed page cannot leak its own URL onward.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../store/media.dart';
import '../../store/ports.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';

/// Whether this port could be forwarded at all (the client-side mirror of the
/// server's D4 rules, so a pointless control is never offered).
///
/// The server re-checks every rule on a fresh scan — this is about not showing a
/// button that is guaranteed to fail, not about trusting the client.
bool portIsForwardable(PortInfo port) =>
    port.reach == PortReach.loopback &&
    port.worktreePath != null &&
    port.openUrl != null;

/// The absolute URL to open for [grant].
///
/// [base] is makit's authenticated HTTP origin — the SAME origin the media route
/// uses, because both routes live on the listener that carries the WebSocket. It
/// is reused rather than rebuilt from the paired server so the dev override
/// (`--dart-define=MAKIT_WS_URL=…`, which has no paired server at all) works
/// here too; whatever address this device reached makit on is, by construction,
/// an address it can reach. The server deliberately returns a path and lets the
/// client join it.
Uri? forwardUrlFor(String? base, ForwardGrant grant) {
  if (base == null || base.isEmpty) return null;
  return Uri.parse('$base${grant.path}');
}

/// Confirm, mint a browser grant, then hand the URL to the system browser.
///
/// Returns the grant when the browser was launched (so a caller can offer to stop
/// it), or null when the user backed out or the server refused.
Future<ForwardGrant?> confirmAndForwardPort(
  BuildContext context,
  WidgetRef ref,
  PortInfo port,
) async {
  // Resolved before the first await: `ref` throws once its widget is
  // unmounted, and the record must survive the thing that reported to it.
  final status = ref.status;
  final worktreePath = port.worktreePath;
  if (worktreePath == null) return null;

  // Resolved before the dialog and before every await: `ref` is the caller's,
  // and reading it after the widget is disposed throws (see
  // `port_kill_confirm.dart`). Both of these outlive the widget.
  final forwarder = ref.read(portsForwarderProvider);
  final origin = ref.read(mediaEndpointProvider)?.base;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text('Open :${port.port} in your browser?'),
      content: Text(
        '127.0.0.1:${port.port} cannot be reached from this device. makit will '
        'carry it over the encrypted session it already has, for 30 minutes, '
        'without opening a port on the host.\n\n'
        'Your browser will warn about the certificate — makit signs its own — '
        'and the link itself grants access until it expires, so treat it as a '
        'password.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dctx, true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (confirmed != true) return null;

  final result = await forwarder.forward(
    worktreePath: worktreePath,
    port: port.port,
    browser: true,
  );
  final grant = result.grant;
  if (grant == null) {
    status.warning(
      'Could not forward :${port.port}',
      detail: result.refusal,
      source: StatusSources.ports,
      sessionId: port.sessionId,
    );
    return null;
  }

  final url = forwardUrlFor(origin, grant);
  if (url == null) {
    // Nothing to open against: revoke rather than leave a live grant behind.
    await forwarder.stop(grant.grantId);
    status.warning(
      'Not connected to a server, so there is nothing to open',
      source: StatusSources.ports,
      sessionId: port.sessionId,
    );
    return null;
  }

  try {
    final launched = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!launched) throw StateError('no handler');
  } catch (e) {
    // A grant nobody can use is a grant worth revoking immediately, rather than
    // leaving it to time out.
    await forwarder.stop(grant.grantId);
    status.failure(
      'Could not open a browser',
      error: e,
      source: StatusSources.ports,
      sessionId: port.sessionId,
    );
    return null;
  }
  return grant;
}
