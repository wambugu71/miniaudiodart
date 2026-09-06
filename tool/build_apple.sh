#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/apple/ios build/apple/ios-sim build/apple/macos

EXTRA_CXXFLAGS=""
EXTRA_LDFLAGS=""
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libcurl; then
  EXTRA_CXXFLAGS="-DAE_ENABLE_CURL=1 $(pkg-config --cflags libcurl)"
  EXTRA_LDFLAGS="$(pkg-config --libs libcurl)"
  echo "libcurl detected: enabling native URL byte-streaming"
else
  echo "libcurl not found: building without native URL byte-streaming"
fi

INCLUDES="-I. -Idsp -Inative/apple/include -Ithird_party -Ithird_party/ffmpeg/include -Ithird_party/faad2/include -Ithird_party/faad2/libfaad -Ithird_party/libsamplerate/include -Ithird_party/libsoxr/include -Ithird_party/libsoxr/src -Ithird_party/r8brain"

DEFINES="-DHAVE_INTTYPES_H=1 -DHAVE_MEMCPY=1 -DHAVE_STRING_H=1 -DHAVE_STDBOOL_H=1 -DHAVE_STRINGS_H=1 -DHAVE_SYS_TYPES_H=1 -DPACKAGE=\"libsamplerate\" -DVERSION=\"0.2.2\" -DPACKAGE_VERSION=\"2.11.1\" -DENABLE_SINC_BEST_CONVERTER=1 -DENABLE_SINC_MEDIUM_CONVERTER=1 -DENABLE_SINC_FAST_CONVERTER=1 -DMA_NO_ASSERT -DMA_DR_WAV_NO_ASSERT -DMA_DR_FLAC_NO_ASSERT -DMA_DR_MP3_NO_ASSERT -DSOXR_LIB=1 -DSAUTIFLOW_ENABLE_FFMPEG=1"

C_SRCS=$(find third_party/faad2/libfaad third_party/libsamplerate/src third_party/libsoxr/src -name "*.c" 2>/dev/null || true)
CPP_SRCS="audio_engine.cpp mp4_aac_decoder.cpp ffmpeg_stream_decoder.cpp"

echo "Building iOS device static library..."
for src in $C_SRCS; do
  obj="build/apple/ios/$(basename "$src" .c)_c.o"
  xcrun --sdk iphoneos clang -std=c11 -O3 -ffast-math -ftree-vectorize -arch arm64 $INCLUDES $DEFINES -c "$src" -o "$obj"
done
for src in $CPP_SRCS; do
  obj="build/apple/ios/$(basename "$src" .cpp)_cpp.o"
  xcrun --sdk iphoneos clang++ -std=c++17 -O3 -ffast-math -ftree-vectorize -arch arm64 $INCLUDES $DEFINES $EXTRA_CXXFLAGS -c "$src" -o "$obj"
done
libtool -static -o build/apple/ios/libsautiflow.a build/apple/ios/*.o
cp -f build/apple/ios/libsautiflow.a build/apple/ios/libaudio_engine.a 2>/dev/null || true

echo "Building iOS simulator static library..."
for src in $C_SRCS; do
  obj="build/apple/ios-sim/$(basename "$src" .c)_c.o"
  xcrun --sdk iphonesimulator clang -std=c11 -O3 -ffast-math -ftree-vectorize -arch arm64 -arch x86_64 $INCLUDES $DEFINES -c "$src" -o "$obj"
done
for src in $CPP_SRCS; do
  obj="build/apple/ios-sim/$(basename "$src" .cpp)_cpp.o"
  xcrun --sdk iphonesimulator clang++ -std=c++17 -O3 -ffast-math -ftree-vectorize -arch arm64 -arch x86_64 $INCLUDES $DEFINES $EXTRA_CXXFLAGS -c "$src" -o "$obj"
done
libtool -static -o build/apple/ios-sim/libsautiflow.a build/apple/ios-sim/*.o
cp -f build/apple/ios-sim/libsautiflow.a build/apple/ios-sim/libaudio_engine.a 2>/dev/null || true

echo "Building macOS dynamic library..."
xcrun --sdk macosx clang++ -std=c++17 -O3 -ffast-math -ftree-vectorize -dynamiclib \
  $INCLUDES $DEFINES $EXTRA_CXXFLAGS \
  $C_SRCS $CPP_SRCS \
  -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework Security \
  -Lnative/apple/macos_universal -Lnative/apple/macos -Lnative/apple -Lthird_party/ffmpeg/lib \
  -lavformat -lavcodec -lavutil -lswresample \
  -o build/apple/macos/libsautiflow.dylib $EXTRA_LDFLAGS
cp -f build/apple/macos/libsautiflow.dylib build/apple/macos/libaudio_engine.dylib 2>/dev/null || true

echo "Creating XCFramework for iOS..."
rm -rf build/apple/sautiflow.xcframework build/apple/audio_engine.xcframework
xcodebuild -create-xcframework \
  -library build/apple/ios/libsautiflow.a \
  -library build/apple/ios-sim/libsautiflow.a \
  -output build/apple/sautiflow.xcframework

cp -r build/apple/sautiflow.xcframework build/apple/audio_engine.xcframework 2>/dev/null || true

echo "Done. Outputs:"
echo "  build/apple/sautiflow.xcframework"
echo "  build/apple/macos/libsautiflow.dylib"
