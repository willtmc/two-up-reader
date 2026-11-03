import Cocoa
import WebKit

struct Browser {
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

func normalizeURL(_ raw: String) -> URL? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    if !text.contains("://") { text = "https://" + text }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme), url.host != nil else { return nil }
    return url
}

func jsonLiteral(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text.replacingOccurrences(of: "</", with: "<\\/")
}

func resourceText(_ name: String, _ ext: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
        NSLog("TwoUp: missing resource \(name).\(ext)")
        return ""
    }
    return text
}

// MARK: Readwise Reader

enum Keychain {
    static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.mclemore.twoup",
        kSecAttrAccount as String: "readwise",
    ]
    static func get() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ value: String) {
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }
    static func delete() { SecItemDelete(base as CFDictionary) }
}

struct ReadwiseError: LocalizedError { let errorDescription: String? }

func readwiseRequest(_ url: URL, method: String = "GET", body: [String: Any]? = nil, token: String,
                     completion: @escaping (Result<[String: Any], Error>) -> Void) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    URLSession.shared.dataTask(with: request) { data, response, error in
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let result: Result<[String: Any], Error>
        if let error {
            result = .failure(error)
        } else if status == 401 || status == 403 {
            result = .failure(ReadwiseError(errorDescription: "Readwise rejected the token. Reconnect with a fresh one."))
        } else if status == 429 {
            let wait = http?.value(forHTTPHeaderField: "Retry-After") ?? "a few"
            result = .failure(ReadwiseError(errorDescription: "Readwise rate limit hit. Try again in \(wait) seconds."))
        } else if !(200..<300).contains(status) {
            result = .failure(ReadwiseError(errorDescription: "Readwise returned HTTP \(status)."))
        } else {
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            result = .success(object ?? [:])
        }
        DispatchQueue.main.async { completion(result) }
    }.resume()
}

// Keeps only readable top-level documents (no highlights, notes, PDFs, videos).
func slimDoc(_ doc: [String: Any]) -> [String: Any]? {
    guard let id = doc["id"] as? String, doc["parent_id"] == nil || doc["parent_id"] is NSNull,
          ["article", "email", "rss"].contains(doc["category"] as? String ?? "") else { return nil }
    var out: [String: Any] = ["id": id]
    for key in ["title", "author", "site_name", "source_url", "word_count", "reading_progress"] {
        if let value = doc[key], !(value is NSNull) { out[key] = value }
    }
    return out
}

struct QueueCache {
    var items: [[String: Any]]
    var fetchedAt: Date
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var reader: WKWebView!
    // Off-screen-ish view that loads the source page; the reader covers it.
    var loader: WKWebView!
    var template = ""
    var extractorSource = ""
    var lastBrowserID: String?
    var launchURL: URL?
    var currentURL: URL?
    var pending: (token: Int, url: URL, html: String?)?
    var token = 0
    var extracting = Set<Int>()
    var currentDocID: String?
    var queueLocation = "later"
    var queueCache: [String: QueueCache] = [:]

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           browsers.contains(where: { $0.bundleID == front }) {
            lastBrowserID = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, browsers.contains(where: { $0.bundleID == id }) else { return }
            self?.lastBrowserID = id
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        template = resourceText("reader", "html")
        extractorSource = resourceText("Readability", "js") + "\n" + resourceText("extract", "js") + "\ntrue;"
        buildMenu()

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(
            contentRect: screen.insetBy(dx: screen.width * 0.08, dy: screen.height * 0.08),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "TwoUp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let bounds = window.contentView!.bounds

        let loaderConfig = WKWebViewConfiguration()
        loaderConfig.mediaTypesRequiringUserActionForPlayback = .all
        loader = WKWebView(frame: bounds, configuration: loaderConfig)
        loader.customUserAgent = safariUserAgent
        loader.navigationDelegate = self
        loader.autoresizingMask = [.width, .height]

        let readerConfig = WKWebViewConfiguration()
        readerConfig.userContentController.add(self, name: "twoup")
        reader = WKWebView(frame: bounds, configuration: readerConfig)
        reader.navigationDelegate = self
        reader.autoresizingMask = [.width, .height]

        window.contentView!.addSubview(loader)
        window.contentView!.addSubview(reader)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(reader)
        NSApp.activate(ignoringOtherApps: true)
        window.toggleFullScreen(nil)

        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let url = launchURL ?? args.first.flatMap(normalizeURL) {
            open(url, html: nil)
        } else if lastBrowserID != nil {
            grabBrowserTab()
        } else {
            showStart()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) else { return }
        if reader == nil { launchURL = url } else { open(url, html: nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
            item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        NSApp.mainMenu = main
    }

    @objc func openURLAction() { showStart() }
    @objc func grabAction() { grabBrowserTab() }
    @objc func originalAction() { if let url = currentURL { NSWorkspace.shared.open(url) } }

    // MARK: Screens

    func prefs() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: "prefs") ?? [:]
    }

    func render(_ mode: String, article: [String: Any]? = nil, url: URL? = nil, message: String? = nil) {
        var data: [String: Any] = ["mode": mode, "prefs": prefs()]
        if let article { data["article"] = article }
        if let url { data["url"] = url.absoluteString }
        if let message { data["message"] = message }
        if mode == "article", let currentDocID { data["docId"] = currentDocID }
        let html = template.replacingOccurrences(of: "/*__TWOUP_DATA__*/", with: "window.TWOUP = \(jsonLiteral(data));")
        reader.loadHTMLString(html, baseURL: mode == "article" ? url : nil)
        window.makeFirstResponder(reader)
    }

    func showStart(message: String? = nil, url: URL? = nil) {
        pending = nil
        render(message == nil ? "start" : "error", url: url, message: message)
    }

    // MARK: Loading and extraction

    func open(_ url: URL, html: String?, docID: String? = nil) {
        token += 1
        let t = token
        pending = (t, url, html)
        currentURL = url
        currentDocID = docID
        render("loading", url: url)
        if html != nil {
            loader.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: url)
        } else {
            loader.load(URLRequest(url: url))
        }
        // Slow or never-finishing pages: extract whatever has loaded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.extract(token: t) }
    }

    func extract(token t: Int) {
        guard let p = pending, p.token == t, !extracting.contains(t) else { return }
        extracting.insert(t)
        let base = (p.html == nil ? loader.url : nil) ?? p.url
        loader.evaluateJavaScript(extractorSource, in: nil, in: .defaultClient) { _ in
            self.loader.callAsyncJavaScript(
                "return __twoupExtract(html, base);",
                arguments: ["html": p.html ?? NSNull(), "base": base.absoluteString],
                in: nil, in: .defaultClient
            ) { result in
                guard self.pending?.token == t else { return }
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
        stopLoader()
    }

    func stopLoader() {
        loader.stopLoading()
        loader.loadHTMLString("", baseURL: nil)
    }

    // MARK: Readwise Reader queue

    func pushQueue(_ state: [String: Any]) {
        reader.evaluateJavaScript("window.updateQueue && window.updateQueue(\(jsonLiteral(state)))")
    }

    func flash(_ message: String) {
        reader.evaluateJavaScript("window.flash && window.flash(\(jsonLiteral(message)))")
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
        fetchQueue(location, key: key, cursor: nil, items: [], pagesLeft: 3)
    }

    func fetchQueue(_ location: String, key: String, cursor: String?, items: [[String: Any]], pagesLeft: Int) {
        var components = URLComponents(string: "https://readwise.io/api/v3/list/")!
        components.queryItems = [URLQueryItem(name: "location", value: location)]
            + (cursor.map { [URLQueryItem(name: "pageCursor", value: $0)] } ?? [])
        readwiseRequest(components.url!, token: key) { result in
            switch result {
            case .failure(let error):
                self.pushQueue(["state": "error", "location": location, "message": error.localizedDescription,
                                "items": self.queueCache[location]?.items ?? []])
            case .success(let json):
                let all = items + (json["results"] as? [[String: Any]] ?? []).compactMap(slimDoc)
                if let next = json["nextPageCursor"] as? String, pagesLeft > 1 {
                    self.fetchQueue(location, key: key, cursor: next, items: all, pagesLeft: pagesLeft - 1)
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
        let item = queueCache.values.flatMap(\.items).first { $0["id"] as? String == id }
        let listedURL = (item?["source_url"] as? String).flatMap(normalizeURL)
        render("loading", url: listedURL)
        var components = URLComponents(string: "https://readwise.io/api/v3/list/")!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "withHtmlContent", value: "true")]
        readwiseRequest(components.url!, token: key) { result in
            guard self.token == t else { return }
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
                            article: ["title": text("title"), "byline": text("author"), "site": text("site_name"), "content": html],
                            url: url ?? URL(string: "https://read.readwise.io")!)
            }
        }
    }

    func archiveCurrent() {
        guard let id = currentDocID, let key = Keychain.get() else { return }
        flash("Archiving…")
        readwiseRequest(URL(string: "https://readwise.io/api/v3/update/\(id)/")!, method: "PATCH",
                        body: ["location": "archive"], token: key) { result in
            switch result {
            case .failure(let error):
                self.flash(error.localizedDescription)
            case .success:
                for location in self.queueCache.keys {
                    self.queueCache[location]?.items.removeAll { $0["id"] as? String == id }
                }
                self.currentDocID = nil
                self.showStart()
            }
        }
    }

    func connectReadwise(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        readwiseRequest(URL(string: "https://readwise.io/api/v2/auth/")!, token: key) { result in
            switch result {
            case .success:
                Keychain.set(key)
                self.queueCache = [:]
                self.serveQueue(force: true)
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
        let target = "tell application id \"\(browser.bundleID)\""
        let tab = browser.isSafari ? "front document" : "active tab of front window"
        var error: NSDictionary?
        let urlText = NSAppleScript(source: "\(target) to return URL of \(tab)")?.executeAndReturnError(&error).stringValue
        guard let urlText, let url = normalizeURL(urlText) else {
            let code = error?[NSAppleScript.errorNumber] as? Int
            let reason = code == -1743
                ? "TwoUp isn't allowed to control \(browser.name). Turn it on in System Settings → Privacy & Security → Automation."
                : "Couldn't read the current tab in \(browser.name)."
            showStart(message: reason)
            return
        }
        // The page's own HTML keeps logged-in/paywalled content. Needs the browser's
        // "Allow JavaScript from Apple Events" setting; otherwise we load the URL fresh.
        let js = "document.documentElement.outerHTML"
        let htmlScript = browser.isSafari
            ? "\(target) to do JavaScript \"\(js)\" in front document"
            : "\(target) to execute active tab of front window javascript \"\(js)\""
        var htmlError: NSDictionary?
        let html = NSAppleScript(source: htmlScript)?.executeAndReturnError(&htmlError).stringValue
        open(url, html: (html?.count ?? 0) > 500 ? html : nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView === reader, action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
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
        guard webView === loader, let p = pending else { return }
        // Give script-rendered pages a moment to settle.
        let delay = p.html == nil ? 0.8 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.extract(token: p.token) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === loader, let p = pending else { return }
        extract(token: p.token)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === loader, let p = pending else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail("Couldn't load the page: \(error.localizedDescription)", url: p.url)
    }

    // MARK: Messages from the reader page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "open":
            if let text = body["url"] as? String {
                if let url = normalizeURL(text) { open(url, html: nil) } else { showStart(message: "That doesn't look like a web address.") }
            }
        case "grab": grabBrowserTab()
        case "original": originalAction()
        case "prefs":
            if let p = body["prefs"] as? [String: Any] { UserDefaults.standard.set(p, forKey: "prefs") }
        case "queue":
            if let location = body["location"] as? String { queueLocation = location }
            serveQueue(force: body["force"] as? Bool ?? false)
        case "openDoc":
            if let id = body["id"] as? String { openDoc(id) }
        case "archive": archiveCurrent()
        case "token":
            if let value = body["value"] as? String { connectReadwise(value) }
        case "disconnect":
            Keychain.delete()
            queueCache = [:]
            pushQueue(["state": "needsToken"])
        case "exitFullscreen":
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
