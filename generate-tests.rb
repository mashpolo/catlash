#!/usr/bin/env ruby
require 'xcodeproj'
source_root = File.expand_path(__dir__)
project_path = File.join(source_root, 'build', 'PacketBridgeTests.xcodeproj')
project = Xcodeproj::Project.new(project_path)
bridge = project.new_target(:framework, 'PacketBridge', :ios, '18.0')
tests = project.new_target(:unit_test_bundle, 'PacketBridgeTests', :ios, '18.0')
[[bridge, 'PacketBridge'], [tests, 'PacketBridgeTests']].each do |target, folder|
  group = project.main_group.new_group(folder)
  Dir.glob(File.join(source_root, folder, '*.swift')).sort.each do |path|
    target.source_build_phase.add_file_reference(group.new_file(path))
  end
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['SWIFT_VERSION'] = '5.0'
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
    settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    settings['ARCHS'] = 'arm64'
    settings['CODE_SIGNING_ALLOWED'] = 'NO'
    settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = "com.mashpolo.phase0.#{target.name}"
    settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
    settings['ENABLE_TESTABILITY'] = 'YES'
    settings['SWIFT_STRICT_CONCURRENCY'] = 'targeted'
    settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
  end
end
['SnapshotStore', 'ProfileStore', 'CloudSync'].each do |folder|
  group = project.main_group.new_group(folder)
  Dir.glob(File.join(source_root, folder, '*.swift')).sort.each do |path|
    bridge.source_build_phase.add_file_reference(group.new_file(path))
  end
end
xcframework = project.frameworks_group.new_file(File.join(source_root, 'build/MihomoBridge.xcframework'))
xcframework.last_known_file_type = 'wrapper.xcframework'
bridge.frameworks_build_phase.add_file_reference(xcframework)
['NetworkExtension', 'Foundation', 'UIKit', 'Security', 'SystemConfiguration'].each { |name| bridge.add_system_framework(name) }
bridge.build_configurations.each do |c|
  c.build_settings['DEFINES_MODULE'] = 'YES'
  c.build_settings['OTHER_LDFLAGS'] = ['$(inherited)', '-ObjC', '-lresolv']
end
tests.add_dependency(bridge)
tests.frameworks_build_phase.add_file_reference(bridge.product_reference)
embed = tests.new_copy_files_build_phase('Embed PacketBridge')
embed.dst_subfolder_spec = '10'
embed.add_file_reference(bridge.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = 'https://github.com/jpsim/Yams.git'
package.requirement = { 'kind' => 'revision', 'revision' => 'a27b21e0c81c5bf42049b897a62aaf387e80f279' }
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = 'Yams'
bridge.package_product_dependencies << product
package_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
package_file.product_ref = product
bridge.frameworks_build_phase.files << package_file
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(bridge)
scheme.add_build_target(tests)
scheme.add_test_target(tests)
scheme.save_as(project_path, 'PacketBridgeTests', true)
puts project_path
