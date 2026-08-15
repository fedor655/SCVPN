#if os(iOS)
import Foundation
import Security

/// Малая обёртка над Keychain — ровно на одно значение: источник HWID.
///
/// Зачем вообще: контейнер приложения умирает вместе с приложением, а
/// `identifierForVendor` обнуляется, когда удалены все приложения вендора.
/// Keychain переживает и то и другое, поэтому HWID не меняется после
/// переустановки и пользователь не занимает второй слот в лимите устройств
/// своей подписки.
///
/// `ThisDeviceOnly` — намеренно: значение не должно уехать в чужой бэкап и
/// стать «тем же устройством» на другом телефоне. `AfterFirstUnlock` — тоже:
/// расширение туннеля может стартовать до того, как человек разблокировал
/// экран.
public enum Keychain {
    private static let service = "com.scvpn.ios"

    public static func load(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Перезапись, а не «добавить»: SecItemAdd на существующем ключе
        // возвращает errSecDuplicateItem и молча ничего не делает.
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif
