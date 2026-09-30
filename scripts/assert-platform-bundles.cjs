const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const directory = process.argv[2];
assert(directory, 'Pass an Expo export directory created with --source-maps');
for (const platform of ['ios', 'android']) {
  const folder = path.join(directory, '_expo/static/js', platform);
  const files = fs.readdirSync(folder).filter(name => name.endsWith('.map'));
  assert(files.length > 0, `Missing ${platform} source maps`);
  const sources = files.flatMap(name => JSON.parse(fs.readFileSync(path.join(folder, name), 'utf8')).sources);
  const native = sources.some(name => name.endsWith('/CADCanvas.ios.tsx'));
  const fallback = sources.some(name => name.endsWith('/CADCanvas.tsx'));
  assert.equal(native, platform === 'ios', `${platform}: incorrect native canvas inclusion`);
  assert.equal(fallback, platform !== 'ios', `${platform}: incorrect no-op inclusion`);
  console.log(`${platform}: correct canvas implementation bundled`);
}
