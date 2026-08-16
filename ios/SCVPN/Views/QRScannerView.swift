import AVFoundation
import SCVPNCore
import SwiftUI

/// Сканер QR на `AVCaptureMetadataOutput`. Сторонних библиотек нет — как и в
/// macOS-версии.
struct QRScannerView: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scvpnBG.ignoresSafeArea()
                #if targetEnvironment(simulator)
                // У симулятора камеры нет. Пустой чёрный экран выглядел бы как
                // сломанный сканер, поэтому говорим прямо.
                Text("В симуляторе камеры нет — сканировать QR можно только на устройстве.")
                    .font(.scvpnUI(12))
                    .foregroundStyle(Color.scvpnDim)
                    .multilineTextAlignment(.center)
                    .padding(Style.emptyPadding)
                #else
                CameraPreview(onCode: { code in
                    onCode(code)
                    dismiss()
                })
                .ignoresSafeArea()
                #endif
            }
            .navigationTitle("Сканировать QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
    }
}

#if !targetEnvironment(simulator)
private struct CameraPreview: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        // Запуск сессии блокирует поток на доли секунды — на главном это
        // заметная задержка при открытии экрана.
        Task.detached { [session] in session.startRunning() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // Кадры идут десятками в секунду: без флага один код прилетел бы
        // столько раз, сколько успел попасть в объектив.
        guard !handled,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        handled = true
        session.stopRunning()
        onCode?(value)
    }
}
#endif
