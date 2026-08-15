import AVFoundation
import CoreImage.CIFilterBuiltins
import SCVPNCore
import SwiftUI

/// Сканер QR-кода камерой — чтобы перенести подписку с телефона.
///
/// `AVCaptureMetadataOutput` распознаёт QR сам: ни ручного цикла захвата
/// кадров, ни детектора писать не нужно. Отсюда и уходит
/// `opencv-python-headless` — 118 МБ из 223 МБ бандла Python-версии
/// (замер Задачи −1.2).
///
/// `NSCameraUsageDescription` лежит в `Info.plist` с Задачи 1.2: без него
/// система убивает процесс при первом же обращении к камере, а не отказывает.
struct QRScannerView: NSViewRepresentable {
    var onFound: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .black
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.preview?.frame = view.bounds
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let onFound: (String) -> Void
        private var reported = false
        var preview: AVCaptureVideoPreviewLayer?

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func attach(to view: NSView) {
            // Разрешение спрашиваем до настройки сессии: без него
            // AVCaptureDeviceInput отдаёт пустую картинку без единой ошибки.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.configure(view) }
            }
        }

        private func configure(_ view: NSView) {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            // Тип задаётся только после addOutput: до него список доступных
            // типов пуст, и .qr вызвал бы исключение.
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
            preview = layer

            // Запуск блокирует поток примерно на секунду — не на главном.
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            // Один код — один доклад: камера отдаёт распознанное каждым кадром,
            // и без флага диалог закрывался бы десятки раз подряд.
            guard !reported,
                  let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                      .first(where: { $0.type == .qr }),
                  let text = code.stringValue, !text.isEmpty else { return }
            reported = true
            onFound(text)
        }

        func stop() {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}

/// QR-код как картинка. `nil` — не вышло собрать.
///
/// `CIFilter.qrCodeGenerator` вместо модуля `qrcode`: то же самое, но своё.
func qrImage(_ text: String, side: CGFloat = 220) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    // M — тот же уровень коррекции, что по умолчанию у python-qrcode.
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }

    // Масштабируем целыми кратностями: дробный масштаб размывает модули, и
    // телефон начинает водить камерой вместо того, чтобы считать сразу.
    let scale = max(1, (side / output.extent.width).rounded(.down))
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}
