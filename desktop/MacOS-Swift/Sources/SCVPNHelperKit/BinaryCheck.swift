import Foundation

/// Демон отказался запускать то, что ему предложили.
public struct HelperPermissionError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}

/// Канонический путь, или `nil`, если файла нет.
///
/// Через POSIX `realpath`, а не `resolvingSymlinksInPath()`: последний не
/// требует существования файла и вдобавок подменяет `/var` на `/private/var`,
/// то есть отвечает на другой вопрос.
func realPath(_ path: String) -> String? {
    guard let buf = realpath(path, nil) else { return nil }
    defer { free(buf) }
    return String(cString: buf)
}

/// Убедиться, что это наш бинарник и подменить его пользователь не мог.
///
/// Демон работает от root. Запустить файл, в который может писать обычный
/// пользователь, значит отдать ему root — поэтому три проверки: файл лежит в
/// нашей папке, принадлежит root, и не доступен на запись группе и остальным.
///
/// Порядок проверок выбран так, чтобы каждая была причиной отказа хотя бы в
/// одном случае: проверка на root стоит **последней**, иначе она срабатывала бы
/// первой на любом пользовательском файле и накрывала бы собой остальные — в
/// том числе в проверках, которые гоняются не от root.
public func checkBinary(_ path: URL, binDir: URL) throws {
    guard let resolved = realPath(path.path) else {
        throw HelperPermissionError("нет такого бинарника: \(path.path)")
    }
    guard let realBin = realPath(binDir.path) else {
        throw HelperPermissionError("нет папки бинарников: \(binDir.path)")
    }
    // Проверяем канонический путь, а не тот, что прислали: симлинк внутри
    // binDir, ведущий наружу, обязан быть отклонён.
    guard resolved.hasPrefix(realBin + "/") else {
        throw HelperPermissionError("бинарник вне \(binDir.path): \(resolved)")
    }

    var st = stat()
    guard stat(resolved, &st) == 0 else {
        throw HelperPermissionError("не смог прочитать \(resolved)")
    }
    if st.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0 {
        throw HelperPermissionError("бинарник доступен на запись не только root: \(resolved)")
    }
    if st.st_mode & mode_t(S_IXUSR) == 0 {
        throw HelperPermissionError("бинарник не исполняемый: \(resolved)")
    }
    if st.st_uid != 0 {
        throw HelperPermissionError("бинарник не принадлежит root: \(resolved)")
    }
}
