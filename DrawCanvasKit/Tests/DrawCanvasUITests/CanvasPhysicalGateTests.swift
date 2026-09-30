import Foundation
import Metal
import UIKit
import XCTest
import DrawCanvasCore
@testable import DrawCanvasUI

@MainActor
final class CanvasPhysicalGateTests: XCTestCase {
    func testPerformanceFixtureContract() throws {
        let first = try PerformanceFixture.make()
        let second = try PerformanceFixture.make()
        let firstAudit = try PerformanceFixture.audit(first)
        let secondAudit = try PerformanceFixture.audit(second)
        let firstEncoding = try CanvasDocumentCodec.encodeString(first)
        let secondEncoding = try CanvasDocumentCodec.encodeString(second)

        XCTAssertEqual(firstAudit, PerformanceFixture.expectedContract)
        XCTAssertEqual(secondAudit, PerformanceFixture.expectedContract)
        XCTAssertEqual(firstEncoding, secondEncoding)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.elements.map(\.id), second.elements.map(\.id))
    }

    private enum GateLimit {
        static let presentationP95Milliseconds = 16.7
        static let presentationMaximumMilliseconds = 33.4
        static let longStrokeP95Milliseconds = 33.4
        static let longStrokeMaximumMilliseconds = 50.1
        static let admissionP95Milliseconds = 1.0
        static let admissionMaximumMilliseconds = 5.0
        static let targetErrorP95Milliseconds = 1.0
        static let targetErrorMaximumMilliseconds = 2.0
    }

    func testPhysicalIPadFiveSecondPhaseLockedRendererSeam() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPad A16-or-later required for presented-frame timing.")
        #else
        try requirePhysicalA16OrLaterIPad()
        let result = try PhysicalCanvasPresentationHarness(samplesPerBatch: 8).run(
            minimumDuration: 5
        )
        add(result.attachment(named: "DrawCanvasKit phase-locked sustained renderer seam"))

        XCTAssertGreaterThanOrEqual(result.elapsedSeconds, 5)
        XCTAssertGreaterThan(result.presentationIntervalsMilliseconds.count, 0)
        XCTAssertEqual(result.acceptedSampleCount, result.retainedSampleCount)
        XCTAssertTrue(result.retainedSamplesMatchAcceptedOrder)
        XCTAssertEqual(result.persistenceDocumentElementCount, 100)
        XCTAssertEqual(result.persistenceDocumentFreehandSampleCount, 500)
        XCTAssertTrue(result.warmUpCommittedFramePresented)
        XCTAssertTrue(result.persistenceDocumentHasVariedPressure)
        XCTAssertGreaterThan(result.persistencePayloadByteCount, 0)
        XCTAssertTrue(result.persistencePayloadMatchesAfterNativePresentation)
        XCTAssertEqual(result.recordedSavePayloadCount, 1)
        XCTAssertTrue(result.recordedSavePayloadMatchesBeforePresentation)
        XCTAssertTrue(result.nativePresentationAdvancedAfterPayloadEncoding)
        XCTAssertEqual(result.completedInputBatchCount, result.inputBatchCount)
        XCTAssertEqual(result.displayLatenciesMilliseconds.count, result.inputBatchCount)
        XCTAssertEqual(result.activeInputBatchCount, 0)
        XCTAssertEqual(result.cancelledInputBatchCount, 0)
        XCTAssertEqual(result.evictedInputBatchCount, 0)
        XCTAssertEqual(result.presentedFrameCount, result.nativePresentationCallbackCount)
        XCTAssertGreaterThanOrEqual(result.presentedFrameCount, 2)
        XCTAssertLessThanOrEqual(result.presentedFrameCount, result.inputBatchCount)
        XCTAssertGreaterThanOrEqual(
            result.presentedFrameCount,
            Int(floor(result.elapsedSeconds / 0.0334))
        )
        XCTAssertGreaterThanOrEqual(
            result.presentationSpanSeconds,
            result.elapsedSeconds - 0.1
        )
        XCTAssertTrue(result.presentationTimestamps.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertTrue(result.presentationIntervalsMilliseconds.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertEqual(result.measuredDisplayLinkStartCount, 0)
        XCTAssertEqual(result.measuredDisplayLinkPauseCount, 0)
        XCTAssertLessThanOrEqual(
            result.presentationP95Milliseconds,
            GateLimit.presentationP95Milliseconds
        )
        XCTAssertLessThanOrEqual(
            result.presentationMaximumMilliseconds,
            GateLimit.presentationMaximumMilliseconds
        )
        #endif
    }

    func testPhysicalIPadPhaseLockedLongStrokeBatchToDisplayLatency() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPad A16-or-later required for phase-locked batch-to-presentation timing.")
        #else
        try requirePhysicalA16OrLaterIPad()
        let result = try PhysicalCanvasPresentationHarness(samplesPerBatch: 100).run(
            minimumDuration: 5
        )
        add(result.attachment(named: "DrawCanvasKit phase-locked sustained long-stroke latency"))

        XCTAssertGreaterThanOrEqual(result.elapsedSeconds, 5)
        XCTAssertGreaterThan(result.displayLatenciesMilliseconds.count, 0)
        XCTAssertEqual(result.acceptedSampleCount, result.retainedSampleCount)
        XCTAssertTrue(result.retainedSamplesMatchAcceptedOrder)
        XCTAssertEqual(result.persistenceDocumentElementCount, 100)
        XCTAssertEqual(result.persistenceDocumentFreehandSampleCount, 500)
        XCTAssertTrue(result.warmUpCommittedFramePresented)
        XCTAssertTrue(result.persistenceDocumentHasVariedPressure)
        XCTAssertGreaterThan(result.persistencePayloadByteCount, 0)
        XCTAssertTrue(result.persistencePayloadMatchesAfterNativePresentation)
        XCTAssertEqual(result.recordedSavePayloadCount, 1)
        XCTAssertTrue(result.recordedSavePayloadMatchesBeforePresentation)
        XCTAssertTrue(result.nativePresentationAdvancedAfterPayloadEncoding)
        XCTAssertEqual(result.completedInputBatchCount, result.inputBatchCount)
        XCTAssertEqual(result.displayLatenciesMilliseconds.count, result.inputBatchCount)
        XCTAssertEqual(result.activeInputBatchCount, 0)
        XCTAssertEqual(result.cancelledInputBatchCount, 0)
        XCTAssertEqual(result.evictedInputBatchCount, 0)
        XCTAssertEqual(result.presentedFrameCount, result.nativePresentationCallbackCount)
        XCTAssertGreaterThanOrEqual(result.presentedFrameCount, 2)
        XCTAssertLessThanOrEqual(result.presentedFrameCount, result.inputBatchCount)
        XCTAssertGreaterThanOrEqual(
            result.presentedFrameCount,
            Int(floor(result.elapsedSeconds / 0.0334))
        )
        XCTAssertGreaterThanOrEqual(
            result.presentationSpanSeconds,
            result.elapsedSeconds - 0.1
        )
        XCTAssertTrue(result.presentationTimestamps.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertEqual(
            result.presentationIntervalsMilliseconds.count,
            result.presentedFrameCount - 1
        )
        XCTAssertTrue(result.presentationIntervalsMilliseconds.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertTrue(result.displayLatenciesMilliseconds.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertEqual(result.measuredDisplayLinkStartCount, 0)
        XCTAssertEqual(result.measuredDisplayLinkPauseCount, 0)
        XCTAssertEqual(result.admittedFrameTimingCount, result.inputBatchCount)
        XCTAssertEqual(
            result.inputSubmitToDisplayLinkCallbackMilliseconds.count,
            result.admittedFrameTimingCount
        )
        XCTAssertEqual(
            result.inputSubmitToAdmissionMilliseconds.count,
            result.admittedFrameTimingCount
        )
        XCTAssertEqual(
            result.displayLinkCallbackToTargetPresentationMilliseconds.count,
            result.admittedFrameTimingCount
        )
        XCTAssertEqual(
            result.displayLinkCallbackToNativePresentationMilliseconds.count,
            result.admittedFrameTimingCount
        )
        XCTAssertEqual(
            result.nativePresentationMinusTargetMilliseconds.count,
            result.admittedFrameTimingCount
        )
        XCTAssertTrue(result.inputSubmitToDisplayLinkCallbackMilliseconds.allSatisfy(\.isFinite))
        XCTAssertTrue(result.inputSubmitToAdmissionMilliseconds.allSatisfy {
            $0.isFinite && $0 >= 0
        })
        XCTAssertTrue(
            result.displayLinkCallbackToTargetPresentationMilliseconds.allSatisfy(\.isFinite)
        )
        XCTAssertTrue(
            result.displayLinkCallbackToNativePresentationMilliseconds.allSatisfy(\.isFinite)
        )
        XCTAssertLessThanOrEqual(
            percentile95(result.inputSubmitToAdmissionMilliseconds),
            GateLimit.admissionP95Milliseconds
        )
        XCTAssertLessThanOrEqual(
            result.inputSubmitToAdmissionMilliseconds.max() ?? .infinity,
            GateLimit.admissionMaximumMilliseconds
        )
        let absoluteTargetErrors = result.nativePresentationMinusTargetMilliseconds.map(abs)
        XCTAssertTrue(absoluteTargetErrors.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(
            percentile95(absoluteTargetErrors),
            GateLimit.targetErrorP95Milliseconds
        )
        XCTAssertLessThanOrEqual(
            absoluteTargetErrors.max() ?? .infinity,
            GateLimit.targetErrorMaximumMilliseconds
        )
        XCTAssertLessThanOrEqual(
            result.displayP95Milliseconds,
            GateLimit.longStrokeP95Milliseconds
        )
        XCTAssertLessThanOrEqual(
            result.displayMaximumMilliseconds,
            GateLimit.longStrokeMaximumMilliseconds
        )
        XCTAssertLessThanOrEqual(
            result.presentationP95Milliseconds,
            GateLimit.presentationP95Milliseconds
        )
        XCTAssertLessThanOrEqual(
            result.presentationMaximumMilliseconds,
            GateLimit.presentationMaximumMilliseconds
        )
        #endif
    }

    func testPhysicalIPadLongFreehandCommitRemainsInteractive() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPad A16-or-later required for Pencil-up timing.")
        #else
        try requirePhysicalA16OrLaterIPad()
        let result = try PhysicalCanvasPresentationHarness(samplesPerBatch: 100).run(
            minimumDuration: 5,
            completion: .commit,
            additionalCommittedStrokeCount: 6
        )
        add(result.attachment(named: "DrawCanvasKit long freehand Pencil-up responsiveness"))

        XCTAssertGreaterThanOrEqual(result.acceptedSampleCount, 30_000)
        XCTAssertEqual(result.acceptedSampleCount, result.committedStrokeSampleCount)
        XCTAssertTrue(result.retainedSamplesMatchAcceptedOrder)
        XCTAssertLessThanOrEqual(result.pencilUpProcessingMilliseconds, 16.7)
        XCTAssertTrue(result.acceptedImmediateFollowUpInput)
        XCTAssertGreaterThan(result.commitPresentationMilliseconds, 0)
        XCTAssertLessThanOrEqual(
            result.commitPresentationMilliseconds,
            GateLimit.longStrokeMaximumMilliseconds
        )
        XCTAssertLessThanOrEqual(
            result.presentationP95Milliseconds,
            GateLimit.presentationP95Milliseconds
        )
        XCTAssertLessThanOrEqual(
            result.presentationMaximumMilliseconds,
            GateLimit.presentationMaximumMilliseconds
        )
        XCTAssertEqual(result.repeatedStrokeBatchCounts, Array(repeating: 50, count: 6))
        XCTAssertEqual(result.repeatedPencilUpProcessingMilliseconds.count, 6)
        XCTAssertLessThanOrEqual(
            result.repeatedPencilUpProcessingMilliseconds.max() ?? .infinity,
            16.7
        )
        XCTAssertEqual(result.repeatedFollowUpProcessingMilliseconds.count, 6)
        XCTAssertLessThanOrEqual(
            result.repeatedFollowUpProcessingMilliseconds.max() ?? .infinity,
            16.7
        )
        XCTAssertEqual(result.repeatedDriverSubmissionMilliseconds.count, 6)
        XCTAssertLessThanOrEqual(
            result.repeatedDriverSubmissionMilliseconds.max() ?? .infinity,
            25
        )
        XCTAssertEqual(result.repeatedCommitPresentationMilliseconds.count, 6)
        XCTAssertTrue(
            result.repeatedCommitPresentationMilliseconds.allSatisfy {
                $0.isFinite && $0 > 0
            }
        )
        XCTAssertLessThanOrEqual(
            result.repeatedCommitPresentationMilliseconds.max() ?? .infinity,
            GateLimit.longStrokeMaximumMilliseconds,
            "Pencil-up and immediate follow-up must reach a native presentation within the input latency budget"
        )
        #endif
    }
}

private func percentile95(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .infinity }
    let sorted = values.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}
