import React from 'react';
import { act, create } from 'react-test-renderer';
import { expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({ props: null as any }));
vi.mock('expo', () => ({
  requireNativeView: (name: string) => {
    if (name !== 'ReactNativeCAD') throw new Error(`Unexpected native module ${name}`);
    return (props: any) => { state.props = props; return null; };
  },
}));
import { CADCanvas, isCADSupported } from '../src/CADCanvas.ios';

it('forwards ref and events without moving documents or Pencil samples through props', async () => {
  const ref = React.createRef<any>();
  const changed = vi.fn();
  const options = { configuration: { enabledTools: ['freehand' as const] } };
  let tree: ReturnType<typeof create>;
  await act(async () => { tree = create(<CADCanvas ref={ref} options={options} onDocumentChange={changed} tool="freehand" />); });
  expect(isCADSupported).toBe(true);
  expect(state.props.ref).toBe(ref);
  expect(JSON.parse(state.props.optionsJSON)).toEqual(options);
  expect(state.props.onDocumentChange).toBe(changed);
  expect(state.props.tool).toBe('freehand');
  expect(state.props).not.toHaveProperty('document');
  await act(async () => { tree!.update(<CADCanvas ref={ref} />); });
  expect(state.props.optionsJSON).toBe('{}');
  await act(async () => tree!.unmount());
});
