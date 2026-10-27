platform :ios, '16.0'
project 'Cinefile.xcodeproj'

target 'Cinefile' do
  use_frameworks!

  # VLC engine: all containers/codecs (mkv, rmvb, avi, ts, webm ...),
  # hardware decoding, subtitle and audio track switching.
  pod 'MobileVLCKit', '~> 3.6'

  # AMSMB2 is a SwiftPM package (no podspec); it is declared in project.yml
  # with embed: true so the dynamic framework lands in Frameworks/.
end
