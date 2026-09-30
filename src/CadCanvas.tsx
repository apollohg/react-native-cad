import type { CadCanvasProps } from './types';

export const isCADSupported = false;

/** Android and web intentionally have no native implementation. */
export function CadCanvas(_props: CadCanvasProps): null {
  return null;
}
