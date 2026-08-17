public import Foundation

public enum SocketPathMarkerFiles {
    public static let stableMarkerFileName = "last-socket-path"
    public static let stableTmpPath = "/tmp/cmux-last-socket-path"
    public static let nightlyBundleIdentifier = "com.cmuxterm.app.nightly"
    public static let stagingBundleIdentifier = "com.cmuxterm.app.staging"
    public static let defaultBaseDebugBundleIdentifier = "com.cmuxterm.app.debug"
    public static let defaultDebugSocketPath = "/tmp/cmux-debug.sock"
    public static let defaultNightlySocketPath = "/tmp/cmux-nightly.sock"
    public static let defaultStagingSocketPath = "/tmp/cmux-staging.sock"

    public static func markerFileURL(
        fileName: String = stableMarkerFileName,
        directory: URL?
    ) -> URL? {
        directory?.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func paths(
        bundleIdentifier: String?,
        environment: [String: String],
        directory: URL?,
        baseDebugBundleIdentifier: String = defaultBaseDebugBundleIdentifier
    ) -> [String] {
        let variant = variant(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            baseDebugBundleIdentifier: baseDebugBundleIdentifier
        )
        var candidates: [String] = []
        if let directoryPath = markerFileURL(
            fileName: variant.markerFileName,
            directory: directory
        )?.path {
            candidates.append(directoryPath)
        }
        candidates.append(variant.tmpPath)
        return dedupe(candidates)
    }

    public static func variant(
        bundleIdentifier: String?,
        environment: [String: String],
        baseDebugBundleIdentifier: String = defaultBaseDebugBundleIdentifier
    ) -> SocketPathVariant {
        let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundleId == nightlyBundleIdentifier {
            return .nightly(slug: nil)
        }
        let nightlyPrefix = nightlyBundleIdentifier + "."
        if bundleId.hasPrefix(nightlyPrefix) {
            return .nightly(slug: bundleSuffixSlug(bundleId, prefix: nightlyPrefix))
        }
        if bundleId == stagingBundleIdentifier {
            return .staging(slug: nil)
        }
        let stagingPrefix = stagingBundleIdentifier + "."
        if bundleId.hasPrefix(stagingPrefix) {
            return .staging(slug: bundleSuffixSlug(bundleId, prefix: stagingPrefix))
        }
        if bundleId == baseDebugBundleIdentifier {
            if let tag = normalized(environment["CMUX_TAG"]),
               let slug = sanitizeSocketSlug(tag) {
                return .dev(slug: slug)
            }
            return .dev(slug: nil)
        }
        if bundleId.hasPrefix("\(baseDebugBundleIdentifier).") {
            return .dev(slug: bundleSuffixSlug(bundleId, prefix: "\(baseDebugBundleIdentifier)."))
        }
        // The comparisons above are all anchored to one vendor's bundle id, so
        // any rename or fork falls through to `.stable` and every tagged build
        // silently collapses onto the single stable socket. Recover the channel
        // from the bundle id's own shape (`<base>.<channel>[.<slug>]`) instead,
        // which is vendor-agnostic and leaves the results above unchanged.
        if let structural = structuralVariant(bundleId, environment: environment) {
            return structural
        }
        return .stable
    }

    /// Channel segments a bundle id may carry after its base identifier.
    private static let channelTokens: Set<String> = ["debug", "nightly", "staging"]

    /// Derives the variant from the bundle id's structure rather than from a
    /// hardcoded vendor prefix.
    ///
    /// Matches the *first* channel token at index >= 1 so a base identifier is
    /// always present and a tag that happens to be named after another channel
    /// (`…debug.nightly`) still resolves as the channel it was built for.
    private static func structuralVariant(
        _ bundleId: String,
        environment: [String: String]
    ) -> SocketPathVariant? {
        let parts = bundleId
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard let index = parts.indices.first(where: { index in
            index >= 1 && channelTokens.contains(parts[index])
        }) else {
            return nil
        }
        let rawSlug = parts.dropFirst(index + 1).joined(separator: ".")
        let slug = rawSlug.isEmpty ? nil : sanitizeSocketSlug(rawSlug)
        switch parts[index] {
        case "debug":
            if let slug {
                return .dev(slug: slug)
            }
            // Untagged debug builds still honour an explicit CMUX_TAG, matching
            // the `bundleId == baseDebugBundleIdentifier` branch above.
            if let tag = normalized(environment["CMUX_TAG"]),
               let tagSlug = sanitizeSocketSlug(tag) {
                return .dev(slug: tagSlug)
            }
            return .dev(slug: nil)
        case "nightly":
            return .nightly(slug: slug)
        case "staging":
            return .staging(slug: slug)
        default:
            return nil
        }
    }

    public static func defaultSocketPath(
        bundleIdentifier: String?,
        environment: [String: String],
        isDebugBuild: Bool,
        stableSocketPath: String,
        baseDebugBundleIdentifier: String = defaultBaseDebugBundleIdentifier,
        debugSocketPath: String = defaultDebugSocketPath,
        nightlySocketPath: String = defaultNightlySocketPath,
        stagingSocketPath: String = defaultStagingSocketPath
    ) -> String {
        switch variant(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            baseDebugBundleIdentifier: baseDebugBundleIdentifier
        ) {
        case .stable:
            return isDebugBuild ? debugSocketPath : stableSocketPath
        case .nightly(let slug):
            if let slug {
                return "/tmp/cmux-nightly-\(slug).sock"
            }
            return nightlySocketPath
        case .staging(let slug):
            if let slug {
                return "/tmp/cmux-staging-\(slug).sock"
            }
            return stagingSocketPath
        case .dev(let slug):
            if let slug {
                return "/tmp/cmux-debug-\(slug).sock"
            }
            return debugSocketPath
        }
    }

    public static func sanitizeSocketSlug(_ raw: String) -> String? {
        let slug = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    private static func bundleSuffixSlug(_ bundleIdentifier: String, prefix: String) -> String? {
        let suffix = String(bundleIdentifier.dropFirst(prefix.count))
        return sanitizeSocketSlug(suffix)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values where seen.insert(value).inserted {
            ordered.append(value)
        }
        return ordered
    }
}
