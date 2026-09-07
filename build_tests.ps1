# =============================================================================
# build_tests.ps1
#
# Builds and runs the fix-verification test suites:
#   tests/test_dsp_fixes.cpp   - header-level DSP unit tests (no device needed)
#   tests/test_engine_api.cpp  - engine API tests (links full engine objects)
#
# Reuses the third-party objects already compiled in build/obj_dll by
# build_quality_foundation_dll.ps1; rebuilds engine objects from current source.
# =============================================================================
$ErrorActionPreference = "Stop"

$objDir = "build/obj_tests"
New-Item -ItemType Directory -Force -Path $objDir | Out-Null

$includes = @(
    "-I.",
    "-Itests",
    "-Ithird_party",
    "-Ithird_party/faad2/include",
    "-Ithird_party/faad2/libfaad",
    "-Ithird_party/libsamplerate/include",
    "-Ithird_party/libsoxr/include",
    "-Ithird_party/libsoxr/src",
    "-Ithird_party/r8brain",
    "-Ithird_party/ffmpeg/include",
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
    "-DSAUTIFLOW_ENABLE_FFMPEG=1"
)

$failed = $false

# ---------------------------------------------------------------------------
# Test 1: header-level DSP unit tests (self-contained, fast)
# ---------------------------------------------------------------------------
Write-Host "== Building test_dsp_fixes.exe =="
g++ -std=c++20 -O2 -Wall -c tests/test_dsp_fixes.cpp -o "$objDir/test_dsp_fixes.o" @includes @defines
if ($LASTEXITCODE -ne 0) { throw "g++ failed on test_dsp_fixes.cpp" }

g++ -std=c++20 -O2 -o test_dsp_fixes.exe "$objDir/test_dsp_fixes.o" -static-libgcc -static-libstdc++
if ($LASTEXITCODE -ne 0) { throw "linking test_dsp_fixes.exe failed" }

Write-Host "== Running test_dsp_fixes.exe =="
./test_dsp_fixes.exe
if ($LASTEXITCODE -ne 0) { Write-Host "test_dsp_fixes FAILED"; $failed = $true }

# ---------------------------------------------------------------------------
# Test 2: engine API tests (needs full engine + third-party objects)
# ---------------------------------------------------------------------------
Write-Host "== Building test_engine_api.exe =="
$cppFiles = @("audio_engine.cpp", "mp4_aac_decoder.cpp", "ffmpeg_stream_decoder.cpp")
foreach ($f in $cppFiles) {
    g++ -std=c++20 -O2 -c $f -o "$objDir/$([System.IO.Path]::GetFileNameWithoutExtension($f)).o" @includes @defines
    if ($LASTEXITCODE -ne 0) { throw "g++ failed on $f" }
}

g++ -std=c++20 -O2 -c tests/test_engine_api.cpp -o "$objDir/test_engine_api.o" @includes @defines
if ($LASTEXITCODE -ne 0) { throw "g++ failed on test_engine_api.cpp" }

# Reuse third-party C objects from the DLL build if present; otherwise fail
# with a clear instruction. Exclude any engine C++ objects (compiled fresh above
# and possibly present multiple times under randomized names).
$dllObjs = Get-ChildItem -Path "build/obj_dll/*.o" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(audio_engine|mp4_aac_decoder|ffmpeg_stream_decoder)' } |
    Select-Object -ExpandProperty FullName
if (-not $dllObjs) {
    throw "build/obj_dll is empty - run build_quality_foundation_dll.ps1 first"
}

$linkObjs = @(
    "$objDir/audio_engine.o",
    "$objDir/mp4_aac_decoder.o",
    "$objDir/ffmpeg_stream_decoder.o",
    "$objDir/test_engine_api.o"
) + $dllObjs

g++ -std=c++20 -O2 -o test_engine_api.exe @linkObjs `
    -Lthird_party/ffmpeg/lib -lavformat -lavcodec -lavutil -lswresample `
    -static-libgcc -static-libstdc++ -lwinmm -lws2_32 -lbcrypt -lsecur32 -lm
if ($LASTEXITCODE -ne 0) { throw "linking test_engine_api.exe failed" }

# FFmpeg runtime DLLs must be findable next to the exe
Copy-Item av*.dll, sw*.dll -Destination . -Force -ErrorAction SilentlyContinue

Write-Host "== Running test_engine_api.exe =="
./test_engine_api.exe
if ($LASTEXITCODE -ne 0) { Write-Host "test_engine_api FAILED"; $failed = $true }

if ($failed) {
    Write-Host ""
    Write-Host "!!! ONE OR MORE TEST SUITES FAILED !!!" -ForegroundColor Red
    exit 1
}
else {
    Write-Host ""
    Write-Host "ALL TEST SUITES PASSED" -ForegroundColor Green
    exit 0
}
