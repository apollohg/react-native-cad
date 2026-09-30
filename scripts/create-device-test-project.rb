require 'xcodeproj'
require 'fileutils'

root = File.expand_path('..', __dir__)
directory = File.join(root, '.verification')
FileUtils.mkdir_p(directory)
project = Xcodeproj::Project.new(File.join(directory, 'CADExpoDeviceTests.xcodeproj'))
target = project.new_target(:ui_test_bundle, 'CADExpoDeviceTests', :ios, '26.0')
source = project.main_group.new_file('../tests/device/CADExpoSmokeTests.swift')
target.add_file_references([source])
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.apollohg.reactnativecad.devicetests',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'SWIFT_VERSION' => '6.0',
    'TARGETED_DEVICE_FAMILY' => '2',
    'CODE_SIGN_STYLE' => 'Automatic'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.save_as(project.path, 'CADExpoDeviceTests', true)
