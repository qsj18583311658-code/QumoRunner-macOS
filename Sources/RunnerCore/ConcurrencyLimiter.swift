import Foundation

public enum ConcurrencyConfigurationError: Error, Equatable, Sendable {
    case outsideAllowedRange
}

public actor GlobalConcurrencyLimiter {
    private var limit: Int
    private var active = 0
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    public init(limit: Int = 4) throws {
        guard (1...8).contains(limit) else {
            throw ConcurrencyConfigurationError.outsideAllowedRange
        }
        self.limit = limit
    }

    public func configuredLimit() -> Int { limit }
    public func activeCount() -> Int { active }

    public func setLimit(_ newValue: Int) throws {
        guard (1...8).contains(newValue) else {
            throw ConcurrencyConfigurationError.outsideAllowedRange
        }
        limit = newValue
        resumeEligibleWaiters()
    }

    func acquire() async throws {
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiterOrder.append(id)
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        precondition(active > 0)
        active -= 1
        resumeEligibleWaiters()
    }

    private func resumeEligibleWaiters() {
        while active < limit, !waiterOrder.isEmpty {
            let id = waiterOrder.removeFirst()
            guard let continuation = waiters.removeValue(forKey: id) else { continue }
            active += 1
            continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}
