import Foundation

/// Все пути приложения в одном месте — чтобы было видно, где что лежит.
///
/// Отличие от Python-версии: там папки при запуске из исходников лежали рядом с
/// проектом, а в собранном виде — в Application Support. Здесь запуск бывает
/// только из бандла (см. раздел 0.1 плана), поэтому вилки нет.
///
/// Значения — переменные, а не константы: проверки подменяют корень на
/// временную папку, иначе они писали бы в настоящие профили пользователя.
public enum Paths {
    /// Пользовательская папка macOS для данных приложения.
    public static var dataDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SCVPN")

    /// Папка с ядром и гео-базами (xray, geoip.dat, geosite.dat).
    ///
    /// Внутрь `.app` писать нельзя, а ядро приложение скачивает само.
    public static var binDir: URL { dataDir.appendingPathComponent("bin") }

    public static var logDir: URL { dataDir.appendingPathComponent("logs") }

    /// Серверы и подписки.
    public static var profilesFile: URL { dataDir.appendingPathComponent("profiles.json") }
    /// Настройки приложения.
    public static var settingsFile: URL { dataDir.appendingPathComponent("settings.json") }
    /// Активный конфиг ядра — лежит на диске для отладки.
    public static var xrayConfigFile: URL { dataDir.appendingPathComponent("xray_running.json") }
    /// PID запущенного ядра: приложение может умереть аварийно, и следующий
    /// запуск обязан найти осиротевший xray и снять его.
    public static var xrayPIDFile: URL { dataDir.appendingPathComponent("xray.pid") }

    // ------------------------------------------------------------------
    // Хозяйство привилегированного демона
    // ------------------------------------------------------------------
    // sing-box запускает root, поэтому он обязан лежать там, куда пользователь
    // не может писать: иначе любой процесс подменил бы бинарник и получил root.
    // Эту папку заводит и наполняет сам демон (root:wheel, 0755).
    public static let helperDir = URL(fileURLWithPath: "/Library/Application Support/SCVPN")
    public static var helperBinDir: URL { helperDir.appendingPathComponent("bin") }
    public static let helperSocket = "/var/run/scvpn-helper.sock"
    public static let helperLabel = "com.scvpn.helper"

    public static var xrayExe: URL { binDir.appendingPathComponent("xray") }
    /// sing-box используется только для TUN-режима и живёт в root-овой папке.
    public static var singboxExe: URL { helperBinDir.appendingPathComponent("sing-box") }
    public static var geoipDat: URL { binDir.appendingPathComponent("geoip.dat") }
    public static var geositeDat: URL { binDir.appendingPathComponent("geosite.dat") }

    public static func ensureDirs() {
        for d in [binDir, dataDir, logDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}
