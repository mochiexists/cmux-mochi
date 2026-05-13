import CMUXAuthCore
import Foundation

enum SettingsPIIDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case visible
    case hidden

    static let key = "cmux.settings.piiDisplayMode"
    static let defaultValue = visible.rawValue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .visible:
            return String(
                localized: "settings.account.displayMode.visible",
                defaultValue: "Show personal info"
            )
        case .hidden:
            return String(
                localized: "settings.account.displayMode.hidden",
                defaultValue: "Hide personal info"
            )
        }
    }
}

final class AuthSettingsStore {
    private enum Keys {
        static let cachedUser = "cmux.auth.cachedUser"
    }

    let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func cachedUser() -> CMUXAuthUser? {
        guard let data = userDefaults.data(forKey: Keys.cachedUser) else { return nil }
        return try? decoder.decode(CMUXAuthUser.self, from: data)
    }

    func saveCachedUser(_ user: CMUXAuthUser?) {
        guard let user else {
            userDefaults.removeObject(forKey: Keys.cachedUser)
            return
        }
        guard let data = try? encoder.encode(user) else { return }
        userDefaults.set(data, forKey: Keys.cachedUser)
    }

}
