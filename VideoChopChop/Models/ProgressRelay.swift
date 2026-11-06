//
//  ProgressRelay.swift
//  VideoChopChop
//

import Foundation

/// Carries progress from a background task to the main actor without flooding it.
///
/// `report` can be called from any thread as often as you like (hundreds of times a second while decoding).
/// Only the newest value is kept, and it is applied on the main actor at most once per `interval`,
/// so the UI never has a backlog of updates to chew through.
@MainActor
final class ProgressRelay {
    private let continuation: AsyncStream<AnalysisProgress>.Continuation
    private var consumer: Task<Void, Never>?

    nonisolated let report: @Sendable (AnalysisProgress) -> Void

    init(interval: Duration = .milliseconds(50), apply: @escaping @MainActor (AnalysisProgress) -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalysisProgress.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        report = { continuation.yield($0) }
        consumer = Task { @MainActor in
            for await update in stream {
                apply(update)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stops the relay after the last queued value has been applied.
    func finish() async {
        continuation.finish()
        await consumer?.value
    }
}
