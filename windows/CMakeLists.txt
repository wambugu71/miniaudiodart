cmake_minimum_required(VERSION 3.14)
project(miniaudiodart_windows LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

file(GLOB FAAD2_SOURCES "../third_party/faad2/libfaad/*.c")
file(GLOB LIBSAMPLERATE_SOURCES "../third_party/libsamplerate/src/*.c")
set(LIBSOXR_SOURCES
  "../third_party/libsoxr/src/soxr.c"
  "../third_party/libsoxr/src/data-io.c"
  "../third_party/libsoxr/src/filter.c"
  "../third_party/libsoxr/src/cr.c"
  "../third_party/libsoxr/src/cr32.c"
  "../third_party/libsoxr/src/cr32s.c"
  "../third_party/libsoxr/src/cr64.c"
  "../third_party/libsoxr/src/vr32.c"
  "../third_party/libsoxr/src/pffft32s.c"
  "../third_party/libsoxr/src/pffft-wrap.c"
  "../third_party/libsoxr/src/fft4g32.c"
  "../third_party/libsoxr/src/fft4g64.c"
  "../third_party/libsoxr/src/dbesi0.c"
  "../third_party/libsoxr/src/vr-coefs.c"
  "../third_party/libsoxr/src/util32s.c"
)
add_library(audio_engine SHARED
  ../audio_engine.cpp
  ../mp4_aac_decoder.cpp
  ../ffmpeg_stream_decoder.cpp
  ${FAAD2_SOURCES}
  ${LIBSAMPLERATE_SOURCES}
  ${LIBSOXR_SOURCES}
)

target_include_directories(audio_engine PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/..
  ${CMAKE_CURRENT_SOURCE_DIR}/../dsp
  ${CMAKE_CURRENT_SOURCE_DIR}/../third_party
  ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/faad2/include
  ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/faad2/libfaad
  ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libsamplerate/include
  ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libsoxr/include
  ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libsoxr/src
  ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/r8brain
  ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ffmpeg/include
)

target_compile_definitions(audio_engine PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _USE_MATH_DEFINES
  _CRT_SECURE_NO_WARNINGS
  _CRT_NONSTDC_NO_DEPRECATE
  PACKAGE_VERSION="2.11.1"
  HAVE_INTTYPES_H=1
  HAVE_MEMCPY=1
  HAVE_STRING_H=1
  HAVE_STDBOOL_H=1
  HAVE_STRINGS_H=1
  HAVE_SYS_TYPES_H=1
  PACKAGE="libsamplerate"
  VERSION="0.2.2"
  ENABLE_SINC_BEST_CONVERTER=1
  ENABLE_SINC_MEDIUM_CONVERTER=1
  ENABLE_SINC_FAST_CONVERTER=1
  MA_NO_ASSERT
  MA_DR_WAV_NO_ASSERT
  MA_DR_FLAC_NO_ASSERT
  MA_DR_MP3_NO_ASSERT
  SOXR_LIB=1
)

if(MSVC)
  # /FS forces synchronous PDB writes, preventing C1041 errors in parallel builds
  target_compile_options(audio_engine PRIVATE /FS /std:c11 $<$<NOT:$<CONFIG:Debug>>:/O2 /fp:fast>)
  set_source_files_properties(${FAAD2_SOURCES} PROPERTIES
    COMPILE_FLAGS "/wd4100 /wd4244 /wd4267 /wd4701 /wd4706"
  )
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(audio_engine PRIVATE $<$<NOT:$<CONFIG:Debug>>:-O3 -ffast-math -ftree-vectorize>)
endif()

set(_md_windows_ffmpeg_dir "${CMAKE_CURRENT_SOURCE_DIR}/../native/windows/x86_64")
if(NOT (EXISTS "${_md_windows_ffmpeg_dir}/lib/avformat.lib" OR EXISTS "${_md_windows_ffmpeg_dir}/lib/libavformat.dll.a"))
  set(_md_windows_ffmpeg_dir "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ffmpeg")
endif()

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../native/windows/include")
  target_include_directories(audio_engine BEFORE PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../native/windows/include")
endif()

if(EXISTS "${_md_windows_ffmpeg_dir}/lib/avformat.lib" OR EXISTS "${_md_windows_ffmpeg_dir}/lib/libavformat.dll.a")
  target_compile_definitions(audio_engine PRIVATE SAUTIFLOW_ENABLE_FFMPEG=1)
  target_link_directories(audio_engine PRIVATE "${_md_windows_ffmpeg_dir}/lib")
  target_link_libraries(audio_engine PRIVATE
    avformat
    avcodec
    avutil
    swresample
  )
endif()

target_link_libraries(audio_engine PRIVATE
  winmm
  ws2_32
  bcrypt
  secur32
)

set_target_properties(audio_engine PROPERTIES
  OUTPUT_NAME "sautiflow"
)

# Required by Flutter FFI plugin packaging.
file(GLOB _md_ffmpeg_dlls "${_md_windows_ffmpeg_dir}/bin/*.dll")

set(sautiflow_bundled_libraries
  $<TARGET_FILE:audio_engine>
  ${_md_ffmpeg_dlls}
  PARENT_SCOPE
)
