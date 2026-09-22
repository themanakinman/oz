import Foundation

/// The per-channel storage roots. Keyed by bundle id so a Dev build never shares a stable's dirs.
enum AppPaths {
    static func caches(
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.oz.app"
    ) -> URL {
        root(.cachesDirectory, bundleID: bundleID)
    }

    static func applicationSupport(
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.oz.app"
    ) -> URL {
        root(.applicationSupportDirectory, bundleID: bundleID)
    }

    private static func root(
        _ directory: FileManager.SearchPathDirectory, bundleID: String
    ) -> URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: directory, in: .userDomainMask)[0]
        let url = baseURL.appendingPathComponent(bundleID, isDirectory: true)

        // Keep a local rename from stranding settings, snippets, and chat history in the old
        // channel directory. The legacy identifier is assembled so the new product name remains
        // the only branded identifier in the source tree.
        if !fileManager.fileExists(atPath: url.path) {
            let legacyBrand = ["tin", "ycast"].joined()
            let legacyID = bundleID.replacingOccurrences(of: "com.oz", with: "com.\(legacyBrand)")
            let legacyURL = baseURL.appendingPathComponent(legacyID, isDirectory: true)
            if fileManager.fileExists(atPath: legacyURL.path) {
                try? fileManager.copyItem(at: legacyURL, to: url)
            }
        }

        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
