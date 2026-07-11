import CryptoKit
import Foundation

/// Content-identity for catalog prompts (plan 42, issue #47): the ONE
/// definition of "the same question", shared by the app's pre-submit check,
/// the seed importer, and `dispatch-mod`'s approve/list paths so all agree.
///
/// v1 identity is an EXACT match over a deterministic normalization — no
/// locale-sensitive APIs, no fuzzy matching, no ML — so the fingerprint is
/// stable across devices, OS versions, and time. Near-duplicate detection
/// (edit distance, stemming) is a documented follow-up, not built here.
///
/// The client-side use is UX friction only (trivially bypassable); the real
/// enforcement is `dispatch-mod`, the sole writer of `CatalogQuestion`.
public enum CatalogDedupe {
    /// Normalize a prompt for identity comparison. In order: Unicode NFC,
    /// curly→straight quote/apostrophe folding, locale-independent
    /// lowercasing, whitespace/newline runs collapsed to single spaces
    /// (which also trims), and a TRAILING run of terminal punctuation
    /// stripped ("Did you exercise today?!" ≡ "did you exercise today").
    /// Internal punctuation is kept; diacritics are NOT folded (café ≠ cafe)
    /// — conservative on purpose.
    public static func normalizedPrompt(_ prompt: String) -> String {
        var text = prompt.precomposedStringWithCanonicalMapping
        for (curly, straight) in quoteFolds {
            text = text.replacingOccurrences(of: curly, with: straight)
        }
        text = text.lowercased()
        let words = text.split(whereSeparator: \.isWhitespace)
        text = words.joined(separator: " ")
        while let last = text.last, trailingPunctuation.contains(last) {
            text.removeLast()
        }
        // Stripping punctuation can expose trailing spaces ("Really ?").
        while text.last == " " { text.removeLast() }
        return text
    }

    /// Lowercase-hex SHA-256 of the UTF-8 normalized prompt. Stored on
    /// `CatalogQuestion.promptFingerprint` (written only by `dispatch-mod`)
    /// and used for the app's targeted duplicate query. A pinned test vector
    /// guards the normalizer: changing normalization invalidates every
    /// stored fingerprint.
    public static func promptFingerprint(_ prompt: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedPrompt(prompt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether two prompts are the same question under v1 identity.
    public static func isDuplicate(_ a: String, _ b: String) -> Bool {
        normalizedPrompt(a) == normalizedPrompt(b)
    }

    /// First catalog entry whose prompt duplicates `prompt`, if any.
    /// Identity is prompt-only (type/choices ignored) — same precedent as
    /// the seed importer's skip; a same-prompt-different-type submission is
    /// still a moderation collision for a human to resolve.
    public static func firstMatch(prompt: String, in entries: [CatalogQuestion]) -> CatalogQuestion? {
        let target = normalizedPrompt(prompt)
        guard !target.isEmpty else { return nil }
        return entries.first { normalizedPrompt($0.prompt) == target }
    }

    private static let quoteFolds: [(String, String)] = [
        ("\u{2019}", "'"), ("\u{2018}", "'"),   // ’ ‘
        ("\u{201C}", "\""), ("\u{201D}", "\""), // “ ”
    ]

    private static let trailingPunctuation: Set<Character> = [".", "?", "!", "…", "‽"]
}
