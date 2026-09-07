$objDir = "build/obj_tests"
$dllObjs = Get-ChildItem -Path "build/obj_dll/*.o" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(audio_engine|mp4_aac_decoder|ffmpeg_stream_decoder)' } |
    Select-Object -ExpandProperty FullName

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
    "-DWIN32_LEAN_AND_MEAN"
)

Write-Host "== Compiling test_buffer_config.cpp =="
g++ -std=c++20 -O2 -c tests/test_buffer_config.cpp -o "$objDir/test_buffer_config.o" @includes @defines
if ($LASTEXITCODE -ne 0) { throw "g++ failed on test_buffer_config.cpp" }

$linkObjs = @(
    "$objDir/audio_engine.o",
    "$objDir/mp4_aac_decoder.o",
    "$objDir/ffmpeg_stream_decoder.o",
    "$objDir/test_buffer_config.o"
) + $dllObjs

Write-Host "== Linking test_buffer_config.exe =="
g++ -std=c++20 -O2 -o test_buffer_config.exe @linkObjs `
    -Lthird_party/ffmpeg/lib -lavformat -lavcodec -lavutil -lswresample `
    -static-libgcc -static-libstdc++ -lwinmm -lws2_32 -lbcrypt -lsecur32 -lm
if ($LASTEXITCODE -ne 0) { throw "linking test_buffer_config.exe failed" }

Write-Host "== Running test_buffer_config.exe =="
./test_buffer_config.exe
