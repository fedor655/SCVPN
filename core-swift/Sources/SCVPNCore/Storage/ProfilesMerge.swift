import Foundation

/// Слияние профилей при переносе с другой платформы.
///
/// Формат `profiles.json` один на Windows, macOS, iOS и Android, поэтому файл
/// можно унести на любую из них. Вопрос только в том, что делать с тем, что уже
/// есть на устройстве: заменять нельзя — человек переносит профиль поверх
/// непустого списка чаще, чем начисто, и терять при этом свои серверы обидно.
public func mergeProfiles(_ existing: Profiles, _ incoming: Profiles) -> Profiles {
    var merged = existing

    // Одиночные серверы отсекаются по тому же ключу, что и при добавлении
    // ссылкой: тот же сервер под другим именем — тот же сервер.
    var known = Set(existing.allServers().map { $0.key() })
    for server in incoming.servers where known.insert(server.key()).inserted {
        merged.servers.append(server)
    }

    // Подписка опознаётся по ссылке. Совпала — обновляем список её серверов
    // целиком: он и так перезапишется при первом обновлении, а половинчатое
    // слияние оставило бы мёртвые серверы навсегда.
    for sub in incoming.subscriptions {
        if let at = merged.subscriptions.firstIndex(where: { $0.url == sub.url }) {
            merged.subscriptions[at].servers = sub.servers
            merged.subscriptions[at].info = sub.info
            merged.subscriptions[at].updated = sub.updated
        } else {
            merged.subscriptions.append(sub)
        }
        known.formUnion(sub.servers.map { $0.key() })
    }
    return merged
}
