import Flutter
import UIKit
import AVFoundation
import Vision

/// Modal QR scanner backed by AVFoundation + Vision.framework.
///
/// Exposed to Flutter via the `makit/qr_scanner` method channel:
///   - `scan` → Future<String?>  (null on cancel/error)
///
/// Vision is used so we avoid the MLKit dependency that breaks iOS 26 arm64
/// simulators. Vision runs natively, no extra binaries to ship.
@objc class QrScannerPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "makit/qr_scanner",
                                       binaryMessenger: registrar.messenger())
    let instance = QrScannerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "scan" else {
      result(FlutterMethodNotImplemented); return
    }
    DispatchQueue.main.async {
      guard let root = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })?.rootViewController else {
        result(nil); return
      }
      let vc = QrScannerViewController { code in
        result(code)
      }
      vc.modalPresentationStyle = .fullScreen
      root.present(vc, animated: true)
    }
  }
}

/// Camera VC that detects QR codes via Vision and calls back with the first
/// non-empty payload string, then dismisses itself.
final class QrScannerViewController: UIViewController {
  private let session = AVCaptureSession()
  private let onResult: (String?) -> Void
  private var preview: AVCaptureVideoPreviewLayer?
  private let visionQueue = DispatchQueue(label: "makit.qr.vision")
  private var didReturn = false

  init(onResult: @escaping (String?) -> Void) {
    self.onResult = onResult
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    let cancel = UIButton(type: .system)
    cancel.setTitle("Cancel", for: .normal)
    cancel.setTitleColor(.white, for: .normal)
    cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
    cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    cancel.translatesAutoresizingMaskIntoConstraints = false

    let hint = UILabel()
    hint.text = "Aim at the makit pair QR"
    hint.textColor = .white
    hint.textAlignment = .center
    hint.font = .systemFont(ofSize: 15)
    hint.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(cancel)
    view.addSubview(hint)
    NSLayoutConstraint.activate([
      cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ])

    configureCamera()
  }

  private func configureCamera() {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: device) else {
      finish(with: nil); return
    }
    if session.canAddInput(input) { session.addInput(input) }

    let output = AVCaptureVideoDataOutput()
    output.setSampleBufferDelegate(self, queue: visionQueue)
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    if session.canAddOutput(output) { session.addOutput(output) }

    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    view.layer.insertSublayer(preview, at: 0)
    self.preview = preview

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  @objc private func cancelTapped() {
    finish(with: nil)
  }

  private func finish(with code: String?) {
    guard !didReturn else { return }
    didReturn = true
    if session.isRunning { session.stopRunning() }
    DispatchQueue.main.async { [weak self] in
      self?.dismiss(animated: true) {
        self?.onResult(code)
      }
    }
  }
}

extension QrScannerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput,
                     didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard !didReturn,
          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let request = VNDetectBarcodesRequest { [weak self] req, _ in
      guard let self = self, !self.didReturn,
            let results = req.results as? [VNBarcodeObservation] else { return }
      for r in results where r.symbology == .qr {
        if let payload = r.payloadStringValue, !payload.isEmpty {
          self.finish(with: payload)
          return
        }
      }
    }
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
    try? handler.perform([request])
  }
}
