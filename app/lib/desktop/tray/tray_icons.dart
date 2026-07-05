/// The tray icon path resolver for the macOS menubar.
///
/// The actual PNG asset (and its registration under `flutter:` `assets:` in
/// `pubspec.yaml`) is handled separately. This class only exposes the logical
/// path that [TrayController] hands to `tray_manager`.
class TrayIcons {
  const TrayIcons._();

  /// Path (relative to the bundled Flutter assets) of the default menubar
  /// icon. On macOS this is rendered as a template image so the system tints
  /// it automatically for light and dark menu bars.
  static String get defaultIconPath => 'assets/tray/TrayIcon.png';
}
