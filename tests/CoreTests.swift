import Foundation

final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0

    func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [\(file):\(line)] \(message)\n", stderr)
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if actual == expected {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [\(file):\(line)] \(message): expected \(expected), got \(actual)\n", stderr)
        }
    }

    func expectNil<T>(_ value: T?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if value == nil {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [\(file):\(line)] \(message): expected nil, got \(String(describing: value!))\n", stderr)
        }
    }
}

@main
enum CoreTests {
    static func main() {
        let t = TestRunner()

        testNormalizeURL(t)
        testParseLaunchURL(t)
        testIsAllowedExternalURL(t)
        testMatchesExpectedReaderURL(t)
        testReadwiseURLs(t)
        testSlimDoc(t)
        testJsonLiteral(t)
        testThemeWindowAppearance(t)

        print("CoreTests: \(t.passed) passed, \(t.failed) failed")
        if t.failed > 0 {
            exit(1)
        }
    }

    static func testNormalizeURL(_ t: TestRunner) {
        t.expectEqual(normalizeURL("https://example.com")?.absoluteString, "https://example.com", "accepts https URL")
        t.expectEqual(normalizeURL("http://example.com/a?x=1#top")?.absoluteString, "http://example.com/a?x=1#top", "accepts http URL with path/query/hash")
        t.expectEqual(normalizeURL("  https://example.com/trimmed  ")?.absoluteString, "https://example.com/trimmed", "trims surrounding whitespace")
        t.expectEqual(normalizeURL("example.com/a")?.absoluteString, "https://example.com/a", "prepends https to bare domain with path")
        t.expectEqual(normalizeURL("sub.example.co.uk/post?id=42")?.absoluteString, "https://sub.example.co.uk/post?id=42", "accepts multi-label bare domain")
        t.expectEqual(normalizeURL("example.xn--p1ai")?.absoluteString, "https://example.xn--p1ai", "accepts punycode TLD")
        t.expectEqual(normalizeURL("localhost")?.absoluteString, "https://localhost", "accepts bare localhost")
        t.expectEqual(normalizeURL("localhost:3000")?.absoluteString, "https://localhost:3000", "accepts localhost with port")
        t.expectEqual(normalizeURL("http://localhost:8080/page")?.absoluteString, "http://localhost:8080/page", "accepts http localhost with port")
        t.expectEqual(normalizeURL("127.0.0.1")?.absoluteString, "https://127.0.0.1", "accepts IPv4 literal")
        t.expectEqual(normalizeURL("192.168.1.10:8080/article")?.absoluteString, "https://192.168.1.10:8080/article", "accepts IPv4 literal with port and path")
        t.expectEqual(normalizeURL("[::1]")?.absoluteString, "https://[::1]", "accepts bracketed IPv6 literal")
        t.expectEqual(normalizeURL("[::1]:8080/test")?.absoluteString, "https://[::1]:8080/test", "accepts bracketed IPv6 literal with port")
        t.expectEqual(normalizeURL("http://[2001:db8::1]/doc")?.absoluteString, "http://[2001:db8::1]/doc", "accepts full IPv6 URL")

        // Rejections: typos, empty, non-HTTP schemes, invalid hosts/ports/IPs
        let rejected = [
            "",
            "   ",
            "hello",
            "en",
            "not a url",
            "https://example.com/has space",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "mailto:user@example.com",
            "ftp://example.com/file",
            ".example.com",
            "example.com.",
            "a..b.com",
            "-bad.com",
            "bad-.com",
            "example.123",
            "999.1.1.1",
            "1.2.3.256",
            "1.2.3",
            "localhost:0",
            "localhost:65536",
            "localhost:abc",
            "example.com:",
        ]
        for raw in rejected {
            t.expectNil(normalizeURL(raw), "rejects invalid URL '\(raw)'")
        }
    }

    static func testParseLaunchURL(_ t: TestRunner) {
        t.expectNil(parseLaunchURL(arguments: []), "empty args returns nil")
        t.expectNil(parseLaunchURL(arguments: ["-AppleLanguages", "en"]), "ignores -AppleLanguages flag pair")
        t.expectNil(parseLaunchURL(arguments: ["-NSDocumentRevisionsDebugMode", "YES"]), "ignores -NS* flag pair")
        t.expectNil(parseLaunchURL(arguments: ["-psn_0_12345"]), "ignores -psn_ launch flag")
        t.expectEqual(
            parseLaunchURL(arguments: [
                "-AppleLanguages", "en",
                "-NSDocumentRevisionsDebugMode", "YES",
                "-psn_0_12345",
                "https://example.com/article",
            ])?.absoluteString,
            "https://example.com/article",
            "extracts URL after macOS launch flags"
        )
        t.expectEqual(
            parseLaunchURL(arguments: ["-foo=bar", "example.com/post"])?.absoluteString,
            "https://example.com/post",
            "ignores key=value flag and extracts bare domain URL"
        )
        t.expectEqual(
            parseLaunchURL(arguments: ["-NSOpen", "https://example.com/direct"])?.absoluteString,
            "https://example.com/direct",
            "does not consume https URL as flag value"
        )
        t.expectEqual(
            parseLaunchURL(arguments: ["--", "example.com/after-dash"])?.absoluteString,
            "https://example.com/after-dash",
            "treats arguments after -- as positional"
        )
        t.expectEqual(
            parseLaunchURL(arguments: ["not-a-url", "example.com/second"])?.absoluteString,
            "https://example.com/second",
            "skips invalid positional args to find first valid URL"
        )
    }

    static func testIsAllowedExternalURL(_ t: TestRunner) {
        let allowed = [
            "http://example.com",
            "https://example.com/path?q=1",
            "HTTPS://EXAMPLE.COM",
            "mailto:reader@example.com",
        ]
        for raw in allowed {
            guard let url = URL(string: raw) else {
                t.expect(false, "failed to construct URL for '\(raw)'")
                continue
            }
            t.expect(isAllowedExternalURL(url), "allows external URL '\(raw)'")
        }

        let disallowed = [
            "file:///etc/passwd",
            "shortcuts://run-shortcut?name=Test",
            "smb://fileserver.local/share",
            "ssh://user@example.com",
            "javascript:alert(1)",
            "data:text/html,<h1>hi</h1>",
            "tel:+15551234567",
            "https://",
            "http://",
            "mailto:",
        ]
        for raw in disallowed {
            guard let url = URL(string: raw) else {
                t.expect(false, "failed to construct URL for '\(raw)'")
                continue
            }
            t.expect(!isAllowedExternalURL(url), "rejects external URL '\(raw)'")
        }
    }

    static func testMatchesExpectedReaderURL(_ t: TestRunner) {
        let expected = URL(string: "https://example.com/post?a=1")!
        let rootExpected = URL(string: "https://example.com/")!

        t.expect(matchesExpectedReaderURL(nil, expected: nil), "nil matches nil")
        t.expect(!matchesExpectedReaderURL(nil, expected: expected), "nil does not match non-nil expected")
        t.expect(matchesExpectedReaderURL(URL(string: "about:blank"), expected: nil), "about:blank matches nil")
        t.expect(matchesExpectedReaderURL(URL(string: "about:blank"), expected: expected), "about:blank matches expected URL")
        t.expect(!matchesExpectedReaderURL(expected, expected: nil), "external URL rejected when expected is nil")

        t.expect(matchesExpectedReaderURL(expected, expected: expected), "exact URL matches")
        t.expect(matchesExpectedReaderURL(URL(string: "https://example.com"), expected: rootExpected), "empty path matches root slash")
        t.expect(matchesExpectedReaderURL(URL(string: "HTTPS://EXAMPLE.COM/post?a=1"), expected: expected), "scheme/host comparison is case-insensitive")
        t.expect(matchesExpectedReaderURL(URL(string: "https://example.com/post?a=1#section"), expected: expected), "same URL with fragment matches")

        t.expect(!matchesExpectedReaderURL(URL(string: "https://evil.test/post?a=1"), expected: expected), "rejects different host")
        t.expect(!matchesExpectedReaderURL(URL(string: "http://example.com/post?a=1"), expected: expected), "rejects different scheme")
        t.expect(!matchesExpectedReaderURL(URL(string: "https://example.com:8443/post?a=1"), expected: expected), "rejects different port")
        t.expect(!matchesExpectedReaderURL(URL(string: "https://example.com/other?a=1"), expected: expected), "rejects different path")
        t.expect(!matchesExpectedReaderURL(URL(string: "https://example.com/post?a=2"), expected: expected), "rejects different query")
    }

    static func testReadwiseURLs(_ t: TestRunner) {
        let listURL = readwiseEndpointURL(
            path: "/api/v3/list/",
            queryItems: [
                URLQueryItem(name: "location", value: "later"),
                URLQueryItem(name: "withHtmlContent", value: "false"),
            ]
        )
        t.expectEqual(
            listURL?.absoluteString,
            "https://readwise.io/api/v3/list/?location=later&withHtmlContent=false",
            "builds Readwise list endpoint URL with query params"
        )

        let noLeadingSlash = readwiseEndpointURL(path: "api/v2/auth/")
        t.expectEqual(noLeadingSlash?.absoluteString, "https://readwise.io/api/v2/auth/", "prepends leading slash when omitted")

        let encodedQuery = readwiseEndpointURL(
            path: "/api/v3/list/",
            queryItems: [URLQueryItem(name: "tag", value: "a&b=c d")]
        )
        t.expectEqual(encodedQuery?.host, "readwise.io", "keeps readwise.io host with encoded query")
        t.expect(encodedQuery?.absoluteString.contains("tag=a%26b%3Dc%20d") == true, "percent-encodes special query characters")

        for badPath in ["", "/api/v3/../v2/auth/", "/api/v3/list/?foo=bar", "/api/v3/list/#frag"] {
            t.expectNil(readwiseEndpointURL(path: badPath), "rejects unsafe Readwise path '\(badPath)'")
        }

        let updateNormal = readwiseUpdateURL(docID: "01abc-DEF_99.1~")
        t.expectEqual(updateNormal?.absoluteString, "https://readwise.io/api/v3/update/01abc-DEF_99.1~/", "builds Readwise update URL for normal docID")

        let updateEncoded = readwiseUpdateURL(docID: "doc id?x=1#h")
        t.expectEqual(updateEncoded?.absoluteString, "https://readwise.io/api/v3/update/doc%20id%3Fx%3D1%23h/", "percent-encodes special chars in docID")

        for badID in ["", ".", "..", "a..b", "a/b", "../v2/auth", "a\\b"] {
            t.expectNil(readwiseUpdateURL(docID: badID), "rejects unsafe docID '\(badID)'")
        }

        t.expectEqual(readwiseReaderBaseURL()?.absoluteString, "https://read.readwise.io", "returns Readwise Reader base URL")
    }

    static func testSlimDoc(_ t: TestRunner) {
        let article: [String: Any] = [
            "id": "doc-1",
            "parent_id": NSNull(),
            "category": "article",
            "title": "Two-Up Reading",
            "author": "Jane Doe",
            "site_name": "Example Press",
            "source_url": "https://example.com/two-up",
            "word_count": 1200,
            "reading_progress": 0.45,
            "location": "later",
            "html_content": "<p>ignored</p>",
        ]
        if let slim = slimDoc(article) {
            t.expectEqual(slim["id"] as? String, "doc-1", "slimDoc preserves id")
            t.expectEqual(slim["title"] as? String, "Two-Up Reading", "slimDoc preserves title")
            t.expectEqual(slim["author"] as? String, "Jane Doe", "slimDoc preserves author")
            t.expectEqual(slim["site_name"] as? String, "Example Press", "slimDoc preserves site_name")
            t.expectEqual(slim["source_url"] as? String, "https://example.com/two-up", "slimDoc preserves source_url")
            t.expectEqual(slim["word_count"] as? Int, 1200, "slimDoc preserves word_count")
            t.expectEqual(slim["reading_progress"] as? Double, 0.45, "slimDoc preserves reading_progress")
            t.expectNil(slim["html_content"], "slimDoc strips html_content")
            t.expectNil(slim["location"], "slimDoc strips location")
        } else {
            t.expect(false, "slimDoc should accept valid article")
        }

        // Drops NSNull optional fields and accepts email/rss categories
        let rss: [String: Any] = [
            "id": "doc-2",
            "category": "rss",
            "title": "RSS Item",
            "author": NSNull(),
        ]
        if let slim = slimDoc(rss) {
            t.expectEqual(slim["id"] as? String, "doc-2", "slimDoc accepts rss category")
            t.expectNil(slim["author"], "slimDoc omits NSNull optional fields")
        } else {
            t.expect(false, "slimDoc should accept rss doc")
        }

        let email: [String: Any] = ["id": "doc-3", "category": "email"]
        t.expect(slimDoc(email) != nil, "slimDoc accepts email category")

        // Rejections
        t.expectNil(slimDoc(["category": "article"]), "rejects missing id")
        t.expectNil(slimDoc(["id": "", "category": "article"]), "rejects empty id")
        t.expectNil(slimDoc(["id": "h1", "parent_id": "doc-1", "category": "article"]), "rejects non-null parent_id")
        for badCategory in ["pdf", "video", "epub", "highlight", "note", "tweet", ""] {
            t.expectNil(slimDoc(["id": "x", "category": badCategory]), "rejects category '\(badCategory)'")
        }
        t.expectNil(slimDoc(["id": "x"]), "rejects missing category")
    }

    static func testJsonLiteral(_ t: TestRunner) {
        let scriptEscape = jsonLiteral("</script><script>alert(1)</script>")
        t.expect(!scriptEscape.contains("</script>"), "escapes </script> closing tags")
        t.expect(scriptEscape.contains("<\\/script>"), "replaces </ with <\\/")

        let quotes = jsonLiteral("say \"hi\" \\ bye")
        t.expectEqual(quotes, "\"say \\\"hi\\\" \\\\ bye\"", "escapes double quotes and backslashes")

        let lineSeps = jsonLiteral("a\u{2028}b\u{2029}c")
        t.expect(!lineSeps.contains("\u{2028}"), "escapes U+2028 line separator")
        t.expect(!lineSeps.contains("\u{2029}"), "escapes U+2029 paragraph separator")
        t.expectEqual(lineSeps, "\"a\\u2028b\\u2029c\"", "emits JS-safe \\u2028/\\u2029 escapes")

        let payload: [String: Any] = [
            "html": "<p></script>\u{2028}\u{2029}</p>",
            "count": 3,
            "ok": true,
        ]
        let encoded = jsonLiteral(payload)
        t.expect(!encoded.contains("</"), "dictionary jsonLiteral escapes </")
        t.expect(!encoded.contains("\u{2028}") && !encoded.contains("\u{2029}"), "dictionary jsonLiteral escapes U+2028/U+2029")
        if let data = encoded.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.expectEqual(decoded["html"] as? String, "<p></script>\u{2028}\u{2029}</p>", "round-trips escaped payload via JSONSerialization")
            t.expectEqual(decoded["count"] as? Int, 3, "round-trips integer")
            t.expectEqual(decoded["ok"] as? Bool, true, "round-trips boolean")
        } else {
            t.expect(false, "encoded dictionary must be valid JSON")
        }

        t.expectEqual(jsonLiteral(URL(string: "https://example.com")!), "{}", "returns {} for non-JSON Swift object")
    }

    static func testThemeWindowAppearance(_ t: TestRunner) {
        let paper = themeWindowAppearance(theme: "paper")
        t.expectEqual(paper.bgHex, "#fbf9f4", "paper bgHex")
        t.expectEqual(paper.isDark, false, "paper isDark")

        let paperUpper = themeWindowAppearance(theme: "PAPER")
        t.expectEqual(paperUpper.bgHex, "#fbf9f4", "paper is case-insensitive")
        t.expectEqual(paperUpper.isDark, false, "paper uppercase isDark")

        let sepia = themeWindowAppearance(theme: "sepia")
        t.expectEqual(sepia.bgHex, "#f3ead6", "sepia bgHex")
        t.expectEqual(sepia.isDark, false, "sepia isDark")

        let dark = themeWindowAppearance(theme: "dark")
        t.expectEqual(dark.bgHex, "#161616", "dark bgHex")
        t.expectEqual(dark.isDark, true, "dark isDark")

        let nilTheme = themeWindowAppearance(theme: nil)
        t.expectEqual(nilTheme.bgHex, "#fbf9f4", "nil theme defaults to paper bgHex")
        t.expectNil(nilTheme.isDark, "nil theme preserves nil isDark (follow system)")

        let unknown = themeWindowAppearance(theme: "solarized")
        t.expectEqual(unknown.bgHex, "#fbf9f4", "unknown theme defaults to paper bgHex")
        t.expectNil(unknown.isDark, "unknown theme preserves nil isDark")
    }
}

