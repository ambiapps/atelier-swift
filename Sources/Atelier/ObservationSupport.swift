import Foundation
import os

#if canImport(Observation)
    import Observation
#endif

/// Bridges snapshot changes into the Observation framework where the OS
/// provides it (iOS 17 / macOS 14 / watchOS 10 / tvOS 17 / visionOS 1),
/// so a flag read inside an observation-tracked scope — a SwiftUI `body`,
/// `withObservationTracking` — re-fires when resolved values change. On
/// older OSes both hooks are no-ops; callers react via the async streams
/// instead.
struct ObservationSupport: Sendable {
    /// Called on every synchronous read.
    let trackAccess: @Sendable () -> Void
    /// Called after every snapshot change.
    let invalidate: @Sendable () -> Void

    static func make() -> ObservationSupport {
        #if canImport(Observation)
            if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) {
                let tracker = SnapshotTracker()
                return ObservationSupport(
                    trackAccess: { tracker.access() },
                    invalidate: { tracker.invalidate() })
            }
        #endif
        return ObservationSupport(trackAccess: {}, invalidate: {})
    }
}

#if canImport(Observation)
    /// One synthetic observable property stands in for the whole snapshot:
    /// any change invalidates every tracked read. Flags change rarely, so
    /// coarse invalidation costs nothing in practice and keeps reads O(1)
    /// with no per-key bookkeeping.
    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
    private final class SnapshotTracker: Observable, @unchecked Sendable {
        private let registrar = ObservationRegistrar()
        private let state = OSAllocatedUnfairLock(initialState: 0)

        private var generation: Int {
            state.withLock { $0 }
        }

        func access() {
            registrar.access(self, keyPath: \.generation)
        }

        func invalidate() {
            registrar.withMutation(of: self, keyPath: \.generation) {
                state.withLock { $0 &+= 1 }
            }
        }
    }
#endif
