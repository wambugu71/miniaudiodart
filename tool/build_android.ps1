param(
    [string]$NdkHome = $env:ANDROID_NDK_HOME,
    [int]$Api = 24
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($NdkHome)) {
    throw "ANDROID_NDK_HOME is not set. Pass -NdkHome or set env var."
}

$toolchain = Join-Path $NdkHome "toolchains\llvm\prebuilt\windows-x86_64\bin"
if (-not (Test-Path $toolchain)) {
    throw "NDK toolchain not found at $toolchain"
}

$targets = @(
    @{ Abi = "arm64-v8a"; Target = "aarch64-linux-android" },
    @{ Abi = "armeabi-v7a"; Target = "armv7a-linux-androideabi" },
    @{ Abi = "x86_64"; Target = "x86_64-linux-android" }
)

New-Item -ItemType Directory -Force -Path "build\android" | Out-Null

$includes = @(
    "-I.",
    "-Idsp",
    "-Ithird_party",
    "-Ithird_party/faad2/include",
    "-Ithird_party/faad2/libfaad",
    "-Ithird_party/libsamplerate/include",
    "-Ithird_party/libsoxr/include",
    "-Ithird_party/libsoxr/src",
    "-Ithird_party/r8brain"
)

$defines = @(
    '-DPACKAGE_VERSION=\"2.11.1\"',
    '-DPACKAGE=\"libsamplerate\"',
    '-DVERSION=\"0.2.2\"',
    '-DHAVE_INTTYPES_H=1',
    '-DHAVE_MEMCPY=1',
    '-DHAVE_STRING_H=1',
    '-DHAVE_STDBOOL_H=1',
    '-DHAVE_STRINGS_H=1',
    '-DHAVE_SYS_TYPES_H=1',
    '-DENABLE_SINC_BEST_CONVERTER=1',
    '-DENABLE_SINC_MEDIUM_CONVERTER=1',
    '-DENABLE_SINC_FAST_CONVERTER=1',
    '-DSOXR_LIB=1'
)

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

$allSources = @(
    "audio_engine.cpp",
    "mp4_aac_decoder.cpp"
) + (Get-ChildItem -Path "third_party/faad2/libfaad/*.c", "third_party/libsamplerate/src/*.c" | Select-Object -ExpandProperty FullName) + ($soxrSources | ForEach-Object { (Get-Item $_).FullName })

foreach ($t in $targets) {
    $abi = $t.Abi
    $target = $t.Target
    $clang = Join-Path $toolchain ("{0}{1}-clang++.cmd" -f $target, $Api)
    if (-not (Test-Path $clang)) {
        throw "Compiler not found: $clang"
    }

    $outDir = Join-Path "build\android" $abi
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $outLib = Join-Path $outDir "libaudio_engine.so"

    & $clang -std=c++17 -O2 -fPIC -shared @allSources -o $outLib -D__ANDROID_API__=$Api @includes @defines
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for ABI $abi"
    }

    Write-Host "Built $outLib"
}

Write-Host "Done. Android ABI outputs under build/android/."
