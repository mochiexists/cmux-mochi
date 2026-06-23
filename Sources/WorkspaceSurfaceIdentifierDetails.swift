struct WorkspaceSurfaceIdentifierDetails: Equatable {
    typealias Row = WorkspaceSurfaceIdentifierDetailsRow

    let rows: [Row]

    var clipboardText: String {
        rows.compactMap(\.copyLine).joined(separator: "\n")
    }

    var hasCopyableRows: Bool {
        rows.contains { $0.value != nil }
    }
}
