import XCTest
import DrawCanvasCore
import DrawCanvasUI
@testable import DrawCanvasDemo

@MainActor
final class HostThemeAndStatisticsTests: XCTestCase {
    func testDarkThemeChangesCreationStylesWithoutRewritingExistingElements() throws {
        let existing = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 0, y: 0, width: 20, height: 20),
            style: .default
        )
        let session = try CanvasSession(document: .init(elements: [existing]))
        let styles = HostTheme.dark.creationStyles

        try session.setStrokeStyle(styles.stroke)
        try session.setTextStyle(styles.text)

        XCTAssertEqual(session.strokeStyle, styles.stroke)
        XCTAssertEqual(session.textStyle, styles.text)
        XCTAssertNotEqual(styles.stroke.stroke, .black)
        XCTAssertNotEqual(styles.text.color, .black)
        XCTAssertEqual(session.document.elements[0].style, existing.style)
    }

    func testStalePayloadStatisticCannotReplaceNewerGeneration() async throws {
        let counter = ControlledPayloadCounter()
        let statistics = HostStatistics(counter: counter)
        let large = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 0, y: 0, width: 10, height: 10)),
            .rectangle(id: UUID(), rect: .init(x: 20, y: 0, width: 10, height: 10)),
        ])
        let small = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 0, y: 0, width: 10, height: 10)),
        ])

        statistics.update(from: large, countAsCallback: false)
        try await Task.sleep(for: .milliseconds(120))
        statistics.update(from: small, countAsCallback: false)
        try await Task.sleep(for: .milliseconds(120))
        await counter.completeNewestFirst()
        await statistics.finishPendingWork()

        XCTAssertEqual(statistics.elementCount, 1)
        XCTAssertEqual(statistics.payloadByteCount, 1)
    }
}

private actor ControlledPayloadCounter: CanvasPayloadCounting {
    private var pending: [(Int, CheckedContinuation<Int?, Never>)] = []

    func count(_ document: CanvasDocument) async -> Int? {
        await withCheckedContinuation { continuation in
            pending.append((document.elements.count, continuation))
        }
    }

    func completeNewestFirst() {
        for item in pending.reversed() {
            item.1.resume(returning: item.0)
        }
        pending.removeAll()
    }
}
