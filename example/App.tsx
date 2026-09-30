import React from 'react';
import { CADCanvas, type CADOptions } from 'react-native-cad';

const OPTIONS: CADOptions = { configuration: { measurements: { showsExtensionLines: false } } };

export default function App() {
  return <CADCanvas testID="cad-canvas" style={{ flex: 1 }} tool="freehand" options={OPTIONS} />;
}
