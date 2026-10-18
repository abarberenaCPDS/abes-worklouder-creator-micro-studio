import Foundation

/// Runs an async job for a burst of requests without piling them up: at
/// most one run is in flight, runs start at least `interval` apart, and a
/// request made while one is running (or waiting out the interval) always
/// gets a trailing run — so the last thing asked for is the last thing done.
///
/// The bridge uses it for lighting previews: a slider drag asks for a paint
/// on every tick, and each paint is ~15–20 HID reports.
@MainActor
final class CoalescingRunner {
    private let interval: TimeInterval
    private let work: () async -> Void
    private var task: Task<Void, Never>?
    private var pending = false

    init(interval: TimeInterval, work: @escaping () async -> Void) {
        self.interval = interval
        self.work = work
    }

    /// True while a run is in flight or the interval after one is pending.
    var isBusy: Bool { task != nil }

    func request() {
        pending = true
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, self.pending, !Task.isCancelled {
                self.pending = false
                let started = Date()
                await self.work()
                let wait = self.interval - Date().timeIntervalSince(started)
                if wait > 0, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
        }
    }

    /// Drops any pending run; a run already in flight finishes on its own.
    func cancel() {
        task?.cancel()
        task = nil
        pending = false
    }
}
