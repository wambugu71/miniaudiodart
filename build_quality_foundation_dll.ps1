$ErrorActionPreference = "Stop"

$objDir = "build/obj_dll"
New-Item -ItemType Directory -Force -Path $objDir | Out-Null
Remove-Item "$objDir/*" -Force -Recurse -ErrorAction SilentlyContinue

$includes = @(
    "-I.",
    "-Ithird_party",
    "-Ithird_party/faad2/include",
    "-Ithird_party/faad2/libfaad",
    "-Ithird_party/libsamplerate/include",
    "-Ithird_party/libsoxr/include",
    "-Ithird_party/libsoxr/src",
    "-Ithird_party/ffmpeg/include",
    "-Ithird_party/r8brain",
    "-Idsp"
)

$defines = @(
    "-D_USE_MATH_DEFINES",
    "-DNOMINMAX",
    "-DWIN32_LEAN_AND_MEAN",
    '-DPACKAGE_VERSION=\"2.11.1\"',
    '-DPACKAGE=\"libsamplerate\"',
    '-DVERSION=\"0.2.2\"',
    '-DHAVE_INTTYPES_H=1',
    '-DHAVE_MEMCPY=1',
    '-DHAVE_STRING_H=1',
    '-DHAVE_STDBOOL_H=1',
    '-DHAVE_STRINGS_H=1',
    '-DHAVE_SYS_TYPES_H=1',
    '-DSOXR_LIB=1',
    '-DENABLE_SINC_BEST_CONVERTER=1',
    '-DENABLE_SINC_MEDIUM_CONVERTER=1',
    '-DENABLE_SINC_FAST_CONVERTER=1',
    "-DSAUTIFLOW_ENABLE_FFMPEG=1"
)

$cFiles = (Get-ChildItem -Path "third_party/libsamplerate/src/*.c" | Select-Object -ExpandProperty FullName) + `
          (Get-ChildItem -Path "third_party/faad2/libfaad/*.c" | Select-Object -ExpandProperty FullName) + @(
    (Get-Item "third_party/libsoxr/src/soxr.c").FullName,
    (Get-Item "third_party/libsoxr/src/data-io.c").FullName,
    (Get-Item "third_party/libsoxr/src/filter.c").FullName,
    (Get-Item "third_party/libsoxr/src/cr.c").FullName,
    (Get-Item "third_party/libsoxr/src/cr32.c").FullName,
    (Get-Item "third_party/libsoxr/src/cr32s.c").FullName,
    (Get-Item "third_party/libsoxr/src/cr64.c").FullName,
    (Get-Item "third_party/libsoxr/src/vr32.c").FullName,
    (Get-Item "third_party/libsoxr/src/pffft32s.c").FullName,
    (Get-Item "third_party/libsoxr/src/pffft-wrap.c").FullName,
    (Get-Item "third_party/libsoxr/src/fft4g32.c").FullName,
    (Get-Item "third_party/libsoxr/src/fft4g64.c").FullName,
    (Get-Item "third_party/libsoxr/src/dbesi0.c").FullName,
    (Get-Item "third_party/libsoxr/src/util32s.c").FullName
)

Write-Host "Compiling C files..."
foreach ($f in $cFiles) {
    $objName = [System.IO.Path]::GetFileNameWithoutExtension($f) + "_" + [System.IO.Path]::GetRandomFileName() + ".o"
    $objPath = Join-Path $objDir $objName
    gcc -O2 -c $f -o $objPath @includes @defines
    if ($LASTEXITCODE -ne 0) { throw "gcc failed on $f" }
}

$cppFiles = @(
    "audio_engine.cpp",
    "mp4_aac_decoder.cpp",
    "ffmpeg_stream_decoder.cpp"
)

Write-Host "Compiling C++ files..."
foreach ($f in $cppFiles) {
    $objName = [System.IO.Path]::GetFileNameWithoutExtension($f) + "_" + [System.IO.Path]::GetRandomFileName() + ".o"
    $objPath = Join-Path $objDir $objName
    g++ -std=c++20 -O2 -c $f -o $objPath @includes @defines
    if ($LASTEXITCODE -ne 0) { throw "g++ failed on $f" }
}

Write-Host "Linking sautiflow.dll & audio_engine.dll..."
$allObjs = Get-ChildItem -Path "$objDir/*.o" | Select-Object -ExpandProperty FullName
g++ -shared -std=c++20 -O2 -o sautiflow.dll @allObjs -Lthird_party/ffmpeg/lib -lavformat -lavcodec -lavutil -lswresample -static-libgcc -static-libstdc++ -lwinmm -lws2_32 -lbcrypt -lsecur32 -lm
if ($LASTEXITCODE -ne 0) { throw "Linking sautiflow.dll failed" }

Copy-Item sautiflow.dll audio_engine.dll -Force

# Copy FFmpeg runtime DLLs to root and build directories
if (Test-Path "third_party/ffmpeg/bin") {
    try { Copy-Item third_party/ffmpeg/bin/*.dll . -Force -ErrorAction SilentlyContinue } catch {}
    if (Test-Path "sautiplay") {
        try { Copy-Item third_party/ffmpeg/bin/*.dll sautiplay/ -Force -ErrorAction SilentlyContinue } catch {}
    }
}

Write-Host "DLL build complete! Created sautiflow.dll and audio_engine.dll with native FFmpeg streaming."
