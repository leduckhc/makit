import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Retains the device-info channel for the lifetime of the app.
  private var deviceInfoChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Route notification taps/foreground presentation through the app so
    // flutter_local_notifications' onDidReceiveNotificationResponse fires.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QrScannerPlugin") {
      QrScannerPlugin.register(with: registrar)
    }
    // `pino/device_info` → the user-set device name (e.g. "KC's iPhone") for
    // the pairing label. Read-only, no third-party plugin (see SECURITY.md §5).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PinoDeviceInfo") {
      let channel = FlutterMethodChannel(
        name: "pino/device_info",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        if call.method == "name" {
          result(UIDevice.current.name)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      deviceInfoChannel = channel
    }
  }
}
