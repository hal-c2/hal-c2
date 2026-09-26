require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'HalC2TerminalNative'
  s.version = package['version']
  s.summary = 'Native terminal surface for HAL-C2 mobile.'
  s.description = 'Native terminal surface bridge used by the HAL-C2 React Native app.'
  s.homepage = 'https://hal-c2.example'
  s.license = { :type => 'UNLICENSED' }
  s.author = { 'HAL-C2' => 'hello@hal-c2.example' }
  s.platforms = { :ios => '16.1' }
  s.source = { :path => '.' }
  s.source_files = 'ios/**/*.{h,m,mm,swift}'
  s.vendored_frameworks = 'Vendor/libghostty/GhosttyKit.xcframework'
  s.frameworks = 'IOSurface', 'Metal', 'MetalKit', 'QuartzCore', 'UIKit'
  s.libraries = 'c++', 'z'
  s.swift_version = '5.9'
  s.dependency 'ExpoModulesCore'
end
