#if os(iOS)
import Foundation

/// Resolves localized folder-child inflection markup before gallery rendering.
struct TerminalArtifactChildCountFormatter: Sendable {
    private let locale: Locale
    private let bundle: Bundle

    init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
        self.bundle = Self.localizedBundle(for: locale)
    }

    /// The `locale:` argument of `String(localized:)` selects formatting and
    /// inflection rules, not the table the string is read from — that follows
    /// the process's preferred languages. Resolve the matching `.lproj`
    /// ourselves so an injected locale actually reads that language's strings.
    ///
    /// Falls back to `.module` when the locale ships no table, which is also
    /// the production path for `.autoupdatingCurrent`: the process language
    /// and the current locale already agree there.
    private static func localizedBundle(for locale: Locale) -> Bundle {
        let candidates: [String?] = [locale.identifier, locale.language.languageCode?.identifier]
        for candidate in candidates.compactMap({ $0 }) {
            if let path = Bundle.module.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .module
    }

    func string(count: Int, isCapped: Bool) -> String {
        if isCapped {
            return String(
                localized: "terminal.artifact.gallery.child_count_capped",
                defaultValue: "\(count)+ items",
                bundle: bundle,
                locale: locale
            )
        }
        let attributed = AttributedString(
            localized: "terminal.artifact.gallery.child_count",
            defaultValue: "^[\(count) item](inflect: true)",
            bundle: bundle,
            locale: locale
        )
        return String(attributed.characters)
    }
}
#endif
