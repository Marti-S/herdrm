@preconcurrency import AVFoundation
import SwiftUI
import UIKit

enum MobilePairingScannerError: LocalizedError, Equatable {
  case cameraUnavailable
  case permissionDenied
  case configurationFailed(String)

  var errorDescription: String? {
    switch self {
    case .cameraUnavailable:
      return String(localized: "No camera is available on this device.")
    case .permissionDenied:
      return String(localized: "Camera access is required to scan the pairing QR code.")
    case .configurationFailed(let detail):
      return String(localized: "The camera could not be configured: \(detail)")
    }
  }

  var canOpenSettings: Bool {
    if case .permissionDenied = self { return true }
    return false
  }
}

/// Full-screen camera sheet for the QR code rendered by HerdrM's Mobile
/// Pairing window. The QR payload is the same versioned JSON accepted by the
/// existing paste flow, so scanning adds no second pairing format.
struct MobilePairingScannerSheet: View {
  let onScanned: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var scannerError: MobilePairingScannerError?

  var body: some View {
    NavigationStack {
      ZStack {
        MobilePairingScannerView(
          onScanned: { payload in
            onScanned(payload)
            dismiss()
          },
          onError: { scannerError = $0 }
        )
        .ignoresSafeArea()

        VStack(spacing: 18) {
          Spacer()
          RoundedRectangle(cornerRadius: 24)
            .stroke(.white, lineWidth: 3)
            .frame(width: 250, height: 250)
            .shadow(radius: 8)
            .accessibilityHidden(true)
          Text(String(localized: "Point the camera at the QR code in HerdrM's Mobile Pairing window."))
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
          Spacer()
        }
      }
      .background(.black)
      .navigationTitle(String(localized: "Scan Pairing Code"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbarBackground(.black.opacity(0.65), for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "Cancel")) { dismiss() }
        }
      }
      .alert(
        String(localized: "Could Not Scan Pairing Code"),
        isPresented: Binding(
          get: { scannerError != nil },
          set: { if !$0 { scannerError = nil } }
        )
      ) {
        if scannerError?.canOpenSettings == true {
          Button(String(localized: "Open Settings")) {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
          }
        }
        Button(String(localized: "Close"), role: .cancel) { dismiss() }
      } message: {
        Text(scannerError?.errorDescription ?? "")
      }
    }
  }
}

private struct MobilePairingScannerView: UIViewControllerRepresentable {
  let onScanned: (String) -> Void
  let onError: (MobilePairingScannerError) -> Void

  func makeUIViewController(context: Context) -> MobilePairingScannerViewController {
    MobilePairingScannerViewController(
      onScanned: onScanned,
      onError: onError
    )
  }

  func updateUIViewController(
    _ uiViewController: MobilePairingScannerViewController,
    context: Context
  ) {}

  static func dismantleUIViewController(
    _ uiViewController: MobilePairingScannerViewController,
    coordinator: Void
  ) {
    uiViewController.stop()
  }
}

private final class MobilePairingScannerViewController: UIViewController,
  AVCaptureMetadataOutputObjectsDelegate
{
  private let captureSession = AVCaptureSession()
  private let sessionQueue = DispatchQueue(
    label: "dev.bybee.herdrm.ios.pairing-scanner",
    qos: .userInitiated
  )
  private let previewLayer: AVCaptureVideoPreviewLayer
  private let onScanned: (String) -> Void
  private let onError: (MobilePairingScannerError) -> Void

  private var configured = false
  private var completed = false
  private var reportedError = false

  init(
    onScanned: @escaping (String) -> Void,
    onError: @escaping (MobilePairingScannerError) -> Void
  ) {
    self.onScanned = onScanned
    self.onError = onError
    previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    previewLayer.videoGravity = .resizeAspectFill
    view.layer.addSublayer(previewLayer)
    requestCameraAccess()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer.frame = view.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stop()
  }

  func stop() {
    let session = captureSession
    sessionQueue.async {
      if session.isRunning {
        session.stopRunning()
      }
    }
  }

  private func requestCameraAccess() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureAndStart()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          if granted {
            self.configureAndStart()
          } else {
            self.report(.permissionDenied)
          }
        }
      }
    case .denied, .restricted:
      report(.permissionDenied)
    @unknown default:
      report(.permissionDenied)
    }
  }

  private func configureAndStart() {
    guard !configured, !completed else { return }
    configured = true

    guard let camera = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: .back
    ) ?? AVCaptureDevice.default(for: .video) else {
      report(.cameraUnavailable)
      return
    }

    do {
      let input = try AVCaptureDeviceInput(device: camera)
      let output = AVCaptureMetadataOutput()

      captureSession.beginConfiguration()
      defer { captureSession.commitConfiguration() }
      if captureSession.canSetSessionPreset(.high) {
        captureSession.sessionPreset = .high
      }
      guard captureSession.canAddInput(input) else {
        throw MobilePairingScannerError.configurationFailed(
          String(localized: "The camera input is unavailable.")
        )
      }
      captureSession.addInput(input)
      guard captureSession.canAddOutput(output) else {
        throw MobilePairingScannerError.configurationFailed(
          String(localized: "QR code detection is unavailable.")
        )
      }
      captureSession.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main)
      guard output.availableMetadataObjectTypes.contains(.qr) else {
        throw MobilePairingScannerError.configurationFailed(
          String(localized: "This camera cannot detect QR codes.")
        )
      }
      output.metadataObjectTypes = [.qr]
    } catch let error as MobilePairingScannerError {
      report(error)
      return
    } catch {
      report(.configurationFailed(error.localizedDescription))
      return
    }

    let session = captureSession
    sessionQueue.async {
      if !session.isRunning {
        session.startRunning()
      }
    }
  }

  private func report(_ error: MobilePairingScannerError) {
    guard !reportedError else { return }
    reportedError = true
    onError(error)
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard !completed else { return }
    guard let object = metadataObjects
      .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
      .first(where: { $0.type == .qr }),
      let payload = object.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !payload.isEmpty
    else { return }

    completed = true
    stop()
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    onScanned(payload)
  }
}
