#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your Android NDK path}"

API=24
ABIS=(arm64-v8a armeabi-v7a x86_64)

# Optional: pass extra compiler/linker flags (for example to enable libcurl).
# Example:
#   export AE_EXTRA_CXXFLAGS="-DAE_ENABLE_CURL=1 -I/path/to/curl/include"
#   export AE_EXTRA_LDFLAGS="-L/path/to/curl/libs/arm64-v8a -lcurl -lz"
AE_EXTRA_CXXFLAGS="${AE_EXTRA_CXXFLAGS:-}"
AE_EXTRA_LDFLAGS="${AE_EXTRA_LDFLAGS:-}"

mkdir -p build/android

INCLUDES=(
  "-I."
  "-Idsp"
  "-Ithird_party"
  "-Ithird_party/faad2/include"
  "-Ithird_party/faad2/libfaad"
  "-Ithird_party/libsamplerate/include"
  "-Ithird_party/libsoxr/include"
  "-Ithird_party/libsoxr/src"
  "-Ithird_party/r8brain"
)

DEFINES=(
  "-DPACKAGE_VERSION=\"2.11.1\""
  "-DPACKAGE=\"libsamplerate\""
  "-DVERSION=\"0.2.2\""
  "-DHAVE_INTTYPES_H=1"
  "-DHAVE_MEMCPY=1"
  "-DHAVE_STRING_H=1"
  "-DHAVE_STDBOOL_H=1"
  "-DHAVE_STRINGS_H=1"
  "-DHAVE_SYS_TYPES_H=1"
  "-DENABLE_SINC_BEST_CONVERTER=1"
  "-DENABLE_SINC_MEDIUM_CONVERTER=1"
  "-DENABLE_SINC_FAST_CONVERTER=1"
  "-DSOXR_LIB=1"
)

SOXR_SRCS=(
  third_party/libsoxr/src/soxr.c
  third_party/libsoxr/src/data-io.c
  third_party/libsoxr/src/filter.c
  third_party/libsoxr/src/cr.c
  third_party/libsoxr/src/cr32.c
  third_party/libsoxr/src/cr32s.c
  third_party/libsoxr/src/cr64.c
  third_party/libsoxr/src/vr32.c
  third_party/libsoxr/src/pffft32s.c
  third_party/libsoxr/src/pffft-wrap.c
  third_party/libsoxr/src/fft4g32.c
  third_party/libsoxr/src/fft4g64.c
  third_party/libsoxr/src/dbesi0.c
  third_party/libsoxr/src/vr-coefs.c
  third_party/libsoxr/src/util32s.c
)

for ABI in "${ABIS[@]}"; do
  case "$ABI" in
    arm64-v8a)
      TARGET=aarch64-linux-android
      ;;
    armeabi-v7a)
      TARGET=armv7a-linux-androideabi
      ;;
    x86_64)
      TARGET=x86_64-linux-android
      ;;
    *)
      echo "Unsupported ABI: $ABI"; exit 1
      ;;
  esac

  OUT_DIR="build/android/$ABI"
  mkdir -p "$OUT_DIR"

  CLANG="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET}${API}-clang++"

  "$CLANG" \
    -std=c++17 -O2 -fPIC -shared \
    audio_engine.cpp mp4_aac_decoder.cpp third_party/faad2/libfaad/*.c third_party/libsamplerate/src/*.c "${SOXR_SRCS[@]}" \
    -o "$OUT_DIR/libaudio_engine.so" \
    -D__ANDROID_API__=$API "${INCLUDES[@]}" "${DEFINES[@]}" \
    $AE_EXTRA_CXXFLAGS \
    $AE_EXTRA_LDFLAGS

  echo "Built $OUT_DIR/libaudio_engine.so"
done
