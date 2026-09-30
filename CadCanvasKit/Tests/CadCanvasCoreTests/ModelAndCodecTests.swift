import XCTest
@testable import CadCanvasCore

final class ModelAndCodecTests: XCTestCase {
    func testVersionTwoRoundTripIsDeterministic() throws {
        let line = CanvasElement(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            geometry: .line(.init(start: .init(x: 10, y: 20), end: .init(x: 110, y: 20))),
            style: .init(stroke: .black, lineWidth: 2)
        )
        let document = CanvasDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            elements: [line],
            calibration: .init(millimetersPerPoint: 50.0 / 15.0)
        )

        let first = try CanvasDocumentCodec.encode(document)
        let decoded = try CanvasDocumentCodec.decode(first)
        let second = try CanvasDocumentCodec.encode(decoded)

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.elements.first?.id, line.id)
    }

    func testStringCodecRoundTripsDocument() throws {
        let document = CanvasDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            revision: 7,
            calibration: .init(millimetersPerPoint: 2.5)
        )

        let encoded = try CanvasDocumentCodec.encodeString(document)
        let decoded = try CanvasDocumentCodec.decode(encoded)

        XCTAssertEqual(encoded, String(data: try CanvasDocumentCodec.encode(document), encoding: .utf8))
        XCTAssertEqual(decoded.id, document.id)
        XCTAssertEqual(decoded.revision, 7)
        XCTAssertEqual(decoded.calibration, document.calibration)
    }

    func testAllGeometryVariantsRoundTrip() throws {
        let samples: [CanvasInkSample] = [
            .init(point: .init(x: 1, y: 2), pressure: 0.25),
            .init(point: .init(x: 3, y: 4), pressure: 0.75),
        ]
        let elements = [
            CanvasElement(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 10, y: 10)))
            ),
            CanvasElement.rectangle(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                rect: .init(x: 10, y: 20, width: 30, height: 40),
                style: .init(
                    stroke: .black,
                    fill: .init(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.8),
                    lineWidth: 3
                )
            ),
            CanvasElement(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
                geometry: .arch(.init(start: .init(x: 0, y: 50), end: .init(x: 100, y: 50), sagitta: 25))
            ),
            CanvasElement(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
                geometry: .freehand(.init(samples: samples, pressureEnabled: true))
            ),
            CanvasElement(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!,
                geometry: .text(
                    .init(
                        frame: .init(x: 12, y: 34, width: 70, height: 20),
                        text: "Canvas",
                        font: .init(familyName: "Helvetica", pointSize: 16),
                        color: .init(red: 0.1, green: 0.2, blue: 0.3)
                    )
                )
            ),
        ]
        let document = CanvasDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            elements: elements
        )

        let first = try CanvasDocumentCodec.encode(document)
        let decoded = try CanvasDocumentCodec.decode(first)

        XCTAssertEqual(decoded.elements.map(\.geometry), elements.map(\.geometry))
        XCTAssertEqual(decoded.elements.map(\.style), elements.map(\.style))
        guard case .freehand(let stroke) = decoded.elements[3].geometry else {
            return XCTFail("Expected freehand geometry at index 3")
        }
        XCTAssertEqual(stroke.samples, samples)
        XCTAssertTrue(stroke.pressureEnabled)
        XCTAssertEqual(stroke.widthMode, .canvasScaled)
        XCTAssertEqual(try CanvasDocumentCodec.encode(decoded), first)
    }

    func testFreehandWidthModeRoundTripsAndMissingModeDefaultsToCanvasScaled() throws {
        let samples = [
            CanvasInkSample(point: .init(x: 1, y: 2), pressure: 0.3),
            CanvasInkSample(point: .init(x: 3, y: 4), pressure: 1),
        ]
        let stroke = CanvasInkStroke(
            samples: samples,
            pressureEnabled: true,
            widthMode: .screenConstant
        )

        let encoded = try JSONEncoder().encode(stroke)
        let decoded = try JSONDecoder().decode(CanvasInkStroke.self, from: encoded)
        let missing = try JSONDecoder().decode(
            CanvasInkStroke.self,
            from: Data(#"{"samples":[{"point":{"x":1,"y":2},"pressure":0.3}],"pressureEnabled":true}"#.utf8)
        )

        XCTAssertEqual(decoded, stroke)
        XCTAssertEqual(decoded.widthMode, .screenConstant)
        XCTAssertEqual(missing.widthMode, .canvasScaled)
    }

    func testDecodeRejectsUnsupportedVersionWithoutReturningEmptyDocument() throws {
        let data = Data(#"{"schemaVersion":99,"id":"00000000-0000-0000-0000-000000000010","revision":0,"elements":[],"calibration":{"millimetersPerPoint":1}}"#.utf8)
        XCTAssertThrowsError(try CanvasDocumentCodec.decode(data)) { error in
            XCTAssertEqual(error as? CanvasDocumentCodec.Error, .unsupportedVersion(99))
        }
    }

    func testMalformedJSONAndInvalidEnumAreTypedFailures() {
        XCTAssertEqual(
            captureCodecError(Data("not-json".utf8)),
            .malformedDocument
        )
        let invalidGeometry = Data(#"{"schemaVersion":2,"id":"00000000-0000-0000-0000-000000000010","revision":0,"elements":[{"id":"00000000-0000-0000-0000-000000000001","contentRevision":0,"geometry":{"type":"triangle"},"style":{"stroke":{"red":0,"green":0,"blue":0,"alpha":1},"lineWidth":1}}],"calibration":{"millimetersPerPoint":1}}"#.utf8)
        XCTAssertEqual(captureCodecError(invalidGeometry), .malformedDocument)
    }

    func testModelRejectsNonFiniteCoordinatesAndCalibration() {
        XCTAssertThrowsError(try CanvasPoint(validatingX: .infinity, y: 0))
        XCTAssertThrowsError(try CanvasCalibration(validatingMillimetersPerPoint: .nan))
        XCTAssertThrowsError(try CanvasCalibration(validatingMillimetersPerPoint: 0))
    }

    func testElementHashAndEqualityUseOnlyStableIdentity() {
        let id = UUID()
        let first = CanvasElement(id: id, geometry: .rectangle(.init(rect: .init(x: 0, y: 0, width: 10, height: 10))), style: .default)
        let second = CanvasElement(id: id, geometry: .rectangle(.init(rect: .init(x: 50, y: 50, width: 20, height: 20))), style: .default)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    func testVersionTwoFixtureCoversEveryPersistedVariant() throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "document-v2", withExtension: "json"))
        let fixture = try Data(contentsOf: fixtureURL)
        let document = try CanvasDocumentCodec.decode(fixture)

        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(document.elements.map(\.geometry.kind), [.line, .rectangle, .arch, .freehand, .text])
        let canonicalFixture = fixture.last == 10 ? Data(fixture.dropLast()) : fixture
        XCTAssertEqual(try CanvasDocumentCodec.encode(document), canonicalFixture)
    }

    func testVersionOneIsRejectedWithoutMigration() throws {
        let json = #"{"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001","revision":0,"elements":[],"calibration":{"millimetersPerPoint":1}}"#

        XCTAssertThrowsError(try CanvasDocumentCodec.decode(json)) { error in
            XCTAssertEqual(error as? CanvasDocumentCodec.Error, .unsupportedVersion(1))
        }
    }

    func testDocumentValidationIdentifiesInvalidFieldAndRejectsDuplicateIdentity() {
        let id = UUID()
        let invalidPoint = CanvasElement(
            id: id,
            geometry: .line(.init(start: .init(x: .infinity, y: 0), end: .init(x: 1, y: 1)))
        )
        XCTAssertTrue(captureInvalidDocumentMessage(.init(elements: [invalidPoint]))?.contains("elements[0].geometry.line.start.x") == true)

        let duplicate = CanvasElement.rectangle(id: id, rect: .init(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(captureInvalidDocumentMessage(.init(elements: [duplicate, duplicate]))?.contains("elements[1].id") == true)
    }

    func testDocumentValidationRejectsNonincrementableRevisions() {
        XCTAssertTrue(captureInvalidDocumentMessage(.init(revision: .max))?.contains("revision") == true)

        let element = CanvasElement(
            id: UUID(),
            contentRevision: .max,
            geometry: .rectangle(.init(rect: .init(x: 0, y: 0, width: 1, height: 1)))
        )
        XCTAssertTrue(captureInvalidDocumentMessage(.init(elements: [element]))?.contains("elements[0].contentRevision") == true)
    }

    func testRectangleValidationReportsExactWidthField() {
        let element = CanvasElement.rectangle(
            id: UUID(),
            rect: .init(x: 0, y: 0, width: -1, height: 10)
        )

        assertInvalidDocument(
            .init(elements: [element]),
            equals: .invalidDocument("elements[0].geometry.rectangle.rect.width: must not be negative")
        )
    }

    func testArchValidationReportsExactSagittaField() {
        let element = CanvasElement(
            id: UUID(),
            geometry: .arch(.init(start: .init(x: 0, y: 0), end: .init(x: 10, y: 0), sagitta: .infinity))
        )

        assertInvalidDocument(
            .init(elements: [element]),
            equals: .invalidDocument("elements[0].geometry.arch.sagitta: must be finite")
        )
    }

    func testFreehandValidationReportsExactNestedSampleField() {
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(
                .init(
                    samples: [.init(point: .init(x: 3, y: .nan), pressure: 0.5)],
                    pressureEnabled: true
                )
            )
        )

        assertInvalidDocument(
            .init(elements: [element]),
            equals: .invalidDocument("elements[0].geometry.freehand.samples[0].point.y: must be finite")
        )
    }

    func testTextValidationReportsExactFrameField() {
        let element = makeTextElement(frame: .init(x: 0, y: 0, width: .infinity, height: 10))

        assertInvalidDocument(
            .init(elements: [element]),
            equals: .invalidDocument("elements[0].geometry.text.frame.width: must be finite")
        )
    }

    func testTextColorValidationReportsExactComponentField() {
        let element = makeTextElement(color: .init(red: 1.1, green: 0, blue: 0))

        assertInvalidDocument(
            .init(elements: [element]),
            equals: .invalidDocument("elements[0].geometry.text.color.red: must be between zero and one")
        )
    }

    func testTextFontValidationReportsExactPointSizeField() {
        let element = makeTextElement(font: .init(familyName: "Helvetica", pointSize: 0))

        assertInvalidDocument(
            .init(elements: [element]),
            equals: .invalidDocument("elements[0].geometry.text.font.pointSize: must be greater than zero")
        )
    }

    func testStyleValidationReportsExactLineWidthField() {
        let element = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1))),
            style: .init(stroke: .black, lineWidth: 0)
        )

        assertInvalidDocument(
            .init(elements: [element]),
            equals: .invalidDocument("elements[0].style.lineWidth: must be greater than zero")
        )
    }

    func testOptionalFillValidationReportsExactComponentField() {
        let element = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1))),
            style: .init(
                stroke: .black,
                fill: .init(red: 0, green: 0, blue: 0, alpha: -0.1),
                lineWidth: 1
            )
        )

        assertInvalidDocument(
            .init(elements: [element]),
            equals: .invalidDocument("elements[0].style.fill.alpha: must be between zero and one")
        )
    }

    private func captureCodecError(_ data: Data) -> CanvasDocumentCodec.Error? {
        do {
            _ = try CanvasDocumentCodec.decode(data)
            return nil
        } catch {
            return error as? CanvasDocumentCodec.Error
        }
    }

    private func captureInvalidDocumentMessage(_ document: CanvasDocument) -> String? {
        do {
            _ = try CanvasDocumentCodec.encode(document)
            return nil
        } catch CanvasDocumentCodec.Error.invalidDocument(let message) {
            return message
        } catch {
            return nil
        }
    }

    private func assertInvalidDocument(
        _ document: CanvasDocument,
        equals expected: CanvasDocumentCodec.Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try CanvasDocumentCodec.encode(document)
            XCTFail("Expected invalid document", file: file, line: line)
        } catch let error as CanvasDocumentCodec.Error {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected CanvasDocumentCodec.Error, got \(error)", file: file, line: line)
        }
    }

    private func makeTextElement(
        frame: CanvasRect = .init(x: 0, y: 0, width: 40, height: 16),
        font: CanvasFont = .init(familyName: "Helvetica", pointSize: 12),
        color: CanvasColor = .black
    ) -> CanvasElement {
        CanvasElement(
            id: UUID(),
            geometry: .text(.init(frame: frame, text: "Text", font: font, color: color))
        )
    }

}
