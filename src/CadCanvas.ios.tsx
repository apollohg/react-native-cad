import React, { useMemo } from 'react';
import { requireNativeView } from 'expo';
import type { CadCanvasProps } from './types';

type NativeProps = Omit<CadCanvasProps, 'options'> & { optionsJSON: string };
const NativeCadCanvas = requireNativeView<NativeProps>('ReactNativeCAD');
export const isCADSupported = true;

export function CadCanvas({ options, ...props }: CadCanvasProps) {
  const optionsJSON = useMemo(() => JSON.stringify(options ?? {}), [options]);
  return <NativeCadCanvas {...props} optionsJSON={optionsJSON} />;
}
