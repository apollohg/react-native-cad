require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
Pod::Spec.new do |s|
  s.name = 'DrawCanvasUI'
  s.version = package['version']
  s.summary = package['description']
  s.homepage = 'https://github.com/apollohg/react-native-cad'
  s.author = 'Apollo'
  s.license = { :type => 'Proprietary' }
  s.source = { :git => 'https://github.com/apollohg/react-native-cad.git', :tag => s.version.to_s }
  s.platform = :ios, '26.0'
  s.swift_version = '6.0'
  s.static_framework = true
  s.source_files = 'DrawCanvasKit/Sources/DrawCanvasUI/**/*.swift', 'ios/Resources/Bundle+Canvas.swift'
  s.resource_bundles = { 'DrawCanvasShaders' => ['DrawCanvasKit/Sources/DrawCanvasUI/Rendering/Metal/Shaders/*.metal'] }
  s.dependency 'DrawCanvasCore', s.version.to_s
  s.frameworks = 'Metal', 'MetalKit', 'SwiftUI', 'UIKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name DrawCanvasKit' }
end
