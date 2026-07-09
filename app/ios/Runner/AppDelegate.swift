import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Retains the device-info channel for the lifetime of the app.
  private var deviceInfoChannel: FlutterMethodChannel?
  // SPEC-07: retains the push channel used to forward the APNs token to Dart.
  private var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Route notification taps/foreground presentation through the app so
    // flutter_local_notifications' onDidReceiveNotificationResponse fires.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    // SPEC-07: register for content-free wake pushes. The token is forwarded to
    // Dart (`makit/push` channel → PushRegistrar) which sends `push.register`.
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // SPEC-07: APNs delivered a device token → forward its hex form to Dart.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushChannel?.invokeMethod("didRegister", arguments: token)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    pushChannel?.invokeMethod("didFail", arguments: error.localizedDescription)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QrScannerPlugin") {
      QrScannerPlugin.register(with: registrar)
    }
    // `makit/device_info` → the user-set device name (e.g. "KC's iPhone") for
    // the pairing label. Read-only, no third-party plugin (see SECURITY.md §5).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MakitDeviceInfo") {
      let channel = FlutterMethodChannel(
        name: "makit/device_info",
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
    // SPEC-07: `makit/push` → forwards the native APNs token to the Dart
    // PushRegistrar. The Dart default is NoopPushRegistrar; a channel-backed
    // registrar (on-device seam) consumes `didRegister` to send push.register.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MakitPush") {
      pushChannel = FlutterMethodChannel(
        name: "makit/push",
        binaryMessenger: registrar.messenger()
      )
    }
  }
}
