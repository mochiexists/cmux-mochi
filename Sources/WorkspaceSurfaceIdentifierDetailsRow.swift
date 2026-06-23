struct WorkspaceSurfaceIdentifierDetailsRow: Identifiable, Equatable {
    let section: WorkspaceSurfaceIdentifierDetailsSection
    let key: String
    let value: String?

    var id: String { key }

    var copyLine: String? {
        guard let value else { return nil }
        return "\(key)=\(value)"
    }
}
