param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

Write-Host "Building Windows DLL..."

$curlArgs = @()
try {
    $null = (Get-Command pkg-config -ErrorAction Stop)
    pkg-config --exists libcurl
    if ($LASTEXITCODE -eq 0) {
        $cflags = (pkg-config --cflags libcurl).Trim()
        $libs = (pkg-config --libs libcurl).Trim()
        $curlArgs += "-DAE_ENABLE_CURL=1"
        if ($cflags) { $curlArgs += ($cflags -split "\s+") }
        if ($libs) { $curlArgs += ($libs -split "\s+") }
        Write-Host "libcurl detected: enabling native URL byte-streaming"
    }
}
catch {
}

if ($curlArgs.Count -eq 0) {
    Write-Host "libcurl not found: building without native URL byte-streaming"
}

# Create temporary obj directory
$objDir = "build\obj"
New-Item -ItemType Directory -Force -Path $objDir | Out-Null
Remove-Item "$objDir\*" -Force -Recurse -ErrorAction SilentlyContinue

$includes = @(
    "-I.",
    "-Idsp",
    "-Ithird_party",
    "-Ithird_party/faad2/include",
    "-Ithird_party/faad2/libfaad",
    "-Ithird_party/libsamplerate/include",
    "-Ithird_party/libsoxr/include",
    "-Ithird_party/libsoxr/src",
    "-Ithird_party/r8brain",
    "-Ithird_party/ffmpeg/include"
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

Write-Host "Compiling C sources with gcc..."
$soxrSources = @(
    "third_party/libsoxr/src/soxr.c",
    "third_party/libsoxr/src/data-io.c",
    "third_party/libsoxr/src/filter.c",
    "third_party/libsoxr/src/cr.c",
    "third_party/libsoxr/src/cr32.c",
    "third_party/libsoxr/src/cr32s.c",
    "third_party/libsoxr/src/cr64.c",
    "third_party/libsoxr/src/vr32.c",
    "third_party/libsoxr/src/pffft32s.c",
    "third_party/libsoxr/src/pffft-wrap.c",
    "third_party/libsoxr/src/fft4g32.c",
    "third_party/libsoxr/src/fft4g64.c",
    "third_party/libsoxr/src/dbesi0.c",
    "third_party/libsoxr/src/vr-coefs.c",
    "third_party/libsoxr/src/util32s.c"
)
$cFiles = (Get-ChildItem -Path "third_party/faad2/libfaad/*.c", "third_party/libsamplerate/src/*.c" | Select-Object -ExpandProperty FullName) + ($soxrSources | ForEach-Object { (Get-Item $_).FullName })
foreach ($f in $cFiles) {
    $objName = [System.IO.Path]::GetFileNameWithoutExtension($f) + "_" + [System.IO.Path]::GetRandomFileName() + ".o"
    $objPath = Join-Path $objDir $objName
    gcc -O2 -c $f -o $objPath @includes @defines
    if ($LASTEXITCODE -ne 0) { throw "gcc failed on $f" }
}

Write-Host "Compiling C++ sources with g++..."
$cppFiles = @(
    "audio_engine.cpp",
    "mp4_aac_decoder.cpp",
    "ffmpeg_stream_decoder.cpp"
)

foreach ($f in $cppFiles) {
    $objName = [System.IO.Path]::GetFileNameWithoutExtension($f) + "_" + [System.IO.Path]::GetRandomFileName() + ".o"
    $objPath = Join-Path $objDir $objName
    g++ -std=c++17 -O2 -c $f -o $objPath @includes @defines @curlArgs
    if ($LASTEXITCODE -ne 0) { throw "g++ failed on $f" }
}

Write-Host "Linking audio_engine.dll..."
$allObjs = Get-ChildItem -Path "$objDir\*.o" | Select-Object -ExpandProperty FullName
g++ -std=c++17 -O2 -shared -o audio_engine.dll @allObjs @curlArgs -Lthird_party/ffmpeg/lib -lavformat -lavcodec -lavutil -lswresample -static-libgcc -static-libstdc++ -lwinmm -lpthread -lws2_32 -lbcrypt -lsecur32 -lm
if ($LASTEXITCODE -ne 0) { throw "Linking failed" }

New-Item -ItemType Directory -Force -Path "build\windows" | Out-Null
Copy-Item "audio_engine.dll" "build\windows\audio_engine.dll" -Force
Copy-Item "audio_engine.dll" "sautiflow.dll" -Force

Write-Host "Done: build/windows/audio_engine.dll"
