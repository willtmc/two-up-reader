import Cocoa
import WebKit

struct Browser: Sendable {
    let bundleID: String
    let name: String
    let isSafari: Bool
}

let browsers = [
    Browser(bundleID: "com.apple.Safari", name: "Safari", isSafari: true),
    Browser(bundleID: "com.google.Chrome", name: "Google Chrome", isSafari: false),
    Browser(bundleID: "company.thebrowser.Browser", name: "Arc", isSafari: false),
    Browser(bundleID: "com.brave.Browser", name: "Brave Browser", isSafari: false),
    Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", isSafari: false),
]

let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

func resourceText(_ name: String, _ ext: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
        NSLog("TwoUp: missing resource \(name).\(ext)")
        return ""
    }
    return text
}

func nsColor(hex: String) -> NSColor {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
        return .windowBackgroundColor
    }
    let r = CGFloat((value >> 16) & 0xff) / 255.0
    let g = CGFloat((value >> 8) & 0xff) / 255.0
    let b = CGFloat(value & 0xff) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
}

// MARK: Readwise Reader

@MainActor
enum Keychain {
    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.mclemore.twoup",
            kSecAttrAccount as String: "readwise",
        ]
    }

    static func get() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String) -> Bool {
        let deleteStatus = SecItemDelete(baseQuery() as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            NSLog("TwoUp: Keychain delete before save returned OSStatus %d", deleteStatus)
        }
        var query = baseQuery()
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("TwoUp: Keychain save failed with OSStatus %d", status)
            return false
        }
        return true
    }

    static func delete() {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("TwoUp: Keychain delete failed with OSStatus %d", status)
        }
    }
}

struct ReadwiseError: LocalizedError { let errorDescription: String? }

@MainActor
func readwiseRequest(
    _ url: URL,
    method: String = "GET",
    body: [String: Any]? = nil,
    token: String,
    completion: @escaping @MainActor (Result<[String: Any], Error>) -> Void
) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    Task { @MainActor in
        let result: Result<[String: Any], Error>
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 || status == 403 {
                result = .failure(ReadwiseError(errorDescription: "Readwise rejected the token. Reconnect with a fresh one."))
            } else if status == 429 {
                let wait = http?.value(forHTTPHeaderField: "Retry-After") ?? "a few"
                result = .failure(ReadwiseError(errorDescription: "Readwise rate limit hit. Try again in \(wait) seconds."))
            } else if !(200..<300).contains(status) {
                result = .failure(ReadwiseError(errorDescription: "Readwise returned HTTP \(status)."))
            } else {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                result = .success(object ?? [:])
            }
        } catch {
            result = .failure(error)
        }
        completion(result)
    }
}

struct QueueCache {
    var items: [[String: Any]]
    var fetchedAt: Date
}

struct PendingLoad {
    let token: Int
    let url: URL
    let html: String?
    var isExtracting = false
}

enum BrowserTabGrabResult: Sendable {
    case success(url: URL, html: String?)
    case failure(String)
}

@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var reader: WKWebView!
    // Off-screen-ish view that loads the source page; the reader covers it.
    var loader: WKWebView!
    var template = ""
    var extractorSource = ""
    var lastBrowserID: String?
    var workspaceObserver: NSObjectProtocol?
    var launchURL: URL?
    var currentURL: URL?
    var pending: PendingLoad?
    var token = 0
    var expectingReaderLoad = false
    var expectedReaderBaseURL: URL?
    var currentDocID: String?
    var archivingDocIDs = Set<String>()
    var showingQueue = false
    var queueLocation = "later"
    var queueCache: [String: QueueCache] = [:]
    var queueRevision = 0
    var queueFetchToken = 0

    private let preferFullScreenKey = "preferFullScreen"

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           browsers.contains(where: { $0.bundleID == front }) {
            lastBrowserID = front
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, browsers.contains(where: { $0.bundleID == id }) else { return }
            Task { @MainActor [weak self] in
                self?.lastBrowserID = id
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        template = resourceText("reader", "html")
        extractorSource = resourceText("Readability", "js") + "\n" + resourceText("extract", "js") + "\ntrue;"
        let savedPrefs = prefs()
        if let savedLoc = savedPrefs["queueLocation"] as? String, !savedLoc.isEmpty {
            queueLocation = savedLoc
        }
        buildMenu()

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(
            contentRect: screen.insetBy(dx: screen.width * 0.08, dy: screen.height * 0.08),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "TwoUp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 640, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("TwoUpMainWindow")
        syncWindowAppearance(theme: savedPrefs["theme"] as? String)
        let bounds = window.contentView!.bounds

        let loaderConfig = WKWebViewConfiguration()
        loaderConfig.websiteDataStore = .nonPersistent()
        loaderConfig.mediaTypesRequiringUserActionForPlayback = .all
        loader = WKWebView(frame: bounds, configuration: loaderConfig)
        loader.customUserAgent = safariUserAgent
        loader.navigationDelegate = self
        loader.autoresizingMask = [.width, .height]
        loader.setValue(false, forKey: "drawsBackground")

        let readerConfig = WKWebViewConfiguration()
        readerConfig.userContentController.add(WeakScriptMessageHandler(self), name: "twoup")
        reader = WKWebView(frame: bounds, configuration: readerConfig)
        reader.navigationDelegate = self
        reader.autoresizingMask = [.width, .height]
        reader.setValue(false, forKey: "drawsBackground")

        window.contentView!.addSubview(loader)
        window.contentView!.addSubview(reader)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(reader)
        NSApp.activate(ignoringOtherApps: true)

        let preferFullScreen = UserDefaults.standard.object(forKey: preferFullScreenKey) as? Bool ?? true
        if preferFullScreen && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        let cliURL = parseLaunchURL(arguments: Array(CommandLine.arguments.dropFirst()))
        if let url = launchURL ?? cliURL {
            open(url, html: nil)
        } else if lastBrowserID != nil {
            grabBrowserTab()
        } else {
            showStart()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && !($0.host ?? "").isEmpty }) else { return }
        if reader == nil { launchURL = url } else { open(url, html: nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        reader?.configuration.userContentController.removeScriptMessageHandler(forName: "twoup")
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: preferFullScreenKey)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: preferFullScreenKey)
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            return it
        }
        submenu("TwoUp", [
            item("About TwoUp", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide TwoUp", #selector(NSApplication.hide(_:)), "h"),
            item("Quit TwoUp", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("Open URL…", #selector(openURLAction), "l"),
            item("Read Front Browser Tab", #selector(grabAction), "b"),
            item("Open Original in Browser", #selector(originalAction), "o"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("View", [
            item("Zoom In", #selector(zoomInAction), "+"),
            item("Zoom Out", #selector(zoomOutAction), "-"),
            item("Actual Size", #selector(zoomResetAction), "0"),
            .separator(),
            item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        NSApp.mainMenu = main
    }

    @objc func openURLAction() { showStart(focusUrl: true) }
    @objc func grabAction() { grabBrowserTab() }
    @objc func originalAction() {
        if let url = currentURL, isAllowedExternalURL(url) {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func zoomInAction() {
        reader.evaluateJavaScript("window.twoupZoom && window.twoupZoom(1)")
    }
    @objc func zoomOutAction() {
        reader.evaluateJavaScript("window.twoupZoom && window.twoupZoom(-1)")
    }
    @objc func zoomResetAction() {
        reader.evaluateJavaScript("window.twoupZoom && window.twoupZoom(0)")
    }

    // MARK: Screens

    func prefs() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: "prefs") ?? [:]
    }

    func syncWindowAppearance(theme: String?) {
        let spec = themeWindowAppearance(theme: theme)
        if let isDark = spec.isDark {
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            window.backgroundColor = nsColor(hex: spec.bgHex)
        } else {
            window.appearance = nil
            let systemDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            window.backgroundColor = nsColor(hex: systemDark ? "#161616" : spec.bgHex)
        }
    }

    func render(_ mode: String, article: [String: Any]? = nil, url: URL? = nil, message: String? = nil, focusUrl: Bool = false) {
        showingQueue = mode == "start" || mode == "error"
        var data: [String: Any] = ["mode": mode, "prefs": prefs()]
        if let article { data["article"] = article }
        if let url { data["url"] = url.absoluteString }
        if let message { data["message"] = message }
        if focusUrl { data["focusUrl"] = true }
        if mode == "article" {
            if let currentDocID { data["docId"] = currentDocID }
            if let dir = article?["dir"] as? String, !dir.isEmpty { data["dir"] = dir }
        }
        let html = template.replacingOccurrences(of: "/*__TWOUP_DATA__*/", with: "window.TWOUP = \(jsonLiteral(data));")
        let baseURL = mode == "article" ? url : nil
        expectingReaderLoad = true
        expectedReaderBaseURL = baseURL
        reader.loadHTMLString(html, baseURL: baseURL)
        window.makeFirstResponder(reader)
    }

    func showStart(message: String? = nil, url: URL? = nil, notice: String? = nil, focusUrl: Bool = false) {
        token += 1
        pending = nil
        currentDocID = nil
        stopLoader()
        window.title = "TwoUp"
        render(message == nil ? "start" : "error", url: url, message: message ?? notice, focusUrl: focusUrl)
    }

    // MARK: Loading and extraction

    func open(_ url: URL, html: String?, docID: String? = nil) {
        token += 1
        let t = token
        pending = PendingLoad(token: t, url: url, html: html)
        currentURL = url
        currentDocID = docID
        render("loading", url: url)
        if html != nil {
            loader.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: url)
        } else {
            loader.load(URLRequest(url: url))
        }
        // Slow or never-finishing pages: extract whatever has loaded.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.extract(token: t)
        }
    }

    func extract(token t: Int) {
        guard var p = pending, p.token == t, !p.isExtracting else { return }
        p.isExtracting = true
        pending = p
        let base = (p.html == nil ? loader.url : nil) ?? p.url
        guard !extractorSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("TwoUp is missing its article extractor resources.", url: base)
            return
        }
        loader.evaluateJavaScript(extractorSource, in: nil, in: .defaultClient) { [weak self] injectResult in
            guard let self, self.pending?.token == t else { return }
            if case .failure(let error) = injectResult {
                NSLog("TwoUp: extractor script evaluation failed: %@", error.localizedDescription)
                self.fail("Couldn't read that page (\(error.localizedDescription)).", url: base)
                return
            }
            self.loader.callAsyncJavaScript(
                "return __twoupExtract(html, base);",
                arguments: ["html": p.html ?? NSNull(), "base": base.absoluteString],
                in: nil, in: .defaultClient
            ) { [weak self] result in
                guard let self, self.pending?.token == t else { return }
                switch result {
                case .success(let value):
                    if let article = value as? [String: Any], let content = article["content"] as? String, !content.isEmpty {
                        self.pending = nil
                        self.currentURL = base
                        self.window.title = (article["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "TwoUp"
                        self.render("article", article: article, url: base)
                        self.stopLoader()
                    } else {
                        self.fail("Couldn't find an article on that page.", url: base)
                    }
                case .failure(let error):
                    self.fail("Couldn't read that page (\(error.localizedDescription)).", url: base)
                }
            }
        }
    }

    func fail(_ message: String, url: URL) {
        showStart(message: message, url: url)
    }

    func stopLoader() {
        loader.stopLoading()
        loader.loadHTMLString("", baseURL: nil)
    }

    // MARK: Readwise Reader queue

    func pushQueue(_ state: [String: Any]) {
        reader.evaluateJavaScript("window.updateQueue && window.updateQueue(\(jsonLiteral(state)))")
    }

    func archiveFailed(_ id: String, message: String) {
        reader.evaluateJavaScript("window.archiveFailed && window.archiveFailed(\(jsonLiteral(id)), \(jsonLiteral(message)))")
    }

    func serveQueue(force: Bool) {
        let location = queueLocation
        guard let key = Keychain.get() else {
            pushQueue(["state": "needsToken"])
            return
        }
        if let cached = queueCache[location] {
            pushQueue(["state": "ready", "location": location, "items": cached.items])
            if !force && Date().timeIntervalSince(cached.fetchedAt) < 120 { return }
        } else {
            pushQueue(["state": "loading", "location": location, "items": []])
        }
        queueFetchToken += 1
        fetchQueue(location, key: key, cursor: nil, items: [], pagesLeft: 3, fetchToken: queueFetchToken)
    }

    func fetchQueue(_ location: String, key: String, cursor: String?, items: [[String: Any]], pagesLeft: Int, fetchToken: Int) {
        let revision = queueRevision
        var queryItems = [URLQueryItem(name: "location", value: location)]
        if let cursor {
            queryItems.append(URLQueryItem(name: "pageCursor", value: cursor))
        }
        guard let url = readwiseEndpointURL(path: "/api/v3/list/", queryItems: queryItems) else {
            pushQueue(["state": "error", "location": location, "message": "Invalid Readwise queue request.",
                       "items": queueCache[location]?.items ?? []])
            return
        }
        readwiseRequest(url, token: key) { [weak self] result in
            guard let self, self.queueRevision == revision, self.queueFetchToken == fetchToken else { return }
            switch result {
            case .failure(let error):
                self.pushQueue(["state": "error", "location": location, "message": error.localizedDescription,
                                "items": self.queueCache[location]?.items ?? []])
            case .success(let json):
                let all = items + (json["results"] as? [[String: Any]] ?? []).compactMap(slimDoc)
                if let next = json["nextPageCursor"] as? String, pagesLeft > 1 {
                    self.fetchQueue(location, key: key, cursor: next, items: all, pagesLeft: pagesLeft - 1, fetchToken: fetchToken)
                    return
                }
                self.queueCache[location] = QueueCache(items: all, fetchedAt: Date())
                if self.queueLocation == location {
                    self.pushQueue(["state": "ready", "location": location, "items": all])
                }
            }
        }
    }

    func openDoc(_ id: String) {
        guard let key = Keychain.get() else { return }
        token += 1
        let t = token
        pending = nil
        currentDocID = nil
        stopLoader()
        let item = queueCache.values.flatMap(\.items).first { $0["id"] as? String == id }
        let listedURL = (item?["source_url"] as? String).flatMap(normalizeURL)
        render("loading", url: listedURL)
        guard let url = readwiseEndpointURL(path: "/api/v3/list/", queryItems: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "withHtmlContent", value: "true"),
        ]) else {
            showStart(message: "Invalid Readwise document request.")
            return
        }
        readwiseRequest(url, token: key) { [weak self] result in
            guard let self, self.token == t else { return }
            switch result {
            case .failure(let error):
                self.showStart(message: error.localizedDescription)
            case .success(let json):
                guard let doc = (json["results"] as? [[String: Any]])?.first else {
                    self.showStart(message: "That document is no longer in Reader.")
                    return
                }
                let url = (doc["source_url"] as? String).flatMap(normalizeURL) ?? listedURL
                let html = doc["html_content"] as? String ?? ""
                if html.isEmpty {
                    if let url { self.open(url, html: nil, docID: id) } else { self.showStart(message: "Reader has no text for that document.") }
                    return
                }
                func text(_ key: String) -> String { doc[key] as? String ?? "" }
                self.currentDocID = id
                self.currentURL = url
                self.window.title = text("title").isEmpty ? "TwoUp" : text("title")
                self.render("article",
                            article: [
                                "title": text("title"),
                                "byline": text("author"),
                                "site": text("site_name"),
                                "dir": text("dir"),
                                "content": html,
                            ],
                            url: url ?? readwiseReaderBaseURL())
            }
        }
    }

    func archiveCurrent(_ id: String, markRead: Bool) {
        guard id == currentDocID, !archivingDocIDs.contains(id) else { return }
        guard let key = Keychain.get() else {
            archiveFailed(id, message: "Connect Readwise Reader from the queue, then try again.")
            return
        }
        guard let url = readwiseUpdateURL(docID: id) else {
            archiveFailed(id, message: "Invalid Readwise document ID.")
            return
        }
        archivingDocIDs.insert(id)
        var update: [String: Any] = ["location": "archive"]
        if markRead {
            update["reading_progress"] = 1
            update["seen"] = true
        }
        readwiseRequest(url, method: "PATCH", body: update, token: key) { [weak self] result in
            guard let self else { return }
            self.archivingDocIDs.remove(id)
            switch result {
            case .failure(let error):
                guard self.currentDocID == id else { return }
                let action = markRead ? "mark as read" : "archive"
                self.archiveFailed(id, message: "Couldn’t \(action). \(error.localizedDescription)")
            case .success:
                // A list response started before the archive could still contain this document.
                self.queueRevision += 1
                self.queueFetchToken += 1
                for location in self.queueCache.keys {
                    self.queueCache[location]?.items.removeAll { $0["id"] as? String == id }
                }
                if self.currentDocID == id {
                    self.showStart(notice: markRead ? "Marked as read." : "Archived.")
                } else if self.showingQueue {
                    self.serveQueue(force: false)
                }
            }
        }
    }

    func connectReadwise(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = readwiseEndpointURL(path: "/api/v2/auth/") else {
            pushQueue(["state": "needsToken", "message": "Invalid Readwise auth endpoint."])
            return
        }
        readwiseRequest(url, token: key) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if Keychain.set(key) {
                    self.queueCache = [:]
                    self.queueRevision += 1
                    self.queueFetchToken += 1
                    self.serveQueue(force: true)
                } else {
                    self.pushQueue(["state": "needsToken", "message": "Couldn't save the token to your macOS Keychain."])
                }
            case .failure(let error):
                self.pushQueue(["state": "needsToken", "message": error.localizedDescription])
            }
        }
    }

    // MARK: Browser tab

    func grabBrowserTab() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard let browser = browsers.first(where: { $0.bundleID == lastBrowserID && running.contains($0.bundleID) })
                ?? browsers.first(where: { running.contains($0.bundleID) }) else {
            showStart(message: "No supported browser is running (Safari, Chrome, Arc, Brave, Edge).")
            return
        }
        token += 1
        let t = token
        pending = nil
        currentDocID = nil
        stopLoader()
        render("loading")

        Task.detached(priority: .userInitiated) {
            let outcome = Self.runBrowserAppleScript(for: browser)
            await MainActor.run { [weak self] in
                guard let self, self.token == t else { return }
                switch outcome {
                case .success(let url, let html):
                    self.open(url, html: html)
                case .failure(let reason):
                    self.showStart(message: reason)
                }
            }
        }
    }

    nonisolated private static func runBrowserAppleScript(for browser: Browser) -> BrowserTabGrabResult {
        let target = "tell application id \"\(browser.bundleID)\""
        let tab = browser.isSafari ? "front document" : "active tab of front window"
        var error: NSDictionary?
        let urlText = NSAppleScript(source: "\(target) to return URL of \(tab)")?.executeAndReturnError(&error).stringValue
        guard let urlText, let url = normalizeURL(urlText) else {
            let code = error?[NSAppleScript.errorNumber] as? Int
            let reason = code == -1743
                ? "TwoUp isn't allowed to control \(browser.name). Turn it on in System Settings → Privacy & Security → Automation."
                : "Couldn't read the current tab in \(browser.name)."
            return .failure(reason)
        }
        // The page's own HTML keeps logged-in/paywalled content. Needs the browser's
        // "Allow JavaScript from Apple Events" setting; otherwise we load the URL fresh.
        let js = "document.documentElement.outerHTML"
        let htmlScript = browser.isSafari
            ? "\(target) to do JavaScript \"\(js)\" in front document"
            : "\(target) to execute active tab of front window javascript \"\(js)\""
        var htmlError: NSDictionary?
        let html = NSAppleScript(source: htmlScript)?.executeAndReturnError(&htmlError).stringValue
        if let htmlError {
            NSLog("TwoUp: browser HTML AppleScript unavailable for %@: %@", browser.name, htmlError)
        }
        return .success(url: url, html: (html?.count ?? 0) > 500 ? html : nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if webView === reader {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, isAllowedExternalURL(url) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            if action.navigationType == .other,
               action.targetFrame?.isMainFrame ?? true,
               expectingReaderLoad,
               matchesExpectedReaderURL(action.request.url, expected: expectedReaderBaseURL) {
                expectingReaderLoad = false
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            return
        }
        if webView === loader, action.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === reader {
            expectingReaderLoad = false
            return
        }
        guard webView === loader, let p = pending else { return }
        // Give script-rendered pages a moment to settle.
        let delayNs: UInt64 = p.html == nil ? 800_000_000 : 0
        let expectedToken = p.token
        if delayNs == 0 {
            extract(token: expectedToken)
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayNs)
                self?.extract(token: expectedToken)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === reader {
            expectingReaderLoad = false
            return
        }
        guard webView === loader, let p = pending else { return }
        extract(token: p.token)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === reader {
            expectingReaderLoad = false
            return
        }
        guard webView === loader, let p = pending else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail("Couldn't load the page: \(error.localizedDescription)", url: p.url)
    }

    // MARK: Messages from the reader page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === reader,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "open":
            if let text = body["url"] as? String {
                if let url = normalizeURL(text) { open(url, html: nil) } else { showStart(message: "That doesn't look like a web address.") }
            }
        case "grab": grabBrowserTab()
        case "original": originalAction()
        case "prefs":
            if let p = body["prefs"] as? [String: Any] {
                UserDefaults.standard.set(p, forKey: "prefs")
                syncWindowAppearance(theme: p["theme"] as? String)
            }
        case "queue":
            if let location = body["location"] as? String { queueLocation = location }
            serveQueue(force: body["force"] as? Bool ?? false)
        case "openDoc":
            if let id = body["id"] as? String { openDoc(id) }
        case "archive":
            if let id = body["id"] as? String { archiveCurrent(id, markRead: body["markRead"] as? Bool ?? false) }
        case "backToQueue": showStart()
        case "token":
            if let value = body["value"] as? String { connectReadwise(value) }
        case "disconnect":
            Keychain.delete()
            queueCache = [:]
            queueRevision += 1
            queueFetchToken += 1
            pushQueue(["state": "needsToken"])
        case "exitFullscreen":
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        default: break
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
