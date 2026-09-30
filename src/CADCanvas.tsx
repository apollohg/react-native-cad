import type { CADCanvasProps } from './types';

export const isCADSupported = false;

/** Android and web intentionally have no native implementation. */
export function CADCanvas(_props: CADCanvasProps): null {
  return null;
}
