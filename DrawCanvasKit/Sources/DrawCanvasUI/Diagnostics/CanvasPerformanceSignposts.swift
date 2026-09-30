import Foundation
import os

@MainActor
final class CanvasPerformanceSignposts {
    enum IntervalEndStatus: Equatable {
        case displayed
        case cancelled
        case capacityEvicted
    }

    struct Statistics: Equatable {
        fileprivate(set) var activeIntervalCount = 0
        fileprivate(set) var completedIntervalCount = 0
        fileprivate(set) var cancelledIntervalCount = 0
        fileprivate(set) var capacityEvictedIntervalCount = 0
    }

    static let shared = CanvasPerformanceSignposts()

    private struct Interval {
        let id: OSSignpostID
        let startTime: TimeInterval
    }

    private static let maximumActiveIntervalCount = 512
    private static let maximumRecentDurationCount = 1_024

    private let log: OSLog
    private let clock: () -> TimeInterval
    private let onIntervalEnd: (RecognitionGeneration, IntervalEndStatus) -> Void
    private var intervals: [RecognitionGeneration: Interval] = [:]
    private var intervalOrder: [RecognitionGeneration] = []
    private(set) var statistics = Statistics()
    private(set) var recentCompletedDurationsMilliseconds: [Double] = []
    private(set) var recentDisplayTimestamps: [TimeInterval] = []

    init(
        log: OSLog = OSLog(subsystem: "DrawCanvasUI", category: "Performance"),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onIntervalEnd: @escaping (
            RecognitionGeneration,
            IntervalEndStatus
        ) -> Void = { _, _ in }
    ) {
        self.log = log
        self.clock = clock
        self.onIntervalEnd = onIntervalEnd
    }

    func begin(generation: RecognitionGeneration) {
        guard intervals[generation] == nil else { return }
        if intervals.count >= Self.maximumActiveIntervalCount,
           let oldestGeneration = intervalOrder.first,
           let oldestInterval = intervals.removeValue(forKey: oldestGeneration) {
            intervalOrder.removeFirst()
            emitEnd(
                for: oldestGeneration,
                interval: oldestInterval,
                status: .capacityEvicted
            )
            statistics.capacityEvictedIntervalCount += 1
        }
        let id = OSSignpostID(log: log)
        intervals[generation] = Interval(id: id, startTime: clock())
        intervalOrder.append(generation)
        statistics.activeIntervalCount = intervals.count
        os_signpost(
            .begin,
            log: log,
            name: "PencilBatchToDisplay",
            signpostID: id
        )
    }

    func completeDisplay(
        through generation: RecognitionGeneration,
        at presentedTime: TimeInterval
    ) {
        guard presentedTime.isFinite, presentedTime > 0 else { return }
        guard let displayedIndex = intervalOrder.firstIndex(of: generation) else { return }
        let completedGenerations = Array(intervalOrder[...displayedIndex])
        guard completedGenerations.allSatisfy({ completedGeneration in
            guard let interval = intervals[completedGeneration] else { return true }
            return presentedTime > interval.startTime
        }) else { return }
        var completedCount = 0
        for completedGeneration in completedGenerations {
            guard let interval = intervals.removeValue(forKey: completedGeneration) else {
                continue
            }
            emitEnd(
                for: completedGeneration,
                interval: interval,
                status: .displayed
            )
            let duration = (presentedTime - interval.startTime) * 1_000
            if duration.isFinite {
                recentCompletedDurationsMilliseconds.append(duration)
            }
            completedCount += 1
        }
        intervalOrder.removeFirst(displayedIndex + 1)
        recentDisplayTimestamps.append(presentedTime)
        trimRecentDurations()
        statistics.activeIntervalCount = intervals.count
        statistics.completedIntervalCount += completedCount
    }

    func cancelAll() {
        guard !intervals.isEmpty else { return }
        for generation in intervalOrder {
            guard let interval = intervals[generation] else { continue }
            emitEnd(for: generation, interval: interval, status: .cancelled)
        }
        statistics.cancelledIntervalCount += intervals.count
        intervals.removeAll(keepingCapacity: false)
        intervalOrder.removeAll(keepingCapacity: false)
        statistics.activeIntervalCount = 0
    }

    func resetRecordedMetrics() {
        cancelAll()
        statistics = Statistics()
        recentCompletedDurationsMilliseconds.removeAll(keepingCapacity: false)
        recentDisplayTimestamps.removeAll(keepingCapacity: false)
    }
}

private extension CanvasPerformanceSignposts {
    private func emitEnd(
        for generation: RecognitionGeneration,
        interval: Interval,
        status: IntervalEndStatus
    ) {
        switch status {
        case .displayed:
            os_signpost(
                .end,
                log: log,
                name: "PencilBatchToDisplay",
                signpostID: interval.id,
                "status=displayed"
            )
        case .cancelled:
            os_signpost(
                .end,
                log: log,
                name: "PencilBatchToDisplay",
                signpostID: interval.id,
                "status=cancelled"
            )
        case .capacityEvicted:
            os_signpost(
                .end,
                log: log,
                name: "PencilBatchToDisplay",
                signpostID: interval.id,
                "status=capacity-evicted"
            )
        }
        onIntervalEnd(generation, status)
    }

    private func trimRecentDurations() {
        guard recentCompletedDurationsMilliseconds.count > Self.maximumRecentDurationCount else {
            return
        }
        recentCompletedDurationsMilliseconds.removeFirst(
            recentCompletedDurationsMilliseconds.count - Self.maximumRecentDurationCount
        )
        if recentDisplayTimestamps.count > Self.maximumRecentDurationCount {
            recentDisplayTimestamps.removeFirst(
                recentDisplayTimestamps.count - Self.maximumRecentDurationCount
            )
        }
    }
}
