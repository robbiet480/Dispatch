import Foundation

/// The catalog of questions seeded on a fresh install, with deterministic
/// identities so two fresh installs (or a fresh install syncing against an
/// existing iCloud store) produce IDENTICAL question IDs and merge instead of
/// duplicating.
public enum DefaultQuestions {
    /// Dispatch's UUIDv5 namespace. FROZEN FOREVER — changing this value
    /// changes the identity of every seeded question on every future install
    /// and breaks cross-device merging. Never regenerate it.
    public static let namespace = UUID(uuidString: "FBD78042-1AFA-45F8-99B5-BC884958B2D1")!

    /// One seeded question. `slug` is a FROZEN identity key — it is never
    /// derived from the prompt at runtime, so editing a prompt's wording
    /// later must never change the question's identity.
    public struct Seed: Sendable {
        public let slug: String
        public let prompt: String
        public let type: QuestionType
        public let choices: [String]
        public let reportKinds: [ReportKind]

        /// Deterministic UUID string for this seed
        /// (uuid5(namespace, "io.robbie.Dispatch.default-question.<slug>")).
        public var identifier: String {
            UUID(v5Namespace: DefaultQuestions.namespace,
                 name: "io.robbie.Dispatch.default-question.\(slug)").uuidString
        }

        init(slug: String, prompt: String, type: QuestionType,
             choices: [String] = [], reportKinds: [ReportKind] = [.regular]) {
            self.slug = slug
            self.prompt = prompt
            self.type = type
            self.choices = choices
            self.reportKinds = reportKinds
        }
    }

    /// Order is load-bearing twice over: it is the seeded `sortOrder`, and
    /// the array index is the `<N>` of the legacy `default-question-<N>`
    /// identifiers that the one-time migration rewrites. Do not reorder;
    /// append only.
    public static let all: [Seed] = [
        Seed(slug: "how-did-you-sleep", prompt: "How did you sleep?", type: .multipleChoice,
             choices: ["Great", "OK", "Poorly"], reportKinds: [.wake]),
        Seed(slug: "are-you-working", prompt: "Are you working?", type: .yesNo),
        Seed(slug: "what-are-you-doing", prompt: "What are you doing?", type: .tokens),
        Seed(slug: "where-are-you", prompt: "Where are you?", type: .location),
        Seed(slug: "who-are-you-with", prompt: "Who are you with?", type: .people),
        Seed(slug: "how-many-coffees", prompt: "How many coffees did you have today?", type: .number),
        Seed(slug: "what-did-you-learn", prompt: "What did you learn today?", type: .note),
    ]

    /// Maps a legacy seeded identifier (`default-question-<N>`) to its
    /// deterministic replacement via the N → slug table above (NOT via the
    /// prompt — prompt edits must not affect identity). Returns nil for
    /// anything that isn't a legacy seeded ID.
    public static func migratedIdentifier(forLegacyID id: String) -> String? {
        let prefix = "default-question-"
        guard id.hasPrefix(prefix),
              let index = Int(id.dropFirst(prefix.count)),
              all.indices.contains(index) else { return nil }
        return all[index].identifier
    }
}
