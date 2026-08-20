import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Retained for the window's lifetime: it owns the View-menu items and is the
  /// target of their action (SPEC-pane-zoom D7).
  private var zoomMenu: ZoomMenu?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    zoomMenu = ZoomMenu(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
