import Foundation

/// Holds at most one long-running task (e.g. the radar play clock) and makes the hand-over race-free.
///
/// The bug this prevents: a task that awaits something slow can be cancelled and replaced while it waits.
/// When it resumes it must neither keep working nor clear the slot, because the slot now belongs to its
/// replacement; clearing it would orphan the new task (nothing could cancel it any more).
/// Each `start` hands the body a token; `clear(token:)` only empties the slot if that token is current.
@MainActor
public final class TaskSlot {
    private var task: Task<Void, Never>?
    private var generation = 0

    public init() {}

    /// True while a task occupies the slot.
    public var isOccupied: Bool { task != nil }

    /// Cancels any current task and starts `body` in its place.
    public func start(_ body: @escaping @MainActor (_ token: Int) async -> Void) {
        task?.cancel()
        generation &+= 1
        let token = generation
        task = Task { @MainActor in await body(token) }
    }

    /// Cancels and empties the slot.
    public func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }

    /// Called by a task that is finishing on its own: empties the slot only if it still owns it.
    public func clear(token: Int) {
        guard token == generation else { return }
        task = nil
    }

    /// True when `token` is the current owner (a resumed task should stop otherwise).
    public func owns(_ token: Int) -> Bool { token == generation && task != nil }
}
