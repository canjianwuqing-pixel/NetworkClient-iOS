/// A value-only generation gate. The owning actor advances it before closing
/// a service so results from an older URLSession cannot publish new state.
struct MihomoBridgeGeneration: Sendable, Equatable {
    private(set) var value: UInt64 = 0

    @discardableResult
    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    func contains(_ candidate: UInt64) -> Bool { value == candidate }
}

enum MihomoBridgeLifecycle: String, CaseIterable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case failed
}
