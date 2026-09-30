require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
Pod::Spec.new do |s|
  s.name = 'ReactNativeCAD'
  s.version = package['version']
  s.summary = package['description']
  s.homepage = 'https://github.com/apollohg/react-native-cad'
  s.author = 'Apollo'
  s.license = { :type => 'Proprietary' }
  s.source = { :git => 'https://github.com/apollohg/react-native-cad.git', :tag => s.version.to_s }
  s.platform = :ios, '26.0'
  # Expo's view-function DSL currently requires its template's language mode.
  s.swift_version = '5.9'
  s.static_framework = true
  s.source_files = 'ios/ReactNativeCAD/**/*.swift'
  s.dependency 'ExpoModulesCore'
  s.dependency 'DrawCanvasCore', s.version.to_s
  s.dependency 'DrawCanvasUI', s.version.to_s
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
