const path = require('path');
const { getDefaultConfig } = require('expo/metro-config');

const config = getDefaultConfig(__dirname);
// The local package is the workspace root, not another workspace child.
config.watchFolders = [...config.watchFolders, path.resolve(__dirname, '..')];
config.resolver.resolveRequest = (context, moduleName, platform) => {
  const entry = moduleName === 'react-native-cad'
    ? path.resolve(__dirname, '../src/index.ts')
    : moduleName;
  return context.resolveRequest(context, entry, platform);
};
module.exports = config;
