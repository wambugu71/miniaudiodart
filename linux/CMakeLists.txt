cmake_minimum_required(VERSION 3.10)
project(miniaudiodart_linux LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

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
  PACKAGE_VERSION="2.11.1"
  PACKAGE="libsamplerate"
  VERSION="0.2.2"
  HAVE_INTTYPES_H=1
  HAVE_MEMCPY=1
  HAVE_STRING_H=1
  HAVE_STDBOOL_H=1
  HAVE_STRINGS_H=1
  HAVE_SYS_TYPES_H=1
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
endif()

find_package(PkgConfig QUIET)
set(_md_linux_ffmpeg_dir "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux/${CMAKE_SYSTEM_PROCESSOR}")
if(NOT EXISTS "${_md_linux_ffmpeg_dir}/libavformat.so")
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "armv7|armhf")
    set(_md_linux_ffmpeg_dir "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux/armhf")
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(_md_linux_ffmpeg_dir "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux/arm64")
  else()
    set(_md_linux_ffmpeg_dir "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux/x86_64")
  endif()
endif()
if(NOT EXISTS "${_md_linux_ffmpeg_dir}/libavformat.so")
  set(_md_linux_ffmpeg_dir "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ffmpeg/lib")
endif()

if(EXISTS "${_md_linux_ffmpeg_dir}/libavformat.so" OR EXISTS "${_md_linux_ffmpeg_dir}/libavformat.a")
  target_compile_definitions(audio_engine PRIVATE SAUTIFLOW_ENABLE_FFMPEG=1)
  # Prebuilt FFmpeg headers live double-nested under native/linux/include.
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux/include/include/libavformat")
    target_include_directories(audio_engine BEFORE PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux/include/include")
  elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux/include/libavformat")
    target_include_directories(audio_engine BEFORE PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../native/linux/include")
  endif()
  target_link_directories(audio_engine PRIVATE ${_md_linux_ffmpeg_dir})
  target_link_libraries(audio_engine PRIVATE avformat avcodec avutil swresample)
  if(EXISTS "${_md_linux_ffmpeg_dir}/libmbedtls.so" OR EXISTS "${_md_linux_ffmpeg_dir}/libmbedtls.a")
    target_link_libraries(audio_engine PRIVATE mbedtls mbedcrypto mbedx509)
  endif()
elseif(PKG_CONFIG_FOUND)
  pkg_check_modules(FFMPEG QUIET libavformat libavcodec libavutil libswresample)
  if(FFMPEG_FOUND)
    target_compile_definitions(audio_engine PRIVATE SAUTIFLOW_ENABLE_FFMPEG=1)
    target_include_directories(audio_engine PRIVATE ${FFMPEG_INCLUDE_DIRS})
    target_link_libraries(audio_engine PRIVATE ${FFMPEG_LIBRARIES})
  endif()
endif()

option(MINIAUDIODART_ENABLE_CURL "Enable native URL streaming via libcurl" ON)
if(MINIAUDIODART_ENABLE_CURL)
  if(PKG_CONFIG_FOUND)
    pkg_check_modules(CURL QUIET libcurl)
    if(CURL_FOUND)
      target_compile_definitions(audio_engine PRIVATE AE_ENABLE_CURL=1)
      target_include_directories(audio_engine PRIVATE ${CURL_INCLUDE_DIRS})
      target_link_libraries(audio_engine PRIVATE ${CURL_LIBRARIES})
    endif()
  endif()
  if(NOT CURL_FOUND)
    find_library(CURL_LIB curl)
    if(CURL_LIB)
      target_compile_definitions(audio_engine PRIVATE AE_ENABLE_CURL=1)
      target_link_libraries(audio_engine PRIVATE ${CURL_LIB})
    endif()
  endif()
endif()

target_link_libraries(audio_engine PRIVATE
  pthread
  dl
  m
)

set_target_properties(audio_engine PROPERTIES
  OUTPUT_NAME "sautiflow"
)

# Required by Flutter FFI plugin packaging.
file(GLOB _md_extra_so_files "${_md_linux_ffmpeg_dir}/*.so*")

set(sautiflow_bundled_libraries
  $<TARGET_FILE:audio_engine>
  ${_md_extra_so_files}
  PARENT_SCOPE
)
