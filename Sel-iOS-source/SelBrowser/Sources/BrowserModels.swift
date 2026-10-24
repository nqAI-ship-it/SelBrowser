import Foundation
import WebKit

struct BrowserSettings: Codable {
    var theme = "light"
    var searchEngine = "yandex"
    var restoreSession = true
    var closeTabBehavior = "right"
    var defaultZoomPercent = 100

    enum CodingKeys: String, CodingKey { case theme, searchEngine, restoreSession, closeTabBehavior, defaultZoomPercent }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "light"
        searchEngine = try c.decodeIfPresent(String.self, forKey: .searchEngine) ?? "yandex"
        restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? true
        closeTabBehavior = try c.decodeIfPresent(String.self, forKey: .closeTabBehavior) ?? "right"
        defaultZoomPercent = try c.decodeIfPresent(Int.self, forKey: .defaultZoomPercent) ?? 100
        if !["light", "dark", "wc2026"].contains(theme) { theme = "light" }
        if !["google", "yandex", "duckduckgo"].contains(searchEngine) { searchEngine = "yandex" }
        if !["right", "left", "recent"].contains(closeTabBehavior) { closeTabBehavior = "right" }
        if !(50...200).contains(defaultZoomPercent) { defaultZoomPercent = 100 }
    }
    var shellState: [String: Any] {
        ["theme": theme, "searchEngine": searchEngine, "RestoreSession": restoreSession,
         "CloseTabBehavior": closeTabBehavior, "DefaultZoomPercent": defaultZoomPercent,
         "MemorySaver": false, "SuspendAfterMinutes": 10]
    }
}

struct Bookmark: Codable {
    var id = UUID().uuidString
    var title: String
    var url: String
    var addedAt = Date()
}

struct HistoryEntry: Codable {
    var title: String
    var url: String
    var visitedAt = Date()
}

struct SavedTab: Codable {
    var id: String
    var url: String
    var pinned: Bool
}

struct BrowserSnapshot: Codable {
    var settings = BrowserSettings()
    var bookmarks: [Bookmark] = []
    var history: [HistoryEntry] = []
    var session: [SavedTab] = []
    var activeID: String?
}

final class BrowserStorage {
    private let file: URL
    private(set) var loadWarning: String?
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelBrowser", isDirectory: true)
        file = directory.appendingPathComponent("state.json")
    }
    func load() -> BrowserSnapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return BrowserSnapshot() }
        do { return try JSONDecoder().decode(BrowserSnapshot.self, from: Data(contentsOf: file)) }
        catch {
            loadWarning = "Сохранённый профиль не удалось прочитать. Его файл оставлен на диске."
            // Preserve a corrupt profile rather than overwriting it during the first launch.
            let recovery = file.deletingLastPathComponent().appendingPathComponent("state-corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: file, to: recovery)
            return BrowserSnapshot()
        }
    }
    func save(_ state: BrowserSnapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

final class BrowserTab {
    let id: String
    var url: String
    var title: String
    var pinned: Bool
    var webView: WKWebView?
    var observations: [NSKeyValueObservation] = []
    var hasLoaded = false
    var favicon = ""
    var faviconGeneration = UUID()
    var faviconTask: URLSessionDataTask?
    var lastSelected = Date()
    var lastRecordedURL: String?
    init(url: String = "sel://newtab", id: String = UUID().uuidString, pinned: Bool = false) {
        self.id = id; self.url = url; self.pinned = pinned
        self.title = BrowserAddress.title(for: url)
    }
    func dispose() {
        faviconTask?.cancel(); faviconTask = nil
        observations.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }
    deinit { faviconTask?.cancel() }
}

final class BrowserContext {
    let isPrivate: Bool
    let dataStore: WKWebsiteDataStore
    var settings: BrowserSettings
    var bookmarks: [Bookmark]
    var history: [HistoryEntry]
    var tabs: [BrowserTab] = []
    var activeID: String?
    var closed: [SavedTab] = []
    init(isPrivate: Bool, settings: BrowserSettings, bookmarks: [Bookmark], history: [HistoryEntry] = []) {
        self.isPrivate = isPrivate; self.settings = settings; self.bookmarks = bookmarks; self.history = history
        dataStore = isPrivate ? .nonPersistent() : .default()
    }
    var active: BrowserTab? { tabs.first { $0.id == activeID } }
    func snapshot() -> BrowserSnapshot {
        var s = BrowserSnapshot()
        s.settings = settings; s.bookmarks = bookmarks; s.history = Array(history.prefix(2000))
        s.session = tabs.filter { BrowserAddress.isWeb($0.url) || $0.url.hasPrefix("sel://") }
            .map { SavedTab(id: $0.id, url: $0.url, pinned: $0.pinned) }
        s.activeID = activeID
        return s
    }
}

enum BrowserAddress {
    static func isWeb(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return false }
        return true
    }
    static func resolve(_ input: String, engine: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "sel://newtab" }
        if ["sel://newtab", "sel://settings", "sel://bookmarks", "sel://history", "sel://downloads", "sel://help"].contains(text) { return text }
        if isWeb(text) { return text }
        let hasSpaces = text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        if !hasSpaces {
            let host = text.components(separatedBy: "/").first ?? text
            let localhost = host == "localhost" || host.hasPrefix("localhost:") || host.hasPrefix("127.") || host.hasPrefix("[")
            if (localhost || host.contains(".")), let result = URL(string: (localhost ? "http://" : "https://") + text), result.host != nil { return result.absoluteString }
            if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return nil }
        }
        var c = URLComponents(string: engine == "google" ? "https://www.google.com/search" : engine == "duckduckgo" ? "https://duckduckgo.com/" : "https://yandex.ru/search/")!
        c.queryItems = [URLQueryItem(name: engine == "yandex" ? "text" : "q", value: text)]
        return c.url?.absoluteString
    }
    static func title(for url: String) -> String {
        switch url {
        case "sel://newtab": return "Новая вкладка"
        case "sel://settings": return "Настройки"
        case "sel://bookmarks": return "Закладки"
        case "sel://history": return "История"
        case "sel://downloads": return "Загрузки"
        case "sel://help": return "О Sel"
        default: return URL(string: url)?.host ?? "Вкладка"
        }
    }
}
