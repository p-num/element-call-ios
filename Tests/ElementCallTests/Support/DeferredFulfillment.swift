//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Testing

/// Starts consuming now, waits later: the sequence is already being read before the act, so an
/// emission that lands between the two cannot be missed, and `until` skips the ones the act did not
/// cause -- a screen republishes for its own reasons.
///
/// A trimmed copy of the host's helper, `UnitTests/Sources/TestUtilities/DeferredFulfillment.swift`
/// in element-x-ios, which 65 of its test files read this way. Keeping the shape means a host
/// engineer reads these tests without learning anything new. Only the async-sequence half is here:
/// the Combine half needs an `ObservableObject`, and the call screen's state is `@Observable`.
/// Every value `read` produces, sampled once per scheduling turn.
///
/// `Observations` is the event-driven source and reads better, and it is what this used to use. It
/// samples *between* iterations, though, so a change landing in the gap is never seen, and there is
/// no bound on how wide that gap gets: suites run in parallel, this all needs the main actor, and
/// `PreviewTests` holds it for 35 seconds on CI. That is what failed there -- `.noOutput` on a test
/// whose own duration was 33 seconds, so it had waited and the transition had gone past it.
///
/// Re-reading cannot miss a transition because it never waits for one; it asks what the value is
/// now. Losing the sampling gap is also what lets these tests run below iOS 26, which `Observations`
/// needs and which would have made them skip silently rather than fail.
func values<Value: Sendable>(_ read: @escaping () -> Value) -> AsyncStream<Value> {
    AsyncStream { continuation in
        let task = Task {
            while !Task.isCancelled {
                continuation.yield(read())
                await Task.yield()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

struct DeferredFulfillment<Value: Sendable> {
    fileprivate let stream: AsyncStream<Value>
    fileprivate let task: Task<Void, Never>
    fileprivate let timeout: Duration
    fileprivate let sourceLocation: SourceLocation
    
    /// The matching value, or a recorded issue at the call site if none arrived in time.
    @discardableResult
    func fulfill() async throws -> Value {
        defer { task.cancel() }
        
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { [stream] in
                for await value in stream {
                    return value
                }
                throw DeferredFulfillmentError.noOutput
            }
            // The bound on a broken expectation. A passing test never reaches it.
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw DeferredFulfillmentError.noOutput
            }
            defer { group.cancelAll() }
            
            do {
                guard let value = try await group.next() else {
                    throw DeferredFulfillmentError.noOutput
                }
                return value
            } catch {
                Issue.record(Comment(rawValue: "Nothing matched `until` within \(timeout)"), sourceLocation: sourceLocation)
                throw error
            }
        }
    }
}

enum DeferredFulfillmentError: Error {
    case noOutput
}

/// - Parameters:
///   - asyncSequence: what to watch. Consumption starts here rather than in `fulfill()`.
///   - timeout: how long `fulfill()` waits before recording an issue. Only a bound on a broken
///     expectation -- a passing test returns the moment the value arrives and never pays it. Five
///     minutes, where the host uses ten seconds, because everything waited on here needs the main
///     actor and `PreviewTests` renders every snapshot on that same actor, for as long as that
///     takes on CI. A minute was enough at 35 seconds of it and failed at 59: size it to the suite
///     growing, not to today's run.
///   - condition: which emission is the one being waited for.
func deferFulfillment<Value: Sendable>(_ asyncSequence: any AsyncSequence<Value, Never>,
                                       timeout: Duration = .seconds(300),
                                       sourceLocation: SourceLocation = #_sourceLocation,
                                       until condition: @escaping (Value) -> Bool) -> DeferredFulfillment<Value> {
    let (stream, continuation) = AsyncStream<Value>.makeStream()
    
    let task = Task {
        for await value in asyncSequence where condition(value) {
            continuation.yield(value)
            break
        }
        continuation.finish()
    }
    
    return DeferredFulfillment(stream: stream, task: task, timeout: timeout, sourceLocation: sourceLocation)
}
