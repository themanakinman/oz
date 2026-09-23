import AppKit

@MainActor
enum QuicklinkIconCache {
    private struct IconCandidate {
        let url: URL
        let score: Int
    }

    private final class Cache: NSCache<NSString, NSImage> {}

    private static let linkTagPattern = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
    private static let attributePattern = try! NSRegularExpression(
        pattern: "([a-zA-Z_:][a-zA-Z0-9_:.-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
        options: [.caseInsensitive])

    private static let cache: Cache = {
        let cache = Cache()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func icon(for link: String) async -> NSImage? {
        guard let destination = QuicklinkDestination.detect(link) else { return nil }
        let key: String
        switch destination {
        case .web(let url):
            guard let host = url.host(), !host.isEmpty else { return nil }
            key = "web:\(host.lowercased())"
        case .deeplink(let url): key = "app:\(url.scheme?.lowercased() ?? link)"
        case .path(let path): key = "file:\(path)"
        case .network: return nil
        }
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let source: NSImage?
        switch destination {
        case .web(let url):
            guard let host = url.host() else { return nil }
            source = await webIcon(for: url, host: host)
        case .deeplink(let url):
            source = NSWorkspace.shared.urlForApplication(toOpen: url).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }
        case .path(let path):
            source = FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path) : nil
        case .network: source = nil
        }
        guard let source else { return nil }
        let (icon, cost) = IconCache.fitted(source, to: IconCache.appIconExtent)
        cache.setObject(icon, forKey: key as NSString, cost: cost)
        return icon
    }

    private static func webIcon(for pageURL: URL, host: String) async -> NSImage? {
        if let icon = await pageIcon(for: pageURL) { return icon }
        return await favicon(for: host)
    }

    private static func pageIcon(for pageURL: URL) async -> NSImage? {
        guard var components = URLComponents(
            url: pageURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 6)
        guard let (data, response) = try? await session.data(for: request),
            let response = response as? HTTPURLResponse, response.statusCode == 200,
            data.count <= 2_000_000
        else { return nil }

        let html = String(decoding: data, as: UTF8.self)
        let candidates = iconCandidates(in: html, baseURL: response.url ?? url)
            .sorted { $0.score > $1.score }
        for candidate in candidates {
            if let icon = await image(at: candidate.url) { return icon }
        }
        return nil
    }

    private static func iconCandidates(in html: String, baseURL: URL) -> [IconCandidate] {
        let source = html as NSString
        let range = NSRange(location: 0, length: source.length)
        let tags = linkTagPattern.matches(in: html, range: range)
        var candidates: [IconCandidate] = []
        for tag in tags {
            let tagText = source.substring(with: tag.range)
            let tagSource = tagText as NSString
            let attributes = attributePattern.matches(
                in: tagText, range: NSRange(location: 0, length: tagSource.length))
            var values: [String: String] = [:]
            for attribute in attributes {
                let name = tagSource.substring(with: attribute.range(at: 1)).lowercased()
                let valueRange = (2...4).first { attribute.range(at: $0).location != NSNotFound }
                guard let valueRange else { continue }
                values[name] = tagSource.substring(with: attribute.range(at: valueRange))
            }

            let relations = Set((values["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace))
            let isSiteIcon = relations.contains("icon")
            let isTouchIcon = relations.contains("apple-touch-icon")
                || relations.contains("apple-touch-icon-precomposed")
            guard isSiteIcon || isTouchIcon, let href = values["href"] else { continue }
            let cleanedHref = href.replacingOccurrences(of: "&amp;", with: "&")
            guard let candidateURL = URL(string: cleanedHref, relativeTo: baseURL)?.absoluteURL,
                ["http", "https"].contains(candidateURL.scheme?.lowercased() ?? "")
            else { continue }

            let largestSize = (values["sizes"] ?? "").split(whereSeparator: \.isWhitespace)
                .compactMap { size -> Int? in
                    let dimensions = size.lowercased().split(separator: "x")
                    return dimensions.compactMap { Int($0) }.min()
                }.max() ?? 0
            candidates.append(
                IconCandidate(
                    url: candidateURL, score: (isSiteIcon ? 1_000 : 800) + largestSize))
        }
        return candidates
    }

    private static func favicon(for host: String) async -> NSImage? {
        for path in ["favicon.ico", "apple-touch-icon.png"] {
            guard let url = URL(string: "https://\(host)/\(path)") else { continue }
            if let icon = await image(at: url) { return icon }
        }
        return nil
    }

    private static func image(at url: URL) async -> NSImage? {
        let request = URLRequest(url: url, timeoutInterval: 6)
        guard let (data, response) = try? await session.data(for: request),
            let response = response as? HTTPURLResponse, response.statusCode == 200,
            data.count <= 1_000_000
        else { return nil }
        return NSImage(data: data)
    }
}
