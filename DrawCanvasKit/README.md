# DrawCanvasKit

DrawCanvasKit is an iOS 26 Swift package for an editable, dimension-aware drawing canvas. It exposes two library products:

- `DrawCanvasCore` contains the document model, geometry, commands and history, dimensions, recognition interfaces, and deterministic JSON codec.
- `DrawCanvasUI` contains the main-actor canvas session, UIKit-backed SwiftUI canvas, controls, dimension overlay, keyboard commands, and themes. It depends only on `DrawCanvasCore`.

The package requires Swift 6 and iOS 26. The standalone iPad host in `DrawCanvasDemo` enables complete strict concurrency checking and demonstrates package integration without an application backend.

Use the physical-device test host in `../DrawCanvasDemo` for renderer and interaction regression checks. Expo integration is documented in the repository root README.

## Add the package to an application

Choose one package source:

1. For a local checkout in Xcode, select **File > Add Package Dependencies > Add Local**, then select the `DrawCanvasKit` directory.
2. This package lives in a subdirectory of the Expo module repository; use the local checkout for Swift Package Manager integration.
3. Link `DrawCanvasCore` and `DrawCanvasUI` to the application target. A model-only or test target can link only `DrawCanvasCore`.
4. Import `DrawCanvasCore` where documents and the codec are used. Import `DrawCanvasUI` where the editor is hosted.

For a local Swift package manifest, the equivalent dependency is:

```swift
.package(path: "../DrawCanvasKit")
```

and the consuming target dependencies are:

```swift
.product(name: "DrawCanvasCore", package: "DrawCanvasKit"),
.product(name: "DrawCanvasUI", package: "DrawCanvasKit")
```

Keep package source outside the application's target membership. Consume the products; do not add files below `DrawCanvasKit/Sources` to an application Sources build phase.

## Create one session and host the editor

Keep one `CanvasSession` for the lifetime of a canvas screen. Create stable `CanvasActions` and `CanvasCommandActions` instances for that same session:

```swift
import DrawCanvasCore
import DrawCanvasUI
import SwiftUI

@MainActor
struct EditorView: View {
    @State private var session: CanvasSession
    @State private var actions: CanvasActions
    @State private var commandActions: CanvasCommandActions
    @State private var showsControls = true

    init() {
        let session = CanvasSession()
        _session = State(initialValue: session)
        _actions = State(initialValue: CanvasActions(session: session))
        _commandActions = State(initialValue: CanvasCommandActions(session: session))
    }

    var body: some View {
        ZStack {
            DrawCanvasView(commandActions: commandActions)
            DimensionOverlay(actions: actions)
        }
        .inspector(isPresented: $showsControls) {
            DrawCanvasControls(actions: actions)
                .inspectorColumnWidth(min: 320, ideal: 340, max: 380)
        }
        .canvasTheme(.default)
    }
}
```

`CanvasSession()` is the nonthrowing empty-editor path. If a caller already has an in-memory document, `try CanvasSession(document:)` validates the complete document before exposing the session. For downloaded or persisted JSON, keep the live empty session and use the atomic decode-and-replace boundary shown below.

`DrawCanvasView(session:)` is sufficient when the host does not need keyboard-command cancellation. Use `DrawCanvasView(commandActions:)` when the containing `Scene` also installs `CanvasKeyboardCommands(actions:)`; both must share the same `CanvasCommandActions` instance.

`CanvasSession.document` is always committed state. Encoding it during an active gesture or text edit returns the last committed document. Gesture, manipulation, freehand, and text drafts are owned preview transactions and never replace the public document before commit.

## Apple Pencil squeeze shortcuts and erasing

`CanvasSession.activeTool` is read-only. Change tools through `selectTool(_:)`; the built-in object eraser is available like every other tool:

```swift
session.selectTool(.eraser)
```

An eraser hover highlights the complete topmost element that will be removed. A continuous Pencil drag can collect lines, rectangles, arches, freehand strokes, and text; the full gesture commits as one Undo step and Undo/Redo preserves the original stacking order. Erasing never removes only part of a stroke.

`DrawCanvasView` honors the user's `UIPencilInteraction.preferredSqueezeAction`. The built-in defaults switch eraser/previous tools or toggle the requested color, ink-attribute, or contextual palette. **Ignore** performs no action, and **Run System Shortcut** remains exclusively system-owned so the package does not duplicate it.

A host may observe or replace actionable defaults without receiving UIKit types:

```swift
DrawCanvasView(
    commandActions: commandActions,
    pencilShortcutHandler: { context in
        analytics.record(context.action)
        return .useDefault // Return .handled to suppress the built-in action.
    }
)
```

The active and previous tools, Pencil hover target, pending shortcut, and visible palette are transient editor state. They are not encoded in `CanvasDocument`, and this feature does not add a schema migration.

`DrawCanvasView` uses `AdaptiveCanvasRenderer` by default. It selects the Metal renderer when the device supports it and falls back to Core Graphics after a typed initialization or runtime failure. Metal paths use analytic/SDF coverage, incremental active-ink updates, committed tiles, and a hard 64 MiB derived-resource cache ceiling.

Custom renderers conform to `CanvasRenderer` and consume backend-neutral `CanvasPreparedScene` values. Prepared geometry is model-space and identified by `resourceIdentity`; backends must not treat a reusable element ID or content revision as unique resource provenance. UIKit exclusively owns text layout, editing, selection, width resizing, and measured auto-fit height, so renderer implementations never receive text nodes.

Pencil input preserves every finite accepted sample in order. Confirmed samples are cumulative, predicted samples are replaceable and never persisted, and only newly drawn strokes use the current pressure setting. Pressure sensitivity defaults on and can be toggled with `session.setInkConfiguration(.init(pressureEnabled: false))`.

`DrawCanvasControls` and `DimensionOverlay` are optional. `DrawCanvasControls` owns its vertical scrolling and adapts its tool and action grids to Dynamic Type, so hosts should not wrap it in another scroll view or force a fixed width. A host may compose the smaller public control views or its own controls around `CanvasActions`, but it should not duplicate drawing behavior outside the package.

`DimensionOverlay` uses CAD-style chains along the bottom and right edges. Individual shape spans and gaps occupy the inner rows; combined spans and the overall measurement sit farther out. Coincident endpoints produce one shared, read-only dimension, not duplicate labels. Overlapping shapes with distinct endpoints retain their individual measurements and eligible edit actions. Labels follow Dynamic Type, rotate along vertical chains, and move clear of ticks when a span is too short. Offscreen endpoints do not acquire artificial ticks, and clipped spans retain their full measurement. When rows cannot fit, excess detail is omitted while reserving a row for the overall span; zooming or hiding dimensions can reveal the remaining detail.

## Configure creation styles, snapping, and themes

### Capabilities and built-in controls

Apply `CanvasConfiguration` to the session at creation (`try CanvasSession(configuration:)`)
or at runtime (`try session.setConfiguration(configuration)`). Defaults retain the full editor.
Invalid configuration is rejected atomically. Configuration is host UI policy, not saved document data.

```swift
var configuration = CanvasConfiguration()
configuration.enabledTools = [.select, .line, .rectangle, .freehand]
configuration.enabledFeatures.remove(.measurements)
configuration.enabledFeatures.remove(.shapeRecognition)
configuration.controls.visibleTools = [.freehand, .line, .rectangle, .select]
configuration.controls.visibleControls.remove(.clear)
configuration.controls.lineWidth = CanvasControlRange(0.5 ... 12, step: 0.5)
configuration.controls.buttonAppearance = .borderless
try session.setConfiguration(configuration)
```

`enabledTools` and `enabledFeatures` gate canvas input, built-in actions, keyboard commands,
Scribble, and Pencil shortcuts. Changing capabilities cancels the active draft and outstanding
recognition. Existing document content remains visible, including disabled element types.
An empty tool set prevents drawing and selection; panning and zooming are separately controlled.

`controls.visibleTools` sets tool order and visibility. `controls.visibleControls` hides individual
fields/actions without disabling their capabilities, allowing a host to supply custom controls.
Empty inspector sections disappear. The same visibility policy applies to Pencil palettes.
Control ranges/steps, font families, button appearance, and clear confirmation are configurable.
Ranges constrain built-in controls, not persisted geometry or trusted host setters.

Features cover measurements/editing/calibration, grid/snapping/recognition, pan/zoom,
selection movement/resizing, delete/duplicate/clear/history, creation styling, and Pencil shortcuts.
Grid visibility and snapping are independent; `showsSnapGuides`, `showsSelection`, and `showsEraserTarget` control overlays.
Set `measurements.axes`, `roles`, `showsExtensionLines`, and `allowsHiding` for dimension presentation.
`measurements.unit` supports mm/cm/m/in/ft; `fractionDigits` controls precision. Built-in dimension
editing and calibration convert the displayed unit back to the document's millimetre calibration.

Use `CanvasActions`/`CanvasCommandActions` for user-triggered operations. Direct session document
commands, loading, viewport setters, and creation-style setters remain trusted host APIs: restrictions
are not a security boundary. A read-only host can still load and display a server document.

### Appearance

`CanvasTheme` controls canvas background; minor/major/axis grid colours and widths;
selection outline, handles and dashes; snap guides; eraser highlight; dimension colours and widths;
and control spacing. `controlTint` and `inactiveToolTint` customise native control colours.
Nil control tints use platform defaults. Document stroke/fill/text colours remain document content;
changing the theme does not recolour saved elements.

```swift
var theme = CanvasTheme.dark
theme.controlTint = CanvasColor(red: 0.2, green: 0.8, blue: 0.6)
theme.dimensionStyle.extensionOpacity = 0.1
theme.dimensionStyle.labelColor = CanvasColor(red: 0.9, green: 0.9, blue: 0.7)
theme.dimensionStyle.labelFontSize = 13
// Apply .canvasTheme(theme) around both canvas and controls.
```

`dimensionStyle` also exposes label background/padding, extension colour/width/gaps/overshoot,
edge inset, lane and label spacing, and terminator size (zero hides terminators). Label measurements
and drawing use the same style, including Dynamic Type. Both Metal and Core Graphics consume the
same configured canvas appearance; UIKit owns text. Custom host chrome remains the host's responsibility.

The session's creation configuration is observable and read-only from outside the session. Custom controls update it through typed throwing setters; `CanvasActions` exposes equivalent delegating setters:

```swift
do {
    try session.setStrokeStyle(.init(
        stroke: .init(red: 0.92, green: 0.93, blue: 0.95),
        fill: nil,
        lineWidth: 2
    ))
    try session.setTextStyle(.init(
        font: .init(familyName: "Avenir Next", pointSize: 18),
        color: .init(red: 0.92, green: 0.93, blue: 0.95)
    ))
    try session.setSnapConfiguration(.init(
        screenThreshold: 8,
        gridSpacing: 20,
        snapToGrid: true
    ))
} catch let error as CanvasValidationError {
    // Present error.field and error.reason in the host UI.
} catch {
    // Handle any application-specific error policy.
}
```

`CanvasStyle.validate()`, `CanvasColor.validate()`, `CanvasFont.validate()`, `CanvasTextStyle.validate()`, and `SnapConfiguration.validate()` use the same public `CanvasValidationError` boundary. Invalid numbers, non-positive widths or font/grid sizes, and out-of-range color channels are rejected before assignment, so the last valid observable session state remains intact.

`CanvasTheme` styles editor chrome: canvas background, grid, selection, guides, dimensions, control spacing, and renderer metrics. It does not rewrite persisted `CanvasElement.style` or text colors. Those element colors travel with the document, while new elements use `session.strokeStyle` and `session.textStyle`. When switching to a dark theme, set contrasting creation styles deliberately, as in the example above. Grid rendering and snapping both take their spacing from `session.snapConfiguration`; the theme has no competing grid-spacing value.

## Observe committed document changes

`CanvasSession.onDocumentChange` reports committed document changes. It runs on the main actor. Capture the application owner weakly, update application state in one direction, and clear the callback when the owner disappears:

```swift
session.onDocumentChange = { [weak drawingStore] document in
    drawingStore?.canvasDocument = document
}

// When the observing screen disappears:
session.onDocumentChange = nil
```

Do not call `replaceDocument(_:)` from this callback. Doing so creates a session-to-host-to-session feedback loop.

## Upload the exact versioned JSON string

DrawCanvasKit persists schema version 2 only. Version-1 payloads are rejected and are not migrated.

`CanvasDocumentCodec.encodeString(_:)` validates the document and returns canonical schema-v2 JSON with deterministic sorted keys. Treat the returned `String` as an opaque handoff payload. Do not decode and rebuild it merely to transfer it.

Networking belongs to the host application:

```swift
protocol DrawingPayloadUploader {
    func uploadDrawingPayload(_ exactJSON: String) async throws
}

@MainActor
func saveDrawing(
    from session: CanvasSession,
    using uploader: any DrawingPayloadUploader
) async throws {
    let exactJSON = try CanvasDocumentCodec.encodeString(session.document)
    try await uploader.uploadDrawingPayload(exactJSON)
}
```

The host upload boundary must receive the exact codec string unchanged. DrawCanvasCore's deterministic codec tests verify byte-for-byte version-2 round trips, while the standalone host's Copy JSON action exposes that same public codec output for integration testing.

## Download and replace atomically

Decode and validate into a temporary document first. Replace the live session only after decoding succeeds:

```swift
@MainActor
func applyDownloadedPayload(
    _ exactJSON: String,
    to session: CanvasSession
) throws {
    let candidate = try CanvasDocumentCodec.decode(exactJSON)
    try session.replaceDocument(candidate)
}
```

If decoding fails, `replaceDocument(_:)` is never called and the live document remains unchanged. A successful replacement validates the candidate again, clears history and transient state, and emits one document-change notification.

Persist and transport the exact schema-v2 string. Unsupported versions and malformed JSON are typed codec errors. DrawCanvasKit performs no version-1 migration.

## Package boundary

DrawCanvasKit performs no HTTP requests, uploads, authentication, application persistence, or quote association. It has no dependency on OAQS, DjangoAPI, Apollo, Drops, SwiftyJSON, or SwiftSimplify. Final customer-facing graphic or PDF export is also outside this package.

The committed iPad-only `DrawCanvasDemo` consumes the local `DrawCanvasUI` product through its Xcode project. It has no application backend or domain-model dependency, and package source is never copied into the app target.

The previous OAQS application, backend client, quote workflow, classifier, tests, and legacy canvas implementation were deleted after the clean-room package and standalone host passed the automated acceptance matrix. Historical design records remain under `docs/` only as implementation history.

## Verification commands

Run the package commands from `DrawCanvasKit/`:

```bash
xcodebuild -scheme DrawCanvasKit-Package \
  -destination 'platform=iOS Simulator,name=iPad (A16)' test

xcodebuild -scheme DrawCanvasCore \
  -destination 'generic/platform=iOS Simulator' \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES build

xcodebuild -scheme DrawCanvasUI \
  -destination 'generic/platform=iOS Simulator' \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES build
```

Open and build the sole application from the repository root:

```bash
xcodebuild -project DrawCanvasDemo/DrawCanvasDemo.xcodeproj \
  -scheme DrawCanvasDemo \
  -destination 'platform=iOS Simulator,name=iPad (A16)' \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES build

xcodebuild -project DrawCanvasDemo/DrawCanvasDemo.xcodeproj \
  -scheme DrawCanvasDemo \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES build
```

For a signed hardware run, create the gitignored `DrawCanvasDemo/Config/Local.xcconfig`, set `DEVELOPMENT_TEAM`, select the connected iPad in Xcode, and press Run. See `DrawCanvasDemo/README.md` for the smoke checklist and physical-gate scheme.

The 2026-08-28 merged simulator result contains 608 tests: 606 passed and the two physical-only gates skipped as expected. The physical iPad interaction and Instruments matrix cannot be replaced by simulator evidence.
