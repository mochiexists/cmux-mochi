import Foundation

/// Built-in sample artifacts bundled under `Resources/artifact-samples/`. These
/// double as the default "show me what artifacts can do" items and as the
/// renderer's acceptance fixtures (e.g. `showcase` exercises the full library
/// allow-list — three/d3/mathjs/lodash/tone/recharts/lucide).
enum ArtifactSamples {
    /// A bundled sample: the `--template` token, its display title, and kind.
    struct Sample {
        let name: String
        let title: String
        let kind: ArtifactKind
        let resource: String
        let ext: String
    }

    static let all: [Sample] = [
        Sample(
            name: "showcase",
            title: "Capabilities Showcase",
            kind: .react,
            resource: "showcase",
            ext: "jsx"
        ),
        Sample(
            name: "live-events",
            title: "Live Events Cockpit",
            kind: .react,
            resource: "live-events",
            ext: "jsx"
        )
    ]

    static func sample(named name: String) -> Sample? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Loads a sample's source from the app bundle, or `nil` if missing.
    static func source(for sample: Sample) -> String? {
        guard let url = Bundle.main.url(
            forResource: sample.resource,
            withExtension: sample.ext,
            subdirectory: "artifact-samples"
        ) ?? Bundle.main.url(forResource: sample.resource, withExtension: sample.ext) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
