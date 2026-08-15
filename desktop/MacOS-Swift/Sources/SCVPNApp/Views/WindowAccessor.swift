import AppKit
import SCVPNCore
import SwiftUI

/// Опустить светофор и отодвинуть его от левого края.
///
/// Прямой перенос `native/titlebar.py`, только без 76 строк `ctypes` вокруг
/// `objc_msgSend` с явными `argtypes` — те понадобились из-за того, что на
/// arm64 вариативный вызов без них молча ломается. Здесь это обычные вызовы
/// AppKit.
///
/// **AppKit возвращает кнопки на штатную высоту при каждой перекладке
/// заголовка**, поэтому звать надо снова после показа и после каждого resize.
func sinkTrafficLights(_ window: NSWindow,
                       centerFromTop: CGFloat = HeaderMetrics.top + HeaderMetrics.buttonSide / 2,
                       left: CGFloat = HeaderMetrics.lightsLeft) {
    let buttons = [NSWindow.ButtonType.closeButton,
                   .miniaturizeButton,
                   .zoomButton].compactMap { window.standardWindowButton($0) }
    guard buttons.count == 3, let container = buttons[0].superview?.superview else { return }

    // Просто сдвинуть кнопки вниз мало: они уедут за пределы контейнера
    // заголовка и пропадут. Растим сам контейнер (верх остаётся на месте,
    // координаты AppKit растут вверх) и ставим кнопки в его центр.
    let frame = container.frame
    let height = centerFromTop * 2
    container.setFrameOrigin(NSPoint(x: frame.origin.x,
                                     y: frame.origin.y + frame.size.height - height))
    container.setFrameSize(NSSize(width: frame.size.width, height: height))

    // Расстояние между кнопками не трогаем — двигаем всю тройку на одну дельту.
    let shift = left - buttons[0].frame.origin.x
    for button in buttons {
        let box = button.frame
        button.setFrameOrigin(NSPoint(x: box.origin.x + shift,
                                      y: (height - box.size.height) / 2))
    }
}

/// Настроить окно один раз и следить за перекладками заголовка.
///
/// `.windowStyle(.hiddenTitleBar)` даёт `titlebarAppearsTransparent` и
/// `fullSizeContentView` разом — это то же, что в Qt делали два флага
/// `ExpandedClientAreaHint` и `NoTitleBarBackgroundHint`. Чего он не делает —
/// не опускает светофор, за этим и нужен доступ к `NSWindow`.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Окно у представления появляется не сразу — ждём следующего витка.
        DispatchQueue.main.async { configure(view.window, context: context) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window, context: context) }
    }

    private func configure(_ window: NSWindow?, context: Context) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true   // полосы нет, тащить не за что
        window.backgroundColor = NSColor.black

        context.coordinator.observe(window)
        context.coordinator.scheduleSink(window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var observed: NSWindow?

        func observe(_ window: NSWindow) {
            guard observed !== window else { return }
            observed = window
            for name in [NSWindow.didResizeNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in self?.scheduleSink(window) }
            }
        }

        /// Двигаем не сразу: AppKit доперекладывает заголовок после события и
        /// вернул бы кнопки на место. Второй заход — ради выхода из полного
        /// экрана, там перекладка приезжает уже после анимации.
        func scheduleSink(_ window: NSWindow) {
            DispatchQueue.main.async { sinkTrafficLights(window) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sinkTrafficLights(window)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
