import Foundation

public struct JobActivityGuard: Sendable {
    public private(set) var activeJobID: UUID?

    public init() {}

    public mutating func begin(_ jobID: UUID) -> Bool {
        guard activeJobID == nil else { return false }
        activeJobID = jobID
        return true
    }

    public mutating func finish(_ jobID: UUID) {
        guard activeJobID == jobID else { return }
        activeJobID = nil
    }

    public func canMutate(_ jobID: UUID) -> Bool { activeJobID != jobID }
}
