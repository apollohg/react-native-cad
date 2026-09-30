import React from 'react';
import { describe, expect, it, vi } from 'vitest';
import { create, act } from 'react-test-renderer';

vi.mock('expo', () => { throw new Error('Unsupported platforms must not load Expo native views'); });
import { CADCanvas, isCADSupported } from '../src/index';

describe('unsupported platforms', () => {
  it('renders no view and never loads a native module', async () => {
    let tree: ReturnType<typeof create>;
    await act(async () => { tree = create(<CADCanvas style={{ flex: 1 }} />); });
    expect(tree!.toJSON()).toBeNull();
    expect(isCADSupported).toBe(false);
    await act(async () => tree!.unmount());
  });
});
