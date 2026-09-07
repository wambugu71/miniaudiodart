Pod::Spec.new do |s|
  s.name             = 'sautiflow'
  s.version          = '0.1.0'
  s.summary          = 'miniaudio C++ FFI engine for Flutter'
  s.description      = <<-DESC
A cross-platform miniaudio-backed native engine exposed to Flutter through Dart FFI.
                       DESC
  s.homepage         = 'https://github.com/wambugukinyua/miniaudiodart'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'sautiflow' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files = '../audio_engine.cpp', '../mp4_aac_decoder.cpp', '../ffmpeg_stream_decoder.cpp', '../third_party/faad2/libfaad/*.c', '../third_party/libsamplerate/src/*.c', '../third_party/libsoxr/src/soxr.c', '../third_party/libsoxr/src/data-io.c', '../third_party/libsoxr/src/filter.c', '../third_party/libsoxr/src/cr.c', '../third_party/libsoxr/src/cr32.c', '../third_party/libsoxr/src/cr32s.c', '../third_party/libsoxr/src/cr64.c', '../third_party/libsoxr/src/vr32.c', '../third_party/libsoxr/src/pffft32s.c', '../third_party/libsoxr/src/pffft-wrap.c', '../third_party/libsoxr/src/fft4g32.c', '../third_party/libsoxr/src/fft4g64.c', '../third_party/libsoxr/src/dbesi0.c', '../third_party/libsoxr/src/vr-coefs.c', '../third_party/libsoxr/src/util32s.c'
  s.public_header_files = '../audio_engine.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.13'
  s.libraries = 'c++', 'z'
  s.frameworks = 'CoreAudio', 'AudioToolbox', 'AVFoundation'

  # FFmpeg prebuilts (built by tool/build_apple.sh): macos_universal covers
  # both arm64 and x86_64.
  repo_root = File.expand_path('..', __FILE__)
  universal_dir = File.join(repo_root, 'native', 'apple', 'macos_universal')
  ffmpeg_libs = %w[libavformat libavcodec libavutil libswresample].select do |lib|
    File.exist?(File.join(universal_dir, "#{lib}.a"))
  end
  have_ffmpeg = ffmpeg_libs.size == 4

  defines = 'HAVE_INTTYPES_H=1 HAVE_MEMCPY=1 HAVE_STRING_H=1 HAVE_STRINGS_H=1 HAVE_SYS_TYPES_H=1 PACKAGE="libsamplerate" VERSION="0.2.2" PACKAGE_VERSION="2.11.1" ENABLE_SINC_BEST_CONVERTER=1 ENABLE_SINC_MEDIUM_CONVERTER=1 ENABLE_SINC_FAST_CONVERTER=1 MA_NO_ASSERT MA_DR_WAV_NO_ASSERT MA_DR_FLAC_NO_ASSERT MA_DR_MP3_NO_ASSERT SOXR_LIB=1'
  defines += ' SAUTIFLOW_ENABLE_FFMPEG=1' if have_ffmpeg

  header_search_paths = '$(inherited) "${PODS_TARGET_SRCROOT}/.." "${PODS_TARGET_SRCROOT}/../dsp" "${PODS_TARGET_SRCROOT}/../third_party" "${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/include" "${PODS_TARGET_SRCROOT}/../third_party/faad2/include" "${PODS_TARGET_SRCROOT}/../third_party/faad2/libfaad" "${PODS_TARGET_SRCROOT}/../third_party/libsamplerate/include" "${PODS_TARGET_SRCROOT}/../third_party/libsoxr/include" "${PODS_TARGET_SRCROOT}/../third_party/libsoxr/src" "${PODS_TARGET_SRCROOT}/../third_party/r8brain"'
  # Prebuilt FFmpeg headers live double-nested under native/apple/include.
  if have_ffmpeg && File.directory?(File.join(repo_root, 'native', 'apple', 'include', 'include'))
    header_search_paths += ' "${PODS_TARGET_SRCROOT}/../native/apple/include/include"'
  end

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -O3 -ffast-math -ftree-vectorize',
    'GCC_PREPROCESSOR_DEFINITIONS' => "$(inherited) #{defines}",
    'HEADER_SEARCH_PATHS' => header_search_paths,
    'LIBRARY_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/../native/apple/macos_universal" "${PODS_TARGET_SRCROOT}/../native/apple"'
  }

  if have_ffmpeg
    s.vendored_libraries = ffmpeg_libs.map { |lib| "native/apple/macos_universal/#{lib}.a" }
  end

  s.swift_version = '5.0'
end
