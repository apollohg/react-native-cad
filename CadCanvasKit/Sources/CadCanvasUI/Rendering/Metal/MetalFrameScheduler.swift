import Foundation
import Metal
import QuartzCore

@MainActor
protocol MetalFrameSchedulerDelegate: AnyObject {
    func frameSchedulerDidPresent(
        _ generation: RecognitionGeneration,
        at presentedTime: TimeInterval
    )
    func frameSchedulerDidFail(
        _ error: MetalCanvasError,
        permanence: MetalFailurePermanence
    )
}

enum MetalFrameCommandResult {
    case completed
    case failed(MetalCanvasError, MetalFailurePermanence)
}

struct MetalNativePresentationEvent: Sendable {
    let presentedTime: TimeInterval
    let isNativePresentation: Bool
}

struct MetalDisplayLinkDrawable {
    let nativeDrawable: AnyObject
    let texture: any MTLTexture
    let callbackTimestamp: TimeInterval
    let admissionTimestamp: TimeInterval
    let targetTimestamp: TimeInterval
    let targetPresentationTimestamp: TimeInterval
    private let presentation: (any MTLCommandBuffer) -> Void

    var identity: ObjectIdentifier { ObjectIdentifier(nativeDrawable) }

    init(
        _ drawable: any CAMetalDrawable,
        callbackTimestamp: TimeInterval = 0,
        targetTimestamp: TimeInterval = 0,
        targetPresentationTimestamp: TimeInterval = 0
    ) {
        nativeDrawable = drawable as AnyObject
        texture = drawable.texture
        self.callbackTimestamp = callbackTimestamp
        admissionTimestamp = callbackTimestamp
        self.targetTimestamp = targetTimestamp
        self.targetPresentationTimestamp = targetPresentationTimestamp
        presentation = { commandBuffer in
            commandBuffer.present(drawable)
        }
    }

    init(
        nativeDrawable: AnyObject,
        texture: any MTLTexture,
        callbackTimestamp: TimeInterval = 0,
        admissionTimestamp: TimeInterval? = nil,
        targetTimestamp: TimeInterval = 0,
        targetPresentationTimestamp: TimeInterval = 0,
        present: @escaping (any MTLCommandBuffer) -> Void
    ) {
        self.nativeDrawable = nativeDrawable
        self.texture = texture
        self.callbackTimestamp = callbackTimestamp
        self.admissionTimestamp = admissionTimestamp ?? callbackTimestamp
        self.targetTimestamp = targetTimestamp
        self.targetPresentationTimestamp = targetPresentationTimestamp
        presentation = present
    }

    func present(on commandBuffer: any MTLCommandBuffer) {
        presentation(commandBuffer)
    }

    func recordingAdmission(at timestamp: TimeInterval) -> MetalDisplayLinkDrawable {
        MetalDisplayLinkDrawable(
            nativeDrawable: nativeDrawable,
            texture: texture,
            callbackTimestamp: callbackTimestamp,
            admissionTimestamp: timestamp,
            targetTimestamp: targetTimestamp,
            targetPresentationTimestamp: targetPresentationTimestamp,
            present: presentation
        )
    }
}

struct MetalAdmittedFrameTimingDiagnostic: Equatable {
    let submissionSequence: UInt64
    let displayLinkCallbackTimestamp: TimeInterval
    let admissionTimestamp: TimeInterval
    let targetTimestamp: TimeInterval
    let targetPresentationTimestamp: TimeInterval
    let inputSubmitToDisplayLinkCallbackMilliseconds: Double?
    let inputSubmitToAdmissionMilliseconds: Double?
    let displayLinkCallbackToTargetPresentationMilliseconds: Double?
    var driverSubmissionMilliseconds: Double?
    var displayLinkCallbackToNativePresentationMilliseconds: Double?
    var nativePresentationMinusTargetMilliseconds: Double?
}

struct MetalFrameDiagnosticSnapshot: Equatable {
    let submissionAttemptCount: Int
    let submittedFrameCount: Int
    let drawableUnavailableCount: Int
    let commandCompletionCount: Int
    let nativePresentationCallbackCount: Int
    let pendingFrameCount: Int
    let trackedSubmittedFrameCount: Int
    let recentAdmittedFrameTimings: [MetalAdmittedFrameTimingDiagnostic]
}

@MainActor
protocol MetalFrameDriving: AnyObject {
    func submit(
        _ scene: MetalCompiledScene,
        drawable: MetalDisplayLinkDrawable,
        displayScale: Double,
        completion: @escaping @MainActor (MetalFrameCommandResult) -> Void,
        presentation: @escaping @MainActor (MetalNativePresentationEvent) -> Void
    ) throws

    func invalidateSizeDependentResources()

    func resetDerivedRenderCaches()
}

extension MetalFrameDriving {
    func resetDerivedRenderCaches() {
        invalidateSizeDependentResources()
    }
}

@MainActor
final class MetalFrameScheduler {
    private struct PendingFrame {
        let scene: MetalCompiledScene
        let epoch: UInt64
        let inputSubmitTimestamp: TimeInterval
    }

    private struct SubmittedFrame {
        let generation: RecognitionGeneration?
        let epoch: UInt64
        let sequence: UInt64
        var commandCompleted = false
        var nativePresentationCompleted = false
    }

    weak var delegate: (any MetalFrameSchedulerDelegate)?

    private let driver: any MetalFrameDriving
    private let maximumInFlight: Int
    private let timingClock: @MainActor () -> TimeInterval
    private let recentTimingCapacity: Int
    private weak var attachedRenderView: MetalCanvasRenderView?
    private var latestFrame: PendingFrame?
    private var pendingFrame: PendingFrame?
    private var submittedFrames: [UUID: SubmittedFrame] = [:]
    private var inFlightCount = 0
    private var epoch: UInt64 = 0
    private var nextSubmissionSequence: UInt64 = 0
    private var latestPresentedSequence: UInt64?
    private var reportedGenerations: Set<RecognitionGeneration> = []
    private var observedDrawableSize: CGSize?
    private var isInvalidated = false
    private var submissionAttemptCount = 0
    private var submittedFrameCount = 0
    private var commandCompletionCount = 0
    private var nativePresentationCallbackCount = 0
    private var recentAdmittedFrameTimings: [MetalAdmittedFrameTimingDiagnostic] = []

    var diagnosticSnapshot: MetalFrameDiagnosticSnapshot {
        MetalFrameDiagnosticSnapshot(
            submissionAttemptCount: submissionAttemptCount,
            submittedFrameCount: submittedFrameCount,
            drawableUnavailableCount: 0,
            commandCompletionCount: commandCompletionCount,
            nativePresentationCallbackCount: nativePresentationCallbackCount,
            pendingFrameCount: pendingFrame == nil ? 0 : 1,
            trackedSubmittedFrameCount: submittedFrames.count,
            recentAdmittedFrameTimings: recentAdmittedFrameTimings
        )
    }

    var hasAttachedRenderView: Bool { attachedRenderView != nil }
    private var hasCurrentPreviewDemand: Bool {
        guard attachedRenderView?.window != nil, let latestFrame else {
            return false
        }
        return latestFrame.epoch == epoch
            && latestFrame.scene.previewGeneration != nil
    }

    var needsDisplayLinkUpdates: Bool {
        !isInvalidated && (
            pendingFrame != nil
                || !submittedFrames.isEmpty
                || hasCurrentPreviewDemand
        )
    }

    convenience init(
        device: any MTLDevice,
        maximumInFlight: Int = CanvasMetalLimits.maximumInFlightFrameCount
    ) {
        self.init(
            driver: LiveMetalFrameDriver(device: device),
            maximumInFlight: maximumInFlight
        )
    }

    init(
        driver: any MetalFrameDriving,
        maximumInFlight: Int = CanvasMetalLimits.maximumInFlightFrameCount,
        timingClock: @escaping @MainActor () -> TimeInterval = { CACurrentMediaTime() },
        recentTimingCapacity: Int = 1_024
    ) {
        self.driver = driver
        self.maximumInFlight = max(
            1,
            min(maximumInFlight, CanvasMetalLimits.maximumInFlightFrameCount)
        )
        self.timingClock = timingClock
        self.recentTimingCapacity = max(1, min(recentTimingCapacity, 1_024))
    }

    func attach(to renderView: MetalCanvasRenderView) {
        guard !isInvalidated else { return }
        attachedRenderView = renderView
    }

    func submit(_ scene: MetalCompiledScene, to view: MetalCanvasRenderView) {
        guard !isInvalidated, attachedRenderView === view else { return }
        if scene.previewGeneration == nil {
            advanceEpoch()
        }
        let frame = PendingFrame(
            scene: scene,
            epoch: epoch,
            inputSubmitTimestamp: timingClock()
        )
        latestFrame = frame
        pendingFrame = frame
        view.requestPresentationUpdates()
    }

    func displayLinkDidUpdate(
        with drawable: MetalDisplayLinkDrawable,
        from renderView: MetalCanvasRenderView
    ) {
        guard !isInvalidated,
              attachedRenderView === renderView,
              inFlightCount < maximumInFlight,
              let frame = pendingFrame else {
            return
        }
        pendingFrame = nil
        let identifier = UUID()
        let submissionSequence = nextSubmissionSequence
        submittedFrames[identifier] = SubmittedFrame(
            generation: frame.scene.previewGeneration,
            epoch: frame.epoch,
            sequence: submissionSequence
        )
        nextSubmissionSequence &+= 1
        inFlightCount += 1
        submissionAttemptCount += 1
        recordAdmissionTiming(
                sequence: submissionSequence,
                inputSubmitTimestamp: frame.inputSubmitTimestamp,
            drawable: drawable
        )
        do {
            let submissionStart = timingClock()
            try driver.submit(
                frame.scene,
                drawable: drawable,
                displayScale: Double(renderView.contentScaleFactor),
                completion: { [weak self] result in
                    self?.commandDidComplete(identifier, result: result)
                },
                presentation: { [weak self] event in
                    self?.drawableDidReachNativePresentation(identifier, event: event)
                }
            )
            recordDriverSubmissionTiming(
                sequence: submissionSequence,
                startedAt: submissionStart,
                completedAt: timingClock()
            )
            submittedFrameCount += 1
        } catch let error as MetalCanvasError {
            removeAdmissionTiming(sequence: submissionSequence)
            cancelProvisionalSubmission(identifier)
            if error == .resourceBudgetExceeded,
               !submittedFrames.isEmpty,
               frame.epoch == epoch,
               pendingFrame == nil {
                pendingFrame = latestFrame ?? frame
                renderView.requestPresentationUpdates()
                return
            }
            reportFailure(error, permanence: .permanent)
        } catch {
            removeAdmissionTiming(sequence: submissionSequence)
            cancelProvisionalSubmission(identifier)
            reportFailure(.commandEncodingFailed, permanence: .permanent)
        }
    }

    func drawableSizeDidChange(to drawableSize: CGSize) {
        guard !isInvalidated else { return }
        if let observedDrawableSize, observedDrawableSize != drawableSize {
            driver.invalidateSizeDependentResources()
        }
        observedDrawableSize = drawableSize
    }

    func renderViewAttachmentDidChange(
        _ renderView: MetalCanvasRenderView,
        isAttached: Bool
    ) {
        guard !isInvalidated, attachedRenderView === renderView else { return }
        if isAttached {
            if pendingFrame != nil {
                renderView.requestPresentationUpdates()
            }
        } else {
            if pendingFrame == nil {
                pendingFrame = latestFrame
            }
            renderView.pausePresentationUpdates()
        }
    }

    func invalidate() {
        invalidateScheduler(notifyView: true)
    }

    func resetDerivedRenderCaches() {
        driver.resetDerivedRenderCaches()
    }
}

@MainActor
private extension MetalFrameScheduler {
    func advanceEpoch() {
        epoch &+= 1
        reportedGenerations.removeAll(keepingCapacity: true)
        latestPresentedSequence = nil
    }

    func cancelProvisionalSubmission(_ identifier: UUID) {
        guard let frame = submittedFrames.removeValue(forKey: identifier) else {
            return
        }
        if !frame.commandCompleted {
            inFlightCount = max(0, inFlightCount - 1)
        }
    }

    func commandDidComplete(_ identifier: UUID, result: MetalFrameCommandResult) {
        guard !isInvalidated,
              var frame = submittedFrames[identifier],
              !frame.commandCompleted else {
            return
        }
        commandCompletionCount += 1
        frame.commandCompleted = true
        inFlightCount = max(0, inFlightCount - 1)
        switch result {
        case .completed:
            if frame.nativePresentationCompleted {
                submittedFrames.removeValue(forKey: identifier)
            } else {
                submittedFrames[identifier] = frame
            }
            if pendingFrame != nil {
                attachedRenderView?.requestPresentationUpdates()
            }
        case .failed(let error, let permanence):
            submittedFrames.removeValue(forKey: identifier)
            reportFailure(error, permanence: permanence)
        }
    }

    func reportFailure(
        _ error: MetalCanvasError,
        permanence: MetalFailurePermanence
    ) {
        guard !isInvalidated else { return }
        if permanence == .permanent {
            invalidateScheduler(notifyView: true)
        }
        delegate?.frameSchedulerDidFail(error, permanence: permanence)
    }

    func invalidateScheduler(notifyView: Bool) {
        guard !isInvalidated else { return }
        isInvalidated = true
        let renderView = attachedRenderView
        attachedRenderView = nil
        advanceEpoch()
        latestFrame = nil
        pendingFrame = nil
        submittedFrames.removeAll(keepingCapacity: false)
        inFlightCount = 0
        observedDrawableSize = nil
        driver.resetDerivedRenderCaches()
        if notifyView {
            renderView?.schedulerDidInvalidate()
        }
    }

    func drawableDidReachNativePresentation(
        _ identifier: UUID,
        event: MetalNativePresentationEvent
    ) {
        guard !isInvalidated,
              var frame = submittedFrames[identifier],
              !frame.nativePresentationCompleted else {
            return
        }
        frame.nativePresentationCompleted = true

        let presentedTime = event.presentedTime
        let isValidNativePresentation = event.isNativePresentation
            && presentedTime.isFinite
            && presentedTime > 0
        if isValidNativePresentation {
            nativePresentationCallbackCount += 1
            recordNativePresentationTiming(
                sequence: frame.sequence,
                presentedTime: presentedTime
            )
            let isNewestPresentation = latestPresentedSequence.map {
                frame.sequence > $0
            } ?? true
            if frame.epoch == epoch, isNewestPresentation {
                latestPresentedSequence = frame.sequence
            }
            if frame.epoch == epoch,
               isNewestPresentation,
               let generation = frame.generation,
               reportedGenerations.insert(generation).inserted {
                delegate?.frameSchedulerDidPresent(generation, at: presentedTime)
            }
        } else if frame.epoch == epoch,
                  latestPresentedSequence.map({ frame.sequence > $0 }) ?? true,
                  pendingFrame == nil,
                  let latestFrame,
                  latestFrame.epoch == epoch {
            pendingFrame = latestFrame
        }

        if frame.commandCompleted {
            submittedFrames.removeValue(forKey: identifier)
        } else {
            submittedFrames[identifier] = frame
        }
    }

    func recordAdmissionTiming(
        sequence: UInt64,
        inputSubmitTimestamp: TimeInterval,
        drawable: MetalDisplayLinkDrawable
    ) {
        recentAdmittedFrameTimings.append(
            MetalAdmittedFrameTimingDiagnostic(
                submissionSequence: sequence,
                displayLinkCallbackTimestamp: drawable.callbackTimestamp,
                admissionTimestamp: drawable.admissionTimestamp,
                targetTimestamp: drawable.targetTimestamp,
                targetPresentationTimestamp: drawable.targetPresentationTimestamp,
                inputSubmitToDisplayLinkCallbackMilliseconds: elapsedMilliseconds(
                    from: inputSubmitTimestamp,
                    to: drawable.callbackTimestamp
                ),
                inputSubmitToAdmissionMilliseconds: elapsedMilliseconds(
                    from: inputSubmitTimestamp,
                    to: drawable.admissionTimestamp
                ),
                displayLinkCallbackToTargetPresentationMilliseconds: elapsedMilliseconds(
                    from: drawable.callbackTimestamp,
                    to: drawable.targetPresentationTimestamp
                ),
                driverSubmissionMilliseconds: nil,
                displayLinkCallbackToNativePresentationMilliseconds: nil,
                nativePresentationMinusTargetMilliseconds: nil
            )
        )
        let overflow = recentAdmittedFrameTimings.count - recentTimingCapacity
        if overflow > 0 {
            recentAdmittedFrameTimings.removeFirst(overflow)
        }
    }

    func removeAdmissionTiming(sequence: UInt64) {
        recentAdmittedFrameTimings.removeAll {
            $0.submissionSequence == sequence
        }
    }

    func recordDriverSubmissionTiming(
        sequence: UInt64,
        startedAt: TimeInterval,
        completedAt: TimeInterval
    ) {
        guard let index = recentAdmittedFrameTimings.firstIndex(where: {
            $0.submissionSequence == sequence
        }) else { return }
        recentAdmittedFrameTimings[index].driverSubmissionMilliseconds = elapsedMilliseconds(
            from: startedAt,
            to: completedAt
        )
    }

    func recordNativePresentationTiming(
        sequence: UInt64,
        presentedTime: TimeInterval
    ) {
        guard let index = recentAdmittedFrameTimings.firstIndex(where: {
            $0.submissionSequence == sequence
        }) else {
            return
        }
        let callbackTimestamp = recentAdmittedFrameTimings[index]
            .displayLinkCallbackTimestamp
        let targetPresentationTimestamp = recentAdmittedFrameTimings[index]
            .targetPresentationTimestamp
        recentAdmittedFrameTimings[index]
            .displayLinkCallbackToNativePresentationMilliseconds = elapsedMilliseconds(
                from: callbackTimestamp,
                to: presentedTime
            )
        recentAdmittedFrameTimings[index]
            .nativePresentationMinusTargetMilliseconds = elapsedMilliseconds(
                from: targetPresentationTimestamp,
                to: presentedTime
            )
    }

    func elapsedMilliseconds(
        from start: TimeInterval,
        to end: TimeInterval
    ) -> Double? {
        guard start.isFinite, start > 0, end.isFinite, end > 0 else {
            return nil
        }
        return (end - start) * 1_000
    }
}

@MainActor
private final class LiveMetalFrameDriver: MetalFrameDriving {
    private var engine: MetalRenderEngine?
    private var initializationError: MetalCanvasError?

    init(device: any MTLDevice) {
        do {
            engine = try MetalRenderEngine(device: device)
        } catch let error as MetalCanvasError {
            initializationError = error
        } catch {
            initializationError = .deviceUnavailable
        }
    }

    func submit(
        _ scene: MetalCompiledScene,
        drawable: MetalDisplayLinkDrawable,
        displayScale: Double,
        completion: @escaping @MainActor (MetalFrameCommandResult) -> Void,
        presentation: @escaping @MainActor (MetalNativePresentationEvent) -> Void
    ) throws {
        if let initializationError { throw initializationError }
        guard let engine else {
            throw MetalCanvasError.deviceUnavailable
        }
        try MetalDrawablePresentationRegistration.registerNativeEvent(
            on: drawable.nativeDrawable,
            presentation: presentation
        )
        let renderSize = try MetalDrawableRenderMetrics.logicalSize(
            textureWidth: drawable.texture.width,
            textureHeight: drawable.texture.height,
            displayScale: displayScale
        )
        try engine.renderPresentedFrame(
            scene,
            into: drawable.texture,
            size: renderSize,
            displayScale: displayScale,
            configureBeforeCommit: { commandBuffer in
                commandBuffer.label = "Canvas drawable presentation"
                drawable.present(on: commandBuffer)
            },
            completion: { succeeded in
                let result: MetalFrameCommandResult = succeeded
                    ? .completed
                    : .failed(.commandBufferFailed, .permanent)
                completion(result)
            }
        )
    }

    func invalidateSizeDependentResources() {
        engine?.invalidateSizeDependentResources()
    }

    func resetDerivedRenderCaches() {
        engine?.handleMemoryPressure()
    }
}

enum MetalDrawableRenderMetrics {
    static func logicalSize(
        textureWidth: Int,
        textureHeight: Int,
        displayScale: Double
    ) throws -> CGSize {
        guard textureWidth > 0,
              textureHeight > 0,
              displayScale.isFinite,
              displayScale > 0 else {
            throw MetalCanvasError.invalidResourceSize
        }
        return CGSize(
            width: Double(textureWidth) / displayScale,
            height: Double(textureHeight) / displayScale
        )
    }
}

@MainActor
enum MetalDrawablePresentationRegistration {
    static func register(
        on drawable: AnyObject,
        presentation: @escaping @MainActor (TimeInterval) -> Void
    ) throws {
        guard let object = drawable as? NSObject else {
            throw MetalCanvasError.presentationCallbackUnavailable
        }
        try register(on: object, presentation: presentation)
    }

    static func register(
        on object: NSObject,
        presentation: @escaping @MainActor (TimeInterval) -> Void
    ) throws {
        try register(
            on: object,
            presentedTime: nativePresentedTime,
            presentation: presentation
        )
    }

    static func register(
        on object: NSObject,
        presentedTime: @escaping (AnyObject) -> TimeInterval,
        presentation: @escaping @MainActor (TimeInterval) -> Void
    ) throws {
        try registerNativeEvent(
            on: object,
            presentedTime: presentedTime,
            presentation: { event in
                guard event.presentedTime.isFinite, event.presentedTime > 0 else {
                    return
                }
                presentation(event.presentedTime)
            }
        )
    }

    static func registerNativeEvent(
        on drawable: AnyObject,
        presentation: @escaping @MainActor (MetalNativePresentationEvent) -> Void
    ) throws {
        guard let object = drawable as? NSObject else {
            throw MetalCanvasError.presentationCallbackUnavailable
        }
        try registerNativeEvent(on: object, presentation: presentation)
    }

    static func registerNativeEvent(
        on object: NSObject,
        presentation: @escaping @MainActor (MetalNativePresentationEvent) -> Void
    ) throws {
        try registerNativeEvent(
            on: object,
            presentedTime: nativePresentedTime,
            presentation: presentation
        )
    }

    static func registerNativeEvent(
        on object: NSObject,
        presentedTime: @escaping (AnyObject) -> TimeInterval,
        presentation: @escaping @MainActor (MetalNativePresentationEvent) -> Void
    ) throws {
        let selector = NSSelectorFromString("addPresentedHandler:")
        guard object.responds(to: selector) else {
            throw MetalCanvasError.presentationCallbackUnavailable
        }
        let handler: @convention(block) (AnyObject) -> Void = { drawable in
            let event = MetalNativePresentationEvent(
                presentedTime: presentedTime(drawable),
                isNativePresentation: true
            )
            Task { @MainActor in presentation(event) }
        }
        object.perform(selector, with: handler)
    }

    private static func nativePresentedTime(_ drawable: AnyObject) -> TimeInterval {
        guard let object = drawable as? NSObject,
              object.responds(to: NSSelectorFromString("presentedTime")),
              let value = object.value(forKey: "presentedTime") as? NSNumber else {
            return 0
        }
        return value.doubleValue
    }
}
