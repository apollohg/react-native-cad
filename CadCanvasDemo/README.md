# CadCanvasDemo

`CadCanvasDemo` is the iPad-only hardware and integration demo for the local `CadCanvasKit` package. It has no login, backend, or remote persistence.

## Run on a connected iPad

Requirements: Xcode 26.6 or newer, an iPad running iOS 26 or newer, and an Apple Developer account available in Xcode.

1. Create `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = YOUR_TEAM_ID`.
2. Open `CadCanvasDemo.xcodeproj` in Xcode.
3. Connect and trust the iPad, select it as the run destination, and press Run.

`Config/Project.xcconfig` includes the local file optionally at project scope, so every target inherits the team without modifying `project.pbxproj`. Do not commit a development-team ID, provisioning profile, certificate, account identifier, or locally modified bundle identifier.

## Physical performance gates

Select the shared `CadCanvasPhysicalGate` scheme and a physical iPad with A16-or-later GPU capability, then choose Product > Test. The suite verifies the deterministic performance fixture, runs the performance regression tests (including the Core Graphics fallback benchmark), and runs three hardware gates. These exercise the default adaptive Metal renderer, require native drawable-presentation callbacks, retain every accepted synthetic Pencil sample, enforce the documented 60 Hz thresholds, and verify that committing a 30,000-sample stroke remains interactive. Simulator runs skip the three hardware gates.

Continuous drawing requires presentation intervals of at most 16.7 ms p95 and 33.4 ms maximum. Input-to-display latency permits 33.4 ms p95 and 50.1 ms maximum. The commit gate separately requires the initial long stroke and six equally sized subsequent strokes to present immediate follow-up input within 50.1 ms of Pencil-up. Repeated samples arrive at display cadence, and commit timing uses native drawable timestamps rather than waiting for the entire frame queue to drain.

## Demo workflows

The gear menu changes measurements, extension lines, units, grid, and snapping at runtime.
It also provides a read-only canvas preset and restores the full editor without changing the drawing.
The library additionally supports per-tool/control visibility, capability restrictions, control ranges,
and theme customisation; see [configuration documentation](../CadCanvasKit/README.md#capabilities-and-built-in-controls).

- Draw and edit lines, rectangles, arches, freehand paths, and text.
- Toggle pressure sensitivity for future freehand strokes; it is enabled by default.
- Select, move, resize, delete, undo, and redo.
- Inspect CAD-style dimension chains (individual spans, gaps, combined spans, and overall size), edit eligible dimensions, and adjust calibration.
- Copy exact version-2 JSON and atomically paste valid JSON. Version-1 payloads are rejected without migration.
- Exercise typed malformed/unsupported JSON failures without replacing the live document.
- Switch light/dark themes and load the deterministic stress document. Theme changes update creation colors but do not rewrite persisted element colors.
- Inspect revision, element-count, payload-size, and callback diagnostics inline on wide layouts or pinned beneath the inspector controls when canvas space is limited.
- Use Controls as a trailing inspector at regular width and as a native system sheet at compact width.
- Use the Eraser tool directly or exercise each Apple Pencil Pro squeeze preference selected in Settings. Built-in color, ink, and contextual palettes appear near the Pencil tip when the corresponding preference is selected.

## On-device smoke checklist

- [ ] Draw every supported geometry with touch and Apple Pencil.
- [ ] Select, move, resize, delete, undo, and redo mixed elements.
- [ ] Hide/show dimensions and perform eligible dimension edits.
- [ ] Copy JSON, paste the copied JSON, and confirm the document is preserved.
- [ ] Paste malformed JSON and confirm an error appears without document mutation.
- [ ] Switch light/dark themes and confirm controls and canvas remain legible.
- [ ] At regular width, open and close the trailing inspector and confirm the canvas uses the remaining space without overlap.
- [ ] Narrow the canvas column and confirm diagnostics move from above the canvas to the fixed bottom of the inspector without pushing the grid down; widen it and confirm they return inline.
- [ ] At compact width, confirm Controls remains reachable, opens the native system sheet, and returns to an unobstructed canvas when dismissed.
- [ ] At maximum Dynamic Type, confirm the inspector uses one-column grids, all sections remain vertically reachable, and no control clips horizontally.
- [ ] Load the deterministic stress document and continue editing without a crash.
- [ ] Insert and edit text with the keyboard and Apple Pencil Scribble.
- [ ] Resize text width through single-line and wrapped states and confirm height always auto-fits.
- [ ] Zoom until the visual grid decimates and confirm snapping still uses the configured base spacing.
- [ ] Exercise pointer hover/selection and keyboard commands when hardware is available.
- [ ] On Apple Pencil Pro, verify **Ignore** performs no app action and **Run System Shortcut** is not duplicated by the app.
- [ ] Verify **Switch Eraser** returns to the last non-eraser tool and **Switch Previous** swaps the two most recent tools.
- [ ] Verify color, ink-attribute, and contextual squeeze palettes toggle near the Pencil tip and remain inside safe bounds.
- [ ] Hover the eraser over line, rectangle, arch, freehand, and text elements; confirm the complete topmost target highlights without changing selection.
- [ ] Erase several mixed elements with one fast drag, cancel a second drag, then verify one-step Undo/Redo restores and removes the first group in its original stacking order.
- [x] Run the hosted physical renderer and long-stroke presentation gates and retain their XCTest evidence.
- [ ] Record Core Animation and Time Profiler evidence before marking the release gate complete.

Payload-size diagnostics encode committed snapshots asynchronously and discard stale results. Explicit Copy JSON remains the synchronous user-requested handoff boundary.

Simulator and unsigned generic-device builds do not satisfy this checklist. Physical interaction and Instruments gates remain pending until recorded on real hardware.
