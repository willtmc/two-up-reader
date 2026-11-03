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
    guard let data = try? JSONSerialization.data(withJSONObject: object),
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
        let html = template.replacingOccurrences(of: "/*__TWOUP_DATA__*/", with: "window.TWOUP = \(jsonLiteral(data));")
        reader.loadHTMLString(html, baseURL: mode == "article" ? url : nil)
        window.makeFirstResponder(reader)
    }

    func showStart(message: String? = nil, url: URL? = nil) {
        pending = nil
        render(message == nil ? "start" : "error", url: url, message: message)
    }

    // MARK: Loading and extraction

    func open(_ url: URL, html: String?) {
        token += 1
        let t = token
        pending = (t, url, html)
        currentURL = url
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
