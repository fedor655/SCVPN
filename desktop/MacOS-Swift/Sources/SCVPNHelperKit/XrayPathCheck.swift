import Foundation
import SCVPNCore

/// Проверить путь к ядру Xray, присланный клиентом.
///
/// Этот путь попадает в правило `process_path`, которое выпускает процесс мимо
/// туннеля. Подставив туда чужой бинарник, злоумышленник раздал бы себе обход
/// VPN — поэтому проверяем имя, существование и права.
///
/// Имя проверяем **после** канонизации, а не до. Раньше было наоборот, и
/// симлинк с именем `xray`, ведущий на `/bin/sh`, проходил проверку именем, а в
/// правило уезжал уже `/bin/sh` — ровно тот обход, который эта функция обязана
/// закрыть.
///
/// Чего здесь нет: требования root-владельца. Ядро Xray лежит в папке самого
/// пользователя и ему же принадлежит — от владельца мы не защищаемся, он и так
/// может делать со своим файлом что угодно. Защищаемся от чужих: файл,
/// открытый на запись группе или остальным, отклоняем.
public func checkedXrayPath(_ raw: Any?) throws -> String {
    guard let path = raw as? String, path.hasPrefix("/") else {
        throw ValidationError("путь к ядру должен быть абсолютным, пришло \(raw ?? "nil")")
    }
    guard let resolved = realPath(path) else {
        throw ValidationError("нет такого файла: \(path)")
    }
    guard (resolved as NSString).lastPathComponent == "xray" else {
        throw ValidationError(
            "ожидался бинарник с именем xray, а путь ведёт на "
            + "\((resolved as NSString).lastPathComponent)")
    }
    var st = stat()
    guard stat(resolved, &st) == 0 else {
        throw ValidationError("не смог прочитать \(resolved)")
    }
    guard st.st_mode & S_IFMT == S_IFREG else {
        throw ValidationError("это не файл: \(resolved)")
    }
    if st.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0 {
        throw ValidationError("ядро доступно на запись группе или остальным: \(resolved)")
    }
    return resolved
}
