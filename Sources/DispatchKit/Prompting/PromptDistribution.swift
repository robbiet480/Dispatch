import Foundation

enum PromptDistribution: String, Codable, CaseIterable, Sendable {
    case random
    case semiRandom
    case regular

    func description(alertsPerDay: Int) -> String {
        let interval = 24 / alertsPerDay
        switch self {
        case .random:
            return "\(alertsPerDay) randomly timed alerts every 24 hours"
        case .semiRandom:
            return "1 random alert every \(interval) hours"
        case .regular:
            return "1 alert every \(interval) hours"
        }
    }
}
