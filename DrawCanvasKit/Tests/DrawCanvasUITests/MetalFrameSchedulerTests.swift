import Metal
import ObjectiveC.runtime
import QuartzCore
import XCTest
@testable import DrawCanvasUI

@MainActor
final class MetalFrameSchedulerTests: XCTestCase {
    func testScenesRemainPendingUntilDisplayLinkDrawableArrives() throws {
        let driver = TestMetalFrameDriver()
        let scheduler = MetalFrameScheduler(driver: driver, maximumInFlight: 1)
        let view = try makeOwnedView(scheduler: scheduler)

        scheduler.submit(scene(1), to: view)
        scheduler.submit(scene(2), to: view)

        XCTAssertEqual(driver.submissionCount, 0)
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 1)

        let fixture = try makeDrawable()
        scheduler.displayLinkDidUpdate(with: fixture.drawable, from: view)

        XCTAssertEqual(driver.attemptedGenerations, [generation(2)])
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 0)
    }

    func testOneDisplayLinkUpdateAdmitsAtMostOneLatestPendingScene() throws {
        let driver = TestMetalFrameDriver()
        let scheduler = MetalFrameScheduler(driver: driver, maximumInFlight: 3)
        let view = try makeOwnedView(scheduler: scheduler)

        scheduler.submit(scene(1), to: view)
        scheduler.submit(scene(2), to: view)
        scheduler.submit(scene(3), to: view)

        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)
        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)

        XCTAssertEqual(driver.attemptedGenerations, [generation(3)])
        XCTAssertEqual(driver.submissionCount, 1)
    }

    func testDriverReceivesExactUpdateDrawableAndTextureWithoutPulling() throws {
        let driver = TestMetalFrameDriver()
        let clock = TestMetalTimingClock(now: 40)
        let scheduler = MetalFrameScheduler(
            driver: driver,
            timingClock: { clock.now },
            recentTimingCapacity: 1_024
        )
        let view = try makeOwnedView(scheduler: scheduler)
        let fixture = try makeDrawable(
            width: 240,
            height: 160,
            callbackTimestamp: 40.004,
            targetTimestamp: 40.012,
            targetPresentationTimestamp: 40.020
        )

        XCTAssertTrue(type(of: view.layer) == CAMetalLayer.self)
        XCTAssertTrue(view.metalLayer.device === (try requiredMetalDevice()))
        XCTAssertEqual(view.metalLayer.pixelFormat, .bgra8Unorm)
        XCTAssertTrue(view.metalLayer.framebufferOnly)

        scheduler.submit(scene(7), to: view)
        scheduler.displayLinkDidUpdate(with: fixture.drawable, from: view)

        XCTAssertEqual(driver.receivedDrawableIdentities, [fixture.identity])
        XCTAssertEqual(driver.receivedTextureIdentities, [ObjectIdentifier(fixture.texture as AnyObject)])
        XCTAssertEqual(driver.receivedDisplayScales, [Double(view.contentScaleFactor)])

        driver.completeSubmission(at: 0)
        driver.presentSubmission(at: 0, presentedTime: 40.021)

        let timing = try XCTUnwrap(
            scheduler.diagnosticSnapshot.recentAdmittedFrameTimings.first
        )
        XCTAssertEqual(timing.displayLinkCallbackTimestamp, 40.004)
        XCTAssertEqual(timing.admissionTimestamp, 40.004)
        XCTAssertEqual(timing.targetTimestamp, 40.012)
        XCTAssertEqual(timing.targetPresentationTimestamp, 40.020)
        XCTAssertEqual(
            try XCTUnwrap(timing.inputSubmitToDisplayLinkCallbackMilliseconds),
            4,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing.inputSubmitToAdmissionMilliseconds),
            4,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing.displayLinkCallbackToTargetPresentationMilliseconds),
            16,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing.driverSubmissionMilliseconds),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing.displayLinkCallbackToNativePresentationMilliseconds),
            17,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing.nativePresentationMinusTargetMilliseconds),
            1,
            accuracy: 0.000_001
        )

        for offset in 1...1_024 {
            clock.now = 40 + Double(offset)
            scheduler.submit(scene(UInt64(7 + offset)), to: view)
            scheduler.displayLinkDidUpdate(
                with: try makeDrawable(
                    callbackTimestamp: clock.now + 0.004,
                    targetTimestamp: clock.now + 0.012,
                    targetPresentationTimestamp: clock.now + 0.020
                ).drawable,
                from: view
            )
            driver.completeSubmission(at: offset)
            driver.presentSubmission(
                at: offset,
                presentedTime: clock.now + 0.021
            )
        }

        XCTAssertEqual(
            scheduler.diagnosticSnapshot.recentAdmittedFrameTimings.count,
            1_024
        )
        XCTAssertEqual(
            scheduler.diagnosticSnapshot.recentAdmittedFrameTimings.first?.submissionSequence,
            1
        )
        XCTAssertEqual(
            scheduler.diagnosticSnapshot.recentAdmittedFrameTimings.last?.submissionSequence,
            1_024
        )
    }

    func testCommandCompletionAndNativePresentationAreIndependentExactlyOnceEvents() throws {
        let driver = TestMetalFrameDriver()
        let delegate = TestMetalFrameSchedulerDelegate()
        let scheduler = MetalFrameScheduler(driver: driver, maximumInFlight: 1)
        scheduler.delegate = delegate
        let view = try makeOwnedView(scheduler: scheduler)

        scheduler.submit(scene(8), to: view)
        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)
        driver.completeSubmission(at: 0)
        driver.completeSubmissionAgain(at: 0)

        XCTAssertTrue(delegate.presentedGenerations.isEmpty)
        XCTAssertEqual(scheduler.diagnosticSnapshot.commandCompletionCount, 1)
        XCTAssertEqual(scheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 1)

        driver.presentSubmission(at: 0, presentedTime: 18.25)
        driver.presentSubmission(at: 0, presentedTime: 99)

        XCTAssertEqual(delegate.presentedGenerations, [generation(8)])
        XCTAssertEqual(delegate.presentedTimes, [18.25])
        XCTAssertEqual(scheduler.diagnosticSnapshot.nativePresentationCallbackCount, 1)
        XCTAssertEqual(scheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 0)

        scheduler.submit(scene(9), to: view)
        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)
        driver.presentSubmission(at: 1, presentedTime: 19)

        XCTAssertEqual(delegate.presentedGenerations, [generation(8), generation(9)])
        XCTAssertEqual(scheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 1)

        driver.completeSubmission(at: 1)
        XCTAssertEqual(scheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 0)
    }

    func testMissingUpdateRetainsOnlyLatestSceneForRetry() throws {
        let driver = TestMetalFrameDriver()
        let scheduler = MetalFrameScheduler(driver: driver, maximumInFlight: 1)
        let view = try makeOwnedView(scheduler: scheduler)

        scheduler.submit(scene(1), to: view)
        scheduler.submit(scene(2), to: view)
        scheduler.submit(scene(3), to: view)

        XCTAssertEqual(driver.submissionCount, 0)
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 1)

        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)
        XCTAssertEqual(driver.attemptedGenerations, [generation(3)])
    }

    func testResizeInvalidatesSizeResourcesWithoutLosingPendingScene() throws {
        XCTAssertEqual(
            try MetalDrawableRenderMetrics.logicalSize(
                textureWidth: 240,
                textureHeight: 160,
                displayScale: 2
            ),
            CGSize(width: 120, height: 80)
        )

        let driver = TestMetalFrameDriver()
        let scheduler = MetalFrameScheduler(driver: driver)
        let view = MetalCanvasRenderView(
            frame: .zero,
            device: try requiredMetalDevice(),
            scheduler: scheduler,
            owner: NSObject()
        )
        scheduler.submit(scene(4), to: view)

        let sentinelSize = CGSize(width: 1, height: 1)
        view.metalLayer.drawableSize = sentinelSize
        view.layoutSubviews()

        XCTAssertEqual(view.metalLayer.drawableSize, sentinelSize)
        XCTAssertEqual(driver.sizeInvalidationCount, 0)

        view.bounds.size = CGSize(width: 100, height: 80)
        view.layoutSubviews()
        let scale = view.contentScaleFactor
        XCTAssertEqual(
            view.metalLayer.drawableSize,
            CGSize(width: 100 * scale, height: 80 * scale)
        )
        XCTAssertEqual(driver.sizeInvalidationCount, 0)

        view.bounds.size = CGSize(width: 200, height: 160)
        view.layoutSubviews()

        XCTAssertEqual(driver.sizeInvalidationCount, 1)
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 1)

        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)
        XCTAssertEqual(driver.attemptedGenerations, [generation(4)])
    }

    func testDismantleInvalidatesDisplayLinkAndDropsStaleCallbacks() throws {
        let driver = TestMetalFrameDriver()
        let delegate = TestMetalFrameSchedulerDelegate()
        let scheduler = MetalFrameScheduler(driver: driver, maximumInFlight: 3)
        scheduler.delegate = delegate
        var links: [TestMetalDisplayLinkController] = []
        let view = try makeOwnedView(scheduler: scheduler) { _, update in
            let link = TestMetalDisplayLinkController(update: update)
            links.append(link)
            return link
        }

        XCTAssertNil(view.beforeDisplayLinkUpdate)

        scheduler.submit(scene(5), to: view)
        XCTAssertEqual(links.first?.startCount, 0)
        XCTAssertTrue(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.startCount, 0)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.pauseCount, 0)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.updateCallbackCount, 0)

        let window = makeSceneBackedWindow()
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.rootViewController?.view.addSubview(view)

        XCTAssertTrue(view.window === window)
        XCTAssertEqual(links[0].startCount, 1)
        XCTAssertFalse(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.startCount, 1)

        var submissionCountObservedByHook: Int?
        var hookTimestamp: TimeInterval?
        view.beforeDisplayLinkUpdate = {
            submissionCountObservedByHook = driver.submissionCount
            hookTimestamp = CACurrentMediaTime()
        }
        links[0].emit(try makeDrawable().drawable)
        XCTAssertEqual(submissionCountObservedByHook, 0)
        XCTAssertEqual(driver.submissionCount, 1)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(
                scheduler.diagnosticSnapshot.recentAdmittedFrameTimings.first?
                    .admissionTimestamp
            ),
            try XCTUnwrap(hookTimestamp)
        )
        view.beforeDisplayLinkUpdate = nil
        XCTAssertEqual(links[0].pauseCount, 0)
        XCTAssertFalse(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.updateCallbackCount, 1)

        driver.completeSubmission(at: 0)
        driver.presentSubmission(at: 0, presentedTime: 20)
        XCTAssertEqual(links[0].pauseCount, 0)
        XCTAssertFalse(view.displayLinkDiagnosticSnapshot.isPaused)

        for _ in 0..<3 {
            links[0].emit(try makeDrawable().drawable)
        }
        XCTAssertEqual(driver.submissionCount, 1)
        XCTAssertEqual(links[0].pauseCount, 0)
        XCTAssertFalse(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.startCount, 1)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.updateCallbackCount, 4)

        scheduler.submit(scene(6), to: view)
        XCTAssertEqual(links[0].startCount, 1)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.startCount, 1)
        links[0].emit(try makeDrawable().drawable)
        XCTAssertEqual(driver.submissionCount, 2)
        driver.completeSubmission(at: 1)
        driver.presentSubmission(at: 1, presentedTime: 21)

        XCTAssertEqual(links[0].pauseCount, 0)
        XCTAssertFalse(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.updateCallbackCount, 5)

        scheduler.submit(scene(nil), to: view)
        XCTAssertEqual(links[0].startCount, 1)
        links[0].emit(try makeDrawable().drawable)
        XCTAssertEqual(driver.submissionCount, 3)
        driver.completeSubmission(at: 2)
        driver.presentSubmission(at: 2, presentedTime: 22)

        XCTAssertEqual(links[0].pauseCount, 0)
        XCTAssertFalse(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.updateCallbackCount, 6)

        links[0].emit(try makeDrawable().drawable)
        XCTAssertEqual(links[0].pauseCount, 1)
        XCTAssertTrue(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.pauseCount, 1)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.updateCallbackCount, 7)

        scheduler.submit(scene(7), to: view)
        XCTAssertEqual(links[0].startCount, 2)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.startCount, 2)
        view.removeFromSuperview()

        XCTAssertNil(view.window)
        XCTAssertEqual(links[0].pauseCount, 2)
        XCTAssertTrue(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.pauseCount, 2)

        window.rootViewController?.view.addSubview(view)
        XCTAssertTrue(view.window === window)
        XCTAssertEqual(links[0].startCount, 3)
        XCTAssertFalse(view.displayLinkDiagnosticSnapshot.isPaused)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.startCount, 3)

        links[0].emit(try makeDrawable().drawable)
        XCTAssertEqual(driver.submissionCount, 4)
        XCTAssertEqual(
            driver.attemptedGenerations,
            [generation(5), generation(6), nil, generation(7)]
        )

        let diagnosticsBeforeDismantle = scheduler.diagnosticSnapshot
        let presentationsBeforeDismantle = delegate.presentedGenerations
        var staleHookCallCount = 0
        view.beforeDisplayLinkUpdate = { staleHookCallCount += 1 }
        view.dismantle()
        XCTAssertNil(view.beforeDisplayLinkUpdate)
        XCTAssertEqual(driver.derivedCacheResetCount, 1)
        links[0].emit(try makeDrawable().drawable)
        for index in 0..<driver.submissionCount {
            driver.completeSubmission(at: index)
            driver.presentSubmission(at: index, presentedTime: 20 + Double(index))
        }

        XCTAssertTrue(links[0].isInvalidated)
        XCTAssertTrue(view.displayLinkDiagnosticSnapshot.isInvalidated)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.startCount, 3)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.pauseCount, 2)
        XCTAssertEqual(view.displayLinkDiagnosticSnapshot.updateCallbackCount, 9)
        XCTAssertFalse(scheduler.hasAttachedRenderView)
        XCTAssertEqual(
            scheduler.diagnosticSnapshot.commandCompletionCount,
            diagnosticsBeforeDismantle.commandCompletionCount
        )
        XCTAssertEqual(
            scheduler.diagnosticSnapshot.nativePresentationCallbackCount,
            diagnosticsBeforeDismantle.nativePresentationCallbackCount
        )
        XCTAssertEqual(scheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 0)
        XCTAssertEqual(delegate.presentedGenerations, presentationsBeforeDismantle)
        XCTAssertEqual(staleHookCallCount, 0)
    }

    func testPermanentFailuresRemainTypedAndFailClosed() throws {
        let driver = TestMetalFrameDriver()
        let delegate = TestMetalFrameSchedulerDelegate()
        let scheduler = MetalFrameScheduler(driver: driver, maximumInFlight: 1)
        scheduler.delegate = delegate
        let view = try makeOwnedView(scheduler: scheduler)
        driver.nextSubmissionError = .commandEncodingFailed

        scheduler.submit(scene(6), to: view)
        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)
        scheduler.submit(scene(7), to: view)
        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)

        XCTAssertEqual(delegate.failures.map(\.0), [.commandEncodingFailed])
        XCTAssertEqual(delegate.failures.map(\.1), [.permanent])
        XCTAssertEqual(driver.submissionCount, 0)
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 0)

        let gpuDriver = TestMetalFrameDriver()
        let gpuDelegate = TestMetalFrameSchedulerDelegate()
        let gpuScheduler = MetalFrameScheduler(driver: gpuDriver, maximumInFlight: 1)
        gpuScheduler.delegate = gpuDelegate
        let gpuView = try makeOwnedView(scheduler: gpuScheduler)
        gpuScheduler.submit(scene(8), to: gpuView)
        gpuScheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: gpuView)
        gpuDriver.failSubmission(at: 0, error: .commandBufferFailed)
        gpuScheduler.submit(scene(9), to: gpuView)
        gpuScheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: gpuView)

        XCTAssertEqual(gpuDelegate.failures.map(\.0), [.commandBufferFailed])
        XCTAssertEqual(gpuDelegate.failures.map(\.1), [.permanent])
        XCTAssertEqual(gpuDriver.submissionCount, 1)
        XCTAssertEqual(gpuScheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 0)
    }

    func testMaximumInFlightAdmissionsNeverExceedThree() throws {
        let driver = TestMetalFrameDriver()
        let delegate = TestMetalFrameSchedulerDelegate()
        let scheduler = MetalFrameScheduler(driver: driver, maximumInFlight: 99)
        scheduler.delegate = delegate
        let view = try makeOwnedView(scheduler: scheduler)

        for value in 1...4 {
            scheduler.submit(scene(UInt64(value)), to: view)
            scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)
        }

        XCTAssertEqual(driver.submissionCount, 3)
        XCTAssertEqual(driver.maximumUncompletedSubmissionCount, 3)
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 1)

        driver.completeSubmission(at: 0)
        XCTAssertEqual(driver.submissionCount, 3)
        driver.nextSubmissionError = .resourceBudgetExceeded
        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)

        XCTAssertEqual(driver.submissionCount, 3)
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 1)
        XCTAssertTrue(delegate.failures.isEmpty)
        scheduler.displayLinkDidUpdate(with: try makeDrawable().drawable, from: view)

        XCTAssertEqual(driver.submissionCount, 4)
        XCTAssertEqual(driver.maximumUncompletedSubmissionCount, 3)
    }

    func testPresentedTimestampsAreFinitePositiveNativeAndSkippedFramesRetryLatestScene() throws {
        XCTAssertThrowsError(
            try MetalDrawablePresentationRegistration.register(
                on: NSObject(),
                presentation: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? MetalCanvasError, .presentationCallbackUnavailable)
        }

        let probe = TestPresentedHandlerProbe()
        var deliveredEvents: [MetalNativePresentationEvent] = []
        try MetalDrawablePresentationRegistration.registerNativeEvent(
            on: probe,
            presentedTime: { ($0 as? TestPresentedHandlerProbe)?.presentedTime ?? 0 },
            presentation: { deliveredEvents.append($0) }
        )
        probe.presentedTime = 42.25
        probe.present()
        probe.presentedTime = 0
        probe.present()
        probe.presentedTime = .nan
        probe.present()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertEqual(deliveredEvents.count, 3)
        XCTAssertEqual(deliveredEvents[0].presentedTime, 42.25)
        XCTAssertEqual(deliveredEvents[1].presentedTime, 0)
        XCTAssertTrue(deliveredEvents[2].presentedTime.isNaN)
        XCTAssertTrue(deliveredEvents[0].isNativePresentation)

        let driver = TestMetalFrameDriver()
        let delegate = TestMetalFrameSchedulerDelegate()
        let scheduler = MetalFrameScheduler(driver: driver, maximumInFlight: 1)
        scheduler.delegate = delegate
        let view = try makeOwnedView(scheduler: scheduler)
        let firstDrawable = try makeDrawable()
        let secondDrawable = try makeDrawable()
        let thirdDrawable = try makeDrawable()
        scheduler.submit(scene(10), to: view)
        scheduler.displayLinkDidUpdate(with: firstDrawable.drawable, from: view)
        driver.completeSubmission(at: 0)
        driver.presentSubmission(at: 0, presentedTime: 0)

        XCTAssertTrue(delegate.presentedTimes.isEmpty)
        XCTAssertEqual(scheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 0)
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 1)
        XCTAssertTrue(scheduler.needsDisplayLinkUpdates)
        guard scheduler.diagnosticSnapshot.pendingFrameCount == 1 else { return }

        scheduler.displayLinkDidUpdate(with: secondDrawable.drawable, from: view)
        driver.completeSubmission(at: 1)
        driver.presentSubmission(at: 1, presentedTime: .nan)

        XCTAssertTrue(delegate.presentedTimes.isEmpty)
        XCTAssertEqual(scheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 0)
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 1)
        XCTAssertTrue(scheduler.needsDisplayLinkUpdates)
        guard scheduler.diagnosticSnapshot.pendingFrameCount == 1 else { return }

        scheduler.displayLinkDidUpdate(with: thirdDrawable.drawable, from: view)
        driver.completeSubmission(at: 2)
        driver.presentSubmission(at: 2, presentedTime: 42.25)
        driver.presentSubmission(at: 2, presentedTime: 99)

        XCTAssertEqual(driver.attemptedGenerations, [generation(10), generation(10), generation(10)])
        XCTAssertEqual(
            driver.receivedDrawableIdentities,
            [firstDrawable.identity, secondDrawable.identity, thirdDrawable.identity]
        )
        XCTAssertEqual(delegate.presentedGenerations, [generation(10)])
        XCTAssertEqual(delegate.presentedTimes, [42.25])
        XCTAssertEqual(scheduler.diagnosticSnapshot.pendingFrameCount, 0)
        XCTAssertEqual(scheduler.diagnosticSnapshot.trackedSubmittedFrameCount, 0)
        XCTAssertFalse(scheduler.needsDisplayLinkUpdates)
    }
}

@MainActor
private final class TestMetalTimingClock {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}

@MainActor
private final class TestMetalFrameSchedulerDelegate: MetalFrameSchedulerDelegate {
    private(set) var presentedGenerations: [RecognitionGeneration] = []
    private(set) var presentedTimes: [TimeInterval] = []
    private(set) var failures: [(MetalCanvasError, MetalFailurePermanence)] = []

    func frameSchedulerDidPresent(
        _ generation: RecognitionGeneration,
        at presentedTime: TimeInterval
    ) {
        presentedGenerations.append(generation)
        presentedTimes.append(presentedTime)
    }

    func frameSchedulerDidFail(
        _ error: MetalCanvasError,
        permanence: MetalFailurePermanence
    ) {
        failures.append((error, permanence))
    }
}

@MainActor
private final class TestMetalFrameDriver: MetalFrameDriving {
    struct Submission {
        let completion: @MainActor (MetalFrameCommandResult) -> Void
        let presentation: @MainActor (MetalNativePresentationEvent) -> Void
        var isComplete = false
    }

    var nextSubmissionError: MetalCanvasError?
    private(set) var attemptedGenerations: [RecognitionGeneration?] = []
    private(set) var receivedDrawableIdentities: [ObjectIdentifier] = []
    private(set) var receivedTextureIdentities: [ObjectIdentifier] = []
    private(set) var receivedDisplayScales: [Double] = []
    private(set) var submissions: [Submission] = []
    private(set) var sizeInvalidationCount = 0
    private(set) var derivedCacheResetCount = 0
    private(set) var maximumUncompletedSubmissionCount = 0

    var submissionCount: Int { submissions.count }

    func submit(
        _ scene: MetalCompiledScene,
        drawable: MetalDisplayLinkDrawable,
        displayScale: Double,
        completion: @escaping @MainActor (MetalFrameCommandResult) -> Void,
        presentation: @escaping @MainActor (MetalNativePresentationEvent) -> Void
    ) throws {
        attemptedGenerations.append(scene.previewGeneration)
        receivedDrawableIdentities.append(drawable.identity)
        receivedTextureIdentities.append(ObjectIdentifier(drawable.texture as AnyObject))
        receivedDisplayScales.append(displayScale)
        if let nextSubmissionError {
            self.nextSubmissionError = nil
            throw nextSubmissionError
        }
        submissions.append(Submission(completion: completion, presentation: presentation))
        maximumUncompletedSubmissionCount = max(
            maximumUncompletedSubmissionCount,
            submissions.filter { !$0.isComplete }.count
        )
    }

    func invalidateSizeDependentResources() {
        sizeInvalidationCount += 1
    }

    func resetDerivedRenderCaches() {
        derivedCacheResetCount += 1
    }

    func completeSubmission(at index: Int) {
        guard !submissions[index].isComplete else { return }
        submissions[index].isComplete = true
        submissions[index].completion(.completed)
    }

    func completeSubmissionAgain(at index: Int) {
        submissions[index].completion(.completed)
    }

    func failSubmission(at index: Int, error: MetalCanvasError) {
        submissions[index].isComplete = true
        submissions[index].completion(.failed(error, .permanent))
    }

    func presentSubmission(at index: Int, presentedTime: TimeInterval) {
        submissions[index].presentation(
            MetalNativePresentationEvent(
                presentedTime: presentedTime,
                isNativePresentation: true
            )
        )
    }
}

@MainActor
private final class TestMetalDisplayLinkController: MetalDisplayLinkControlling {
    private let update: (MetalDisplayLinkDrawable) -> Void
    private(set) var startCount = 0
    private(set) var pauseCount = 0
    private(set) var updateCallbackCount = 0
    private(set) var isInvalidated = false
    private(set) var isPaused = true

    init(update: @escaping (MetalDisplayLinkDrawable) -> Void) {
        self.update = update
    }

    func start() {
        startCount += 1
        isPaused = false
    }

    func pause() {
        pauseCount += 1
        isPaused = true
    }

    func invalidate() {
        isInvalidated = true
        isPaused = true
    }
    func emit(_ drawable: MetalDisplayLinkDrawable) {
        updateCallbackCount += 1
        update(drawable)
    }
}

private final class TestPresentedHandlerProbe: NSObject {
    private var handler: ((AnyObject) -> Void)?
    var presentedTime: TimeInterval = 0

    @objc(addPresentedHandler:)
    func addPresentedHandler(_ handler: @escaping (AnyObject) -> Void) {
        self.handler = handler
    }

    func present() {
        handler?(self)
    }
}

@MainActor
private extension MetalFrameSchedulerTests {
    struct DrawableFixture {
        let identityObject: NSObject
        let texture: any MTLTexture
        let drawable: MetalDisplayLinkDrawable

        var identity: ObjectIdentifier { ObjectIdentifier(identityObject) }
    }

    func requiredMetalDevice(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> any MTLDevice {
        try XCTUnwrap(
            MTLCreateSystemDefaultDevice(),
            "The iOS Simulator must provide a Metal device",
            file: file,
            line: line
        )
    }

    func makeSceneBackedWindow() -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return makeWindow(in: scene)
        }
        let scene = class_createInstance(UIWindowScene.self, 0) as! UIWindowScene
        return makeWindow(in: scene)
    }

    func makeWindow(in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        return window
    }

    func makeDrawable(
        width: Int = 100,
        height: Int = 80,
        callbackTimestamp: TimeInterval = 0,
        targetTimestamp: TimeInterval = 0,
        targetPresentationTimestamp: TimeInterval = 0
    ) throws -> DrawableFixture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(requiredMetalDevice().makeTexture(descriptor: descriptor))
        let identityObject = NSObject()
        return DrawableFixture(
            identityObject: identityObject,
            texture: texture,
            drawable: MetalDisplayLinkDrawable(
                nativeDrawable: identityObject,
                texture: texture,
                callbackTimestamp: callbackTimestamp,
                targetTimestamp: targetTimestamp,
                targetPresentationTimestamp: targetPresentationTimestamp,
                present: { _ in }
            )
        )
    }

    func makeOwnedView(
        scheduler: MetalFrameScheduler,
        displayLinkFactory: MetalDisplayLinkFactory? = nil
    ) throws -> MetalCanvasRenderView {
        MetalCanvasRenderView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80),
            device: try requiredMetalDevice(),
            scheduler: scheduler,
            owner: NSObject(),
            displayLinkFactory: displayLinkFactory
        )
    }

    func generation(_ value: UInt64) -> RecognitionGeneration {
        RecognitionGeneration(words: [value])
    }

    func scene(_ value: UInt64?) -> MetalCompiledScene {
        MetalCompiledScene(
            background: SIMD4<Float>(0, 0, 0, 1),
            items: [],
            viewport: try! .identity(size: .init(width: 100, height: 80)),
            previewGeneration: value.map(generation)
        )
    }
}
