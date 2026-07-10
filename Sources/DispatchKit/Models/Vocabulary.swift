import Foundation
import SwiftData

@Model
public final class TokenEntity {
    public var text: String = ""
    public var usageCount: Int = 0
    public var questionCount: Int = 0
    public init() {}
}

@Model
public final class PersonEntity {
    public var text: String = ""
    public var usageCount: Int = 0
    public var questionCount: Int = 0
    /// Synced person identity (plan 22). Additive + defaulted so the schema
    /// stays CloudKit-safe; the UUID string is the stable cross-device key.
    public var uniqueIdentifier: String = UUID().uuidString
    /// Previous display names and aliases (plan 22). `text` remains the
    /// current display name; resolution matches either.
    public var alternateNames: [String] = []
    public init() {}
}
