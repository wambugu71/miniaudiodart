#!/usr/bin/env bash
set -euo pipefail

echo "Building Linux shared library..."
mkdir -p build/linux

EXTRA_CXXFLAGS=""
EXTRA_LDFLAGS=""
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libcurl; then
	EXTRA_CXXFLAGS="-DAE_ENABLE_CURL=1 $(pkg-config --cflags libcurl)"
	EXTRA_LDFLAGS="$(pkg-config --libs libcurl)"
	echo "libcurl detected: enabling native URL byte-streaming"
else
	echo "libcurl not found: building without native URL byte-streaming"
fi

FFMPEG_CFLAGS=""
FFMPEG_LDFLAGS=""
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libavformat libavcodec libavutil libswresample; then
	FFMPEG_CFLAGS="$(pkg-config --cflags libavformat libavcodec libavutil libswresample)"
	FFMPEG_LDFLAGS="$(pkg-config --libs libavformat libavcodec libavutil libswresample)"
else
	FFMPEG_CFLAGS="-Ithird_party/ffmpeg/include"
	FFMPEG_LDFLAGS="-Lthird_party/ffmpeg/lib -lavformat -lavcodec -lavutil -lswresample"
fi

INCLUDES="-I. -Idsp -Ithird_party -Ithird_party/faad2/include -Ithird_party/faad2/libfaad -Ithird_party/libsamplerate/include -Ithird_party/libsoxr/include -Ithird_party/libsoxr/src -Ithird_party/r8brain $FFMPEG_CFLAGS"

DEFINES="-DHAVE_INTTYPES_H=1 -DHAVE_MEMCPY=1 -DHAVE_STRING_H=1 -DHAVE_STDBOOL_H=1 -DHAVE_STRINGS_H=1 -DHAVE_SYS_TYPES_H=1 -DPACKAGE=\"libsamplerate\" -DVERSION=\"0.2.2\" -DPACKAGE_VERSION=\"2.11.1\" -DENABLE_SINC_BEST_CONVERTER=1 -DENABLE_SINC_MEDIUM_CONVERTER=1 -DENABLE_SINC_FAST_CONVERTER=1 -DMA_NO_ASSERT -DMA_DR_WAV_NO_ASSERT -DMA_DR_FLAC_NO_ASSERT -DMA_DR_MP3_NO_ASSERT -DSOXR_LIB=1 -DSAUTIFLOW_ENABLE_FFMPEG=1"

C_SRCS=$(find third_party/faad2/libfaad third_party/libsamplerate/src third_party/libsoxr/src -name "*.c" 2>/dev/null || true)
CPP_SRCS="audio_engine.cpp mp4_aac_decoder.cpp ffmpeg_stream_decoder.cpp"

g++ -std=c++17 -O3 -ffast-math -ftree-vectorize -fPIC -shared \
	$INCLUDES $DEFINES $EXTRA_CXXFLAGS \
	$C_SRCS $CPP_SRCS \
	-o build/linux/libsautiflow.so \
	$FFMPEG_LDFLAGS -lpthread -ldl -lm $EXTRA_LDFLAGS

cp -f build/linux/libsautiflow.so build/linux/libaudio_engine.so 2>/dev/null || true

echo "Done: build/linux/libsautiflow.so"
