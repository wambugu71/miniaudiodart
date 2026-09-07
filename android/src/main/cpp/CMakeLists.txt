cmake_minimum_required(VERSION 3.10)
project(miniaudiodart_android LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

file(GLOB FAAD2_SOURCES "../../../../third_party/faad2/libfaad/*.c")
file(GLOB LIBSAMPLERATE_SOURCES "../../../../third_party/libsamplerate/src/*.c")
set(LIBSOXR_SOURCES
  "../../../../third_party/libsoxr/src/soxr.c"
  "../../../../third_party/libsoxr/src/data-io.c"
  "../../../../third_party/libsoxr/src/filter.c"
  "../../../../third_party/libsoxr/src/cr.c"
  "../../../../third_party/libsoxr/src/cr32.c"
  "../../../../third_party/libsoxr/src/cr32s.c"
  "../../../../third_party/libsoxr/src/cr64.c"
  "../../../../third_party/libsoxr/src/vr32.c"
  "../../../../third_party/libsoxr/src/pffft32s.c"
  "../../../../third_party/libsoxr/src/pffft-wrap.c"
  "../../../../third_party/libsoxr/src/fft4g32.c"
  "../../../../third_party/libsoxr/src/fft4g64.c"
  "../../../../third_party/libsoxr/src/dbesi0.c"
  "../../../../third_party/libsoxr/src/vr-coefs.c"
  "../../../../third_party/libsoxr/src/util32s.c"
)
add_library(audio_engine SHARED
  ../../../../audio_engine.cpp
  ../../../../mp4_aac_decoder.cpp
  ../../../../ffmpeg_stream_decoder.cpp
  ${FAAD2_SOURCES}
  ${LIBSAMPLERATE_SOURCES}
  ${LIBSOXR_SOURCES}
)

target_include_directories(audio_engine PRIVATE
  ../../../../
  ../../../../dsp
  ../../../../third_party
  ../../../../third_party/faad2/include
  ../../../../third_party/faad2/libfaad
  ../../../../third_party/libsamplerate/include
  ../../../../third_party/libsoxr/include
  ../../../../third_party/libsoxr/src
  ../../../../third_party/r8brain
  ../../../../third_party/ffmpeg/include
)

target_compile_definitions(audio_engine PRIVATE
  HAVE_INTTYPES_H=1
  HAVE_MEMCPY=1
  HAVE_STRING_H=1
  HAVE_STDBOOL_H=1
  HAVE_STRINGS_H=1
  HAVE_SYS_TYPES_H=1
  PACKAGE="libsamplerate"
  VERSION="0.2.2"
  PACKAGE_VERSION="2.11.1"
  ENABLE_SINC_BEST_CONVERTER=1
  ENABLE_SINC_MEDIUM_CONVERTER=1
  ENABLE_SINC_FAST_CONVERTER=1
  MA_NO_ASSERT
  MA_DR_WAV_NO_ASSERT
  MA_DR_FLAC_NO_ASSERT
  MA_DR_MP3_NO_ASSERT
  SOXR_LIB=1
)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(audio_engine PRIVATE $<$<NOT:$<CONFIG:Debug>>:-O3 -ffast-math -ftree-vectorize>)
  if(ANDROID_ABI STREQUAL "armeabi-v7a")
    target_compile_options(audio_engine PRIVATE -mfpu=neon)
  endif()
endif()

# Suppress harmless warnings from third-party FAAD2 C code
set_source_files_properties(${FAAD2_SOURCES} PROPERTIES
  COMPILE_FLAGS "-Wno-everything"
)

find_library(log-lib log)

# IMPORTANT:
# Avoid find_package(CURL) in Android plugin builds. It can trigger repeated
# CMake regeneration loops on some NDK/AGP setups (ninja: build.ninja dirty).
# If you need native URL streaming on Android, pass explicit variables from
# Gradle/CMake args instead:
#   -DMINIAUDIODART_ENABLE_CURL=ON
#   -DMINIAUDIODART_CURL_INCLUDE_DIR=<path>
#   -DMINIAUDIODART_CURL_LIBRARY=<path-to-libcurl>
# Optional convenience:
#   -DMINIAUDIODART_CURL_LIBRARY_DIR=<dir-containing-abi-folders>
# If MINIAUDIODART_CURL_LIBRARY is omitted, CMake will attempt to resolve
# one of:
#   <MINIAUDIODART_CURL_LIBRARY_DIR>/<ANDROID_ABI>/libcurl.a
#   <MINIAUDIODART_CURL_LIBRARY_DIR>/<ANDROID_ABI>/libcurl.so
# and fallback to:
#   <repo>/native/android/<ANDROID_ABI>/libcurl.a
#   <repo>/native/android/<ANDROID_ABI>/libcurl.so
set(_md_repo_root "${CMAKE_CURRENT_SOURCE_DIR}/../../../../")

option(MINIAUDIODART_ENABLE_CURL "Enable native URL streaming via libcurl" ON)
if(MINIAUDIODART_ENABLE_CURL)
  set(_md_default_include_dir "${_md_repo_root}/native/android/include")
  set(_md_default_library_dir "${_md_repo_root}/native/android")

  set(_md_curl_include_dir "${MINIAUDIODART_CURL_INCLUDE_DIR}")
  set(_md_curl_library "${MINIAUDIODART_CURL_LIBRARY}")
  set(_md_curl_library_dir "${MINIAUDIODART_CURL_LIBRARY_DIR}")
  set(_md_curl_extra_libs "${MINIAUDIODART_CURL_EXTRA_LIBS}")

  if(NOT _md_curl_include_dir)
    if(EXISTS "${_md_default_include_dir}")
      set(_md_curl_include_dir "${_md_default_include_dir}")
    endif()
  endif()

  if(NOT _md_curl_library)
    if(NOT _md_curl_library_dir)
      set(_md_curl_library_dir "${_md_default_library_dir}")
    endif()

    if(ANDROID_ABI)
      set(_md_curl_abi_dir "${_md_curl_library_dir}/${ANDROID_ABI}")
      # Prefer static linking on Android plugin builds to avoid extra .so packaging.
      if(EXISTS "${_md_curl_abi_dir}/libcurl.a")
        set(_md_curl_library "${_md_curl_abi_dir}/libcurl.a")
      elseif(EXISTS "${_md_curl_abi_dir}/libcurl.so")
        set(_md_curl_library "${_md_curl_abi_dir}/libcurl.so")
      endif()
    endif()
  endif()

  if(NOT _md_curl_library)
    find_library(_md_system_curl curl)
    if(_md_system_curl)
      set(_md_curl_library "${_md_system_curl}")
    endif()
  endif()

  if(_md_curl_include_dir AND _md_curl_library)
    target_compile_definitions(audio_engine PRIVATE AE_ENABLE_CURL=1)
    target_include_directories(audio_engine PRIVATE ${_md_curl_include_dir})
    target_link_libraries(audio_engine PRIVATE ${_md_curl_library} ${_md_curl_extra_libs})
    message(STATUS "MiniAudioDart Android: native network streaming enabled (libcurl).")
  else()
    message(WARNING
      "MiniAudioDart Android: libcurl not resolved; building without native network streaming. "
      "To enable, provide MINIAUDIODART_CURL_INCLUDE_DIR and MINIAUDIODART_CURL_LIBRARY "
      "or bundle artifacts under native/android/include and native/android/<ABI>/libcurl.(so|a)."
    )
  endif()
endif()

# FFmpeg native libraries resolution for Android
set(_md_ffmpeg_lib_dir "${_md_repo_root}/third_party/ffmpeg/android/${ANDROID_ABI}")
if(NOT (EXISTS "${_md_ffmpeg_lib_dir}/libavformat.so" OR EXISTS "${_md_ffmpeg_lib_dir}/libavformat.a"))
  set(_md_ffmpeg_lib_dir "${_md_repo_root}/native/android/${ANDROID_ABI}")
endif()

set(_md_has_avformat FALSE)
set(_md_has_avcodec FALSE)
set(_md_has_avutil FALSE)
set(_md_has_swresample FALSE)

if(EXISTS "${_md_ffmpeg_lib_dir}/libavformat.so" OR EXISTS "${_md_ffmpeg_lib_dir}/libavformat.a")
  set(_md_has_avformat TRUE)
endif()
if(EXISTS "${_md_ffmpeg_lib_dir}/libavcodec.so" OR EXISTS "${_md_ffmpeg_lib_dir}/libavcodec.a")
  set(_md_has_avcodec TRUE)
endif()
if(EXISTS "${_md_ffmpeg_lib_dir}/libavutil.so" OR EXISTS "${_md_ffmpeg_lib_dir}/libavutil.a")
  set(_md_has_avutil TRUE)
endif()
if(EXISTS "${_md_ffmpeg_lib_dir}/libswresample.so" OR EXISTS "${_md_ffmpeg_lib_dir}/libswresample.a")
  set(_md_has_swresample TRUE)
endif()

if(_md_has_avformat AND _md_has_avcodec AND _md_has_avutil AND _md_has_swresample)
  target_compile_definitions(audio_engine PRIVATE SAUTIFLOW_ENABLE_FFMPEG=1)
  if(EXISTS "${_md_repo_root}/native/android/include")
    target_include_directories(audio_engine BEFORE PRIVATE "${_md_repo_root}/native/android/include")
  endif()
  target_link_directories(audio_engine PRIVATE ${_md_ffmpeg_lib_dir})
  target_link_libraries(audio_engine PRIVATE avformat avcodec avutil swresample)
  if(EXISTS "${_md_ffmpeg_lib_dir}/libmbedtls.so" OR EXISTS "${_md_ffmpeg_lib_dir}/libmbedtls.a")
    target_link_libraries(audio_engine PRIVATE mbedtls mbedcrypto mbedx509)
  endif()
  message(STATUS "MiniAudioDart Android: FFmpeg native streaming decoder enabled for ${ANDROID_ABI} (${_md_ffmpeg_lib_dir}).")
else()
  # Attempt direct/system resolution
  find_library(avformat-lib avformat)
  find_library(avcodec-lib avcodec)
  find_library(avutil-lib avutil)
  find_library(swresample-lib swresample)
  if(avformat-lib AND avcodec-lib AND avutil-lib AND swresample-lib)
    target_compile_definitions(audio_engine PRIVATE SAUTIFLOW_ENABLE_FFMPEG=1)
    target_link_libraries(audio_engine PRIVATE ${avformat-lib} ${avcodec-lib} ${avutil-lib} ${swresample-lib})
    message(STATUS "MiniAudioDart Android: FFmpeg native streaming decoder enabled for ${ANDROID_ABI} (system libs).")
  else()
    message(STATUS "MiniAudioDart Android: FFmpeg prebuilts (including libswresample) not fully resolved for ${ANDROID_ABI}; built with native decoders (minimp4/faad2/miniaudio).")
  endif()
endif()

target_link_libraries(audio_engine PRIVATE
  ${log-lib}
  android
  m
)

set_target_properties(audio_engine PROPERTIES
  OUTPUT_NAME "sautiflow"
)
