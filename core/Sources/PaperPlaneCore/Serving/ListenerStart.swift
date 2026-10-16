import Foundation
import Network
import os

extension NWListener {
    /// Starts listening on `queue` and returns once ready. A listener that fails, or waits (its
    /// address isn't available, which waiting won't fix), is cancelled and the error thrown.
    func startAndWaitUntilReady(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            stateUpdateHandler = { [weak self] state in
                let result: Result<Void, any Error>
                switch state {
                case .ready:
                    result = .success(())
                case .failed(let error), .waiting(let error):
                    self?.cancel()
                    result = .failure(error)
                case .cancelled:
                    result = .failure(CancellationError())
                default:
                    return // .setup: not settled yet
                }
                let first = resumed.withLock { (done: inout Bool) -> Bool in
                    defer { done = true }
                    return !done
                }
                if first {
                    continuation.resume(with: result)
                }
            }
            start(queue: queue)
        }
    }
}
