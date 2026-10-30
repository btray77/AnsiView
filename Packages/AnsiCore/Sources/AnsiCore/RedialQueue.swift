import Foundation

/// Why one dial attempt did not reach a BBS.
public enum DialOutcome: Equatable {
    case refused
    /// The BBS answered with its busy text (or all nodes in use).
    case busy
    case notFound
    case timedOut
    case failed(String)

    public init(_ error: BBSConnectionError) {
        switch error {
        case .refused: self = .refused
        case .hostNotFound: self = .notFound
        case .timedOut: self = .timedOut
        default: self = .failed(error.message)
        }
    }

    public var label: String {
        switch self {
        case .refused: return "Refused"
        case .busy: return "Busy"
        case .notFound: return "Not found"
        case .timedOut: return "No answer"
        case .failed: return "Failed"
        }
    }
}

/// The dialer's state machine (ruling 7): dial each entry in order; after a failure wait `delay`
/// seconds and dial the next, wrapping; give up after `passes` trips through the queue. Pure: the
/// caller connects, runs the timer and reports what happened.
public struct RedialQueue {
    public static let passRange = 1...99
    public static let delayRange: ClosedRange<Double> = 0...600

    public enum State: Equatable {
        case idle
        case dialing(UUID)
        case waiting(next: UUID)
        case connected(UUID)
        case exhausted
        case stopped
    }

    /// What the caller should do next.
    public enum Step: Equatable {
        case dial(UUID)
        case wait(TimeInterval, next: UUID)
        case exhausted
        case none
    }

    public let ids: [UUID]
    public let passes: Int
    public let delay: TimeInterval
    public private(set) var state = State.idle
    /// One based trip through the queue.
    public private(set) var pass = 1
    /// Index in `ids` of the entry being (or about to be) dialed.
    public private(set) var position = 0
    public private(set) var lastOutcome: DialOutcome?

    public init(ids: [UUID], passes: Int, delay: TimeInterval) {
        self.ids = ids
        self.passes = min(Self.passRange.upperBound, max(Self.passRange.lowerBound, passes))
        self.delay = min(Self.delayRange.upperBound, max(Self.delayRange.lowerBound, delay))
    }

    public var current: UUID? { ids.indices.contains(position) ? ids[position] : nil }

    public mutating func start() -> Step {
        guard state == .idle else { return .none }
        guard let first = ids.first else { state = .exhausted; return .exhausted }
        pass = 1
        position = 0
        state = .dialing(first)
        return .dial(first)
    }

    /// The BBS answered. The queue ends unless `busyAfterConnect` follows.
    public mutating func connected() {
        guard case .dialing(let id) = state else { return }
        state = .connected(id)
    }

    /// This attempt failed: wait, then the next entry (or give up after the last pass).
    public mutating func failed(_ outcome: DialOutcome) -> Step {
        guard case .dialing = state else { return .none }
        lastOutcome = outcome
        return advance(waiting: true)
    }

    /// The BBS answered but then showed its busy text: as a busy failure.
    public mutating func busyAfterConnect() -> Step {
        guard case .connected = state else { return .none }
        lastOutcome = .busy
        return advance(waiting: true)
    }

    /// The wait is over (or Dial Now was pressed).
    public mutating func delayElapsed() -> Step {
        guard case .waiting(let next) = state else { return .none }
        state = .dialing(next)
        return .dial(next)
    }

    /// Gives up on the current entry and dials the next one at once.
    public mutating func skip() -> Step {
        switch state {
        case .dialing, .waiting:
            let step = advance(waiting: false)
            return step
        default:
            return .none
        }
    }

    public mutating func stop() {
        switch state {
        case .connected, .exhausted: break
        default: state = .stopped
        }
    }

    private mutating func advance(waiting: Bool) -> Step {
        var nextPosition = position + 1
        var nextPass = pass
        if nextPosition >= ids.count {
            nextPosition = 0
            nextPass += 1
        }
        guard nextPass <= passes else {
            state = .exhausted
            return .exhausted
        }
        position = nextPosition
        pass = nextPass
        let next = ids[position]
        if waiting {
            state = .waiting(next: next)
            return .wait(delay, next: next)
        }
        state = .dialing(next)
        return .dial(next)
    }
}
