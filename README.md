# react-native-cad

An Expo native view wrapping the Swift/Metal DrawCanvas engine. iPad and Apple Pencil support; Android and web deliberately render `null` and load no native canvas module.

Requires **Expo SDK 57**, **React Native 0.86**, **iOS 26+**, and a custom development or production build. It does not run in Expo Go. The native engine remains Swift 6; the small Expo adapter uses Expo's Swift 5.9 language mode.

## Install

Until published, install a package tarball built from this repository:

```sh
npm ci
npm pack
# In your Expo application:
npm install /path/to/react-native-cad-0.1.0.tgz
npx expo install expo-build-properties
```

Set the consuming application's iOS deployment target in its Expo configuration:

```json
{
  "expo": {
    "plugins": [["expo-build-properties", { "ios": { "deploymentTarget": "26.0", "enableSceneSupport": true } }]]
  }
}
```

Then run `npx expo prebuild --platform ios` and build for your physical iPad. CocoaPods autolinks the canvas core, UI, Expo adapter, and compiled Metal resource bundle. No Android native dependency is registered.

Expo SDK 57 needs `enableSceneSupport` when building with Xcode 27. See [Expo's scene lifecycle guide](https://github.com/expo/fyi/blob/main/ios-scene-lifecycle.md).

## Use

```tsx
import { useRef } from 'react';
import { CADCanvas, type CADCanvasRef } from 'react-native-cad';

export function Drawing() {
  const canvas = useRef<CADCanvasRef>(null);
  return (
    <CADCanvas
      ref={canvas}
      style={{ flex: 1 }}
      tool="freehand"
      options={{
        configuration: { measurements: { showsExtensionLines: false } },
        inkConfiguration: { pressureEnabled: true, widthMode: 'canvasScaled' },
      }}
      onError={({ nativeEvent }) => console.error(nativeEvent.operation, nativeEvent.message)}
    />
  );
}
```

Give the view a nonzero size. The Expo view has no native toolbar or inspector. Build tool selection, options, and action buttons in React Native using the props and ref methods. Pencil interaction, text editing, rendering, and history remain native. React renders do not recreate the document session.

### Save to your server

`await canvas.current.getDocument()` returns versioned JSON for the **last committed document**, excluding any in-progress stroke or edit. Send this string to your own server and associate it with your quote. No backend, authentication, storage policy, or image format is imposed by this package.

`await canvas.current.loadDocument(json)` validates and replaces a document, clearing undo history and selection. Invalid data rejects the promise without replacing the document. Await loads in sequence. Encoding and decoding run off the UI thread; final validated replacement runs on the main actor.

`onDocumentChange` sends only document ID, revision, and element count—not the entire document or Pencil samples. Revision is a decimal string to preserve 64-bit precision. Pull a snapshot when your application needs to persist it; avoid encoding on every drawing event.

### Configuration

See [the TypeScript API](src/types.ts) for every option. `options` is a partial configuration over native defaults, not a patch over previous props. Removing an override restores its default. Arrays replace defaults; an empty array disables all entries. Colours use normalized RGBA components, and nullable colours/fill accept `null` to clear them.

- `configuration.enabledTools` and `enabledFeatures`: independently enable drawing tools and editing capabilities, including measurements, grid, snapping, panning, zooming, recognition, history, styling, and Pencil shortcuts.
- `configuration.controls`: visible controls/tool order, value ranges and steps, fonts, button appearance, and clear confirmation.
- `configuration.measurements`: axes, dimension roles, units, precision, extension lines, and hiding.
- `theme`: all canvas/selection/grid/guide colours, line widths, dash patterns, handles, spacing, and dimension-label styling.
- `strokeStyle`, `textStyle`, `inkConfiguration`, `snapConfiguration`: creation and interaction settings. Width and pressure settings affect newly drawn strokes, not saved strokes.

An unchanged `tool` prop does not override a subsequent Pencil-shortcut tool selection. Disable `pencilShortcuts` through `enabledFeatures` if React Native must exclusively own tool changes. Configuration errors arrive through `onError`; keep a handler installed.

### Commands and renderer status

The ref exposes `perform('undo' | 'redo' | 'clear' | 'deleteSelection' | 'duplicateSelection' | 'zoomToFit')`, returning whether the command succeeded. Commands respect feature gates; `clear` is programmatic, so provide any confirmation in React Native.

`getRenderer()` and `onRendererChange` report `initializing`, `metal`, or `coreGraphics`. Fallback diagnostics arrive through `onError`.

On Android/web, `isCADSupported` is false, `CADCanvas` returns `null`, and its ref remains null. Check support before calling methods. Unsupported platforms show no placeholder or error UI unless your application adds one.

## Example and native tests

```sh
npm ci
npm run prebuild --workspace example
cd example/ios && pod install
```

Open `example/ios/CADExample.xcworkspace` in Xcode, choose your signing team locally and your connected iPad, and run. Debug needs `npm run start --workspace example`; Release embeds the JavaScript bundle. Generated native projects and signing settings are gitignored. The example is a bare, full-size canvas with freehand selected—no toolbar, inspector, or debug labels. Add your own React Native controls when integrating it.

`DrawCanvasDemo` retains the native physical-device regression host. Its signing team comes from gitignored `DrawCanvasDemo/Config/Local.xcconfig`. See its README for the physical test schemes. The Swift sources have one copy under `DrawCanvasKit/Sources`, shared by CocoaPods and the local Swift package.

```sh
npm test
npm run build
npx tsc --noEmit -p example/tsconfig.json
```

For a packed-package integration check, install the tarball into a separate Expo app, export both platforms with `--source-maps`, then run `node scripts/assert-platform-bundles.cjs /path/to/export`. This checks Metro selected the native iOS view and the Android no-op.

The on-device Expo smoke test is in `tests/device`. Generate its disposable Xcode project with `ruby scripts/create-device-test-project.rb` (requires the `xcodeproj` gem), install the Release example, and run the `CADExpoDeviceTests` scheme on the iPad. It checks the canvas mounts without built-in controls. Signing remains local.

This repository starts with fresh history. It is proprietary (`UNLICENSED`); no npm publish or Git push is performed by local packaging.
