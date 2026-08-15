import Foundation

/// Разовое скачивание ядра Xray-core с официального GitHub.
///
/// Берём последний релиз XTLS/Xray-core, качаем архив для macOS arm64 и
/// распаковываем в `bin/` ровно три файла. Это единственный внешний источник, и
/// он официальный и открытый.
///
/// Подписывать скачанное не нужно: линковщик Go сам проставляет ad-hoc подпись
/// для darwin/arm64, иначе бинарник не запустился бы вовсе. Достаточно дать
/// право на исполнение.
///
/// sing-box здесь нет намеренно: его запускает root, поэтому качает и кладёт
/// его к себе привилегированный демон.
public enum CoreDownloader {
    public static let releasesAPI = "https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    public static let assetName = "Xray-macos-arm64-v8a.zip"
    public static let wanted: Set<String> = ["xray", "geoip.dat", "geosite.dat"]

    /// Тег версии и ссылка на архив последнего релиза.
    public static func pickAsset(tag: String, assets: [[String: Any]]) throws -> (tag: String, url: URL) {
        for asset in assets where asset["name"] as? String == assetName {
            guard let raw = asset["browser_download_url"] as? String, let url = URL(string: raw) else {
                break
            }
            return (tag, url)
        }
        throw ValidationError("В релизе \(tag) не найден ассет \(assetName)")
    }

    public static func latestXrayAsset() async throws -> (tag: String, url: URL) {
        var request = URLRequest(url: URL(string: releasesAPI)!, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ValidationError("GitHub не отдал сведения о релизе Xray-core")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("не разобрал ответ GitHub про релиз Xray-core")
        }
        return try pickAsset(tag: json["tag_name"] as? String ?? "?",
                             assets: json["assets"] as? [[String: Any]] ?? [])
    }

    /// Скачать и распаковать ядро. Вернуть версию.
    ///
    /// `onBytes` отдельным колбэком, а не строкой в лог: иначе каждый кусок
    /// уезжал бы в лог отдельной строкой, и на пятнадцатимегабайтном архиве это
    /// две с лишним сотни строк «Скачано X / Y КБ», в которых тонет всё
    /// остальное.
    public static func downloadCore(
        progress: @escaping (String) -> Void = { _ in },
        onBytes: @escaping (Int, Int) -> Void = { _, _ in }
    ) async throws -> String {
        Paths.ensureDirs()

        progress("Узнаю последнюю версию Xray-core…")
        let (tag, url) = try await latestXrayAsset()
        progress("Версия \(tag). Скачиваю \(assetName)…")

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = Int((response as? HTTPURLResponse)?.expectedContentLength ?? 0)
        var data = Data()
        data.reserveCapacity(max(total, 1 << 20))
        var got = 0
        var lastReport = 0
        for try await byte in bytes {
            data.append(byte)
            got += 1
            // Докладываем не на каждый байт: колбэк идёт в интерфейс, и
            // пятнадцать миллионов обновлений полоски его просто повесят.
            if got - lastReport >= 64 * 1024 {
                lastReport = got
                onBytes(got, total)
            }
        }
        onBytes(got, total)

        progress("Распаковываю…")
        try unpack(data, progress: progress)

        let missing = wanted.filter {
            !FileManager.default.fileExists(atPath: Paths.binDir.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw ValidationError("После распаковки не хватает файлов: \(missing.sorted())")
        }

        progress("Готово. Ядро Xray-core \(tag) установлено в bin/")
        return tag
    }

    /// Распаковать нужные файлы из zip.
    ///
    /// `/usr/bin/unzip`, а не свой разборщик: он есть в системе всегда, а
    /// разбор чужого архива своими руками — лишний код с лишними ошибками.
    /// Флаг `-j` кладёт файлы без путей: внутри архива они лежат в подпапке.
    static func unpack(_ archive: Data, progress: (String) -> Void) throws {
        let tmp = URL(fileURLWithPath: "/tmp/scvpn-xray-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let zip = tmp.appendingPathComponent("xray.zip")
        try archive.write(to: zip)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-j", zip.path] + wanted.sorted() + ["-d", Paths.binDir.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ValidationError("не смог распаковать \(assetName)")
        }

        for name in wanted.sorted() {
            progress("  -> bin/\(name)")
        }
        finishUnpacked()
    }

    /// Довести распакованное до годного: бит исполнения и снятие карантина.
    static func finishUnpacked() {
        let exe = Paths.xrayExe
        // Из zip права не переносятся — бит исполнения ставим сами.
        var st = stat()
        if stat(exe.path, &st) == 0 {
            chmod(exe.path, st.st_mode | mode_t(S_IXUSR | S_IXGRP | S_IXOTH))
        }
        // Карантин снимаем безусловно со всех трёх файлов, ENOATTR игнорируем.
        // Одна строка, снимающая целый класс проблем: файл с
        // com.apple.quarantine система откажется запускать, а объяснение
        // пользователь увидит в виде окна про «неизвестного разработчика».
        for name in wanted {
            let path = Paths.binDir.appendingPathComponent(name).path
            removexattr(path, "com.apple.quarantine", 0)
        }
    }

    public static func corePresent() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Paths.xrayExe.path)
            && fm.fileExists(atPath: Paths.geoipDat.path)
            && fm.fileExists(atPath: Paths.geositeDat.path)
    }

    /// Лежит ли sing-box на месте.
    ///
    /// **Про демона здесь не спрашиваем намеренно.** Раньше это было
    /// «демон установлен И бинарник на месте», и понятия оказывались
    /// вложенными, хотя ставит демона совсем другая ветка. На чистой машине из
    /// такой вложенности получался неснимаемый круг: префлайт требовал
    /// компоненты раньше прав, компонентов не было, потому что их кладёт демон,
    /// а демона ставила только ветка прав — за уже непроходимым гейтом.
    ///
    /// Проверка работает и без root: папка демона read-only для пользователя,
    /// но читаемая (0755).
    public static func tunPresent() -> Bool {
        FileManager.default.fileExists(atPath: Paths.singboxExe.path)
    }
}
