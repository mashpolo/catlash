#!/usr/bin/env ruby
require 'xcodeproj'

root = File.expand_path(__dir__)
project_path = File.join(root, 'MihomoProbe.xcodeproj')
project = Xcodeproj::Project.new(project_path)
app = project.new_target(:application, 'FlClashIOSProbe', :ios, '18.0')
tunnel = project.new_target(:app_extension, 'PacketTunnel', :ios, '18.0')
ui_tests = project.new_target(:ui_test_bundle, 'ProbeAppUITests', :ios, '18.0')

def add_sources(project, target, root, directory)
  group = project.main_group.new_group(directory)
  Dir.glob(File.join(root, directory, '*.swift')).sort.each do |path|
    relative = path.delete_prefix(root + '/')
    target.source_build_phase.add_file_reference(group.new_file(relative))
  end
end

add_sources(project, app, root, 'ProbeApp')
add_sources(project, ui_tests, root, 'ProbeAppUITests')
add_sources(project, tunnel, root, 'ProbeTunnel')
tunnel.source_build_phase.add_file_reference(project.main_group.new_file('ProbeTunnel/SystemDNS.m'))
add_sources(project, tunnel, root, 'PacketBridge')
add_sources(project, app, root, 'SnapshotStore')
add_sources(project, app, root, 'ProfileStore')
add_sources(project, app, root, 'CloudSync')
app.source_build_phase.add_file_reference(project.main_group.new_file('PacketBridge/ProxyDelayBatch.swift'))
app.source_build_phase.add_file_reference(project.main_group.new_file('PacketBridge/TunnelStartupDiagnostics.swift'))
add_sources(project, tunnel, root, 'SnapshotStore')

app.resources_build_phase.add_file_reference(project.main_group.new_file('ProbeApp/Assets.xcassets'))
geodata = project.main_group.new_file('Resources/Geo')
geodata.last_known_file_type = 'folder'
[app, tunnel].each { |target| target.resources_build_phase.add_file_reference(geodata) }

[app, tunnel, ui_tests].each do |target|
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['SWIFT_VERSION'] = '5.0'
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
    settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    settings['ARCHS'] = 'arm64'
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['DEVELOPMENT_TEAM'] = ENV['DEVELOPMENT_TEAM'] if ENV['DEVELOPMENT_TEAM']
    settings['CURRENT_PROJECT_VERSION'] = '1'
    settings['MARKETING_VERSION'] = '0.1.0'
    settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
    settings['SWIFT_STRICT_CONCURRENCY'] = 'targeted'
  end
  target.add_system_framework('NetworkExtension')
end

app.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.mashpolo.FlClashIOSProbe'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = ''
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'ProbeApp/ProbeApp.entitlements'
  settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'Catlash'
  settings['INFOPLIST_FILE'] = 'ProbeApp/Info.plist'
  settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  settings['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
end

tunnel.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.mashpolo.FlClashIOSProbe.PacketTunnel'
  settings['INFOPLIST_FILE'] = 'ProbeTunnel/Info.plist'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'ProbeTunnel/ProbeTunnel.entitlements'
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'ProbeTunnel/PacketTunnel-Bridging-Header.h'
  settings['SKIP_INSTALL'] = 'YES'
  settings['OTHER_LDFLAGS'] = ['$(inherited)', '-ObjC', '-lresolv']
end

framework = project.frameworks_group.new_file('build/MihomoBridge.xcframework')
framework.last_known_file_type = 'wrapper.xcframework'
tunnel.frameworks_build_phase.add_file_reference(framework)
tunnel.add_system_framework('Foundation')
tunnel.add_system_framework('UIKit')
tunnel.add_system_framework('Security')
tunnel.add_system_framework('SystemConfiguration')

app.add_dependency(tunnel)
embed = app.new_copy_files_build_phase('Embed Packet Tunnel')
embed.dst_subfolder_spec = '13'
embedded = embed.add_file_reference(tunnel.product_reference)
embedded.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
ui_tests.add_dependency(app)
ui_tests.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.mashpolo.FlClashIOSProbe.UITests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['TEST_TARGET_NAME'] = 'FlClashIOSProbe'
end
package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = 'https://github.com/jpsim/Yams.git'
package.requirement = { 'kind' => 'revision', 'revision' => 'a27b21e0c81c5bf42049b897a62aaf387e80f279' }
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = 'Yams'
app.package_product_dependencies << product
package_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
package_file.product_ref = product
app.frameworks_build_phase.files << package_file
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(ui_tests)
scheme.save_as(project_path, 'FlClashIOSProbe', true)
puts project_path
