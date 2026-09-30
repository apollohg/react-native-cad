import Foundation

public enum CanvasDocumentCodec {
    public enum Error: Swift.Error, Equatable {
        case malformedDocument
        case unsupportedVersion(Int)
        case invalidDocument(String)
    }

    public static func encode(_ document: CanvasDocument) throws -> Data {
        do {
            try document.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(document)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.invalidDocument(String(describing: error))
        }
    }

    public static func encodeString(_ document: CanvasDocument) throws -> String {
        guard let value = String(data: try encode(document), encoding: .utf8) else {
            throw Error.malformedDocument
        }
        return value
    }

    public static func decode(_ data: Data) throws -> CanvasDocument {
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).schemaVersion
        } catch {
            throw Error.malformedDocument
        }
        guard version == CanvasDocument.currentSchemaVersion else {
            throw Error.unsupportedVersion(version)
        }
        let document: CanvasDocument
        do {
            document = try decoder.decode(CanvasDocument.self, from: data)
        } catch {
            throw Error.malformedDocument
        }
        do {
            try document.validate()
            return document
        } catch {
            throw Error.invalidDocument(String(describing: error))
        }
    }

    public static func decode(_ string: String) throws -> CanvasDocument {
        guard let data = string.data(using: .utf8) else { throw Error.malformedDocument }
        return try decode(data)
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }
}
