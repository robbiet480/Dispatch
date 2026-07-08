import Foundation

/// One allocator owns the 64-pending-request arithmetic (plan 12): global
/// prompts claim slots first (existing behavior), then groups in creation
/// order, then nags with the existing per-prompt clamp folded in. Pure and
/// deterministic; callers log what got clamped by comparing requested vs
/// allocated.
public enum NotificationBudget {
    public struct NagRequest: Equatable, Sendable {
        public var delayMinutes: Int
        public var intervalMinutes: Int
        public var maxCount: Int
        public init(delayMinutes: Int, intervalMinutes: Int, maxCount: Int) {
            self.delayMinutes = delayMinutes
            self.intervalMinutes = intervalMinutes
            self.maxCount = maxCount
        }
    }

    public struct GroupAllocation: Equatable, Sendable {
        public var id: String
        public var count: Int
        public init(id: String, count: Int) {
            self.id = id
            self.count = count
        }
    }

    public struct Allocation: Equatable, Sendable {
        /// Slots granted to the global schedule's prompts.
        public var global: Int
        /// Per-group slots, same order as the request.
        public var groups: [GroupAllocation]
        /// Nag chain length per prompt (0 when nags are off or no room).
        public var nagsPerPrompt: Int

        public var totalPrompts: Int { global + groups.reduce(0) { $0 + $1.count } }
        public var total: Int { totalPrompts * (1 + nagsPerPrompt) }

        public func count(forGroup id: String) -> Int {
            groups.first { $0.id == id }?.count ?? 0
        }
    }

    /// Allocates `cap` pending-request slots. Guarantees: every allocation
    /// ≥ 0, `total ≤ cap`, global before groups, groups in given order,
    /// nags last (`min(maxCount, remaining / totalPrompts)` — the NagPlanner
    /// clamp). Negative/garbage inputs are treated as 0.
    public static func allocate(
        globalCount: Int,
        groupCounts: [(id: String, count: Int)],
        nagRequest: NagRequest?,
        cap: Int = 64
    ) -> Allocation {
        var remaining = max(0, cap)
        let global = min(max(0, globalCount), remaining)
        remaining -= global

        var groups: [GroupAllocation] = []
        for (id, count) in groupCounts {
            let granted = min(max(0, count), remaining)
            remaining -= granted
            groups.append(GroupAllocation(id: id, count: granted))
        }

        var allocation = Allocation(global: global, groups: groups, nagsPerPrompt: 0)
        if let nagRequest, allocation.totalPrompts > 0 {
            allocation.nagsPerPrompt = max(
                0, min(nagRequest.maxCount, remaining / allocation.totalPrompts))
        }
        return allocation
    }
}
