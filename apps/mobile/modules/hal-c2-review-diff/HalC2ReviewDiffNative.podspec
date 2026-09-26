require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'HalC2ReviewDiffNative'
  s.version = package['version']
  s.summary = 'Native review diff debug surface for HAL-C2 mobile.'
  s.description = 'Native iOS review diff renderer used to prototype fast mobile review scrolling.'
  s.homepage = 'https://hal-c2.example'
  s.license = { :type => 'UNLICENSED' }
  s.author = { 'HAL-C2' => 'hello@hal-c2.example' }
  s.platforms = { :ios => '16.1' }
  s.source = { :path => '.' }
  s.source_files = 'ios/**/*.{h,m,mm,swift}'
  s.frameworks = 'CoreGraphics', 'UIKit'
  s.swift_version = '5.9'
  s.dependency 'ExpoModulesCore'
end
