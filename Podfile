platform :ios, '16.0'
project 'Cinefile.xcodeproj'

target 'Cinefile' do
  use_frameworks!

  # VLC engine: all containers/codecs (mkv, rmvb, avi, ts, webm ...),
  # hardware decoding, subtitle and audio track switching.
  pod 'MobileVLCKit', '~> 3.6'

  # SMB browsing (libsmb2). Declared dynamic upstream, so it MUST be embedded:
  # a bare SPM package dependency links @rpath/AMSMB2.framework but never
  # embeds it, which makes dyld abort at launch. It is not on the CocoaPods
  # trunk, so pull the podspec from the repository itself.
  pod 'AMSMB2', :git => 'https://github.com/amosavian/AMSMB2.git', :branch => 'master'
end
