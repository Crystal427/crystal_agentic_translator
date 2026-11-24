import Foundation

public struct SerialJobQueue: Sendable {
    public private(set) var pendingIDs: [UUID] = []

    public init() {}

    @discardableResult
    public mutating func enqueue(_ id: UUID) -> Bool {
        guard !pendingIDs.contains(id) else { return false }
        pendingIDs.append(id)
        return true
    }

    public mutating func dequeue() -> UUID? {
        guard !pendingIDs.isEmpty else { return nil }
        return pendingIDs.removeFirst()
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let index = pendingIDs.firstIndex(of: id) else { return false }
        pendingIDs.remove(at: index)
        return true
    }

    public func contains(_ id: UUID) -> Bool { pendingIDs.contains(id) }
    public var isEmpty: Bool { pendingIDs.isEmpty }
}
