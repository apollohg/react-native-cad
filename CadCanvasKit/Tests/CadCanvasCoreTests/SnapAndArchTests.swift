import XCTest
@testable import CadCanvasCore

final class SnapAndArchTests: XCTestCase {
    func testShapeSnapUsesCanvasCoordinatesAtTwoTimesZoom() throws {
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 25, y: -10),
            viewportSize: .init(width: 1_000, height: 800)
        )
        let target = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 100, y: 100, width: 50, height: 50)
        )
        let candidateScreen = viewport.screenPoint(fromCanvas: .init(x: 103, y: 125))
        let candidateCanvas = viewport.canvasPoint(fromScreen: candidateScreen)

        let result = SnapEngine.snap(
            point: candidateCanvas,
            excluding: nil,
            elements: [target],
            viewport: viewport,
            configuration: .init(screenThreshold: 8, gridSpacing: 15, snapToGrid: true)
        )

        XCTAssertEqual(result.point.x, 100, accuracy: 0.000_001)
        XCTAssertEqual(result.point.y, 125, accuracy: 0.000_001)
        XCTAssertEqual(result.guides, [.vertical(canvasX: 100)])
    }

    func testScreenThresholdIsConvertedToCanvasDistanceExactlyOnce() throws {
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 300, y: -200),
            viewportSize: .init(width: 1_000, height: 800)
        )
        let target = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 100, y: 100, width: 50, height: 100)
        )

        let atThreshold = SnapEngine.snap(
            point: .init(x: 104, y: 150),
            excluding: nil,
            elements: [target],
            viewport: viewport,
            configuration: .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: false)
        )
        let beyondThreshold = SnapEngine.snap(
            point: .init(x: 104.000_001, y: 150),
            excluding: nil,
            elements: [target],
            viewport: viewport,
            configuration: .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: false)
        )

        XCTAssertEqual(atThreshold.point, CanvasPoint(x: 100, y: 150))
        XCTAssertEqual(atThreshold.guides, [.vertical(canvasX: 100)])
        XCTAssertEqual(beyondThreshold.point, CanvasPoint(x: 104.000_001, y: 150))
        XCTAssertTrue(beyondThreshold.guides.isEmpty)
    }

    func testCornerOrEndpointTakesPriorityOverNearerEdge() {
        let endpointTarget = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: -100, y: -100)))
        )
        let edgeTarget = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 2, y: 100, width: 50, height: 100)
        )

        let result = SnapEngine.snap(
            point: .init(x: 3, y: 4),
            excluding: nil,
            elements: [edgeTarget, endpointTarget],
            viewport: try! .identity(size: .init(width: 500, height: 500)),
            configuration: .init(screenThreshold: 6, gridSpacing: 10, snapToGrid: true)
        )

        XCTAssertEqual(result.point, CanvasPoint(x: 0, y: 0))
        XCTAssertEqual(
            result.guides,
            [.vertical(canvasX: 0), .horizontal(canvasY: 0)]
        )
    }

    func testNearestCornerIsChosenDeterministically() {
        let farther = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 10, y: 10), end: .init(x: 50, y: 50)))
        )
        let nearer = CanvasElement(
            id: UUID(),
            geometry: .arch(.init(start: .init(x: 12, y: 11), end: .init(x: 80, y: 80), sagitta: 5))
        )

        let result = SnapEngine.snap(
            point: .init(x: 13, y: 12),
            excluding: nil,
            elements: [farther, nearer],
            viewport: try! .identity(size: .init(width: 500, height: 500)),
            configuration: .init(screenThreshold: 10, gridSpacing: 10, snapToGrid: false)
        )

        XCTAssertEqual(result.point, CanvasPoint(x: 12, y: 11))
        XCTAssertEqual(
            result.guides,
            [.vertical(canvasX: 12), .horizontal(canvasY: 11)]
        )
    }

    func testNearestBoundsEdgesSnapBothAxesAndPrecedeGrid() {
        let target = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 100, y: 100, width: 100, height: 100)
        )

        let result = SnapEngine.snap(
            point: .init(x: 104, y: 196),
            excluding: nil,
            elements: [target],
            viewport: try! .identity(size: .init(width: 500, height: 500)),
            configuration: .init(screenThreshold: 5, gridSpacing: 25, snapToGrid: true)
        )

        XCTAssertEqual(result.point, CanvasPoint(x: 100, y: 200))
        XCTAssertEqual(
            result.guides,
            [.vertical(canvasX: 100), .horizontal(canvasY: 200)]
        )
    }

    func testExcludedElementCannotContributeSnapTargets() {
        let selectedID = UUID()
        let selected = CanvasElement.rectangle(
            id: selectedID,
            rect: .init(x: 11, y: 11, width: 20, height: 20)
        )

        let result = SnapEngine.snap(
            point: .init(x: 12, y: 12),
            excluding: selectedID,
            elements: [selected],
            viewport: try! .identity(size: .init(width: 500, height: 500)),
            configuration: .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: true)
        )

        XCTAssertEqual(result.point, CanvasPoint(x: 10, y: 10))
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testGridFallbackSnapsBothAxesWithoutAlignmentGuides() {
        let result = SnapEngine.snap(
            point: .init(x: 16, y: 29),
            excluding: nil,
            elements: [],
            viewport: try! .identity(size: .init(width: 500, height: 500)),
            configuration: .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: true)
        )

        XCTAssertEqual(result.point, CanvasPoint(x: 20, y: 30))
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testInvalidSnapInputsReturnFiniteSafePointsWithoutGuides() {
        let invalidElement = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: .infinity, y: 0, width: 10, height: 10)
        )
        let viewport = try! CanvasViewport.identity(size: .init(width: 500, height: 500))

        for configuration in [
            SnapConfiguration(screenThreshold: .nan, gridSpacing: 0, snapToGrid: true),
            SnapConfiguration(screenThreshold: -1, gridSpacing: .infinity, snapToGrid: true),
            SnapConfiguration(screenThreshold: .infinity, gridSpacing: .nan, snapToGrid: true),
        ] {
            let result = SnapEngine.snap(
                point: .init(x: 12, y: 13),
                excluding: nil,
                elements: [invalidElement],
                viewport: viewport,
                configuration: configuration
            )
            XCTAssertEqual(result.point, CanvasPoint(x: 12, y: 13))
            XCTAssertTrue(result.guides.isEmpty)
            XCTAssertTrue(result.point.x.isFinite)
            XCTAssertTrue(result.point.y.isFinite)
        }

        for (input, expected) in [
            (CanvasPoint(x: .nan, y: 13), CanvasPoint(x: 0, y: 13)),
            (CanvasPoint(x: 12, y: .infinity), CanvasPoint(x: 12, y: 0)),
            (CanvasPoint(x: -.infinity, y: .nan), CanvasPoint(x: 0, y: 0)),
        ] {
            let result = SnapEngine.snap(
                point: input,
                excluding: nil,
                elements: [],
                viewport: viewport,
                configuration: .init(screenThreshold: 8, gridSpacing: 10, snapToGrid: true)
            )
            XCTAssertEqual(result.point, expected)
            XCTAssertTrue(result.point.x.isFinite)
            XCTAssertTrue(result.point.y.isFinite)
            XCTAssertTrue(result.guides.isEmpty)
        }
    }

    func testInfiniteThresholdDisablesShapeSnapSafely() {
        let target = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 10, y: 10, width: 20, height: 20)
        )
        let candidate = CanvasPoint(x: 12, y: 15)
        let infiniteThreshold = SnapEngine.snap(
            point: candidate,
            excluding: nil,
            elements: [target],
            viewport: try! .identity(size: .init(width: 500, height: 500)),
            configuration: .init(screenThreshold: .infinity, gridSpacing: 10, snapToGrid: false)
        )
        XCTAssertEqual(infiniteThreshold.point, candidate)
        XCTAssertTrue(infiniteThreshold.point.x.isFinite)
        XCTAssertTrue(infiniteThreshold.point.y.isFinite)
        XCTAssertTrue(infiniteThreshold.guides.isEmpty)
    }

    func testSlopedArchMeetsBothEndpoints() throws {
        let arch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 100, y: 100),
            sagitta: 50
        )

        let parameters = try ArchGeometry.parameters(for: arch)

        XCTAssertEqual(parameters.startPoint.x, arch.start.x, accuracy: 0.000_001)
        XCTAssertEqual(parameters.startPoint.y, arch.start.y, accuracy: 0.000_001)
        XCTAssertEqual(parameters.endPoint.x, arch.end.x, accuracy: 0.000_001)
        XCTAssertEqual(parameters.endPoint.y, arch.end.y, accuracy: 0.000_001)
        XCTAssertEqual(parameters.center.distance(to: arch.start), parameters.radius, accuracy: 0.000_001)
        XCTAssertEqual(parameters.center.distance(to: arch.end), parameters.radius, accuracy: 0.000_001)
        XCTAssertEqual(parameters.center.x, 67.677_669_53, accuracy: 0.000_001)
        XCTAssertEqual(parameters.center.y, 32.322_330_47, accuracy: 0.000_001)
        XCTAssertEqual(parameters.radius, 75, accuracy: 0.000_001)
    }

    func testSignedSagittaChoosesSweepThroughApex() throws {
        let positive = try ArchGeometry.parameters(
            for: .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25)
        )
        let negative = try ArchGeometry.parameters(
            for: .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: -25)
        )

        XCTAssertEqual(positive.center, CanvasPoint(x: 50, y: -37.5))
        XCTAssertEqual(positive.apex, CanvasPoint(x: 50, y: 25))
        XCTAssertLessThan(positive.sweepAngle, 0)
        XCTAssertEqual(negative.center, CanvasPoint(x: 50, y: 37.5))
        XCTAssertEqual(negative.apex, CanvasPoint(x: 50, y: -25))
        XCTAssertGreaterThan(negative.sweepAngle, 0)

        for parameters in [positive, negative] {
            let apexAngle = atan2(
                parameters.apex.y - parameters.center.y,
                parameters.apex.x - parameters.center.x
            )
            XCTAssertTrue(parameters.contains(angle: apexAngle))
            XCTAssertEqual(parameters.center.distance(to: parameters.apex), parameters.radius, accuracy: 0.000_001)
        }
    }

    func testMinorAndMajorArchBoundsIncludeOnlyCardinalsInSweep() throws {
        let minorPositive = try ArchGeometry.bounds(
            for: .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25)
        )
        let minorNegative = try ArchGeometry.bounds(
            for: .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: -25)
        )
        let major = try ArchGeometry.bounds(
            for: .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 100)
        )

        assertRect(minorPositive, equals: .init(x: 0, y: 0, width: 100, height: 25))
        assertRect(minorNegative, equals: .init(x: 0, y: -25, width: 100, height: 25))
        assertRect(major, equals: .init(x: -12.5, y: 0, width: 125, height: 100))
    }

    func testShallowSignedSagittasRemainMinorArcsWithTinyBounds() throws {
        let sagitta = 1e-12
        let expectedSweepMagnitude = 4 * atan2(sagitta, 50)
        let positiveArch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 100, y: 0),
            sagitta: sagitta
        )
        let negativeArch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 100, y: 0),
            sagitta: -sagitta
        )

        let positive = try ArchGeometry.parameters(for: positiveArch)
        let negative = try ArchGeometry.parameters(for: negativeArch)
        let positiveBounds = try ArchGeometry.bounds(for: positiveArch)
        let negativeBounds = try ArchGeometry.bounds(for: negativeArch)

        XCTAssertEqual(positive.sweepAngle, -expectedSweepMagnitude, accuracy: 1e-26)
        XCTAssertEqual(negative.sweepAngle, expectedSweepMagnitude, accuracy: 1e-26)
        XCTAssertLessThan(abs(positive.sweepAngle), Double.pi)
        XCTAssertLessThan(abs(negative.sweepAngle), Double.pi)
        XCTAssertEqual(positiveBounds.x, 0, accuracy: 1e-12)
        XCTAssertEqual(positiveBounds.y, 0, accuracy: 1e-24)
        XCTAssertEqual(positiveBounds.width, 100, accuracy: 1e-12)
        XCTAssertEqual(positiveBounds.height, sagitta, accuracy: 1e-24)
        XCTAssertEqual(negativeBounds.x, 0, accuracy: 1e-12)
        XCTAssertEqual(negativeBounds.y, -sagitta, accuracy: 1e-24)
        XCTAssertEqual(negativeBounds.width, 100, accuracy: 1e-12)
        XCTAssertEqual(negativeBounds.height, sagitta, accuracy: 1e-24)
    }

    func testShallowRotatedArchExcludesNearbyCardinalOutsideSweep() throws {
        let rotation = 5e-13
        let arch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 100 * cos(rotation), y: 100 * sin(rotation)),
            sagitta: 1e-12
        )

        let bounds = try ArchGeometry.bounds(for: arch)

        XCTAssertEqual(bounds.x, 0, accuracy: 1e-12)
        XCTAssertEqual(bounds.y, 0, accuracy: 1e-20)
        XCTAssertEqual(bounds.width, arch.end.x, accuracy: 1e-12)
        XCTAssertEqual(bounds.height, arch.end.y, accuracy: 1e-20)
    }

    func testHugeRepresentableSagittaProducesFiniteRadiusAndMajorSweep() throws {
        let arch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 100, y: 0),
            sagitta: 1e200
        )

        let parameters = try ArchGeometry.parameters(for: arch)

        XCTAssertTrue(parameters.radius.isFinite)
        XCTAssertEqual(parameters.radius, 5e199, accuracy: 5e185)
        XCTAssertTrue(parameters.center.x.isFinite)
        XCTAssertTrue(parameters.center.y.isFinite)
        XCTAssertTrue(parameters.apex.x.isFinite)
        XCTAssertTrue(parameters.apex.y.isFinite)
        XCTAssertLessThan(parameters.sweepAngle, -Double.pi)
    }

    func testSubnormalChordAndSagittaProduceNearestRepresentableRadius() throws {
        let unit = Double.leastNonzeroMagnitude
        let chordLength = 4 * unit
        let arch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: chordLength, y: 0),
            sagitta: unit
        )
        let normalizedChord = 1.0
        let normalizedSagitta = 0.25
        let normalizedRadius = (
            normalizedSagitta * normalizedSagitta
                + normalizedChord * normalizedChord / 4
        ) / (2 * normalizedSagitta)
        let expectedRadius = chordLength * normalizedRadius

        let parameters = try ArchGeometry.parameters(for: arch)

        XCTAssertTrue(parameters.radius.isFinite)
        XCTAssertGreaterThan(parameters.radius, 0)
        XCTAssertEqual(parameters.radius, expectedRadius)
        XCTAssertEqual(expectedRadius, 2 * unit)
    }

    func testSubnormalRadiusTermsAreCombinedBeforeRounding() throws {
        let unit = Double.leastNonzeroMagnitude
        let arch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 2 * unit, y: 0),
            sagitta: unit
        )

        let parameters = try ArchGeometry.parameters(for: arch)

        XCTAssertTrue(parameters.radius.isFinite)
        XCTAssertEqual(parameters.radius, unit)
    }

    func testSubnormalMajorSweepPreservesRatioAndExactCardinalBounds() throws {
        let unit = Double.leastNonzeroMagnitude
        let positiveArch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: unit, y: 0),
            sagitta: 2 * unit
        )
        let negativeArch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: unit, y: 0),
            sagitta: -2 * unit
        )
        let expectedSweepMagnitude = 4 * atan2(1.0, 0.25)

        let positive = try ArchGeometry.parameters(for: positiveArch)
        let negative = try ArchGeometry.parameters(for: negativeArch)
        let positiveBounds = try ArchGeometry.bounds(for: positiveArch)
        let negativeBounds = try ArchGeometry.bounds(for: negativeArch)

        XCTAssertEqual(positive.sweepAngle, -expectedSweepMagnitude)
        XCTAssertEqual(negative.sweepAngle, expectedSweepMagnitude)
        XCTAssertTrue(positive.clockwise)
        XCTAssertFalse(negative.clockwise)
        for cardinal in [0.0, Double.pi / 2, Double.pi, Double.pi * 3 / 2] {
            XCTAssertTrue(positive.contains(angle: cardinal))
            XCTAssertTrue(negative.contains(angle: cardinal))
        }
        XCTAssertEqual(positiveBounds.x, -unit)
        XCTAssertEqual(positiveBounds.y, 0)
        XCTAssertEqual(positiveBounds.width, 2 * unit)
        XCTAssertEqual(positiveBounds.height, 2 * unit)
        XCTAssertEqual(negativeBounds.x, -unit)
        XCTAssertEqual(negativeBounds.y, -2 * unit)
        XCTAssertEqual(negativeBounds.width, 2 * unit)
        XCTAssertEqual(negativeBounds.height, 2 * unit)
    }

    func testMixedScaleChordAndSubnormalSagittaProduceFiniteGeometry() throws {
        let chordLength = 1e-10
        let sagitta = Double.leastNonzeroMagnitude
        let arch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: chordLength, y: 0),
            sagitta: sagitta
        )
        let expectedRadius = 2.530_028_166_341_382_6e302
        let radiusRelativeTolerance = 8 * Double.ulpOfOne
        let expectedSweep = -4 * atan2(sagitta, chordLength / 2)

        let parameters = try ArchGeometry.parameters(for: arch)
        let bounds = try ArchGeometry.bounds(for: arch)

        XCTAssertTrue(parameters.radius.isFinite)
        XCTAssertGreaterThan(parameters.radius, 0)
        XCTAssertEqual(
            parameters.radius,
            expectedRadius,
            accuracy: expectedRadius * radiusRelativeTolerance
        )
        XCTAssertLessThan(parameters.sweepAngle, 0)
        XCTAssertEqual(parameters.sweepAngle, expectedSweep)
        XCTAssertTrue(parameters.clockwise)
        XCTAssertTrue(bounds.isFinite)
        XCTAssertEqual(bounds.x, 0)
        XCTAssertEqual(bounds.y, 0)
        XCTAssertEqual(bounds.width, chordLength)
        XCTAssertEqual(bounds.height, sagitta)
    }

    func testSlopedArchBoundsIncludeCardinalExtremaInSweep() throws {
        let bounds = try ArchGeometry.bounds(
            for: .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 100), sagitta: 50)
        )

        assertRect(
            bounds,
            equals: .init(
                x: -7.322_330_47,
                y: 0,
                width: 107.322_330_47,
                height: 107.322_330_47
            )
        )
    }

    func testPathDescriptionUsesExactChosenSweep() throws {
        let arch = CanvasArch(
            start: .init(x: 10, y: 20),
            end: .init(x: 80, y: 110),
            sagitta: -30
        )
        let parameters = try ArchGeometry.parameters(for: arch)

        let path = try ArchGeometry.pathDescription(for: arch)

        XCTAssertEqual(path.moveTo, arch.start)
        XCTAssertEqual(path.center, parameters.center)
        XCTAssertEqual(path.radius, parameters.radius)
        XCTAssertEqual(path.startAngle, parameters.startAngle)
        XCTAssertEqual(path.endAngle, parameters.endAngle)
        XCTAssertEqual(path.clockwise, parameters.sweepAngle < 0)
        XCTAssertEqual(
            path.center.x + cos(path.endAngle) * path.radius,
            arch.end.x,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            path.center.y + sin(path.endAngle) * path.radius,
            arch.end.y,
            accuracy: 0.000_001
        )
    }

    func testArchGeometryRejectsDegenerateAndNonfiniteValuesWithTypedErrors() {
        assertArchError(
            .zeroLengthChord,
            for: .init(start: .init(x: 1, y: 1), end: .init(x: 1, y: 1), sagitta: 10)
        )
        assertArchError(
            .zeroSagitta,
            for: .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 0)
        )
        assertArchError(
            .nonFiniteInput,
            for: .init(start: .init(x: .nan, y: 0), end: .init(x: 100, y: 0), sagitta: 10)
        )
        assertArchError(
            .nonFiniteInput,
            for: .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: .infinity)
        )
        assertArchError(
            .nonFiniteResult,
            for: .init(
                start: .init(x: -Double.greatestFiniteMagnitude, y: 0),
                end: .init(x: Double.greatestFiniteMagnitude, y: 0),
                sagitta: 1
            )
        )
        assertArchError(
            .nonFiniteResult,
            for: .init(
                start: .init(x: 0, y: 0),
                end: .init(x: 100, y: 0),
                sagitta: Double.leastNonzeroMagnitude
            )
        )
    }

    func testCanvasGeometryUsesExactArchBoundsAndHitTesting() throws {
        let arch = CanvasArch(
            start: .init(x: 0, y: 0),
            end: .init(x: 100, y: 100),
            sagitta: 50
        )
        let geometry = CanvasGeometry.arch(arch)
        let parameters = try ArchGeometry.parameters(for: arch)

        assertRect(geometry.bounds, equals: try ArchGeometry.bounds(for: arch))
        XCTAssertEqual(geometry.renderPath.commands.first, .move(arch.start))
        XCTAssertTrue(geometry.hitTest(parameters.apex, tolerance: 0.000_001, textBounds: nil))
        XCTAssertFalse(
            geometry.hitTest(
                .init(x: parameters.center.x, y: parameters.center.y),
                tolerance: 0.000_001,
                textBounds: nil
            )
        )
    }

    private func assertRect(
        _ actual: CanvasRect,
        equals expected: CanvasRect,
        accuracy: Double = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func assertArchError(
        _ expected: ArchGeometryError,
        for arch: CanvasArch,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ArchGeometry.parameters(for: arch), file: file, line: line) { error in
            XCTAssertEqual(error as? ArchGeometryError, expected, file: file, line: line)
        }
    }
}
