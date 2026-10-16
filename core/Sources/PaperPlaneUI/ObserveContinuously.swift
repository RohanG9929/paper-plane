import Observation

/// Runs `apply` now and again after every change to the observable state it reads, until a
/// run reads nothing (for example once the object it works on has gone).
@MainActor
public func observeContinuously(_ apply: @escaping @MainActor @Sendable () -> Void) {
    withObservationTracking(apply) {
        Task { @MainActor in observeContinuously(apply) }
    }
}
