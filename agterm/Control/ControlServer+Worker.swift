import Foundation

extension ControlServer {
    /// startWorker runs a connection's work on its own thread. Callers type `work` as `@Sendable` before passing it:
    /// Xcode 26.3 (Swift 6.2.4) infers `@MainActor` for a closure literal handed to `Thread` inside this main-actor
    /// class, and the thread then dies on `dispatch_assert_queue`. Fork-only; Xcode 27 does not infer it.
    nonisolated static func startWorker(_ name: String, _ work: @escaping @Sendable () -> Void) {
        let worker = Thread(block: work)
        worker.name = name
        worker.start()
    }
}
