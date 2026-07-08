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
    public init() {}
}
