import Foundation

private final class CanvasBundleAnchor {}

extension Bundle {
    static let module: Bundle = {
        let name = "CadCanvasShaders"
        let containers = [Bundle(for: CanvasBundleAnchor.self), Bundle.main]
        for container in containers {
            if let url = container.url(forResource: name, withExtension: "bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        // The renderer reports a shader-library failure and selects its fallback.
        return Bundle(for: CanvasBundleAnchor.self)
    }()
}
