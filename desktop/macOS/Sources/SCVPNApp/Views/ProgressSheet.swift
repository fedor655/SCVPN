import SCVPNCore
import SwiftUI

/// Окно загрузки: полоска и текущий шаг.
///
/// **Отмены нет намеренно.** Прервать можно было бы только сам поток, а он
/// сидит в чтении сокета — на macOS вдобавок в чужом, демоновом, где качает
/// root. Кнопка, которая закрывает окно, но не останавливает загрузку, врёт
/// про то, что она делает.
///
/// **Полоска бегущая, пока никто не считает байты.** Кто умеет — переведёт её
/// в проценты первым же замером; кто не умеет (sing-box качает демон) —
/// оставит бегущей до конца, и это честно.
struct ProgressSheet: View {
    var download: AppModel.Download

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Скачиваю \(download.what)…")
                .font(.scvpnUI(13, weight: .semibold))
                .foregroundStyle(Color.scvpnText)

            if let fraction = download.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text("\(Int(fraction * 100)) %")
                    .font(.scvpnUI(11))
                    .foregroundStyle(Color.scvpnDim)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(download.step)
                .font(.scvpnUI(11))
                .foregroundStyle(Color.scvpnDim)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Style.sheetPadding)
        .frame(width: Style.sheetWidth)
        .background(Color.scvpnSurface)
    }
}
