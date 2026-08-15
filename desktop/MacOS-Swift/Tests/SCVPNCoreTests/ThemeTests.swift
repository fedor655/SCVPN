import XCTest
@testable import SCVPNCore

final class ThemeTests: XCTestCase {

    private func androidColorsXML() throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SCVPNCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MacOS-Swift
            .deletingLastPathComponent()   // desktop
            .deletingLastPathComponent()   // корень репозитория
        let url = repo.appendingPathComponent("android/app/src/main/res/values/colors.xml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_palette_matches_android_colors_xml() throws {
        // Палитра дублируется вручную в трёх местах, и расхождение сегодня
        // никем не проверяется: приложение на одной платформе тихо уезжает в
        // другой оттенок, и замечает это только пользователь с двумя
        // устройствами.
        let xml = try androidColorsXML()
        for color in Palette.all {
            XCTAssertTrue(xml.contains(color), "палитра разошлась с Android: нет \(color)")
        }
    }

    func test_android_defines_every_colour_we_use_by_name() throws {
        let xml = try androidColorsXML()
        for (name, value) in [("bg", Palette.bg), ("surface", Palette.surface),
                              ("surface_hi", Palette.surfaceHi), ("stroke", Palette.stroke),
                              ("text", Palette.text), ("text_dim", Palette.dim),
                              ("muted", Palette.muted), ("accent", Palette.accent)] {
            XCTAssertTrue(xml.contains("name=\"\(name)\">\(value)<"),
                          "у Android \(name) не равен \(value)")
        }
    }

    func test_palette_is_greyscale_only() throws {
        // Цвета в теме нет вовсе — состояния различаются формой и текстом.
        // Появление цветного значения означает, что кто-то начал показывать
        // состояние оттенком, а это ломает и доступность, и Android заодно.
        for hex in Palette.all {
            let c = try XCTUnwrap(rgbComponents(hex), hex)
            XCTAssertEqual(c.r, c.g, accuracy: 0.001, hex)
            XCTAssertEqual(c.g, c.b, accuracy: 0.001, hex)
        }
    }

    func test_hex_parser_handles_the_forms_we_use() {
        XCTAssertEqual(rgbComponents("#000000")?.r, 0)
        XCTAssertEqual(rgbComponents("FFFFFF")?.b, 1)
        XCTAssertNil(rgbComponents("#FFF"))
        XCTAssertNil(rgbComponents("не цвет"))
    }

    func test_header_metrics_leave_room_for_the_traffic_lights() {
        // Светофор стоит слева, надпись — правее него. Съедь отступ, и
        // «SCVPN» окажется под кнопками окна.
        XCTAssertGreaterThan(HeaderMetrics.left, HeaderMetrics.lightsLeft + 3 * 20)
        // Кнопки шапки обязаны помещаться в её высоту.
        XCTAssertGreaterThanOrEqual(HeaderMetrics.height,
                                    HeaderMetrics.top + HeaderMetrics.buttonSide)
    }

    func test_traffic_lights_sit_in_the_middle_of_the_header_row() {
        // Центр кнопок считается как top + сторона/2: именно это значение
        // уходит в sinkTrafficLights, и оно обязано лежать внутри шапки.
        let centre = HeaderMetrics.top + HeaderMetrics.buttonSide / 2
        XCTAssertLessThan(centre, HeaderMetrics.height)
        XCTAssertGreaterThan(centre, 0)
    }
}
