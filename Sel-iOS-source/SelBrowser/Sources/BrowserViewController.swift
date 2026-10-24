import UIKit
import WebKit

// Only the local shell receives a native message handler. Website configurations never do.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserViewController?
    init(_ owner: BrowserViewController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receiveShellMessage(message)
    }
}

final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private let storage = BrowserStorage()
    private var normal: BrowserContext!
    private var privateContext: BrowserContext?
    private var context: BrowserContext!
    private let container = UIView()
    private var shell: WKWebView!
    private var shellURL: URL?
    private var shellReady = false
    private var lastShellJSON = ""
    private var contentBounds = CGRect.zero
    private var saveWork: DispatchWorkItem?
    private var stateWork: DispatchWorkItem?
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var retainedDownloads: [ObjectIdentifier: WKDownload] = [:]
    private var storageErrorShown = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        let saved = storage.load()
        normal = BrowserContext(isPrivate: false, settings: saved.settings, bookmarks: saved.bookmarks, history: saved.history)
        context = normal
        if saved.settings.restoreSession {
            normal.tabs = saved.session.prefix(40).filter { BrowserAddress.isWeb($0.url) || ["sel://newtab", "sel://settings"].contains($0.url) }
                .map { BrowserTab(url: $0.url, id: $0.id, pinned: $0.pinned) }
            normal.activeID = saved.activeID
        }
        if normal.tabs.isEmpty { normal.tabs = [BrowserTab()] }
        if normal.active == nil { normal.activeID = normal.tabs.first?.id }
        configureShell()
        if let tab = context.active { select(tab) }
        NotificationCenter.default.addObserver(self, selector: #selector(backgroundSave), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        shell?.frame = container.bounds
        layoutWebsiteViews()
    }

    private func configureShell() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakMessageHandler(self), name: "sel")
        shell = WKWebView(frame: container.bounds, configuration: configuration)
        shell.navigationDelegate = self
        shell.uiDelegate = self
        shell.scrollView.isScrollEnabled = false
        shell.isOpaque = false
        shell.backgroundColor = .clear
        container.addSubview(shell)
        shellURL = Bundle.main.url(forResource: "Shell", withExtension: "html", subdirectory: "Resources")
            ?? Bundle.main.url(forResource: "Shell", withExtension: "html")
        guard let url = shellURL else {
            DispatchQueue.main.async { [weak self] in self?.alert("Нет ресурсов интерфейса", "Файл Shell.html не включён в сборку.") }
            return
        }
        shell.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func layoutWebsiteViews() {
        let fallback = CGRect(x: 0, y: 84, width: container.bounds.width, height: max(0, container.bounds.height - 84))
        let frame = contentBounds.width > 0 ? contentBounds : fallback
        for c in allContexts { for tab in c.tabs { tab.webView?.frame = frame } }
    }

    private var allContexts: [BrowserContext] { [normal, privateContext].compactMap { $0 } }

    private func context(for webView: WKWebView) -> BrowserContext? {
        allContexts.first { c in c.tabs.contains { $0.webView === webView } }
    }

    private func tab(for webView: WKWebView) -> BrowserTab? {
        allContexts.flatMap { $0.tabs }.first { $0.webView === webView }
    }

    private func makeWebsiteView(for tab: BrowserTab, in owner: BrowserContext, supplied: WKWebViewConfiguration? = nil) -> WKWebView {
        if let existing = tab.webView { return existing }
        let configuration = supplied ?? WKWebViewConfiguration()
        configuration.websiteDataStore = owner.dataStore
        // A popup's supplied configuration also comes from a website without host handlers.
        configuration.userContentController.removeScriptMessageHandler(forName: "sel")
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let webView = WKWebView(frame: contentBounds, configuration: configuration)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = CGFloat(owner.settings.defaultZoomPercent) / 100
        webView.isHidden = true
        tab.webView = webView
        container.addSubview(webView)
        let update: () -> Void = { [weak self, weak tab, weak owner] in
            guard let self = self, let tab = tab, let owner = owner, owner.tabs.contains(where: { $0 === tab }) else { return }
            if !tab.url.hasPrefix("sel://"), let title = tab.webView?.title, !title.isEmpty { tab.title = String(title.prefix(512)) }
            if let url = tab.webView?.url, !tab.url.hasPrefix("sel://") { tab.url = url.absoluteString }
            self.scheduleState()
            if !owner.isPrivate { self.scheduleSave() }
        }
        tab.observations = [
            webView.observe(\.title, options: [.new]) { _, _ in update() },
            webView.observe(\.url, options: [.new]) { _, _ in update() },
            webView.observe(\.isLoading, options: [.new]) { _, _ in update() },
            webView.observe(\.canGoBack, options: [.new]) { _, _ in update() },
            webView.observe(\.canGoForward, options: [.new]) { _, _ in update() }
        ]
        layoutWebsiteViews()
        return webView
    }

    @discardableResult
    private func newTab(_ input: String = "sel://newtab", activate: Bool = true) -> BrowserTab {
        let resolved = BrowserAddress.resolve(input, engine: context.settings.searchEngine) ?? "sel://newtab"
        let tab = BrowserTab(url: resolved)
        context.tabs.append(tab)
        if activate || context.active == nil { select(tab) }
        scheduleState(); if !context.isPrivate { scheduleSave() }
        return tab
    }

    private func select(_ tab: BrowserTab) {
        guard context.tabs.contains(where: { $0 === tab }) else { return }
        context.activeID = tab.id; tab.lastSelected = Date()
        for c in allContexts { for t in c.tabs { t.webView?.isHidden = true } }
        if !tab.url.hasPrefix("sel://") {
            let webView = makeWebsiteView(for: tab, in: context)
            webView.isHidden = false; container.bringSubviewToFront(webView)
            if !tab.hasLoaded, let url = URL(string: tab.url) {
                tab.hasLoaded = true; webView.load(URLRequest(url: url))
            }
        }
        pushState(); if !context.isPrivate { scheduleSave() }
    }

    private func close(_ tab: BrowserTab) {
        guard let index = context.tabs.firstIndex(where: { $0 === tab }) else { return }
        context.closed.append(SavedTab(id: tab.id, url: tab.url, pinned: tab.pinned))
        context.closed = Array(context.closed.suffix(50))
        let wasActive = context.activeID == tab.id
        context.tabs.remove(at: index); tab.dispose()
        if context.tabs.isEmpty { newTab() }
        else if wasActive {
            let next: BrowserTab
            switch context.settings.closeTabBehavior {
            case "left": next = context.tabs[max(0, index - 1)]
            case "recent": next = context.tabs.max(by: { $0.lastSelected < $1.lastSelected })!
            default: next = context.tabs[min(index, context.tabs.count - 1)]
            }
            select(next)
        }
        pushState(); if !context.isPrivate { scheduleSave() }
    }

    private func restoreClosed() {
        guard let saved = context.closed.popLast() else { return }
        let tab = newTab(saved.url); tab.pinned = saved.pinned; pushState()
    }

    private func navigate(_ input: String) {
        guard let tab = context.active else { return }
        guard let target = BrowserAddress.resolve(input, engine: context.settings.searchEngine) else { alert("Адрес не поддерживается", "Введите HTTP- или HTTPS-адрес либо поисковый запрос."); return }
        switch target {
        case "sel://bookmarks": showBookmarks(); return
        case "sel://history": showHistory(); return
        case "sel://downloads": showDownloads(); return
        case "sel://help": showAbout(); return
        default: break
        }
        tab.url = target; tab.title = BrowserAddress.title(for: target)
        if target.hasPrefix("sel://") { select(tab) }
        else if let url = URL(string: target) {
            let webView = makeWebsiteView(for: tab, in: context)
            tab.hasLoaded = true; tab.favicon = ""; tab.faviconTask?.cancel()
            select(tab); webView.load(URLRequest(url: url))
        }
        pushState(); if !context.isPrivate { scheduleSave() }
    }

    func receiveShellMessage(_ message: WKScriptMessage) {
        guard message.webView === shell, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == shellURL?.standardizedFileURL,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        // Dispatch outside WebKit callbacks before presenting or disposing UI.
        DispatchQueue.main.async { [weak self] in self?.handle(action, body: body) }
    }

    private func handle(_ action: String, body: [String: Any]) {
        let value = body["value"].map { String(describing: $0) } ?? ""
        let extra = body["extra"]
        switch action {
        case "ready": shellReady = true; lastShellJSON = ""; pushState()
        case "bounds":
            if let data = value.data(using: .utf8), let rect = (try? JSONSerialization.jsonObject(with: data)) as? [String: Double],
               let x = rect["left"], let y = rect["top"], let width = rect["width"], let height = rect["height"],
               [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height >= 0 {
                contentBounds = CGRect(x: x, y: y, width: width, height: height); layoutWebsiteViews()
            }
        case "newTab": newTab(value.isEmpty ? "sel://newtab" : value)
        case "selectTab": if let tab = context.tabs.first(where: { $0.id == value }) { select(tab) }
        case "closeTab": if let tab = context.tabs.first(where: { $0.id == value }) { close(tab) }
        case "tabMove":
            if let from = context.tabs.firstIndex(where: { $0.id == value }), let target = extra as? String,
               let to = context.tabs.firstIndex(where: { $0.id == target }), from != to {
                let tab = context.tabs.remove(at: from); context.tabs.insert(tab, at: min(to, context.tabs.count)); pushState(); if !context.isPrivate { scheduleSave() }
            }
        case "tabMenu": if let tab = context.tabs.first(where: { $0.id == value }) { showTabMenu(tab) }
        case "navigate": navigate(value)
        case "back":
            if let tab = context.active, tab.url.hasPrefix("sel://"), let previous = tab.webView?.url, BrowserAddress.isWeb(previous.absoluteString) { tab.url = previous.absoluteString; select(tab) }
            else if let webView = context.active?.webView, webView.canGoBack { webView.goBack() }
            else { navigate("sel://newtab") }
        case "forward":
            if let tab = context.active, tab.url.hasPrefix("sel://"), let previous = tab.webView?.url, BrowserAddress.isWeb(previous.absoluteString) { tab.url = previous.absoluteString; select(tab) }
            else { context.active?.webView?.goForward() }
        case "reload": if let webView = context.active?.webView, context.active?.url.hasPrefix("sel://") == false { if webView.isLoading { webView.stopLoading() } else { webView.reload() } }
        case "menu": showMenu()
        case "closeWindow": if let tab = context.active { close(tab) }
        case "bookmark": toggleBookmark()
        case "downloads": showDownloads()
        case "settings": changeSetting(value, extra: extra)
        default: break
        }
    }

    private func changeSetting(_ key: String, extra: Any?) {
        let value = extra.map { String(describing: $0) } ?? ""
        switch key {
        case "Theme": if ["light", "dark", "wc2026"].contains(value) { context.settings.theme = value }
        case "SearchEngine": if ["google", "yandex", "duckduckgo"].contains(value) { context.settings.searchEngine = value }
        case "RestoreSession": context.settings.restoreSession = (extra as? Bool) ?? (value == "true")
        case "CloseTabBehavior": if ["right", "left", "recent"].contains(value) { context.settings.closeTabBehavior = value }
        case "DefaultZoomPercent":
            if let percent = Int(value), (50...200).contains(percent) {
                context.settings.defaultZoomPercent = percent
                for tab in context.tabs { tab.webView?.pageZoom = CGFloat(percent) / 100 }
            }
        default: break // WebKit manages iOS memory; unsupported controls are hidden by the mobile adapter.
        }
        pushState(); if !context.isPrivate { scheduleSave() }
    }

    private func scheduleState() {
        stateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushState() }
        stateWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func pushState() {
        guard shellReady, let active = context.active else { return }
        let retainedSite = active.url.hasPrefix("sel://") && (active.webView?.url).map({ BrowserAddress.isWeb($0.absoluteString) }) == true
        let state: [String: Any] = [
            "type": "state", "tabs": context.tabs.map { t in
                ["id": t.id, "url": t.url, "title": t.title, "pinned": t.pinned, "muted": false,
                 "loading": t.webView?.isLoading == true && !t.url.hasPrefix("sel://"), "favicon": t.url.hasPrefix("sel://") ? "" : t.favicon] as [String: Any]
            },
            "active": active.id, "settings": context.settings.shellState,
            "canBack": active.webView?.canGoBack == true || !active.url.hasPrefix("sel://") || retainedSite,
            "canForward": active.webView?.canGoForward == true || retainedSite,
            "bookmarked": context.bookmarks.contains { $0.url == active.url }, "isPrivate": context.isPrivate,
            "bookmarks": context.bookmarks.prefix(4).map { ["title": $0.title, "url": $0.url] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != lastShellJSON else { return }
        lastShellJSON = json
        let safeJSON = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        shell.evaluateJavaScript("window.selApplyState(\(safeJSON));", completionHandler: nil)
        view.backgroundColor = context.settings.theme == "light" ? UIColor(red: 0.87, green: 0.89, blue: 0.92, alpha: 1) : UIColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 1)
        overrideUserInterfaceStyle = context.settings.theme == "light" ? .light : .dark
    }

    @objc private func backgroundSave() { saveNormalProfile() }
    func saveNormalProfile() {
        guard normal != nil else { return }
        do { try storage.save(normal.snapshot()) }
        catch {
            if !storageErrorShown {
                storageErrorShown = true
                alert("Профиль не сохранён", error.localizedDescription)
            }
        }
    }
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNormalProfile() }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Website navigation and UI
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if webView === shell {
            decisionHandler(url.standardizedFileURL == shellURL?.standardizedFileURL ? .allow : .cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if ["mailto", "tel"].contains(scheme), navigationAction.navigationType == .linkActivated {
            DispatchQueue.main.async { [weak self] in
                self?.confirm("Открыть другое приложение?", url.absoluteString) { UIApplication.shared.open(url) }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if webView === shell { decisionHandler(.allow); return }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || disposition.contains("attachment") ? .download : .allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView !== shell, let tab = tab(for: webView), !tab.url.hasPrefix("sel://"), let owner = context(for: webView) else { return }
        if let title = webView.title, !title.isEmpty { tab.title = String(title.prefix(512)) }
        if let url = webView.url?.absoluteString { tab.url = url }
        if !owner.isPrivate, BrowserAddress.isWeb(tab.url) {
            owner.history.removeAll { $0.url == tab.url }
            owner.history.insert(HistoryEntry(title: tab.title, url: tab.url), at: 0)
            owner.history = Array(owner.history.prefix(2000)); scheduleSave()
        }
        updateFavicon(tab, owner: owner); pushState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView !== shell, (error as NSError).code != NSURLErrorCancelled else { return }
        scheduleState()
        if context.active?.webView === webView { DispatchQueue.main.async { [weak self] in self?.alert("Страница не открылась", error.localizedDescription) } }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === shell { shellReady = false; lastShellJSON = ""; shell.reload() }
        else if context.active?.webView === webView { webView.reload() }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView !== shell, let owner = context(for: webView), owner === context,
              let url = navigationAction.request.url, ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let tab = BrowserTab(url: url.absoluteString)
        owner.tabs.append(tab)
        let child = makeWebsiteView(for: tab, in: owner, supplied: configuration)
        tab.hasLoaded = true; select(tab)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView), context.tabs.contains(where: { $0 === tab }) else { return }
        DispatchQueue.main.async { [weak self, weak tab] in if let tab = tab { self?.close(tab) } }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard presentedViewController == nil, view.window != nil else { completionHandler(); return }
        let dialog = UIAlertController(title: webView.url?.host ?? "Сайт", message: message, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }); present(dialog, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard presentedViewController == nil, view.window != nil else { completionHandler(false); return }
        let dialog = UIAlertController(title: webView.url?.host ?? "Сайт", message: message, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
        dialog.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }); present(dialog, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard presentedViewController == nil, view.window != nil else { completionHandler(nil); return }
        let dialog = UIAlertController(title: webView.url?.host ?? "Сайт", message: prompt, preferredStyle: .alert)
        dialog.addTextField { $0.text = defaultText }
        dialog.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(nil) })
        dialog.addAction(UIAlertAction(title: "OK", style: .default) { [weak dialog] _ in completionHandler(dialog?.textFields?.first?.text) }); present(dialog, animated: true)
    }

    // MARK: Favicons (direct site requests, never a third-party favicon service)
    private func updateFavicon(_ tab: BrowserTab, owner: BrowserContext) {
        guard let webView = tab.webView, let pageURL = webView.url, BrowserAddress.isWeb(pageURL.absoluteString) else { return }
        tab.faviconTask?.cancel(); let generation = UUID(); tab.faviconGeneration = generation
        webView.evaluateJavaScript("Array.from(document.querySelectorAll('link[rel]')).find(x=>x.rel.toLowerCase().split(/\\s+/).includes('icon'))?.href || new URL('/favicon.ico',location.href).href") { [weak self, weak tab, weak owner] value, _ in
            guard let self = self, let tab = tab, let owner = owner, tab.faviconGeneration == generation,
                  let string = value as? String, let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            var request = URLRequest(url: url); request.timeoutInterval = 10
            let task = BoundedIconRequest.start(request, isPrivate: owner.isPrivate) { [weak self, weak tab, weak owner] data in
                guard let data = data else { return }
                DispatchQueue.main.async {
                    guard let self = self, let tab = tab, let owner = owner, tab.faviconGeneration == generation,
                          owner.tabs.contains(where: { $0 === tab }), let image = UIImage(data: data), image.size.width <= 1024, image.size.height <= 1024 else { return }
                    let resized = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 32, height: 32)) }
                    guard let png = resized.pngData() else { return }
                    tab.favicon = "data:image/png;base64," + png.base64EncodedString(); self.scheduleState()
                }
            }
            tab.faviconTask = task; task.resume()
        }
    }

    // MARK: Native menus and data views
    private func showMenu() {
        let menu = UIAlertController(title: context.isPrivate ? "Sel · Приватное окно" : "Sel", message: nil, preferredStyle: .actionSheet)
        add(menu, "Новая вкладка") { [weak self] in self?.newTab() }
        add(menu, "Вернуть закрытую вкладку") { [weak self] in self?.restoreClosed() }
        add(menu, context.isPrivate ? "Вернуться в обычные вкладки" : "Приватные вкладки") { [weak self] in self?.switchPrivacy() }
        if context.isPrivate { add(menu, "Закрыть все приватные вкладки", style: .destructive) { [weak self] in self?.endPrivateSession() } }
        add(menu, context.bookmarks.contains(where: { $0.url == context.active?.url }) ? "Удалить закладку" : "Добавить закладку") { [weak self] in self?.toggleBookmark() }
        add(menu, "Закладки") { [weak self] in self?.showBookmarks() }
        add(menu, "История") { [weak self] in self?.showHistory() }
        add(menu, "Загрузки") { [weak self] in self?.showDownloads() }
        if let text = context.active?.url, BrowserAddress.isWeb(text), let url = URL(string: text) { add(menu, "Поделиться страницей") { [weak self] in self?.share(url) } }
        add(menu, "Настройки") { [weak self] in self?.navigate("sel://settings") }
        add(menu, "Очистить историю, cookie и кеш", style: .destructive) { [weak self] in self?.clearData() }
        add(menu, "О Sel") { [weak self] in self?.showAbout() }
        menu.addAction(UIAlertAction(title: "Отмена", style: .cancel)); presentSheet(menu)
    }
    private func showTabMenu(_ tab: BrowserTab) {
        let menu = UIAlertController(title: tab.title, message: nil, preferredStyle: .actionSheet)
        add(menu, tab.pinned ? "Открепить" : "Закрепить") { [weak self, weak tab] in guard let self = self, let tab = tab else { return }; tab.pinned.toggle(); self.pushState(); if !self.context.isPrivate { self.scheduleSave() } }
        add(menu, "Дублировать") { [weak self, weak tab] in if let tab = tab { self?.newTab(tab.url) } }
        add(menu, "Закрыть вкладку", style: .destructive) { [weak self, weak tab] in if let tab = tab { self?.close(tab) } }
        menu.addAction(UIAlertAction(title: "Отмена", style: .cancel)); presentSheet(menu)
    }
    private func toggleBookmark() {
        guard let tab = context.active, BrowserAddress.isWeb(tab.url) else { return }
        if let index = context.bookmarks.firstIndex(where: { $0.url == tab.url }) { context.bookmarks.remove(at: index) }
        else { context.bookmarks.insert(Bookmark(title: tab.title, url: tab.url), at: 0) }
        pushState(); if !context.isPrivate { scheduleSave() }
    }
    private func switchPrivacy() {
        if context.isPrivate { context = normal }
        else {
            saveNormalProfile()
            if privateContext == nil { privateContext = BrowserContext(isPrivate: true, settings: normal.settings, bookmarks: normal.bookmarks) }
            context = privateContext!
        }
        if context.tabs.isEmpty { newTab() }
        else if let tab = context.active ?? context.tabs.first { select(tab) }
        lastShellJSON = ""; pushState()
    }
    private func endPrivateSession() {
        for tab in privateContext?.tabs ?? [] { tab.dispose() }
        privateContext = nil
        context = normal
        if let tab = context.active ?? context.tabs.first { select(tab) } else { newTab() }
        lastShellJSON = ""; pushState()
    }
    private func showBookmarks() {
        let owner = context!
        let rows = owner.bookmarks.map { BrowserRow(id: $0.id, title: $0.title, subtitle: $0.url, value: $0.url) }
        showList("Закладки", rows: rows, selected: { [weak self] row in self?.navigate(row.value) }, deleted: { [weak self, weak owner] row in
            guard let self = self, let owner = owner else { return }; owner.bookmarks.removeAll { $0.id == row.id }; self.pushState(); if !owner.isPrivate { self.scheduleSave() }
        })
    }
    private func showHistory() {
        let rows = context.history.map { BrowserRow(id: UUID().uuidString, title: $0.title, subtitle: $0.url, value: $0.url) }
        showList(context.isPrivate ? "История не сохраняется" : "История", rows: rows, selected: { [weak self] row in self?.navigate(row.value) })
    }
    private func clearData() {
        let owner = context!
        confirm("Очистить данные?", "Удалить историю, cookie и кеш этого режима? Закладки и скачанные файлы сохранятся.") { [weak self, weak owner] in
            guard let self = self, let owner = owner else { return }
            owner.history.removeAll()
            owner.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
                DispatchQueue.main.async { if !owner.isPrivate { self?.scheduleSave() }; self?.pushState() }
            }
        }
    }
    private func showAbout() {
        alert("Sel для iOS · 0.1", "Нативные вкладки WebKit / WKWebView. Интерфейс Sel работает локально.\n\nПриватный режим не сохраняет историю и использует временные cookie, но не делает соединения анонимными. Скачанные файлы остаются.\n\nВ этой первой версии нет расширений Chrome, Google Sync, импорта HTML-закладок и управления звуком отдельной вкладки. Памятью iOS управляет WebKit.")
    }
    private func add(_ menu: UIAlertController, _ title: String, style: UIAlertAction.Style = .default, action: @escaping () -> Void) {
        menu.addAction(UIAlertAction(title: title, style: style) { _ in DispatchQueue.main.async(execute: action) })
    }
    private func presentSheet(_ menu: UIAlertController) {
        guard presentedViewController == nil else { return }
        if let popover = menu.popoverPresentationController { popover.sourceView = shell; popover.sourceRect = CGRect(x: max(0, shell.bounds.width - 35), y: 55, width: 25, height: 25) }
        present(menu, animated: true)
    }
    private func alert(_ title: String, _ message: String) {
        guard presentedViewController == nil, view.window != nil else { return }
        let dialog = UIAlertController(title: title, message: message, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "OK", style: .default)); present(dialog, animated: true)
    }
    private func confirm(_ title: String, _ message: String, action: @escaping () -> Void) {
        guard presentedViewController == nil else { return }
        let dialog = UIAlertController(title: title, message: message, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        dialog.addAction(UIAlertAction(title: "Продолжить", style: .destructive) { _ in action() }); present(dialog, animated: true)
    }
    private func share(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = shell
        controller.popoverPresentationController?.sourceRect = CGRect(x: shell.bounds.midX, y: 75, width: 1, height: 1)
        present(controller, animated: true)
    }
    private func showList(_ title: String, rows: [BrowserRow], selected: @escaping (BrowserRow) -> Void, deleted: ((BrowserRow) -> Void)? = nil) {
        let list = BrowserListController(title: title, rows: rows)
        list.onSelect = { [weak list] row in list?.dismiss(animated: true) { selected(row) } }
        list.onDelete = deleted
        let navigation = UINavigationController(rootViewController: list)
        present(navigation, animated: true)
    }

    // MARK: Downloads
    private var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { retain(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { retain(download) }
    private func retain(_ download: WKDownload) { retainedDownloads[ObjectIdentifier(download)] = download; download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            let name = String(URL(fileURLWithPath: suggestedFilename).lastPathComponent.prefix(160))
            let destination = downloadsDirectory.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "-" + (name.isEmpty ? "download" : name))
            downloads[ObjectIdentifier(download)] = destination; completionHandler(destination)
        } catch { completionHandler(nil); alert("Загрузка не началась", error.localizedDescription) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        retainedDownloads.removeValue(forKey: id)
        if let url = downloads.removeValue(forKey: id) { alert("Файл загружен", url.lastPathComponent + "\nФайл доступен в меню «Загрузки» и в приложении «Файлы».") }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download); retainedDownloads.removeValue(forKey: id)
        if let url = downloads.removeValue(forKey: id) { try? FileManager.default.removeItem(at: url) }
        alert("Ошибка загрузки", error.localizedDescription)
    }
    private func showDownloads() {
        let activePaths = Set(downloads.values.map { $0.path })
        let files = ((try? FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)) ?? []).filter { !activePaths.contains($0.path) }
        let rows = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { BrowserRow(id: $0.path, title: $0.lastPathComponent, subtitle: "Открыть меню сохранения и отправки", value: $0.absoluteString) }
        showList("Загрузки", rows: rows, selected: { [weak self] row in if let url = URL(string: row.value) { self?.share(url) } })
    }
}

private struct BrowserRow { let id: String; let title: String; let subtitle: String; let value: String }

private final class BrowserListController: UITableViewController, UISearchResultsUpdating {
    private var rows: [BrowserRow]
    private var filtered: [BrowserRow] = []
    private let search = UISearchController(searchResultsController: nil)
    var onSelect: ((BrowserRow) -> Void)?
    var onDelete: ((BrowserRow) -> Void)?
    init(title: String, rows: [BrowserRow]) { self.rows = rows; self.filtered = rows; super.init(style: .insetGrouped); self.title = title }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Готово", style: .done, target: self, action: #selector(close))
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Поиск"; navigationItem.searchController = search
        if rows.isEmpty { let label = UILabel(); label.text = "Пока пусто"; label.textAlignment = .center; label.textColor = .secondaryLabel; tableView.backgroundView = label }
    }
    @objc private func close() { dismiss(animated: true) }
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        filtered = query.isEmpty ? rows : rows.filter { ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query) }; tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil); let row = filtered[indexPath.row]
        cell.textLabel?.text = row.title; cell.detailTextLabel?.text = row.subtitle; cell.detailTextLabel?.textColor = .secondaryLabel; cell.accessoryType = .disclosureIndicator; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { onSelect?(filtered[indexPath.row]) }
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { onDelete != nil }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }; let row = filtered.remove(at: indexPath.row); rows.removeAll { $0.id == row.id }; onDelete?(row); tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}
