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
    private let headerBackground = UIView()
    private let footerBackground = UIView()
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
    private let mobileChrome = MobileBrowserChrome()
    private var headerHeight: NSLayoutConstraint!
    private var contentBottomToFooter: NSLayoutConstraint!
    private var contentBottomToKeyboard: NSLayoutConstraint!
    private var keyboardVisible = false
    private weak var tabOverview: TabOverviewController?
    private var snapshotsInProgress = Set<String>()
    private var didPreparePreview = false
    #if DEBUG
    private var simulatorFixtureFocus: String?
    #endif
    private var usesSimulatorFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--sel-ui-preview") || arguments.contains("--sel-ui-smoke")
        #else
        return false
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "selMobileBrowser"
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = "mobileWebContent"
        container.clipsToBounds = true
        for background in [headerBackground, footerBackground] {
            background.translatesAutoresizingMaskIntoConstraints = false
            background.backgroundColor = .systemBackground
            view.addSubview(background)
        }
        view.addSubview(container)
        configureMobileChrome()
        contentBottomToFooter = container.bottomAnchor.constraint(equalTo: mobileChrome.footer.topAnchor, constant: -8)
        contentBottomToKeyboard = container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        contentBottomToKeyboard.priority = .defaultHigh
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: mobileChrome.header.bottomAnchor, constant: 8),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            contentBottomToFooter,
            headerBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBackground.topAnchor.constraint(equalTo: view.topAnchor),
            headerBackground.bottomAnchor.constraint(equalTo: container.topAnchor),
            footerBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerBackground.topAnchor.constraint(equalTo: mobileChrome.footer.topAnchor, constant: -8),
            footerBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let saved = usesSimulatorFixture ? BrowserSnapshot() : storage.load()
        normal = BrowserContext(isPrivate: false, settings: saved.settings, bookmarks: saved.bookmarks, history: saved.history)
        context = normal
        if saved.settings.restoreSession {
            normal.tabs = saved.session.prefix(40).filter { BrowserAddress.isWeb($0.url) || ["sel://newtab", "sel://settings"].contains($0.url) }
                .map { BrowserTab(url: $0.url == "sel://settings" ? "sel://newtab" : $0.url, id: $0.id, pinned: $0.pinned) }
            normal.activeID = saved.activeID
        }
        if normal.tabs.isEmpty { normal.tabs = [BrowserTab()] }
        if normal.active == nil { normal.activeID = normal.tabs.first?.id }
        configureShell()
        if let tab = context.active { select(tab) }
        NotificationCenter.default.addObserver(self, selector: #selector(backgroundSave), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameWillChange), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameWillChange), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        shell?.frame = container.bounds
        layoutWebsiteViews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        prepareSimulatorPreviewIfRequested()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        for owner in allContexts { for tab in owner.tabs { tab.preview = nil } }
        refreshTabOverview()
    }

    private func configureMobileChrome() {
        view.addSubview(mobileChrome.header)
        view.addSubview(mobileChrome.footer)
        headerHeight = mobileChrome.header.heightAnchor.constraint(equalToConstant: mobileChrome.preferredHeaderHeight)
        NSLayoutConstraint.activate([
            mobileChrome.header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            mobileChrome.header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            mobileChrome.header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            headerHeight,
            mobileChrome.footer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            mobileChrome.footer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            mobileChrome.footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            mobileChrome.footer.heightAnchor.constraint(equalToConstant: 52)
        ])
        mobileChrome.onNavigate = { [weak self] value in self?.navigate(value) }
        mobileChrome.onBack = { [weak self] in self?.handle("back", body: [:]) }
        mobileChrome.onForward = { [weak self] in self?.handle("forward", body: [:]) }
        mobileChrome.onReload = { [weak self] in self?.handle("reload", body: [:]) }
        mobileChrome.onHome = { [weak self] in self?.navigate("sel://newtab") }
        mobileChrome.onTabs = { [weak self] in self?.showTabOverview() }
        mobileChrome.onSettings = { [weak self] in self?.showSettings() }
        mobileChrome.onMenu = { [weak self] in self?.showMenu() }
        mobileChrome.onMetricsChange = { [weak self] height in
            self?.headerHeight.constant = height
            self?.view.setNeedsLayout()
        }
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard isViewLoaded, view.window != nil,
              let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        guard let window = view.window else { return }
        let screen = (notification.object as? UIScreen) ?? window.screen
        guard screen === window.screen else { return }
        let keyboardFrame = screen.coordinateSpace.convert(endFrame, to: view)
        // A floating iPad keyboard must not move the entire browser viewport.
        let docked = keyboardFrame.width >= view.bounds.width * 0.7 && keyboardFrame.maxY >= view.bounds.maxY - 1
        let visible = notification.name != UIResponder.keyboardWillHideNotification && docked &&
            keyboardFrame.minY < view.bounds.maxY - max(view.safeAreaInsets.bottom, 1)
        if visible != keyboardVisible {
            keyboardVisible = visible
            NSLayoutConstraint.deactivate([contentBottomToFooter, contentBottomToKeyboard])
            (visible ? contentBottomToKeyboard : contentBottomToFooter).isActive = true
            mobileChrome.setKeyboardVisible(visible)
            footerBackground.isHidden = visible
        }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, delay: 0,
                       options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
        }
    }

    private func configureShell() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakMessageHandler(self), name: "sel")
        shell = BrowserWebView(frame: container.bounds, configuration: configuration)
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
        contentBounds = container.bounds
        for c in allContexts { for tab in c.tabs {
            tab.webView?.frame = container.bounds
            tab.webView?.scrollView.contentInset = .zero
            tab.webView?.scrollView.verticalScrollIndicatorInsets = .zero
        } }
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
        let webView = BrowserWebView(frame: contentBounds, configuration: configuration)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
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
        if let previous = context.active, previous !== tab { capturePreview(previous, owner: context) }
        context.activeID = tab.id; tab.lastSelected = Date()
        for c in allContexts { for t in c.tabs { t.webView?.isHidden = true } }
        if !tab.url.hasPrefix("sel://") {
            let webView = makeWebsiteView(for: tab, in: context)
            webView.isHidden = false; container.bringSubviewToFront(webView)
            if !tab.hasLoaded, let url = URL(string: tab.url) {
                tab.hasLoaded = true
                if webView.url != nil { webView.reload() } else { webView.load(URLRequest(url: url)) }
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
        case "sel://settings": showSettings(); return
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
        case "ready":
            shellReady = true; lastShellJSON = ""; pushState()
            prepareSimulatorPreviewIfRequested()
        case "bounds":
            // The iOS host owns the entire page rectangle; HTML never positions browser controls.
            layoutWebsiteViews()
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
        applySettings(context.settings)
    }

    private func scheduleState() {
        stateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushState() }
        stateWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func pushState() {
        guard context != nil, let current = context.active else { return }
        let retained = current.url.hasPrefix("sel://") && (current.webView?.url).map({ BrowserAddress.isWeb($0.absoluteString) }) == true
        mobileChrome.update(url: current.url, isPrivate: context.isPrivate, tabCount: context.tabs.count,
                            canBack: current.webView?.canGoBack == true || !current.url.hasPrefix("sel://") || retained,
                            canForward: current.webView?.canGoForward == true || retained,
                            isLoading: current.webView?.isLoading == true && !current.url.hasPrefix("sel://"))
        mobileChrome.setMenu(makePageMenu())
        mobileChrome.bindScrollView(BrowserAddress.isWeb(current.url) ? current.webView?.scrollView : nil)
        overrideUserInterfaceStyle = context.settings.theme == "light" ? .light : .dark
        view.backgroundColor = .systemBackground
        refreshTabOverview()
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
    }

    @objc private func backgroundSave() { saveNormalProfile() }
    func saveNormalProfile() {
        guard normal != nil, !usesSimulatorFixture else { return }
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

    // MARK: Mobile tab library and settings
    private func showTabOverview() {
        guard presentedViewController == nil else { return }
        view.endEditing(true)
        if let active = context.active { capturePreview(active, owner: context) }
        let overview = TabOverviewController(isPrivate: context.isPrivate)
        overview.normalInterfaceStyle = overrideUserInterfaceStyle
        overview.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        overview.modalPresentationStyle = .fullScreen
        tabOverview = overview
        overview.onSelect = { [weak self, weak overview] id in
            guard let self = self, let tab = self.context.tabs.first(where: { $0.id == id }) else { return }
            overview?.dismiss(animated: true) { [weak self, weak tab] in if let tab = tab { self?.select(tab) } }
        }
        overview.onClose = { [weak self] id in
            guard let self = self, let tab = self.context.tabs.first(where: { $0.id == id }) else { return }
            self.close(tab)
        }
        overview.onNewTab = { [weak self, weak overview] in
            overview?.dismiss(animated: true) { [weak self] in
                self?.newTab(); self?.mobileChrome.focusAddress()
            }
        }
        overview.onMove = { [weak self] id, target in
            guard let self = self,
                  let from = self.context.tabs.firstIndex(where: { $0.id == id }),
                  let to = self.context.tabs.firstIndex(where: { $0.id == target }), from != to else { return }
            let tab = self.context.tabs.remove(at: from)
            self.context.tabs.insert(tab, at: min(to, self.context.tabs.count))
            self.pushState(); if !self.context.isPrivate { self.scheduleSave() }
        }
        overview.onPrivacyChange = { [weak self] isPrivate in
            guard let self = self else { return }
            if self.context.isPrivate != isPrivate { self.switchPrivacy() }
            self.refreshTabOverview()
        }
        overview.onCloseAll = { [weak self, weak overview] in
            guard let self = self, let overview = overview else { return }
            let owner = self.context!
            let dialog = UIAlertController(title: owner.isPrivate ? "Закрыть приватные вкладки?" : "Закрыть все вкладки?",
                                          message: owner.isPrivate ? "Завершится приватный сеанс. Его cookie и история не сохранятся." : "Закрытые страницы можно вернуть через меню браузера.", preferredStyle: .alert)
            dialog.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            dialog.addAction(UIAlertAction(title: "Закрыть все", style: .destructive) { [weak self, weak owner] _ in
                guard let self = self, let owner = owner, self.context === owner else { return }
                if owner.isPrivate { self.endPrivateSession() }
                else {
                    owner.closed.append(contentsOf: owner.tabs.map { SavedTab(id: $0.id, url: $0.url, pinned: $0.pinned) })
                    owner.closed = Array(owner.closed.suffix(50))
                    owner.tabs.forEach { $0.dispose() }; owner.tabs.removeAll(); owner.activeID = nil
                    self.newTab(); self.pushState(); self.scheduleSave()
                }
            })
            overview.present(dialog, animated: true)
        }
        overview.onDone = { [weak overview] in overview?.dismiss(animated: true) }
        overview.onBookmarks = { [weak self, weak overview] in
            overview?.dismiss(animated: true) { [weak self] in self?.showBookmarks() }
        }
        refreshTabOverview()
        present(overview, animated: true)
    }

    private func refreshTabOverview() {
        guard let overview = tabOverview, context != nil else { return }
        let items = context.tabs.map { tab -> TabOverviewItem in
            var icon: UIImage?
            if let separator = tab.favicon.firstIndex(of: ","), tab.favicon.hasPrefix("data:image/"),
               let data = Data(base64Encoded: String(tab.favicon[tab.favicon.index(after: separator)...])) { icon = UIImage(data: data) }
            return TabOverviewItem(id: tab.id, title: tab.title, url: tab.url, favicon: icon,
                                   preview: BrowserAddress.isWeb(tab.url) ? tab.preview : nil,
                                   selected: context.activeID == tab.id, pinned: tab.pinned)
        }
        overview.update(items: items, isPrivate: context.isPrivate)
    }

    private func capturePreview(_ tab: BrowserTab, owner: BrowserContext) {
        guard BrowserAddress.isWeb(tab.url), let webView = tab.webView, webView.window != nil,
              !webView.isHidden, webView.bounds.width > 0, webView.bounds.height > 0,
              !snapshotsInProgress.contains(tab.id) else { return }
        let capturedURL = tab.url
        let capturedID = tab.id
        let generation = UUID(); tab.previewGeneration = generation
        snapshotsInProgress.insert(tab.id)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: 220)
        webView.takeSnapshot(with: configuration) { [weak self, weak tab, weak owner] image, _ in
            guard let self = self else { return }
            self.snapshotsInProgress.remove(capturedID)
            guard let tab = tab else { return }
            guard let owner = owner, owner.tabs.contains(where: { $0 === tab }),
                  tab.previewGeneration == generation, tab.url == capturedURL, let image = image else { return }
            tab.preview = image
            // Limit thumbnail memory independently of the number of loaded website processes.
            let recent = Set(self.allContexts.flatMap { $0.tabs }.sorted { $0.lastSelected > $1.lastSelected }.prefix(40).map { $0.id })
            for context in self.allContexts { for candidate in context.tabs where !recent.contains(candidate.id) { candidate.preview = nil } }
            self.refreshTabOverview()
        }
    }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        view.endEditing(true)
        let settings = MobileSettingsController(settings: context.settings, isPrivate: context.isPrivate)
        let navigation = UINavigationController(rootViewController: settings)
        navigation.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]; sheet.prefersGrabberVisible = true
            if #available(iOS 26.0, *) {} else { sheet.preferredCornerRadius = 24 }
        }
        settings.onSettingsChange = { [weak self, weak navigation] changed in
            self?.applySettings(changed)
            navigation?.overrideUserInterfaceStyle = changed.theme == "light" ? .light : .dark
        }
        settings.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        settings.onAction = { [weak self, weak navigation] action in
            navigation?.dismiss(animated: true) { [weak self] in
                guard let self = self else { return }
                switch action {
                case "bookmarks": self.showBookmarks()
                case "history": self.showHistory()
                case "downloads": self.showDownloads()
                case "clearData": self.clearData()
                case "about": self.showAbout()
                default: break
                }
            }
        }
        present(navigation, animated: true)
    }

    private func applySettings(_ settings: BrowserSettings) {
        normal.settings = settings
        privateContext?.settings = settings
        for owner in allContexts { for tab in owner.tabs { tab.webView?.pageZoom = CGFloat(settings.defaultZoomPercent) / 100 } }
        lastShellJSON = ""; pushState(); scheduleSave()
    }

    private func prepareSimulatorPreviewIfRequested() {
        #if DEBUG
        // A cold simulator can finish presenting UIKit before WebKit has loaded the local shell.
        guard !didPreparePreview, shellReady, viewIfLoaded?.window != nil else { return }
        didPreparePreview = true
        let arguments = ProcessInfo.processInfo.arguments
        #if targetEnvironment(simulator)
        if arguments.contains("--sel-ui-smoke") { runSimulatorSmokeChecks(); return }
        #endif
        guard let index = arguments.firstIndex(of: "--sel-ui-preview"), arguments.indices.contains(index + 1) else { return }
        let screen = arguments[index + 1]
        if ["page", "page-dark", "form", "address-long"].contains(screen) {
            showSimulatorFixture(screen)
        } else if screen == "tabs" || screen == "tabs-search" {
            // Only the simulator smoke launch creates these local metadata cards. No website is loaded.
            let pages = [("https://www.apple.com", "Apple"), ("https://ru.wikipedia.org", "Википедия"), ("https://www.youtube.com", "YouTube")]
            for (url, title) in pages { let tab = BrowserTab(url: url); tab.title = title; normal.tabs.append(tab) }
            showTabOverview()
            if screen == "tabs-search" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tabOverview?.focusSearch() }
            }
        } else if screen == "settings" { showSettings() }
        else if screen == "search" { mobileChrome.focusAddress() }
        else if screen == "home-dark" { var settings = normal.settings; settings.theme = "dark"; applySettings(settings) }
        #endif
    }

    #if DEBUG
    private func showSimulatorFixture(_ screen: String) {
        var settings = normal.settings
        settings.theme = screen == "page-dark" || screen == "form" || screen == "address-long" ? "dark" : "light"
        applySettings(settings)
        let address = "https://sel-preview.invalid/search?text=проверка-длинного-адреса-и-мобильного-поиска"
        guard let url = URL(string: address) else { return }
        let tab = BrowserTab(url: url.absoluteString)
        context.tabs.append(tab)
        let webView = makeWebsiteView(for: tab, in: context)
        tab.hasLoaded = true
        select(tab)
        simulatorFixtureFocus = screen == "form" ? "form" : screen == "address-long" ? "address" : nil
        webView.loadHTMLString("""
        <!doctype html><html lang="ru"><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>Проверка мобильного поиска</title><style>
        *{box-sizing:border-box}html{color-scheme:light dark}body{margin:0;font:17px -apple-system,sans-serif;background:#f4f6fa;color:#172335}
        header{position:sticky;top:0;background:#fff;padding:14px 16px;border-bottom:1px solid #ddd;z-index:2}
        form{display:flex;gap:8px;align-items:center}input{font:17px -apple-system;min-width:0;width:100%;padding:12px;border:1px solid #9ba6b5;border-radius:12px;color:inherit;background:transparent}
        button{font:16px -apple-system;background:#ed5a45;color:white;border:0;padding:13px;border-radius:12px;flex-shrink:0}
        nav{display:flex;gap:20px;overflow-x:auto;white-space:nowrap;padding-top:16px;font-size:14px}main{padding:22px 18px}article{padding:18px 0;border-bottom:1px solid #8893a533}
        h1{font-size:24px;margin:0 0 12px}h2{font-size:21px;color:#4077df}p{line-height:1.65;margin:12px 0}small{color:#7a8799}
        @media(prefers-color-scheme:dark){body{background:#111317;color:#e3e8ef}header{background:#191c22;border-color:#343a46}h2{color:#94b9ff}}
        </style></head><body><header><form onsubmit="event.preventDefault()"><input id="fixture-query" aria-label="Поиск на странице" placeholder="Поиск на странице" value="subway surf"><button>Найти</button></form>
        <nav><b>Поиск</b><span>Картинки</span><span>Видео</span><span>Карты</span></nav></header><main><small>Локальная проверка отображения сайта</small>
        <article><h1>Мобильный поиск</h1><p>Текст страницы начинается под панелью браузера и не проходит под адресной строкой.</p></article>
        <article><h2>Результат поиска</h2><p>Нижняя навигация остаётся у края экрана. Во время ввода она скрывается и освобождает место для страницы.</p></article>
        <article><h2>Ещё один результат</h2><p>Поле поиска использует настоящую клавиатуру iOS. Дополнительная панель перехода между полями отключена.</p></article>
        <article><h2>Продолжение страницы</h2><p>Прокрутите страницу: её содержимое ограничено областью просмотра WebKit.</p></article>
        <article><h2>Конец страницы</h2><p>Эти данные созданы только для проверки интерфейса и не требуют подключения к сайту.</p></article>
        </main></body></html>
        """, baseURL: url)
    }
    #endif

    #if DEBUG && targetEnvironment(simulator)
    private func runSimulatorSmokeChecks() {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func control(_ view: UIView, id: String) -> UIControl? {
            if view.accessibilityIdentifier == id { return view as? UIControl }
            for child in view.subviews { if let found = control(child, id: id) { return found } }
            return nil
        }
        func record() {
            let report: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sel-ui-smoke.json")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            let initial = self.context.active!
            let left = self.newTab(), middle = self.newTab(), right = self.newTab()
            self.close(middle)
            check("Closing a middle tab preserves its neighbours", self.context.tabs.contains { $0 === left } && self.context.tabs.contains { $0 === right } && !self.context.tabs.contains { $0 === middle })
            check("Closing an inactive tab preserves the selected tab", self.context.activeID == right.id)
            self.select(left); self.close(right)
            check("Closing the right tab preserves the selected left tab", self.context.activeID == left.id && !self.context.tabs.contains { $0 === right })
            self.close(initial); self.close(left)
            check("Closing the last tab creates a usable new tab", self.context.tabs.count == 1 && self.context.active?.url == "sel://newtab")
            self.view.layoutIfNeeded()
            check("Tab control is anchored below page content", self.mobileChrome.footer.frame.minY > self.view.bounds.midY)
            check("Website viewport cannot overlap the address controls", self.container.frame.minY >= self.mobileChrome.header.frame.maxY + 7)
            check("Website viewport stays above the bottom navigation", self.container.frame.maxY <= self.mobileChrome.footer.frame.minY - 7)
            check("Bottom navigation stays at the safe-area edge", abs(self.mobileChrome.footer.frame.maxY - self.view.safeAreaLayoutGuide.layoutFrame.maxY + 6) < 1)
            check("Website content is clipped to its own viewport", self.container.clipsToBounds)
            if let profile = control(self.mobileChrome.header, id: "mobileSettings") {
                let addressFrame = self.mobileChrome.addressField.convert(self.mobileChrome.addressField.bounds, to: self.view)
                let profileFrame = profile.convert(profile.bounds, to: self.view)
                check("Address text and profile button have separate layout columns", !addressFrame.intersects(profileFrame))
            }
            check("Native navigation reserves safe hit targets", self.mobileChrome.footer.bounds.height >= 44 && self.mobileChrome.header.bounds.height >= 44)
            check("Browser menu uses a native system menu", (control(self.mobileChrome.footer, id: "mobileMenu") as? UIButton)?.menu != nil)
            if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
                check("Navigation uses the real Apple UIGlassEffect", self.mobileChrome.footer.effect is UIGlassEffect)
            } else {
                check("Older iOS uses a compatible navigation material", self.mobileChrome.footer.effect is UIBlurEffect || UIAccessibility.isReduceTransparencyEnabled)
            }
            let original = self.normal.settings
            var changed = original; changed.searchEngine = "duckduckgo"; changed.defaultZoomPercent = 125
            self.applySettings(changed)
            check("Native search selection resolves real search URLs", BrowserAddress.resolve("проверка", engine: self.context.settings.searchEngine)?.hasPrefix("https://duckduckgo.com/") == true)
            self.switchPrivacy()
            let normalCount = self.normal.tabs.count
            self.newTab()
            check("Private tabs do not modify the normal session", self.normal.tabs.count == normalCount && self.context.isPrivate && self.context.dataStore !== self.normal.dataStore)
            self.endPrivateSession(); self.applySettings(original)
            let legacy = #"{"settings":{"theme":"light","searchEngine":"yandex","restoreSession":true,"closeTabBehavior":"right","defaultZoomPercent":100},"bookmarks":[{"id":"old-bookmark","title":"Сохранённая закладка","url":"https://example.com","addedAt":0}],"history":[],"session":[{"id":"old-tab","url":"sel://newtab","pinned":false}],"activeID":"old-tab"}"#
            let decoded = try? JSONDecoder().decode(BrowserSnapshot.self, from: Data(legacy.utf8))
            check("Version 1.0 profile format remains readable", decoded?.bookmarks.first?.id == "old-bookmark" && decoded?.session.first?.id == "old-tab")
            let persisted = (try? JSONEncoder().encode(self.normal.snapshot())).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            check("Page thumbnails are not serialized to disk", !persisted.isEmpty && !persisted.contains("previewGeneration") && !persisted.contains("\"preview\""))
            self.shell.evaluateJavaScript("[getComputedStyle(document.getElementById('desktop-tab-strip')).display,getComputedStyle(document.getElementById('desktop-navigation')).display]") { result, error in
                if let error = error { checks.append(["name": "Local shell evaluation", "passed": false, "error": error.localizedDescription]) }
                check("The desktop top tab strip and toolbar are hidden", (result as? [String]) == ["none", "none"])
                control(self.mobileChrome.footer, id: "mobileTabs")?.sendActions(for: .touchUpInside)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    check("Bottom tab button opens the native full-screen library", self.presentedViewController is TabOverviewController)
                    self.dismiss(animated: false) {
                        control(self.mobileChrome.header, id: "mobileSettings")?.sendActions(for: .touchUpInside)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            let navigation = self.presentedViewController as? UINavigationController
                            check("Settings opens a native navigation sheet", navigation?.topViewController is MobileSettingsController)
                            self.dismiss(animated: false) {
                                self.mobileChrome.focusAddress()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    self.view.layoutIfNeeded()
                                    check("Keyboard hides browser navigation instead of raising it", self.keyboardVisible && self.mobileChrome.footer.isHidden)
                                    check("Keyboard leaves the page inside the available viewport", self.container.frame.maxY <= self.view.keyboardLayoutGuide.layoutFrame.minY + 1)
                                    check("Address keyboard has no additional accessory toolbar", self.mobileChrome.addressField.inputAccessoryView == nil)
                                    self.view.endEditing(true)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                        check("Navigation returns after keyboard dismissal", !self.keyboardVisible && !self.mobileChrome.footer.isHidden)
                                        record()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    #endif

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
        #if DEBUG
        if webView.url?.host == "sel-preview.invalid" {
            capturePreview(tab, owner: owner); pushState()
            if simulatorFixtureFocus == "form" {
                simulatorFixtureFocus = nil
                webView.evaluateJavaScript("document.getElementById('fixture-query').focus()", completionHandler: nil)
            } else if simulatorFixtureFocus == "address" {
                simulatorFixtureFocus = nil
                mobileChrome.focusAddress()
            }
            return
        }
        #endif
        if !owner.isPrivate, BrowserAddress.isWeb(tab.url) {
            owner.history.removeAll { $0.url == tab.url }
            owner.history.insert(HistoryEntry(title: tab.title, url: tab.url), at: 0)
            owner.history = Array(owner.history.prefix(2000)); scheduleSave()
        }
        updateFavicon(tab, owner: owner); capturePreview(tab, owner: owner); pushState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView !== shell, (error as NSError).code != NSURLErrorCancelled else { return }
        scheduleState()
        if context.active?.webView === webView { DispatchQueue.main.async { [weak self] in self?.alert("Страница не открылась", error.localizedDescription) } }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === shell { shellReady = false; lastShellJSON = ""; shell.reload() }
        else if context.active?.webView === webView { webView.reload() }
        else { tab(for: webView)?.hasLoaded = false }
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
    private func makePageMenu() -> UIMenu {
        func action(_ title: String, _ image: String, destructive: Bool = false, handler: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: image), attributes: destructive ? [.destructive] : []) { _ in
                DispatchQueue.main.async(execute: handler)
            }
        }
        var navigation: [UIMenuElement] = [
            action("Главная", "house") { [weak self] in self?.navigate("sel://newtab") },
            action("Новая вкладка", "plus") { [weak self] in self?.newTab(); self?.mobileChrome.focusAddress() },
            action("Вернуть закрытую вкладку", "arrow.uturn.backward") { [weak self] in self?.restoreClosed() },
            action(context.isPrivate ? "Обычные вкладки" : "Приватные вкладки", "eyeglasses") { [weak self] in self?.switchPrivacy() }
        ]
        if let tab = context.active {
            navigation.append(action("Дублировать вкладку", "plus.square.on.square") { [weak self, weak tab] in if let tab = tab { self?.newTab(tab.url) } })
            navigation.append(action(tab.pinned ? "Открепить вкладку" : "Закрепить вкладку", "pin") { [weak self, weak tab] in
                guard let self = self, let tab = tab else { return }
                tab.pinned.toggle(); self.pushState(); if !self.context.isPrivate { self.scheduleSave() }
            })
        }
        var page: [UIMenuElement] = []
        if let text = context.active?.url, BrowserAddress.isWeb(text), let url = URL(string: text) {
            page.append(action(context.bookmarks.contains(where: { $0.url == text }) ? "Удалить закладку" : "Добавить закладку", "bookmark") { [weak self] in self?.toggleBookmark() })
            page.append(action("Поделиться", "square.and.arrow.up") { [weak self] in self?.share(url) })
        }
        page.append(contentsOf: [
            action("Закладки", "bookmark") { [weak self] in self?.showBookmarks() },
            action("История", "clock.arrow.circlepath") { [weak self] in self?.showHistory() },
            action("Загрузки", "arrow.down.circle") { [weak self] in self?.showDownloads() },
            action("Настройки", "gearshape") { [weak self] in self?.showSettings() }
        ])
        return UIMenu(children: [UIMenu(options: .displayInline, children: navigation), UIMenu(options: .displayInline, children: page)])
    }

    private func showMenu() {
        let menu = UIAlertController(title: context.isPrivate ? "Sel · Приватное окно" : "Sel", message: nil, preferredStyle: .actionSheet)
        add(menu, "Новая вкладка") { [weak self] in self?.newTab() }
        add(menu, "Главная") { [weak self] in self?.navigate("sel://newtab") }
        add(menu, "Вернуть закрытую вкладку") { [weak self] in self?.restoreClosed() }
        add(menu, context.isPrivate ? "Вернуться в обычные вкладки" : "Приватные вкладки") { [weak self] in self?.switchPrivacy() }
        if context.isPrivate { add(menu, "Закрыть все приватные вкладки", style: .destructive) { [weak self] in self?.endPrivateSession() } }
        add(menu, context.bookmarks.contains(where: { $0.url == context.active?.url }) ? "Удалить закладку" : "Добавить закладку") { [weak self] in self?.toggleBookmark() }
        add(menu, "Закладки") { [weak self] in self?.showBookmarks() }
        add(menu, "История") { [weak self] in self?.showHistory() }
        add(menu, "Загрузки") { [weak self] in self?.showDownloads() }
        if let text = context.active?.url, BrowserAddress.isWeb(text), let url = URL(string: text) { add(menu, "Поделиться страницей") { [weak self] in self?.share(url) } }
        add(menu, "Настройки") { [weak self] in self?.showSettings() }
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
        if let active = context.active { capturePreview(active, owner: context) }
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
        alert("Sel для iOS · \(version)", "Нативные вкладки WebKit / WKWebView. Экран вкладок и настройки адаптированы для iPhone и iPad.\n\nПриватный режим не сохраняет историю и использует временные cookie, но не делает соединения анонимными. Скачанные файлы остаются.\n\nРасширения Chrome и Google Sync не поддерживаются. Памятью сайтов управляют iOS и WebKit.")
    }
    private func add(_ menu: UIAlertController, _ title: String, style: UIAlertAction.Style = .default, action: @escaping () -> Void) {
        menu.addAction(UIAlertAction(title: title, style: style) { _ in DispatchQueue.main.async(execute: action) })
    }
    private func presentSheet(_ menu: UIAlertController) {
        guard presentedViewController == nil else { return }
        if let popover = menu.popoverPresentationController { popover.sourceView = mobileChrome.footer; popover.sourceRect = CGRect(x: mobileChrome.footer.bounds.midX, y: 0, width: 1, height: 1) }
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
        controller.popoverPresentationController?.sourceView = mobileChrome.footer
        controller.popoverPresentationController?.sourceRect = CGRect(x: mobileChrome.footer.bounds.midX, y: 0, width: 1, height: 1)
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
