import LinkPresentation
import SwiftUI
import UIKit

/// Поделиться строкой именно как текстом.
///
/// Система разворачивает всё, что похоже на ссылку: сама идёт по адресу и
/// предлагает отправить **содержимое**. Для подписки это весь список серверов
/// вместо её адреса — и приходит он тому, кому отправили. Поэтому превью
/// задаётся вручную, без `url` в метаданных: тогда в сеть никто не ходит.
struct ShareText: UIViewControllerRepresentable {
    var text: String
    var title: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [PlainText(text: text, title: title)],
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class PlainText: NSObject, UIActivityItemSource {
    let text: String
    let title: String

    init(text: String, title: String) {
        self.text = text; self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        text
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        // `url` намеренно не заполняем: с ним система лезет за содержимым.
        return metadata
    }
}
