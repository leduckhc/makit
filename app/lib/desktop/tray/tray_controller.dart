import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import 'tray_icons.dart';

/// Lifecycle state of the pino daemon as far as the tray needs to know.
///
/// This is a deliberately minimal mirror of the richer types Stream A defines
/// in `control_types.dart`; keeping it local keeps the tray decoupled from the
/// rest of the desktop control layer.
enum DaemonState {
  /// The daemon process is not running.
  stopped,

  /// The daemon process is up and accepting connections.
  running,

  /// The daemon is in the middle of starting up.
  starting,
}

/// A snapshot of daemon state used to render the tray menu and tooltip.
@immutable
class DaemonSummary {
  /// Creates a summary. [pairedDevices] and [runningSessions] are the counts
  /// shown in the submenu titles; [deviceLabels] and [sessionTitles] are the
  /// individual entries listed inside those submenus (optional).
  const DaemonSummary({
    required this.state,
    this.pid,
    required this.pairedDevices,
    required this.runningSessions,
    this.deviceLabels = const [],
    this.sessionTitles = const [],
  });

  /// Current lifecycle state of the daemon.
  final DaemonState state;

  /// Process id of the daemon when [state] is [DaemonState.running].
  final int? pid;

  /// Number of currently paired devices.
  final int pairedDevices;

  /// Number of currently running agent sessions.
  final int runningSessions;

  /// Human-readable labels for each paired device (shown in the submenu).
  final List<String> deviceLabels;

  /// Human-readable titles for each running session (shown in the submenu).
  final List<String> sessionTitles;
}

/// Seam over the parts of `tray_manager` that [TrayController] uses.
///
/// Abstracting these native calls lets unit tests inject a fake and assert on
/// behaviour without a real OS tray. Production uses [TrayManagerPlatform].
abstract class TrayPlatform {
  /// Sets the tray icon image to the asset at [path].
  Future<void> setImagePath(String path);

  /// Marks the tray icon as a macOS template image (auto light/dark tinting).
  Future<void> setTemplateImage(bool isTemplate);

  /// Sets the tray icon hover tooltip.
  Future<void> setTooltip(String tooltip);

  /// Sets the tray context menu.
  Future<void> setMenu(Menu menu);

  /// Removes the tray icon.
  Future<void> destroy();
}

/// Production [TrayPlatform] backed by the real `tray_manager` plugin.
class TrayManagerPlatform implements TrayPlatform {
  String? _iconPath;
  bool _isTemplate = false;

  @override
  Future<void> setImagePath(String path) async {
    _iconPath = path;
    await trayManager.setIcon(path, isTemplate: _isTemplate);
  }

  @override
  Future<void> setTemplateImage(bool isTemplate) async {
    _isTemplate = isTemplate;
    final path = _iconPath;
    // Re-apply so the template flag takes effect if the icon was set first.
    if (path != null) {
      await trayManager.setIcon(path, isTemplate: isTemplate);
    }
  }

  @override
  Future<void> setTooltip(String tooltip) => trayManager.setToolTip(tooltip);

  @override
  Future<void> setMenu(Menu menu) => trayManager.setContextMenu(menu);

  @override
  Future<void> destroy() => trayManager.destroy();
}

/// Drives the macOS menubar tray: shows daemon state and offers Start/Stop,
/// Dashboard, QR, Devices, Sessions and Quit actions.
///
/// Every `tray_manager` call is guarded by [Platform.isMacOS]; on other
/// platforms the controller is a no-op. It is a [ChangeNotifier] so callers can
/// react to state refreshes (each [update] fires [notifyListeners]).
class TrayController extends ChangeNotifier {
  /// Creates a controller.
  ///
  /// [stateAccessor] returns the current [DaemonSummary] (used by [init]).
  /// [platform] defaults to the real [TrayManagerPlatform]; tests inject a
  /// fake. The `on*` callbacks are invoked when the matching menu item is
  /// clicked.
  TrayController({
    required DaemonSummary Function() stateAccessor,
    TrayPlatform? platform,
    bool? isMacOS,
    this.onStart,
    this.onStop,
    this.onOpenDashboard,
    this.onOpenQr,
    this.onQuit,
  }) : _stateAccessor = stateAccessor,
       _platform = platform ?? TrayManagerPlatform(),
       _isMacOS = isMacOS ?? Platform.isMacOS;

  final DaemonSummary Function() _stateAccessor;
  final TrayPlatform _platform;

  /// Whether tray calls should reach the native platform. Defaults to
  /// [Platform.isMacOS]; tests override it so they can exercise the real
  /// menu/tooltip building through the injected [TrayPlatform].
  final bool _isMacOS;

  /// Invoked when the user chooses "Start Server".
  final VoidCallback? onStart;

  /// Invoked when the user chooses "Stop Server".
  final VoidCallback? onStop;

  /// Invoked when the user chooses "Dashboard".
  final VoidCallback? onOpenDashboard;

  /// Invoked when the user chooses "Pair QR...".
  final VoidCallback? onOpenQr;

  /// Invoked when the user chooses "Quit Pino".
  final VoidCallback? onQuit;

  /// Creates the tray icon and its initial tooltip/menu from the current state.
  Future<void> init() async {
    if (!_isMacOS) return;
    final state = _stateAccessor();
    await _platform.setImagePath(TrayIcons.defaultIconPath);
    await _platform.setTemplateImage(true);
    await _platform.setTooltip(_tooltipFor(state));
    await _platform.setMenu(_buildMenu(state));
  }

  /// Refreshes the tooltip and rebuilds the menu for [state], then notifies
  /// listeners.
  Future<void> update(DaemonSummary state) async {
    if (!_isMacOS) return;
    await _platform.setTooltip(_tooltipFor(state));
    await _platform.setMenu(_buildMenu(state));
    notifyListeners();
  }

  @override
  void dispose() {
    if (_isMacOS) {
      // Fire-and-forget: the icon removal is a one-way native call.
      unawaited(_platform.destroy());
    }
    super.dispose();
  }

  String _tooltipFor(DaemonSummary state) => 'Pino — ${state.state.name}';

  String _stateLine(DaemonSummary state) => switch (state.state) {
    DaemonState.running => 'Running (pid ${state.pid})',
    DaemonState.starting => 'Starting…',
    DaemonState.stopped => 'Stopped',
  };

  Menu _buildMenu(DaemonSummary state) {
    final items = <MenuItem>[
      MenuItem(label: 'Pino', disabled: true),
      MenuItem(label: _stateLine(state), disabled: true),
      MenuItem.separator(),
      if (state.state == DaemonState.stopped)
        MenuItem(label: 'Start Server', onClick: (_) => onStart?.call()),
      if (state.state == DaemonState.running)
        MenuItem(label: 'Stop Server', onClick: (_) => onStop?.call()),
      MenuItem.separator(),
      MenuItem(label: 'Dashboard', onClick: (_) => onOpenDashboard?.call()),
      MenuItem(label: 'Pair QR...', onClick: (_) => onOpenQr?.call()),
      MenuItem.separator(),
      _dynamicDeviceSubmenu(state),
      _dynamicSessionSubmenu(state),
      MenuItem.separator(),
      MenuItem(label: 'Quit Pino', onClick: (_) => onQuit?.call()),
    ];
    return Menu(items: items);
  }

  MenuItem _dynamicDeviceSubmenu(DaemonSummary state) => MenuItem.submenu(
    label: 'Devices (${state.pairedDevices})',
    submenu: Menu(
      items: state.deviceLabels.isEmpty
          ? [MenuItem(label: 'No devices', disabled: true)]
          : [for (final label in state.deviceLabels) MenuItem(label: label)],
    ),
  );

  MenuItem _dynamicSessionSubmenu(DaemonSummary state) => MenuItem.submenu(
    label: 'Sessions (${state.runningSessions})',
    submenu: Menu(
      items: state.sessionTitles.isEmpty
          ? [MenuItem(label: 'No sessions', disabled: true)]
          : [for (final title in state.sessionTitles) MenuItem(label: title)],
    ),
  );
}
