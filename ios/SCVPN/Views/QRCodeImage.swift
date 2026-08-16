import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR-код ссылки. CoreImage, без сторонних библиотек — как и сканер.
struct QRCodeImage: View {
    var text: String
    var side: CGFloat = 200

    var body: some View {
        if let image = Self.make(text) {
            Image(uiImage: image)
                .interpolation(.none)          // иначе код мылится и не читается
                .resizable()
                .frame(width: side, height: side)
                .background(Color.white)       // тёмная тема QR ломает: сканеры ждут светлый фон
                .cornerRadius(8)
        }
    }

    private static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // M — тот же уровень коррекции, что у генератора на других платформах.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
