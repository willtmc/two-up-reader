import Foundation

private let readwisePathSegmentAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

private func isValidIPv4(_ labels: [Substring]) -> Bool {
    guard labels.count == 4 else { return false }
    return labels.allSatisfy { label in
        guard !label.isEmpty, label.allSatisfy(\.isASCII), label.allSatisfy(\.isNumber) else { return false }
        return UInt8(label) != nil
    }
}

private func isValidWebHost(_ host: String) -> Bool {
    let lower = host.lowercased()
    if lower.isEmpty { return false }
    if lower == "localhost" { return true }

    // Bracketed IPv6 literals arrive in URLComponents.host either with or without brackets depending on OS version.
    if lower.contains(":") {
        let inner: Substring = (lower.hasPrefix("[") && lower.hasSuffix("]"))
            ? lower.dropFirst().dropLast()
            : lower[...]
        let ipv6Allowed = CharacterSet(charactersIn: "0123456789abcdef:.")
        return !inner.isEmpty && inner.contains(":") && inner.unicodeScalars.allSatisfy { ipv6Allowed.contains($0) }
    }

    if lower.hasPrefix(".") || lower.hasSuffix(".") || lower.contains("..") { return false }
    let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }

    if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
        return isValidIPv4(labels)
    }

    for label in labels {
        if label.hasPrefix("-") || label.hasSuffix("-") { return false }
        for scalar in label.unicodeScalars {
            if scalar.isASCII {
                let c = Character(scalar)
                if !(c.isLetter || c.isNumber || c == "-") { return false }
            }
        }
    }

    guard let tld = labels.last else { return false }
    if tld.hasPrefix("xn--") {
        return tld.count >= 5
    }
    return tld.count >= 2 && tld.allSatisfy(\.isLetter)
}

func normalizeURL(_ raw: String) -> URL? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

    if !text.contains("://") {
        let authorityEnd = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? text.endIndex
        let authority = text[..<authorityEnd]
        if !authority.hasPrefix("["), let colon = authority.firstIndex(of: ":") {
            let afterColon = authority[authority.index(after: colon)...]
            guard !afterColon.isEmpty, afterColon.allSatisfy(\.isASCII), afterColon.allSatisfy(\.isNumber),
                  let port = Int(afterColon), (1...65535).contains(port) else {
                return nil
            }
        }
        text = "https://" + text
    }

    guard let components = URLComponents(string: text),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host,
          isValidWebHost(host),
          let url = components.url else {
        return nil
    }
    return url
}

func parseLaunchURL(arguments: [String]) -> URL? {
    var index = 0
    var afterDoubleDash = false
    while index < arguments.count {
        let arg = arguments[index]
        if !afterDoubleDash && arg.hasPrefix("-") {
            if arg == "--" {
                afterDoubleDash = true
                index += 1
                continue
            }
            if arg.hasPrefix("-psn_") || arg.contains("=") {
                index += 1
                continue
            }
            // Skip macOS defaults key-value flag pairs (e.g. -AppleLanguages en, -NS* YES).
            index += 1
            if index < arguments.count {
                let next = arguments[index]
                let lowerNext = next.lowercased()
                if !next.hasPrefix("-") && !lowerNext.hasPrefix("http://") && !lowerNext.hasPrefix("https://") {
                    index += 1
                }
            }
            continue
        }
        if let url = normalizeURL(arg) {
            return url
        }
        index += 1
    }
    return nil
}

func isAllowedExternalURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    switch scheme {
    case "http", "https":
        return !(url.host ?? "").isEmpty
    case "mailto":
        let specifier = url.absoluteString.dropFirst("mailto:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return !specifier.isEmpty
    default:
        return false
    }
}

func matchesExpectedReaderURL(_ requestURL: URL?, expected: URL?) -> Bool {
    guard let requestURL else { return expected == nil }
    if requestURL.absoluteString == "about:blank" { return true }
    guard let expected else { return false }
    if requestURL == expected { return true }
    let reqPath = requestURL.path.isEmpty ? "/" : requestURL.path
    let expPath = expected.path.isEmpty ? "/" : expected.path
    return requestURL.scheme?.lowercased() == expected.scheme?.lowercased()
        && requestURL.host?.lowercased() == expected.host?.lowercased()
        && requestURL.port == expected.port
        && reqPath == expPath
        && requestURL.query == expected.query
}

func readwiseEndpointURL(path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
    guard !path.isEmpty, !path.contains(".."), !path.contains("?"), !path.contains("#") else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "readwise.io"
    components.path = path.hasPrefix("/") ? path : "/" + path
    if let queryItems, !queryItems.isEmpty {
        components.queryItems = queryItems
    }
    guard let url = components.url, url.host?.lowercased() == "readwise.io" else { return nil }
    return url
}

func readwiseUpdateURL(docID: String) -> URL? {
    guard !docID.isEmpty,
          docID != ".",
          !docID.contains(".."),
          !docID.contains("/"),
          !docID.contains("\\"),
          let encoded = docID.addingPercentEncoding(withAllowedCharacters: readwisePathSegmentAllowed),
          !encoded.isEmpty else {
        return nil
    }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "readwise.io"
    components.percentEncodedPath = "/api/v3/update/\(encoded)/"
    guard let url = components.url, url.host?.lowercased() == "readwise.io" else { return nil }
    return url
}

func readwiseReaderBaseURL() -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "read.readwise.io"
    return components.url
}

// Keeps only readable top-level documents (no highlights, notes, PDFs, videos).
func slimDoc(_ raw: [String: Any]) -> [String: Any]? {
    guard let id = raw["id"] as? String, !id.isEmpty,
          raw["parent_id"] == nil || raw["parent_id"] is NSNull,
          ["article", "email", "rss"].contains(raw["category"] as? String ?? "") else { return nil }
    var out: [String: Any] = ["id": id]
    for key in ["title", "author", "site_name", "source_url", "word_count", "reading_progress"] {
        if let value = raw[key], !(value is NSNull) { out[key] = value }
    }
    return out
}

func jsonLiteral(_ object: Any) -> String {
    let valid = JSONSerialization.isValidJSONObject(object)
        || object is String
        || object is NSNumber
        || object is Bool
        || object is NSNull
    guard valid,
          let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
        .replacingOccurrences(of: "</", with: "<\\/")
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

func themeWindowAppearance(theme: String?) -> (bgHex: String, isDark: Bool?) {
    switch theme?.lowercased() {
    case "paper":
        return ("#fbf9f4", false)
    case "sepia":
        return ("#f3ead6", false)
    case "dark":
        return ("#161616", true)
    default:
        return ("#fbf9f4", nil)
    }
}
