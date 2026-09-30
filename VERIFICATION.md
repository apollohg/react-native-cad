# Extraction verification — 30 September 2026

Verified using Xcode 27, Expo SDK 57, React Native 0.86.3, Node 24, and the connected M4 iPad running iOS 27.0.1. No simulator was used.

- The extracted native regression target passed 200 tests, including three physical Metal interaction/display gates and three JSON configuration tests. `CanvasPerformanceTests` microbenchmarks were excluded from this run; the dedicated `CanvasPhysicalGateTests` ran.
- The Expo Release app built, installed, and passed a physical-device integration test: Metal active, no native inspector, load five elements, save JSON, clear, restore, and verify identical JSON and element count. This ran before removing the example's top debug toolbar at the user's request.
- TypeScript package and example checks passed. Both JavaScript wrapper tests passed.
- After removing both toolbars, the rebuilt bare-canvas example passed its physical-device smoke test and was installed on the iPad.
- An actual npm tarball installed into an independent Expo consumer and bundled for both platforms. Source-map checks confirmed the native view only appears in iOS, with the no-op selected on Android.
- CocoaPods autolinking resolved all three pods. The installed app contained `CadCanvasShaders.bundle/default.metallib`; the device test confirmed the Metal backend, not fallback.

The Expo canvas and final example contain no toolbar, inspector, or debug labels. The final smoke test checks this bare-canvas host. The original SwiftUI demo is retained separately as the native regression host.

The native engine's rendering and interaction implementation was preserved. Extraction changes to its existing source declarations add serialization conformances; `CanvasJSONOptions` adds the validated configuration boundary. Original app history, local signing, caches, and diagnostics are excluded from Git.

Known tooling notes: Expo's view-function DSL requires Swift 5.9 language mode for the thin adapter and produces isolation warnings with Xcode 27; the core and UI modules retain Swift 6. The dependency audit reports 10 moderate upstream/tooling advisories, with no high or critical advisories. No forced Expo dependency upgrades were applied.

This verifies extraction and integration, not a new exhaustive manual Pencil-quality/performance review in the Expo host, Android drawing support, npm publication, or remote Git push.
