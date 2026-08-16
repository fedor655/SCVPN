// Рендер иконки приложения из общей геометрии знака.
//
// Запускается разово на macOS: та же BrandmarkShape, что рисует знак в
// приложении, кладётся на плашку и сохраняется PNG. Иначе иконка и знак в
// интерфейсе разъезжаются — а это ровно то, чего репозиторий избегает,
// описывая знак кодом в одном месте.
import AppKit
import SCVPNCore
import SwiftUI

let side: CGFloat = 1024

struct Icon: View {
    var body: some View {
        ZStack {
            // Плашка чёрная, как фон приложения; знак — фирменным градиентом.
            Rectangle().fill(Color(hex: Palette.bg))
            // Знак занимает по вертикали примерно 0.71 своей рамки: четыре
            // радиуса (0.155 каждый) плюс толщина штриха (0.09). Чтобы он
            // занял привычные 62 % холста, рамка берётся 0.87 от него.
            BrandmarkView(side: side * 0.87)
        }
        .frame(width: side, height: side)
    }
}

@MainActor
func render(to path: String) throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("не отрисовалось")
    }
    try png.write(to: URL(fileURLWithPath: path))
    print("готово: \(path)")
}

// Скрипт исполняется на главном потоке, поэтому изоляцию можно занять прямо:
// Task + семафор здесь дают дедлок — главный поток ждёт задачу, которой нужен
// он сам.
MainActor.assumeIsolated {
    try? render(to: CommandLine.arguments[1])
}
