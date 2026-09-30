import Foundation
import CoreGraphics
import Metal
import UIKit
import SwiftUI
import XCTest
import CadCanvasCore
@testable import CadCanvasUI

struct TimedBatchRunResult {
    let batchCount: Int
    let elapsedSeconds: TimeInterval
}

struct SustainedInputRunState {
    private let startTime: TimeInterval
    private let minimumDuration: TimeInterval
    private(set) var batchCount = 0
    private(set) var elapsedSeconds = 0.0
    private(set) var hasStopped = false

    init(startTime: TimeInterval, minimumDuration: TimeInterval) {
        self.startTime = startTime
        self.minimumDuration = max(0, minimumDuration)
    }

    mutating func takeBatchIndex(at timestamp: TimeInterval) -> Int? {
        guard !hasStopped else { return nil }
        let elapsed = max(0, timestamp - startTime)
        guard elapsed < minimumDuration else {
            elapsedSeconds = elapsed
            hasStopped = true
            return nil
        }
        defer { batchCount += 1 }
        return batchCount
    }

    func isDrained(
        completedIntervalCount: Int,
        activeIntervalCount: Int,
        cancelledIntervalCount: Int,
        capacityEvictedIntervalCount: Int,
        pendingFrameCount: Int,
        trackedSubmittedFrameCount: Int
    ) -> Bool {
        hasStopped
            && completedIntervalCount == batchCount
            && activeIntervalCount == 0
            && cancelledIntervalCount == 0
            && capacityEvictedIntervalCount == 0
            && pendingFrameCount == 0
            && trackedSubmittedFrameCount == 0
    }
}

@MainActor
func runTimedBatches(
    minimumDuration: TimeInterval,
    clock: () -> TimeInterval,
    performBatch: (Int) throws -> Void
) rethrows -> TimedBatchRunResult {
    let start = clock()
    var batchCount = 0
    var elapsedSeconds = 0.0

    repeat {
        try performBatch(batchCount)
        batchCount += 1
        elapsedSeconds = clock() - start
    } while elapsedSeconds < minimumDuration

    return TimedBatchRunResult(
        batchCount: batchCount,
        elapsedSeconds: elapsedSeconds
    )
}

func makeLatencyContext(width: Int, height: Int) -> CGContext? {
    CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

func isPhysicalA16OrLaterIPad(
    isIPad: Bool,
    machineIdentifier: String,
    supportsApple8OrNewer: Bool
) -> Bool {
    let a15IPadMiniIdentifiers: Set<String> = ["iPad14,1", "iPad14,2"]
    return isIPad
        && supportsApple8OrNewer
        && !a15IPadMiniIdentifiers.contains(machineIdentifier)
}

#if !targetEnvironment(simulator)
@MainActor
func requirePhysicalA16OrLaterIPad() throws {
    let device = MTLCreateSystemDefaultDevice()
    guard isPhysicalA16OrLaterIPad(
        isIPad: UIDevice.current.userInterfaceIdiom == .pad,
        machineIdentifier: physicalMachineModel(),
        supportsApple8OrNewer: device?.supportsFamily(.apple8) == true
    ) else {
        throw XCTSkip("The physical renderer gate requires iPad A16-or-later GPU capability.")
    }
}

@MainActor
private final class PhysicalCanvasHostController: UIHostingController<CadCanvasView> {}

@MainActor
private final class PhysicalCanvasDiagnosticRecorder {
    private(set) var values: [CanvasDiagnostic] = []

    func record(_ diagnostic: CanvasDiagnostic) {
        values.append(diagnostic)
    }

    var sanitizedDescription: String {
        guard !values.isEmpty else { return "none" }
        return values.map { diagnostic in
            switch diagnostic {
            case .scenePreparationFailed(let failure):
                return "scenePreparationFailed(\(failure))"
            case .rendererFallback(let failure):
                return "rendererFallback(\(failure))"
            case .unknownPencilPreferredAction(let rawValue):
                return "unknownPencilPreferredAction(\(rawValue))"
            case .pencilPalettePresentationUnavailable:
                return "pencilPalettePresentationUnavailable"
            }
        }.joined(separator: ",")
    }
}

@MainActor
struct PhysicalCanvasPresentationResult {
    let elapsedSeconds: TimeInterval
    let acceptedSampleCount: Int
    let retainedSampleCount: Int
    let retainedSamplesMatchAcceptedOrder: Bool
    let displayLatenciesMilliseconds: [Double]
    let presentationTimestamps: [TimeInterval]
    let presentationIntervalsMilliseconds: [Double]
    let presentationSpanSeconds: TimeInterval
    let presentationP95Milliseconds: Double
    let presentationMaximumMilliseconds: Double
    let displayP95Milliseconds: Double
    let displayMaximumMilliseconds: Double
    let machineModel: String
    let operatingSystem: String
    let inputBatchCount: Int
    let completedInputBatchCount: Int
    let activeInputBatchCount: Int
    let cancelledInputBatchCount: Int
    let evictedInputBatchCount: Int
    let presentedFrameCount: Int
    let nativePresentationCallbackCount: Int
    let coalescedInputBatchCount: Int
    let displayLinkStartCount: Int
    let displayLinkPauseCount: Int
    let displayLinkUpdateCallbackCount: Int
    let measuredDisplayLinkStartCount: Int
    let measuredDisplayLinkPauseCount: Int
    let admittedFrameTimingCount: Int
    let inputSubmitToDisplayLinkCallbackMilliseconds: [Double]
    let inputSubmitToAdmissionMilliseconds: [Double]
    let displayLinkCallbackToTargetPresentationMilliseconds: [Double]
    let displayLinkCallbackToNativePresentationMilliseconds: [Double]
    let nativePresentationMinusTargetMilliseconds: [Double]
    let persistenceDocumentElementCount: Int
    let persistenceDocumentFreehandSampleCount: Int
    let persistenceDocumentHasVariedPressure: Bool
    let persistencePayloadByteCount: Int
    let persistencePayloadMatchesAfterNativePresentation: Bool
    let recordedSavePayloadCount: Int
    let recordedSavePayloadMatchesBeforePresentation: Bool
    let nativePresentationAdvancedAfterPayloadEncoding: Bool
    let warmUpCommittedFramePresented: Bool
    let pencilUpProcessingMilliseconds: Double
    let commitPresentationMilliseconds: Double
    let committedStrokeSampleCount: Int
    let acceptedImmediateFollowUpInput: Bool
    let repeatedStrokeBatchCounts: [Int]
    let repeatedPencilUpProcessingMilliseconds: [Double]
    let repeatedFollowUpProcessingMilliseconds: [Double]
    let repeatedDriverSubmissionMilliseconds: [Double]
    let repeatedCommitPresentationMilliseconds: [Double]

    func attachment(named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(string: """
        observedMachineModel: \(machineModel)
        requiredCapability: physical iPad A16-or-later
        operatingSystem: \(operatingSystem)
        elapsedSeconds: \(String(format: "%.6f", elapsedSeconds))
        presentedFrameIntervals: \(presentationIntervalsMilliseconds.count)
        presentationP95Milliseconds: \(String(format: "%.6f", presentationP95Milliseconds))
        presentationMaximumMilliseconds: \(String(format: "%.6f", presentationMaximumMilliseconds))
        displayedBatchIntervals: \(displayLatenciesMilliseconds.count)
        displayP95Milliseconds: \(String(format: "%.6f", displayP95Milliseconds))
        displayMaximumMilliseconds: \(String(format: "%.6f", displayMaximumMilliseconds))
        acceptedSyntheticSamples: \(acceptedSampleCount)
        retainedSyntheticSamples: \(retainedSampleCount)
        retainedSamplesMatchAcceptedOrder: \(retainedSamplesMatchAcceptedOrder)
        measuredInputBatches: \(inputBatchCount)
        completedInputBatches: \(completedInputBatchCount)
        activeInputBatchesAfterDrain: \(activeInputBatchCount)
        cancelledInputBatches: \(cancelledInputBatchCount)
        evictedInputBatches: \(evictedInputBatchCount)
        nativePresentedFrames: \(presentedFrameCount)
        nativePresentationCallbacks: \(nativePresentationCallbackCount)
        coalescedInputBatches: \(coalescedInputBatchCount)
        displayLinkStarts: \(displayLinkStartCount)
        displayLinkPauses: \(displayLinkPauseCount)
        displayLinkUpdateCallbacks: \(displayLinkUpdateCallbackCount)
        measuredDisplayLinkStarts: \(measuredDisplayLinkStartCount)
        measuredDisplayLinkPauses: \(measuredDisplayLinkPauseCount)
        admittedFrameTimingRecords: \(admittedFrameTimingCount)
        admittedFrameTimingSamples: \(inputSubmitToDisplayLinkCallbackMilliseconds.count)
        inputSubmitToDisplayLinkCallbackP95Milliseconds: \(String(format: "%.6f", percentile95(inputSubmitToDisplayLinkCallbackMilliseconds)))
        inputSubmitToDisplayLinkCallbackMaximumMilliseconds: \(String(format: "%.6f", inputSubmitToDisplayLinkCallbackMilliseconds.max() ?? .infinity))
        inputSubmitToPostInjectionAdmissionP95Milliseconds: \(String(format: "%.6f", percentile95(inputSubmitToAdmissionMilliseconds)))
        inputSubmitToPostInjectionAdmissionMaximumMilliseconds: \(String(format: "%.6f", inputSubmitToAdmissionMilliseconds.max() ?? .infinity))
        displayLinkCallbackToTargetPresentationP95Milliseconds: \(String(format: "%.6f", percentile95(displayLinkCallbackToTargetPresentationMilliseconds)))
        displayLinkCallbackToTargetPresentationMaximumMilliseconds: \(String(format: "%.6f", displayLinkCallbackToTargetPresentationMilliseconds.max() ?? .infinity))
        displayLinkCallbackToNativePresentationP95Milliseconds: \(String(format: "%.6f", percentile95(displayLinkCallbackToNativePresentationMilliseconds)))
        displayLinkCallbackToNativePresentationMaximumMilliseconds: \(String(format: "%.6f", displayLinkCallbackToNativePresentationMilliseconds.max() ?? .infinity))
        nativePresentationMinusTargetP95Milliseconds: \(String(format: "%.6f", percentile95(nativePresentationMinusTargetMilliseconds)))
        nativePresentationMinusTargetMaximumMilliseconds: \(String(format: "%.6f", nativePresentationMinusTargetMilliseconds.max() ?? .infinity))
        persistenceDocumentElements: \(persistenceDocumentElementCount)
        persistenceDocumentFreehandSamples: \(persistenceDocumentFreehandSampleCount)
        persistenceDocumentHasVariedPressure: \(persistenceDocumentHasVariedPressure)
        persistencePayloadBytes: \(persistencePayloadByteCount)
        persistencePayloadMatchesAfterNativePresentation: \(persistencePayloadMatchesAfterNativePresentation)
        recordedSavePayloads: \(recordedSavePayloadCount)
        recordedSavePayloadMatchesBeforePresentation: \(recordedSavePayloadMatchesBeforePresentation)
        nativePresentationAdvancedAfterPayloadEncoding: \(nativePresentationAdvancedAfterPayloadEncoding)
        warmUpCommittedFramePresented: \(warmUpCommittedFramePresented)
        pencilUpProcessingMilliseconds: \(String(format: "%.6f", pencilUpProcessingMilliseconds))
        commitPresentationMilliseconds: \(String(format: "%.6f", commitPresentationMilliseconds))
        committedStrokeSamples: \(committedStrokeSampleCount)
        acceptedImmediateFollowUpInput: \(acceptedImmediateFollowUpInput)
        repeatedStrokeBatchCounts: \(repeatedStrokeBatchCounts)
        repeatedPencilUpProcessingMilliseconds: \(repeatedPencilUpProcessingMilliseconds)
        repeatedFollowUpProcessingMilliseconds: \(repeatedFollowUpProcessingMilliseconds)
        repeatedDriverSubmissionMilliseconds: \(repeatedDriverSubmissionMilliseconds)
        repeatedCommitPresentationMilliseconds: \(repeatedCommitPresentationMilliseconds)
        gateSemantics: sustained drawing metrics exclude commits; commit latency ends at native follow-up presentation
        renderer: CadCanvasView default AdaptiveCanvasRenderer / MetalCanvasRenderView
        timingSource: synchronous input/driver timing plus actual MTLDrawable callbacks
        """)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

@MainActor
final class PhysicalCanvasPresentationHarness {
    enum Completion {
        case cancel
        case commit
    }

    enum HarnessError: Error, CustomStringConvertible {
        case hostDidNotMount
        case metalBackendNotActive
        case presentationTimedOut(String)
        case missingRetainedStroke
        case retainedStrokeMismatch

        var description: String {
            switch self {
            case .hostDidNotMount:
                return "hostDidNotMount"
            case .metalBackendNotActive:
                return "metalBackendNotActive"
            case .presentationTimedOut(let evidence):
                return "presentationTimedOut(\(evidence))"
            case .missingRetainedStroke:
                return "missingRetainedStroke"
            case .retainedStrokeMismatch:
                return "retainedStrokeMismatch"
            }
        }
    }

    private let session: CanvasSession
    private let samplesPerBatch: Int
    private let signposts = CanvasPerformanceSignposts.shared
    private let window: UIWindow
    private let controller: PhysicalCanvasHostController
    private let host: CanvasHostView
    private let diagnosticRecorder: PhysicalCanvasDiagnosticRecorder

    init(samplesPerBatch: Int) throws {
        let mountedSession = try CanvasSession(
            document: physicalPersistenceDocument(),
            viewport: .identity(size: .init(width: 1_024, height: 768))
        )
        let recorder = PhysicalCanvasDiagnosticRecorder()
        mountedSession.onDiagnostic = { [weak recorder] diagnostic in
            recorder?.record(diagnostic)
        }
        mountedSession.selectTool(.freehand)
        let mountedController = PhysicalCanvasHostController(
            rootView: CadCanvasView(session: mountedSession, recognizer: nil)
        )
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else {
            throw HarnessError.hostDidNotMount
        }
        let mountedWindow = UIWindow(windowScene: windowScene)
        mountedWindow.rootViewController = mountedController
        mountedWindow.makeKeyAndVisible()
        mountedController.view.frame = mountedWindow.bounds
        mountedController.view.setNeedsLayout()
        mountedController.view.layoutIfNeeded()
        guard pumpRunLoop(until: {
            firstDescendant(of: mountedController.view, as: CanvasHostView.self) != nil
        }, timeout: 2),
        let mountedHost = firstDescendant(
            of: mountedController.view,
            as: CanvasHostView.self
        ) else {
            throw HarnessError.hostDidNotMount
        }
        self.samplesPerBatch = samplesPerBatch
        session = mountedSession
        controller = mountedController
        window = mountedWindow
        host = mountedHost
        diagnosticRecorder = recorder
        guard let activeBackendView = host.renderView.subviews.first(where: { !$0.isHidden }),
              activeBackendView is MetalCanvasRenderView else {
            throw HarnessError.metalBackendNotActive
        }
    }

    deinit {
        MainActor.assumeIsolated { window.isHidden = true }
    }

    func run(
        minimumDuration: TimeInterval,
        completion: Completion = .cancel,
        additionalCommittedStrokeCount: Int = 0
    ) throws -> PhysicalCanvasPresentationResult {
        signposts.resetRecordedMetrics()
        var acceptedSamples = 0
        var acceptedPoints: [CanvasPoint] = []
        guard let metalView = host.renderView.subviews
            .first(where: { !$0.isHidden }) as? MetalCanvasRenderView else {
            throw HarnessError.metalBackendNotActive
        }

        let nativePresentationsBeforeWarmUp = metalView.frameDiagnosticSnapshot
            .nativePresentationCallbackCount
        let warmUpCommittedFramePresented = pumpRunLoop(until: {
            let frame = metalView.frameDiagnosticSnapshot
            return (nativePresentationsBeforeWarmUp > 0
                    || frame.nativePresentationCallbackCount > nativePresentationsBeforeWarmUp)
                && frame.pendingFrameCount == 0
                && frame.trackedSubmittedFrameCount == 0
        }, timeout: 2)
        guard warmUpCommittedFramePresented else {
            throw HarnessError.presentationTimedOut(timeoutEvidence())
        }

        let sampleCount = samplesPerBatch
        let mountedSession = session
        func deliverBatch(to targetHost: CanvasHostView, phase: CanvasPencilBatchPhase) {
            let identities = (0..<sampleCount).map { _ in NSObject() }
            let samples = identities.enumerated().map { offset, identity in
                let pointIndex = acceptedSamples + offset
                return CanvasPencilTouchSample(
                    identity: identity,
                    location: CGPoint(
                        x: 24 + Double(pointIndex % 960),
                        y: 24 + Double((pointIndex * 17) % 700)
                    )
                )
            }
            guard let primary = samples.last else { return }
            let viewport = mountedSession.viewport
            acceptedPoints.append(contentsOf: samples.map { sample in
                viewport.canvasPoint(
                    fromScreen: CanvasPoint(
                        x: Double(sample.location.x),
                        y: Double(sample.location.y)
                    )
                )
            })
            targetHost.deliverPencilSamples(
                coalesced: samples,
                primary: primary,
                phase: phase
            )
            acceptedSamples += samples.count
        }

        let completedBeforeWarmUp = signposts.statistics.completedIntervalCount
        deliverBatch(to: host, phase: .began)
        guard pumpRunLoop(until: {
            signposts.statistics.completedIntervalCount > completedBeforeWarmUp
        }, timeout: 2) else {
            throw HarnessError.presentationTimedOut(timeoutEvidence())
        }
        guard isMetalBackendActive else {
            throw HarnessError.metalBackendNotActive
        }

        let persistencePayloadBeforePresentation = try CanvasDocumentCodec.encode(
            session.document
        )
        let nativePresentationCountAtPayloadEncoding = metalView.frameDiagnosticSnapshot
            .nativePresentationCallbackCount
        signposts.resetRecordedMetrics()
        let diagnosticBaseline = metalView.frameDiagnosticSnapshot
        let displayLinkBaseline = metalView.displayLinkDiagnosticSnapshot
        let baselineSubmissionSequence = diagnosticBaseline.recentAdmittedFrameTimings.last?
            .submissionSequence
        var runState = SustainedInputRunState(
            startTime: ProcessInfo.processInfo.systemUptime,
            minimumDuration: minimumDuration
        )
        metalView.beforeDisplayLinkUpdate = { [weak host] in
            guard let host,
                  runState.takeBatchIndex(
                at: ProcessInfo.processInfo.systemUptime
                  ) != nil else {
                return
            }
            deliverBatch(to: host, phase: .moved)
        }
        defer { metalView.beforeDisplayLinkUpdate = nil }
        metalView.requestPresentationUpdates()

        guard pumpRunLoop(until: { runState.hasStopped }, timeout: minimumDuration + 2) else {
            throw HarnessError.presentationTimedOut(timeoutEvidence())
        }
        metalView.beforeDisplayLinkUpdate = nil

        guard pumpRunLoop(until: {
            let statistics = signposts.statistics
            let frame = metalView.frameDiagnosticSnapshot
            return runState.isDrained(
                completedIntervalCount: statistics.completedIntervalCount,
                activeIntervalCount: statistics.activeIntervalCount,
                cancelledIntervalCount: statistics.cancelledIntervalCount,
                capacityEvictedIntervalCount: statistics.capacityEvictedIntervalCount,
                pendingFrameCount: frame.pendingFrameCount,
                trackedSubmittedFrameCount: frame.trackedSubmittedFrameCount
            )
        }, timeout: 2) else {
            throw HarnessError.presentationTimedOut(timeoutEvidence())
        }

        guard isMetalBackendActive else {
            throw HarnessError.metalBackendNotActive
        }

        let elapsed = runState.elapsedSeconds
        let timestamps = signposts.recentDisplayTimestamps
        let latencies = signposts.recentCompletedDurationsMilliseconds
        let statistics = signposts.statistics
        let displayLink = metalView.displayLinkDiagnosticSnapshot
        let frameDiagnostics = metalView.frameDiagnosticSnapshot
        guard let retainedPoints = session.activeFreehandPreviewPoints else {
            throw HarnessError.missingRetainedStroke
        }
        guard retainedPoints == acceptedPoints else {
            throw HarnessError.retainedStrokeMismatch
        }
        var verifiedSampleCount = retainedPoints.count
        var verifiedSamplesMatchAcceptedOrder = true
        var pencilUpProcessingMilliseconds = 0.0
        var commitPresentationMilliseconds = 0.0
        var committedStrokeSampleCount = 0
        var acceptedImmediateFollowUpInput = false
        var repeatedStrokeBatchCounts: [Int] = []
        var repeatedPencilUpProcessingMilliseconds: [Double] = []
        var repeatedFollowUpProcessingMilliseconds: [Double] = []
        var repeatedDriverSubmissionMilliseconds: [Double] = []
        var repeatedCommitPresentationMilliseconds: [Double] = []
        if completion == .commit {
            let pencilUpStart = ProcessInfo.processInfo.systemUptime
            deliverBatch(to: host, phase: .ended)
            pencilUpProcessingMilliseconds = (
                ProcessInfo.processInfo.systemUptime - pencilUpStart
            ) * 1_000
            let committedStroke = session.document.elements.reversed().compactMap {
                element -> CanvasInkStroke? in
                guard case .freehand(let stroke) = element.geometry else { return nil }
                return stroke
            }.first
            committedStrokeSampleCount = committedStroke?.samples.count ?? 0
            verifiedSampleCount = committedStrokeSampleCount
            verifiedSamplesMatchAcceptedOrder = committedStroke?.samples.map { $0.point }
                == acceptedPoints

            let followUpIdentity = NSObject()
            let followUp = CanvasPencilTouchSample(
                identity: followUpIdentity,
                location: CGPoint(x: 32, y: 32)
            )
            host.deliverPencilSamples(
                coalesced: [followUp],
                primary: followUp,
                phase: .began
            )
            acceptedImmediateFollowUpInput = session.activeFreehandPreviewPoints?.count == 1
            commitPresentationMilliseconds = try waitForFollowUpPresentation(
                metalView: metalView,
                after: ProcessInfo.processInfo.systemUptime,
                commitStart: pencilUpStart
            )
            host.sendPencilCancelled?()
            guard pumpRunLoop(until: {
                let frame = metalView.frameDiagnosticSnapshot
                return frame.pendingFrameCount == 0 && frame.trackedSubmittedFrameCount == 0
            }, timeout: 2) else {
                throw HarnessError.presentationTimedOut(timeoutEvidence())
            }
            for repeatedStroke in 0..<additionalCommittedStrokeCount {
                let batchCount = 50
                repeatedStrokeBatchCounts.append(batchCount)
                var repeatedSampleIndex = 0
                func deliverRepeatedBatch(_ phase: CanvasPencilBatchPhase) {
                    let identities = (0..<100).map { _ in NSObject() }
                    let samples = identities.enumerated().map { offset, identity in
                        let pointIndex = repeatedSampleIndex + offset
                        return CanvasPencilTouchSample(
                            identity: identity,
                            location: CGPoint(
                                x: 24 + Double(pointIndex % 960),
                                y: 24 + Double(
                                    (pointIndex * 17 + repeatedStroke * 31) % 700
                                )
                            )
                        )
                    }
                    guard let primary = samples.last else { return }
                    host.deliverPencilSamples(
                        coalesced: samples,
                        primary: primary,
                        phase: phase
                    )
                    repeatedSampleIndex += samples.count
                }

                var deliveredBatchCount = 0
                metalView.beforeDisplayLinkUpdate = {
                    guard deliveredBatchCount < batchCount else { return }
                    deliverRepeatedBatch(deliveredBatchCount == 0 ? .began : .moved)
                    deliveredBatchCount += 1
                }
                metalView.requestPresentationUpdates()
                guard pumpRunLoop(until: {
                    deliveredBatchCount == batchCount
                }, timeout: 2) else {
                    throw HarnessError.presentationTimedOut(timeoutEvidence())
                }
                metalView.beforeDisplayLinkUpdate = nil
                let submissionSequenceBaseline = metalView.frameDiagnosticSnapshot
                    .recentAdmittedFrameTimings.last?.submissionSequence
                let commitStart = ProcessInfo.processInfo.systemUptime
                deliverRepeatedBatch(.ended)
                let pencilUpEnd = ProcessInfo.processInfo.systemUptime
                let followUpIdentity = NSObject()
                let followUp = CanvasPencilTouchSample(
                    identity: followUpIdentity,
                    location: CGPoint(x: 40, y: 40)
                )
                host.deliverPencilSamples(
                    coalesced: [followUp],
                    primary: followUp,
                    phase: .began
                )
                let followUpEnd = ProcessInfo.processInfo.systemUptime
                repeatedPencilUpProcessingMilliseconds.append(
                    (pencilUpEnd - commitStart) * 1_000
                )
                repeatedFollowUpProcessingMilliseconds.append(
                    (followUpEnd - pencilUpEnd) * 1_000
                )
                repeatedCommitPresentationMilliseconds.append(
                    try waitForFollowUpPresentation(
                        metalView: metalView,
                        after: followUpEnd,
                        commitStart: commitStart
                    )
                )
                let newSubmissionDurations = metalView.frameDiagnosticSnapshot
                    .recentAdmittedFrameTimings
                    .filter { timing in
                        submissionSequenceBaseline.map {
                            timing.submissionSequence > $0
                        } ?? true
                    }
                    .compactMap(\.driverSubmissionMilliseconds)
                repeatedDriverSubmissionMilliseconds.append(
                    newSubmissionDurations.max() ?? .infinity
                )
                guard isMetalBackendActive else {
                    throw HarnessError.metalBackendNotActive
                }
                host.sendPencilCancelled?()
                guard pumpRunLoop(until: {
                    let frame = metalView.frameDiagnosticSnapshot
                    return frame.pendingFrameCount == 0
                        && frame.trackedSubmittedFrameCount == 0
                }, timeout: 2) else {
                    throw HarnessError.presentationTimedOut(timeoutEvidence())
                }
            }
        }
        let presentationIntervals = zip(timestamps, timestamps.dropFirst()).map {
            ($1 - $0) * 1_000
        }
        let persistencePayloadAfterPresentation = try CanvasDocumentCodec.encode(
            session.document
        )
        let saveSink = PhysicalRecordingSaveSink()
        saveSink.save(persistencePayloadAfterPresentation)
        let persistenceStrokes: [CanvasInkStroke] = session.document.elements.compactMap { element in
            guard case .freehand(let stroke) = element.geometry else { return nil }
            return stroke
        }
        let persistencePressures = persistenceStrokes.flatMap { stroke in
            stroke.samples.map { $0.pressure }
        }
        let admittedFrameTimings = frameDiagnostics.recentAdmittedFrameTimings.filter { timing in
            baselineSubmissionSequence.map { timing.submissionSequence > $0 } ?? true
        }.prefix(runState.batchCount)
        let measuredNativePresentationCount = admittedFrameTimings.filter {
            $0.displayLinkCallbackToNativePresentationMilliseconds != nil
        }.count
        let measuredDisplayLinkStartCount = max(
            0,
            displayLink.startCount - displayLinkBaseline.startCount
        )
        let measuredDisplayLinkPauseCount = max(
            0,
            displayLink.pauseCount - displayLinkBaseline.pauseCount
        )
        let presentationSpan = timestamps.count >= 2
            ? (timestamps.last ?? 0) - (timestamps.first ?? 0)
            : 0
        let result = PhysicalCanvasPresentationResult(
            elapsedSeconds: elapsed,
            acceptedSampleCount: acceptedSamples,
            retainedSampleCount: verifiedSampleCount,
            retainedSamplesMatchAcceptedOrder: verifiedSamplesMatchAcceptedOrder,
            displayLatenciesMilliseconds: latencies,
            presentationTimestamps: timestamps,
            presentationIntervalsMilliseconds: presentationIntervals,
            presentationSpanSeconds: presentationSpan,
            presentationP95Milliseconds: percentile95(presentationIntervals),
            presentationMaximumMilliseconds: presentationIntervals.max() ?? .infinity,
            displayP95Milliseconds: percentile95(latencies),
            displayMaximumMilliseconds: latencies.max() ?? .infinity,
            machineModel: physicalMachineModel(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            inputBatchCount: runState.batchCount,
            completedInputBatchCount: statistics.completedIntervalCount,
            activeInputBatchCount: statistics.activeIntervalCount,
            cancelledInputBatchCount: statistics.cancelledIntervalCount,
            evictedInputBatchCount: statistics.capacityEvictedIntervalCount,
            presentedFrameCount: timestamps.count,
            nativePresentationCallbackCount: measuredNativePresentationCount,
            coalescedInputBatchCount: max(0, runState.batchCount - timestamps.count),
            displayLinkStartCount: displayLink.startCount,
            displayLinkPauseCount: displayLink.pauseCount,
            displayLinkUpdateCallbackCount: displayLink.updateCallbackCount,
            measuredDisplayLinkStartCount: measuredDisplayLinkStartCount,
            measuredDisplayLinkPauseCount: measuredDisplayLinkPauseCount,
            admittedFrameTimingCount: admittedFrameTimings.count,
            inputSubmitToDisplayLinkCallbackMilliseconds: admittedFrameTimings.compactMap(
                \.inputSubmitToDisplayLinkCallbackMilliseconds
            ),
            inputSubmitToAdmissionMilliseconds: admittedFrameTimings.compactMap(
                \.inputSubmitToAdmissionMilliseconds
            ),
            displayLinkCallbackToTargetPresentationMilliseconds: admittedFrameTimings.compactMap(
                \.displayLinkCallbackToTargetPresentationMilliseconds
            ),
            displayLinkCallbackToNativePresentationMilliseconds: admittedFrameTimings.compactMap(
                \.displayLinkCallbackToNativePresentationMilliseconds
            ),
            nativePresentationMinusTargetMilliseconds: admittedFrameTimings.compactMap(
                \.nativePresentationMinusTargetMilliseconds
            ),
            persistenceDocumentElementCount: session.document.elements.count,
            persistenceDocumentFreehandSampleCount: persistenceStrokes.reduce(0) {
                $0 + $1.samples.count
            },
            persistenceDocumentHasVariedPressure: Set(persistencePressures).count > 1,
            persistencePayloadByteCount: persistencePayloadBeforePresentation.count,
            persistencePayloadMatchesAfterNativePresentation:
                persistencePayloadAfterPresentation == persistencePayloadBeforePresentation,
            recordedSavePayloadCount: saveSink.payloads.count,
            recordedSavePayloadMatchesBeforePresentation:
                saveSink.payloads == [persistencePayloadBeforePresentation],
            nativePresentationAdvancedAfterPayloadEncoding:
                frameDiagnostics.nativePresentationCallbackCount
                    > nativePresentationCountAtPayloadEncoding,
            warmUpCommittedFramePresented: warmUpCommittedFramePresented,
            pencilUpProcessingMilliseconds: pencilUpProcessingMilliseconds,
            commitPresentationMilliseconds: commitPresentationMilliseconds,
            committedStrokeSampleCount: committedStrokeSampleCount,
            acceptedImmediateFollowUpInput: acceptedImmediateFollowUpInput,
            repeatedStrokeBatchCounts: repeatedStrokeBatchCounts,
            repeatedPencilUpProcessingMilliseconds: repeatedPencilUpProcessingMilliseconds,
            repeatedFollowUpProcessingMilliseconds: repeatedFollowUpProcessingMilliseconds,
            repeatedDriverSubmissionMilliseconds: repeatedDriverSubmissionMilliseconds,
            repeatedCommitPresentationMilliseconds: repeatedCommitPresentationMilliseconds
        )
        host.sendPencilCancelled?()
        signposts.cancelAll()
        window.isHidden = true
        return result
    }

    private func waitForFollowUpPresentation(
        metalView: MetalCanvasRenderView,
        after followUpEnd: TimeInterval,
        commitStart: TimeInterval
    ) throws -> Double {
        var presentation: MetalAdmittedFrameTimingDiagnostic?
        guard pumpRunLoop(until: {
            presentation = metalView.frameDiagnosticSnapshot.recentAdmittedFrameTimings.first {
                $0.admissionTimestamp >= followUpEnd
                    && $0.displayLinkCallbackToNativePresentationMilliseconds != nil
            }
            return presentation != nil
        }, timeout: 2), let presentation,
        let nativeElapsed = presentation.displayLinkCallbackToNativePresentationMilliseconds else {
            throw HarnessError.presentationTimedOut(timeoutEvidence())
        }
        return (presentation.displayLinkCallbackTimestamp - commitStart) * 1_000 + nativeElapsed
    }

    private var isMetalBackendActive: Bool {
        host.renderView.subviews.first(where: { !$0.isHidden }) is MetalCanvasRenderView
    }

    private func timeoutEvidence() -> String {
        let visibleBackend = host.renderView.subviews.first(where: { !$0.isHidden })
        let metalView = host.renderView.subviews.compactMap { $0 as? MetalCanvasRenderView }.first
        let metalLayer = metalView?.layer as? CAMetalLayer
        let frame = metalView?.frameDiagnosticSnapshot
        let displayLink = metalView?.displayLinkDiagnosticSnapshot
        let scene = window.windowScene
        let sceneWindows = scene?.windows.enumerated().map { index, candidate in
            "\(index):key=\(candidate.isKeyWindow),hidden=\(candidate.isHidden),"
                + "alpha=\(candidate.alpha),level=\(candidate.windowLevel.rawValue),"
                + "root=\(candidate.rootViewController.map { String(describing: type(of: $0)) } ?? "none")"
        }.joined(separator: "|") ?? "none"
        return [
            "applicationState=\(UIApplication.shared.applicationState.rawValue)",
            "sceneActivationState=\(scene?.activationState.rawValue ?? -1)",
            "sceneWindowCount=\(scene?.windows.count ?? 0)",
            "sceneWindows=\(sceneWindows)",
            "windowIsKey=\(window.isKeyWindow)",
            "windowIsHidden=\(window.isHidden)",
            "windowAlpha=\(window.alpha)",
            "windowLevel=\(window.windowLevel.rawValue)",
            "windowScreenMatchesScene=\(scene.map { window.screen === $0.screen } ?? false)",
            "rootViewWindowMatches=\(window.rootViewController?.viewIfLoaded?.window === window)",
            "visibleBackend=\(visibleBackend.map { String(describing: type(of: $0)) } ?? "none")",
            "diagnostics=\(diagnosticRecorder.sanitizedDescription)",
            "hostBounds=\(NSCoder.string(for: host.bounds))",
            "renderBounds=\(NSCoder.string(for: host.renderView.bounds))",
            "metalBounds=\(metalView.map { NSCoder.string(for: $0.bounds) } ?? "none")",
            "drawableSize=\(metalLayer.map { NSCoder.string(for: $0.drawableSize) } ?? "none")",
            "metalSuperviewMounted=\(metalView?.superview != nil)",
            "metalWindowMounted=\(metalView?.window != nil)",
            "metalWindowMatches=\(metalView?.window === window)",
            "metalHidden=\(metalView?.isHidden ?? true)",
            "metalAlpha=\(metalView?.alpha ?? 0)",
            "displayLinkPaused=\(displayLink?.isPaused ?? true)",
            "displayLinkInvalidated=\(displayLink?.isInvalidated ?? true)",
            "displayLinkStarts=\(displayLink?.startCount ?? 0)",
            "displayLinkPauses=\(displayLink?.pauseCount ?? 0)",
            "displayLinkUpdateCallbacks=\(displayLink?.updateCallbackCount ?? 0)",
            "metalFramebufferOnly=\(metalLayer?.framebufferOnly ?? false)",
            "metalDevice=\(metalLayer?.device?.name ?? "none")",
            "layerIsCAMetalLayer=\(metalLayer != nil)",
            "layerBounds=\(metalLayer.map { NSCoder.string(for: $0.bounds) } ?? "none")",
            "layerFrame=\(metalLayer.map { NSCoder.string(for: $0.frame) } ?? "none")",
            "layerContentsScale=\(metalLayer?.contentsScale ?? 0)",
            "layerPresentationAvailable=\(metalLayer?.presentation() != nil)",
            "layerSuperlayerMounted=\(metalLayer?.superlayer != nil)",
            "layerPresentsWithTransaction=\(metalLayer?.presentsWithTransaction ?? false)",
            "layerAllowsNextDrawableTimeout=\(metalLayer?.allowsNextDrawableTimeout ?? false)",
            "layerMaximumDrawableCount=\(metalLayer?.maximumDrawableCount ?? 0)",
            "submissionAttempts=\(frame?.submissionAttemptCount ?? 0)",
            "submittedFrames=\(frame?.submittedFrameCount ?? 0)",
            "drawableUnavailable=\(frame?.drawableUnavailableCount ?? 0)",
            "commandCompletions=\(frame?.commandCompletionCount ?? 0)",
            "nativePresentationCallbacks=\(frame?.nativePresentationCallbackCount ?? 0)",
            "recentAdmittedFrameTimings=\(frame?.recentAdmittedFrameTimings.count ?? 0)",
            "pendingFrames=\(frame?.pendingFrameCount ?? 0)",
            "trackedSubmittedFrames=\(frame?.trackedSubmittedFrameCount ?? 0)",
            "signpostActive=\(signposts.statistics.activeIntervalCount)",
            "signpostCompleted=\(signposts.statistics.completedIntervalCount)",
        ].joined(separator: ";")
    }
}

@MainActor
private final class PhysicalRecordingSaveSink {
    private(set) var payloads: [Data] = []

    func save(_ payload: Data) {
        payloads.append(payload)
    }
}

private func physicalPersistenceDocument() -> CanvasDocument {
    return CanvasDocument(
        id: UUID(uuidString: "50485953-4943-414C-5045-525349535401")!,
        elements: (0..<100).map { index in
            let column = index % 10
            let row = index / 10
            let origin = CanvasPoint(
                x: 28 + Double(column * 96),
                y: 28 + Double(row * 70)
            )
            let samples = [
                CanvasInkSample(point: origin, pressure: 0),
                CanvasInkSample(
                    point: .init(x: origin.x + 14, y: origin.y + 18),
                    pressure: 0.25
                ),
                CanvasInkSample(
                    point: .init(x: origin.x + 28, y: origin.y + 6),
                    pressure: 0.5
                ),
                CanvasInkSample(
                    point: .init(x: origin.x + 42, y: origin.y + 22),
                    pressure: 0.75
                ),
                CanvasInkSample(
                    point: .init(x: origin.x + 56, y: origin.y + 10),
                    pressure: 1
                ),
            ]
            return CanvasElement(
                id: physicalFixtureID(index),
                geometry: .freehand(.init(samples: samples, pressureEnabled: true)),
                style: .init(stroke: .black, lineWidth: 6)
            )
        }
    )
}

private func physicalFixtureID(_ index: Int) -> UUID {
    UUID(uuidString: String(
        format: "50485953-4943-414C-494E-%012llX",
        UInt64(index + 1)
    ))!
}

@MainActor
private func firstDescendant<T: UIView>(of view: UIView, as type: T.Type) -> T? {
    if let match = view as? T { return match }
    for child in view.subviews {
        if let match = firstDescendant(of: child, as: type) { return match }
    }
    return nil
}

@MainActor
private func pumpRunLoop(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }
    return condition()
}

private func percentile95(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .infinity }
    let sorted = values.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}

private func physicalMachineModel() -> String {
    var system = utsname()
    uname(&system)
    return withUnsafePointer(to: &system.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
}
#endif

@MainActor
struct RendererPerformanceBenchmark {
    struct PhysicalAcceptance: Equatable {
        let requiredHardware: String
        let requiredEvidence: String
        let p95FrameMilliseconds: Double
        let maximumFrameMilliseconds: Double
    }

    struct DeviceResult {
        let renderedFrameCount: Int
        let elapsedSeconds: Double
        let p95Milliseconds: Double
        let maximumMilliseconds: Double
    }

    enum BenchmarkError: Error {
        case contextCreationFailed
    }

    let warmUpRenderCount = 30
    let measuredRenderCount = 300
    let bounds = CGRect(x: 0, y: 0, width: 1_180, height: 820)
    let displayScale = 2.0

    static let pendingPhysicalAcceptance = PhysicalAcceptance(
        requiredHardware: "iPad (A16)",
        requiredEvidence: "Core Animation + Time Profiler",
        p95FrameMilliseconds: 16.7,
        maximumFrameMilliseconds: 33.4
    )

    private let document: CanvasDocument
    private let renderer = CoreGraphicsCanvasRenderer()
    private let scenePreparer = CanvasScenePreparer()

    init(document: CanvasDocument) throws {
        try document.validate()
        self.document = document
    }

    func makeReusableContext() throws -> CGContext {
        let pixelWidth = Int(Double(bounds.width) * displayScale)
        let pixelHeight = Int(Double(bounds.height) * displayScale)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BenchmarkError.contextCreationFailed
        }
        context.scaleBy(x: displayScale, y: displayScale)
        return context
    }

    func warmUp(context: CGContext) {
        for index in 0 ..< warmUpRenderCount {
            render(index: index, context: context)
        }
    }

    func renderMeasuredBatch(context: CGContext) {
        for index in 0 ..< measuredRenderCount {
            render(index: index, context: context)
        }
    }

    func viewport(at index: Int) -> CanvasViewport {
        let boundedIndex = index % measuredRenderCount
        let zoomStep = Double(boundedIndex % 75) / 74
        return try! CanvasViewport(
            zoom: 0.75 + zoomStep * 0.75,
            translation: CanvasPoint(
                x: 40 - Double((boundedIndex * 23) % 1_800),
                y: 30 - Double((boundedIndex * 17) % 1_200)
            ),
            viewportSize: CanvasSize(
                width: Double(bounds.width),
                height: Double(bounds.height)
            )
        )
    }

    func diagnosticAttachment(batchDuration: Double) -> XCTAttachment {
        let metadata = PerformanceFixture.expectedContract.metadata
        let averageMilliseconds = batchDuration * 1_000 / Double(measuredRenderCount)
        let attachment = XCTAttachment(
            string: """
            environment: \(environmentDescription)
            operatingSystem: \(ProcessInfo.processInfo.operatingSystemVersionString)
            processorCount: \(ProcessInfo.processInfo.processorCount)
            elements: \(metadata.elementCount)
            freehandSamples: \(metadata.freehandSampleCount)
            freehandPoints: \(metadata.freehandPointCount)
            boundsPoints: \(Int(bounds.width))x\(Int(bounds.height))
            displayScale: \(displayScale)
            bitmapPixels: \(Int(Double(bounds.width) * displayScale))x\(Int(Double(bounds.height) * displayScale))
            warmUpRenders: \(warmUpRenderCount)
            measuredRenders: \(measuredRenderCount)
            reusableContext: true
            manualBatchSeconds: \(String(format: "%.6f", batchDuration))
            manualAverageMilliseconds: \(String(format: "%.6f", averageMilliseconds))
            releaseGate: Offscreen timing is diagnostic only. The physical iPad five-second Core Animation + Time Profiler gate remains required.
            """
        )
        attachment.name = "CadCanvasKit Core Graphics offscreen baseline"
        attachment.lifetime = .keepAlways
        return attachment
    }

    func runFiveSecondDeviceSeam(context: CGContext) -> DeviceResult {
        let targetDuration = 5.0
        let start = ProcessInfo.processInfo.systemUptime
        var frameDurations: [Double] = []
        var index = 0

        repeat {
            let frameStart = ProcessInfo.processInfo.systemUptime
            render(index: index, context: context)
            frameDurations.append(
                (ProcessInfo.processInfo.systemUptime - frameStart) * 1_000
            )
            index += 1
        } while ProcessInfo.processInfo.systemUptime - start < targetDuration

        let sorted = frameDurations.sorted()
        let percentileIndex = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return DeviceResult(
            renderedFrameCount: frameDurations.count,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
            p95Milliseconds: sorted[percentileIndex],
            maximumMilliseconds: sorted.max() ?? .infinity
        )
    }

    func deviceAttachment(result: DeviceResult) -> XCTAttachment {
        let acceptance = Self.pendingPhysicalAcceptance
        let attachment = XCTAttachment(
            string: """
            environment: \(environmentDescription)
            scriptedPanZoomSeconds: \(String(format: "%.6f", result.elapsedSeconds))
            warmUpRenders: \(warmUpRenderCount)
            renderedFrames: \(result.renderedFrameCount)
            offscreenRendererP95Milliseconds: \(String(format: "%.6f", result.p95Milliseconds))
            offscreenRendererMaximumMilliseconds: \(String(format: "%.6f", result.maximumMilliseconds))
            offscreenTimingRole: Diagnostic only; these are not Core Animation presented-frame timings.
            physicalReleaseGate: PENDING external Instruments acceptance.
            requiredHardware: \(acceptance.requiredHardware)
            requiredEvidence: \(acceptance.requiredEvidence)
            requiredCoreAnimationP95Milliseconds: <= \(acceptance.p95FrameMilliseconds)
            requiredCoreAnimationMaximumMilliseconds: <= \(acceptance.maximumFrameMilliseconds)
            """
        )
        attachment.name = "CadCanvasKit physical iPad renderer seam (release gate pending)"
        attachment.lifetime = .keepAlways
        return attachment
    }
}

@MainActor
extension RendererPerformanceBenchmark {
    var environmentDescription: String {
        #if targetEnvironment(simulator)
        "iOS Simulator (diagnostic only)"
        #else
        "Physical \(UIDevice.current.model)"
        #endif
    }

    func render(index: Int, context: CGContext) {
        guard let scene = try? scenePreparer.prepare(
            document: document,
            preview: nil,
            viewport: viewport(at: index),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        ).scene else {
            return
        }
        renderer.draw(
            scene: scene,
            in: context,
            bounds: bounds,
            displayScale: displayScale
        )
    }
}

enum PerformanceFixture {
    struct Metadata: Equatable {
        let elementCount: Int
        let rectangleCount: Int
        let lineCount: Int
        let archCount: Int
        let textCount: Int
        let freehandCount: Int
        let freehandSampleCount: Int
        let freehandPointCount: Int
    }

    struct Fingerprint: Equatable {
        let encodedUTF8ByteCount: Int
        let encodedFNV1a64: UInt64
    }

    struct Contract: Equatable {
        let metadata: Metadata
        let fingerprint: Fingerprint
    }

    static let expectedContract = Contract(
        metadata: Metadata(
            elementCount: 500,
            rectangleCount: 100,
            lineCount: 100,
            archCount: 100,
            textCount: 100,
            freehandCount: 100,
            freehandSampleCount: 100_000,
            freehandPointCount: 100_000
        ),
        fingerprint: Fingerprint(
            encodedUTF8ByteCount: 4_683_777,
            encodedFNV1a64: 1_856_650_250_789_757_776
        )
    )

    static func make() throws -> CanvasDocument {
        var elements: [CanvasElement] = []
        elements.reserveCapacity(expectedContract.metadata.elementCount)

        for index in 0 ..< 100 {
            elements.append(rectangle(at: index))
        }
        for index in 0 ..< 100 {
            elements.append(line(at: index))
        }
        for index in 0 ..< 100 {
            elements.append(arch(at: index))
        }
        for index in 0 ..< 100 {
            elements.append(text(at: index))
        }
        for index in 0 ..< 100 {
            elements.append(freehand(at: index))
        }

        let document = CanvasDocument(
            id: fixtureID(kind: 0, index: 0),
            revision: 0,
            elements: elements,
            calibration: CanvasCalibration(millimetersPerPoint: 0.5)
        )
        try document.validate()
        return document
    }

    static func audit(_ document: CanvasDocument) throws -> Contract {
        try document.validate()
        guard document.revision == 0,
              document.calibration.millimetersPerPoint.isFinite,
              document.calibration.millimetersPerPoint > 0,
              document.elements.allSatisfy({ $0.contentRevision == 0 }),
              Set(document.elements.map(\.id)).count == document.elements.count else {
            throw FixtureError.invalidIdentityOrRevisionContract
        }

        var rectangleCount = 0
        var lineCount = 0
        var archCount = 0
        var textCount = 0
        var freehandCount = 0
        var freehandSampleCount = 0
        var freehandPointCount = 0

        for element in document.elements {
            switch element.geometry {
            case .rectangle:
                rectangleCount += 1
            case .line:
                lineCount += 1
            case .arch:
                archCount += 1
            case .text:
                textCount += 1
            case .freehand(let stroke):
                guard stroke.samples.count == 1_000,
                      stroke.pressureEnabled,
                      stroke.samples.allSatisfy({ $0.pressure == 1 }) else {
                    throw FixtureError.invalidFreehandContract
                }
                freehandCount += 1
                freehandSampleCount += stroke.samples.count
                freehandPointCount += stroke.points.count
            }
        }

        let encoding = try CanvasDocumentCodec.encodeString(document)
        return Contract(
            metadata: Metadata(
                elementCount: document.elements.count,
                rectangleCount: rectangleCount,
                lineCount: lineCount,
                archCount: archCount,
                textCount: textCount,
                freehandCount: freehandCount,
                freehandSampleCount: freehandSampleCount,
                freehandPointCount: freehandPointCount
            ),
            fingerprint: Fingerprint(
                encodedUTF8ByteCount: encoding.utf8.count,
                encodedFNV1a64: stableChecksum(encoding.utf8)
            )
        )
    }
}

extension PerformanceFixture {
    enum FixtureError: Error {
        case invalidIdentityOrRevisionContract
        case invalidFreehandContract
    }

    static let outline = CanvasStyle(
        stroke: CanvasColor(red: 0.08, green: 0.27, blue: 0.58),
        fill: nil,
        lineWidth: 2
    )

    static let filled = CanvasStyle(
        stroke: CanvasColor(red: 0.12, green: 0.38, blue: 0.62),
        fill: CanvasColor(red: 0.72, green: 0.86, blue: 0.98, alpha: 0.35),
        lineWidth: 1.5
    )

    static func rectangle(at index: Int) -> CanvasElement {
        let column = index % 10
        let row = index / 10
        return CanvasElement.rectangle(
            id: fixtureID(kind: 1, index: index),
            rect: CanvasRect(
                x: Double(column * 76),
                y: Double(row * 58),
                width: 48 + Double(index % 4),
                height: 32 + Double(index % 5)
            ),
            style: filled
        )
    }

    static func line(at index: Int) -> CanvasElement {
        let column = index % 10
        let row = index / 10
        let start = CanvasPoint(x: 820 + Double(column * 72), y: Double(row * 58))
        let end = CanvasPoint(x: start.x + 44, y: start.y + 28 + Double(index % 6))
        return CanvasElement(
            id: fixtureID(kind: 2, index: index),
            geometry: .line(CanvasLine(start: start, end: end)),
            style: outline
        )
    }

    static func arch(at index: Int) -> CanvasElement {
        let column = index % 10
        let row = index / 10
        let start = CanvasPoint(x: 1_580 + Double(column * 72), y: Double(row * 58))
        let end = CanvasPoint(x: start.x + 48, y: start.y)
        return CanvasElement(
            id: fixtureID(kind: 3, index: index),
            geometry: .arch(
                CanvasArch(start: start, end: end, sagitta: 18 + Double(index % 7))
            ),
            style: outline
        )
    }

    static func text(at index: Int) -> CanvasElement {
        let column = index % 10
        let row = index / 10
        return CanvasElement(
            id: fixtureID(kind: 4, index: index),
            geometry: .text(
                CanvasText(
                    frame: CanvasRect(
                        x: 2_340 + Double(column * 88),
                        y: 20 + Double(row * 58),
                        width: 80,
                        height: 20
                    ),
                    text: "Fixture \(index)",
                    font: CanvasFont(familyName: "Helvetica", pointSize: 16),
                    color: CanvasColor(red: 0.16, green: 0.18, blue: 0.22)
                )
            ),
            style: outline
        )
    }

    static func freehand(at index: Int) -> CanvasElement {
        var samples: [CanvasInkSample] = []
        samples.reserveCapacity(1_000)

        for pointIndex in 0 ..< 1_000 {
            let point = CanvasPoint(
                x: Double(pointIndex) * 1.25,
                y: 700 + Double(index * 12) + Double((pointIndex * 17 + index * 13) % 19) * 0.4
            )
            samples.append(CanvasInkSample(point: point, pressure: 1))
        }

        return CanvasElement(
            id: fixtureID(kind: 5, index: index),
            geometry: .freehand(CanvasInkStroke(samples: samples, pressureEnabled: true)),
            style: CanvasStyle(
                stroke: CanvasColor(red: 0.48, green: 0.18, blue: 0.58),
                lineWidth: 1.25
            )
        )
    }

    static func fixtureID(kind: UInt8, index: Int) -> UUID {
        UUID(
            uuid: (
                0x44, 0x52, 0x41, 0x57,
                0x43, 0x41, 0x4e, 0x56,
                0x41, 0x53, 0x00, kind,
                0x00, 0x00, 0x00, UInt8(index)
            )
        )
    }

    static func stableChecksum(_ bytes: String.UTF8View) -> UInt64 {
        bytes.reduce(UInt64(14_695_981_039_346_656_037)) { checksum, byte in
            (checksum ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
