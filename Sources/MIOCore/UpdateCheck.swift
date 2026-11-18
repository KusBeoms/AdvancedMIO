import Foundation

/// A dotted numeric version such as "0.2.0" (a leading "v" is ignored). Missing parts count as 0.
public struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let numbers = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The newest published release, read from the GitHub "latest release" API response.
public struct ReleaseInfo: Equatable {
    public let version: AppVersion
    public let assetName: String
    public let assetURL: URL
    public let notes: String
}

public enum ReleaseFeed {
    /// Returns nil for drafts, prereleases, unparsable tags, or releases without an `AdvancedMIO*.zip` asset.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable {
            let tag_name: String; let draft: Bool?; let prerelease: Bool?; let body: String?; let assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let version = AppVersion(release.tag_name),
              let asset = release.assets.first(where: { $0.name.hasPrefix("AdvancedMIO") && $0.name.hasSuffix(".zip") }),
              let url = URL(string: asset.browser_download_url), url.scheme == "https" else { return nil }
        return ReleaseInfo(version: version, assetName: asset.name, assetURL: url, notes: release.body ?? "")
    }
}
