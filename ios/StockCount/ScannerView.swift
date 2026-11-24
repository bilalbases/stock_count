import SwiftUI
import AVFoundation
import AudioToolbox

/// Full-screen camera barcode scanner (built into iOS, works offline).
struct ScannerView: View {
    let onResult: (String) -> Void
    let onClose: () -> Void
    @State private var torch = false
    @State private var denied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if denied {
                VStack(spacing: 16) {
                    Text("Camera not allowed").font(.title3.bold()).foregroundColor(.white)
                    Text("Allow the camera for Stock Count in Settings to scan barcodes.")
                        .multilineTextAlignment(.center).foregroundColor(.white.opacity(0.8))
                    Button("Open Settings") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }.buttonStyle(.borderedProminent)
                }.padding(32)
            } else {
                CameraScanner(torch: torch, onResult: onResult).ignoresSafeArea()
                // Aim box
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 280, height: 160)
                    .overlay(Rectangle().fill(Color(red: 0.35, green: 0.86, blue: 0.85)).frame(height: 2))
            }
            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundColor(.white)
                            .padding(12).background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    Spacer()
                    Button { torch.toggle() } label: {
                        Image(systemName: torch ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title2).foregroundColor(.white)
                            .padding(12).background(Circle().fill(Color.black.opacity(0.5)))
                    }
                }.padding()
                Spacer()
                Text("Point the camera at the barcode")
                    .foregroundColor(.white).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted: denied = true
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { denied = !ok } }
            default: break
            }
        }
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let torch: Bool
    let onResult: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onResult = onResult
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) {
        c.onResult = onResult
        c.setTorch(torch)
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var device: AVCaptureDevice?
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return }
        device = dev
        if dev.isFocusModeSupported(.continuousAutoFocus) {
            try? dev.lockForConfiguration()
            dev.focusMode = .continuousAutoFocus
            if dev.isAutoFocusRangeRestrictionSupported { dev.autoFocusRangeRestriction = .near }
            dev.unlockForConfiguration()
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        let wanted: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128, .code39, .code93, .itf14, .interleaved2of5, .qr, .dataMatrix]
        output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setTorch(false)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }

    func setTorch(_ on: Bool) {
        guard let d = device, d.hasTorch else { return }
        try? d.lockForConfiguration()
        d.torchMode = on ? .on : .off
        d.unlockForConfiguration()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, !code.isEmpty else { return }
        done = true
        AudioServicesPlaySystemSound(1057)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onResult?(code.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
