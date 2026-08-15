import Foundation

/// URL архива sing-box для darwin/arm64 из списка ассетов релиза.
public func pickSingboxAsset(_ assets: [[String: Any]]) throws -> String {
    for asset in assets {
        if let name = asset["name"] as? String, name.hasSuffix("darwin-arm64.tar.gz"),
           let url = asset["browser_download_url"] as? String {
            return url
        }
    }
    throw HelperError("в релизе sing-box не найден архив darwin-arm64.tar.gz")
}

/// Синхронно скачать URL.
///
/// `URLSession` в root-овом демоне без runloop работает, но результат приходит
/// на фоновой очереди — отсюда семафор. Запасным путём был `/usr/bin/curl`; он
/// не понадобился.
func fetch(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval) throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

    var result: Result<Data, Error>?
    let sem = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            result = .failure(error)
        } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            result = .failure(HelperError("сервер ответил \(http.statusCode) на \(url.absoluteString)"))
        } else {
            result = .success(data ?? Data())
        }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
        task.cancel()
        throw HelperError("не дождался ответа от \(url.host ?? url.absoluteString)")
    }
    switch result {
    case .success(let data): return data
    case .failure(let e): throw e
    case nil: throw HelperError("пустой ответ от \(url.absoluteString)")
    }
}

/// Скачать sing-box в свою папку. Вернуть версию.
public func installSingbox(_ env: HelperEnv, say: (String) -> Void) throws -> String {
    let helperDir = env.binDir.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: env.binDir, withIntermediateDirectories: true)
    chown(helperDir.path, 0, 0)
    chown(env.binDir.path, 0, 0)
    chmod(env.binDir.path, 0o755)

    say("Узнаю последнюю версию sing-box…")
    let meta = try fetch(URL(string: singboxReleasesAPI)!,
                         headers: ["Accept": "application/vnd.github+json"], timeout: 30)
    guard let json = try JSONSerialization.jsonObject(with: meta) as? [String: Any] else {
        throw HelperError("не разобрал ответ GitHub про релиз sing-box")
    }
    let tag = json["tag_name"] as? String ?? "?"
    let assets = json["assets"] as? [[String: Any]] ?? []
    let urlString = try pickSingboxAsset(assets)
    guard let url = URL(string: urlString) else {
        throw HelperError("кривая ссылка на архив sing-box: \(urlString)")
    }

    say("Версия sing-box \(tag). Скачиваю…")
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scvpn-singbox-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let archive = tmp.appendingPathComponent("sing-box.tar.gz")
    try fetch(url, timeout: 180).write(to: archive)

    say("Распаковываю…")
    // /usr/bin/tar, а не свой разборщик и не libarchive: tar есть в системе
    // всегда, а разбор чужого архива в root-процессе — лишняя поверхность.
    guard let r = runProcTool(["/usr/bin/tar", "-xzf", archive.path, "-C", tmp.path]),
          r.status == 0 else {
        throw HelperError("не смог распаковать архив sing-box")
    }

    guard let found = findFile(named: "sing-box", under: tmp) else {
        throw HelperError("sing-box не найден в архиве")
    }

    let target = env.singboxExe
    try? FileManager.default.removeItem(at: target)
    try FileManager.default.moveItem(at: found, to: target)

    // root:wheel 0755 — иначе checkBinary откажется его запускать, и правильно.
    chown(target.path, 0, 0)
    chmod(target.path, 0o755)
    say("Готово. sing-box \(tag) установлен.")
    return tag
}

func findFile(named name: String, under root: URL) -> URL? {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return nil
    }
    for case let url as URL in e {
        if url.lastPathComponent == name,
           (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            return url
        }
    }
    return nil
}

/// Удалить sing-box из своей папки. `true` — файла больше нет.
///
/// Живой туннель — отказ, а не «удалю, а там разберёмся»: `unlink` уберёт имя,
/// но работающий процесс останется держать маршруты, и снять его будет уже
/// нечем — бинарника, по командной строке которого его ищет `killStaleSingbox`,
/// на диске не будет. Поэтому сначала стоп, потом удаление, и оба шага — по
/// явной команде пользователя.
public func removeSingbox(_ env: HelperEnv, sup: Supervisor, say: (String) -> Void) throws -> Bool {
    if sup.isRunning {
        throw HelperError("туннель поднят — сначала отключитесь")
    }
    let target = env.singboxExe
    guard FileManager.default.fileExists(atPath: target.path) else {
        say("sing-box и так не установлен.")
        return false
    }
    try FileManager.default.removeItem(at: target)
    say("sing-box удалён.")
    return true
}
