import Cocoa
import FlutterMacOS

/// The native View-menu zoom items (SPEC-pane-zoom D7, D8).
///
/// Flutter cannot own this menu bar: `PlatformMenuBar` replaces the whole bar,
/// and `PlatformProvidedMenuItemType` has no Cut, Copy, Paste, Undo or Select
/// All. Adopting it would force hand-rolled Edit items that no longer reach the
/// focused native text view. So the bar stays in `MainMenu.xib`, and only these
/// three items are added here.
///
/// Dart owns the bindings (D8). It is already the source of truth for the
/// rebindable keymap, and macOS consumes a menu item's key equivalent before
/// Flutter ever sees the keystroke — so a key equivalent hard-coded here would
/// silently ignore a rebind. Dart therefore pushes the labels and the key
/// equivalents down, and this class only renders them and reports a click.
final class ZoomMenu: NSObject {
  private static let channelName = "makit/zoom_menu"

  private let channel: FlutterMethodChannel

  /// The items this class added, so a later push can replace exactly those and
  /// leave the XIB's own items (Enter Full Screen) alone.
  private var installed: [NSMenuItem] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: ZoomMenu.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setItems":
        guard let specs = call.arguments as? [[String: Any]] else {
          result(FlutterError(code: "bad-args", message: "expected a list of item maps", details: nil))
          return
        }
        self?.install(specs)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The XIB's View menu.
  ///
  /// Matched by title, which is safe while the app ships one English menu bar.
  /// A localised bar would need a tagged outlet instead.
  private var viewMenu: NSMenu? {
    NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu
  }

  /// Replaces the zoom items with [specs], newest push wins.
  ///
  /// Each spec carries `id`, `label`, `key` (a single-character key equivalent)
  /// and `modifiers` (the `NSEvent.ModifierFlags` raw value). An item with no
  /// `key` renders with no shortcut, which is what an unbound action looks like.
  private func install(_ specs: [[String: Any]]) {
    guard let menu = viewMenu else { return }
    for item in installed {
      if let index = menu.items.firstIndex(of: item) {
        menu.removeItem(at: index)
      }
    }
    installed = []

    // Above the XIB's Enter Full Screen, where a browser also puts them.
    var index = 0
    for spec in specs {
      guard let id = spec["id"] as? String, let label = spec["label"] as? String else { continue }
      let item = NSMenuItem(
        title: label,
        action: #selector(fire(_:)),
        keyEquivalent: spec["key"] as? String ?? ""
      )
      if let modifiers = spec["modifiers"] as? UInt {
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: modifiers)
      }
      item.target = self
      item.representedObject = id
      menu.insertItem(item, at: index)
      installed.append(item)
      index += 1
    }
    if !installed.isEmpty {
      let separator = NSMenuItem.separator()
      menu.insertItem(separator, at: index)
      installed.append(separator)
    }
  }

  /// Reports a chosen item to Dart, which holds the zoom state.
  @objc private func fire(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    channel.invokeMethod("invoke", arguments: id)
  }
}
