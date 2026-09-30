public struct StrokeSample: Hashable, Sendable {
    public var points: [CanvasPoint]

    public init(points: [CanvasPoint]) {
        self.points = points
    }
}

public struct RecognitionResult: Hashable, Sendable {
    public var geometry: CanvasGeometry
    public var confidence: Double

    public init(geometry: CanvasGeometry, confidence: Double) {
        self.geometry = geometry
        self.confidence = confidence
    }
}

public protocol ShapeRecognizing: Sendable {
    func recognize(_ sample: StrokeSample) -> RecognitionResult?
}
