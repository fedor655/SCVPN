import Foundation

/// Обслужить одного клиента и прибрать за ним, когда он отвалится.
///
/// **Главное свойство всего проекта.** Обрыв соединения — это и есть dead-man's
/// switch: приложение мертво, значит туннель надо снять, иначе система
/// останется без интернета. Но снимаем только **свой** туннель — тот, который
/// подняло именно это соединение. Клиентов больше одного бывает:
/// `install_singbox` открывает отдельное соединение на один запрос и закрывает
/// его же — такое соединение не должно ронять чужой активный туннель одним
/// своим обрывом.
public func serveClient(fd: Int32, sup: Supervisor, env: HelperEnv) {
    let conn = ClientHandle(fd: fd)
    // Всё, что может бросить, — внутри. Снаружи не должно оставаться ничего:
    // создание потока не всегда удаётся, и исключение уходило бы мимо уборки,
    // то есть мимо самого dead-man's switch.
    let outbox = Outbox(fd: fd, log: env.log).start()
    let ctx = CommandContext(say: { [weak outbox] s in outbox?.sendLog(["log": s]) }, conn: conn)

    readLines(fd: fd, limit: maxLine, onOverlong: {
        outbox.send(["ok": false, "error": "запрос длиннее допустимого"])
    }, onLine: { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        outbox.send(handleLine(trimmed, ctx, sup, env))
    })

    // Единственная ветка выхода: сюда приходят и обрыв, и EOF, и любая
    // неожиданная ошибка выше. Но снимаем, только если это соединение и есть
    // владелец текущего туннеля — иначе постороннее соединение
    // (install_singbox, status и т.п.) сносило бы чужой активный туннель одним
    // своим закрытием.
    //
    // Ветка `owner == nil` — отказ в безопасную сторону. `owner` сбрасывается
    // только вместе с процессом, так что «протухшего» владельца без процесса
    // не бывает, а вот процесс без владельца в принципе не должен возникать.
    // Если он всё же возникнет (дефект, о котором мы ещё не знаем) — туннель
    // без хозяина обязан снять первый же отключившийся, а не остаться висеть
    // навсегда.
    if sup.isRunning && (sup.owner === conn || sup.owner == nil) {
        env.log("клиент отключился, а туннель поднят — снимаю его")
        sup.stop()
    }
    outbox.close()
    close(fd)
}

/// Читать сокет построчно до EOF, с потолком на длину строки.
///
/// Строка без перевода строки не должна расти в памяти root-процесса
/// бесконечно. Упёрлись в потолок — отвечаем и заканчиваем разговор: такой
/// клиент нам не свой.
func readLines(fd: Int32, limit: Int, onOverlong: () -> Void, onLine: (String) -> Void) {
    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 {
            if errno == EINTR { continue }
            return
        }
        if n == 0 { return }
        buffer.append(contentsOf: chunk[0..<n])

        while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[0..<idx], as: UTF8.self)
            buffer.removeSubrange(0...idx)
            onLine(line)
        }
        if buffer.count >= limit {
            onOverlong()
            return
        }
    }
}
