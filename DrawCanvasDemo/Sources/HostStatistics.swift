import Observation
import Foundation
import DrawCanvasCore

protocol CanvasPayloadCounting: Sendable {
    func count(_ document: CanvasDocument) async -> Int?
}

struct CanvasPayloadCounter: CanvasPayloadCounting {
    nonisolated func count(_ document: CanvasDocument) async -> Int? {
        try? CanvasDocumentCodec.encodeString(document).utf8.count
    }
}

@MainActor
@Observable
final class HostStatistics {
    private(set) var revision: UInt64 = 0
    private(set) var elementCount = 0
    private(set) var payloadByteCount: Int?
    private(set) var callbackCount = 0

    @ObservationIgnored private let counter: any CanvasPayloadCounting
    @ObservationIgnored private var encodingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(counter: any CanvasPayloadCounting = CanvasPayloadCounter()) {
        self.counter = counter
    }

    var payloadDescription: String {
        payloadByteCount.map { "\($0) UTF-8 bytes" } ?? "Payload pending"
    }

    func update(from document: CanvasDocument, countAsCallback: Bool) {
        revision = document.revision
        elementCount = document.elements.count
        if countAsCallback { callbackCount += 1 }

        encodingTask?.cancel()
        let generation = UUID()
        self.generation = generation
        let counter = self.counter
        encodingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let count = await counter.count(document)
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.payloadByteCount = count
        }
    }

    func finishPendingWork() async {
        await encodingTask?.value
    }
}
