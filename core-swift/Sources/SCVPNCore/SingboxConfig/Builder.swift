// Только macOS: демон, sing-box, системный прокси и дочерние процессы.
// На iOS ничего этого нет — там туннель поднимает NEPacketTunnelProvider.
#if os(macOS)
import Foundation

/// Конфиг sing-box: TUN -> SOCKS Xray, плюс правила раздельного туннеля.
///
/// Раздельное туннелирование делает сам sing-box: он умеет сопоставлять
/// соединение с процессом-владельцем (`process_name`) и отправлять его либо в
/// туннель, либо напрямую. Поэтому это работает только в TUN-режиме —
/// системный прокси про приложения ничего не знает.
///
/// `params` приходит только из `validate`, поэтому проверок здесь уже нет.
///
/// Отличия от windows-варианта конфига:
///   - нет `strict_route`: поле поддержано только на Linux и Windows;
///   - нет `interface_name`: utun-устройства именует ядро, своё имя не задать;
///   - wintun не нужен, TUN на macOS штатный.
public func buildSingboxConfig(_ p: SingboxParams, xrayPath: String) -> [String: Any] {
    let excludes = p.excludeIPs.map { ip in
        ipVersion(ip) == 4 ? "\(ip)/32" : "\(ip)/128"
    }

    var rules: [[String: Any]] = []

    // Первым делом выводим из туннеля сам Xray. Без этого соединение ядра к
    // серверу снова попадает в TUN, оттуда обратно в ядро — и так по кругу.
    // Это правило переживает смену IP сервера, в отличие от списка исключений
    // ниже, поэтому оно главный пояс, а route_exclude_address — запасной.
    //
    // Процесса `scvpn-awg` здесь намеренно нет, хотя наружу ходит именно он.
    // Его путь пришлось бы протащить через протокол привилегированного демона
    // и его проверку пути — ради случая, где запасного пояса достаточно: у
    // wireguard-сервера Endpoint это фиксированный адрес из конфига, а не имя,
    // которое панель может переставить на другой IP посреди сессии. Так что
    // route_exclude_address покрывает его точно. Появится wireguard-сервер с
    // Endpoint по имени и меняющимся IP — правило придётся завести.
    rules.append(["process_path": [xrayPath], "outbound": "direct"])

    if !p.splitApps.isEmpty {
        switch p.splitMode {
        case .exclude:
            // Выбранные — мимо VPN, всё остальное (final) — в туннель.
            rules.append(["process_name": p.splitApps, "outbound": "direct"])
        case .include:
            // Выбранные — в туннель, всё остальное — напрямую (см. final ниже).
            rules.append(["process_name": p.splitApps, "outbound": "to-xray"])
        case .off:
            break
        }
    }

    let final = (!p.splitApps.isEmpty && p.splitMode == .include) ? "direct" : "to-xray"

    return [
        "log": ["level": p.logLevel],
        "inbounds": [
            [
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.18.0.1/30"],
                "mtu": 1500,
                "auto_route": true,
                "stack": p.stack.rawValue,
                "route_exclude_address": excludes,
            ] as [String: Any]
        ],
        "outbounds": [
            [
                "type": "socks",
                "tag": "to-xray",
                "server": "127.0.0.1",
                "server_port": p.socksPort,
                "version": "5",
            ] as [String: Any],
            ["type": "direct", "tag": "direct"] as [String: Any],
        ],
        "route": [
            "auto_detect_interface": true,
            "final": final,
            "rules": rules,
        ] as [String: Any],
    ]
}
#endif
