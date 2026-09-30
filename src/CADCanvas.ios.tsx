import React, { useMemo } from 'react';
import { requireNativeView } from 'expo';
import type { CADCanvasProps } from './types';

type NativeProps = Omit<CADCanvasProps, 'options'> & { optionsJSON: string };
const NativeCADCanvas = requireNativeView<NativeProps>('ReactNativeCAD');
export const isCADSupported = true;

export function CADCanvas({ options, ...props }: CADCanvasProps) {
  const optionsJSON = useMemo(() => JSON.stringify(options ?? {}), [options]);
  return <NativeCADCanvas {...props} optionsJSON={optionsJSON} />;
}
