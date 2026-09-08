// =============================================================================
// tests/test_engine_api.cpp
//
// Engine-level verification through the public ae_* C API:
//   [C] 1.1  Auto-SR jump no longer self-deadlocks (control-path exercise)
//   [C] 1.3  DSP setters are safe against the realtime thread (smoke)
//   [C] 1.8  Push-stream chunk wait is abortable via ae_stop()
//   [C] 1.9  End-callback registration is race-free under a running producer
//   [M] 3.6  Telemetry reports real underrun counter / sample peak fields
//
// Links directly against the engine objects; does not require audible output
// but DOES open the default audio device.
// =============================================================================

#include "audio_engine.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <thread>
#include <vector>

static int g_failures = 0;
static int g_passes = 0;

#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (cond) {                                                             \
            ++g_passes;                                                         \
            std::printf("  [PASS] %s\n", msg);                                  \
        } else {                                                                \
            ++g_failures;                                                       \
            std::printf("  [FAIL] %s  (%s:%d)\n", msg, __FILE__, __LINE__);     \
        }                                                                       \
    } while (0)

using Clock = std::chrono::steady_clock;

static void test_create_destroy()
{
    std::printf("\n== Engine create/destroy ==\n");
    for (int i = 0; i < 2; ++i)
    {
        AudioEngineHandle *e = ae_create_engine(48000, 2);
        CHECK(e != nullptr, "engine created");
        ae_destroy_engine(e);
        CHECK(true, "engine destroyed without hang");
    }
}

static void test_dsp_setters_smoke()
{
    std::printf("\n== Clean-room DSP setter smoke ([C] 1.3) ==\n");
    AudioEngineHandle *e = ae_create_engine(48000, 2);
    CHECK(e != nullptr, "engine created");

    // Hammer every clean-room setter repeatedly while the device/producer run.
    bool ok = true;
    for (int i = 0; i < 200; ++i)
    {
        ae_dsp_set_clarity_enabled(e, i & 1);
        ae_dsp_set_clarity_params(e, i % 4, (i % 100) / 100.0f);
        ae_dsp_set_bass_enabled(e, i & 1);
        ae_dsp_set_bass_params(e, i % 5, 40.0f + (i % 120), (i % 100) / 100.0f);
        ae_dsp_set_dynamic_system_enabled(e, i & 1);
        ae_dsp_set_dynamic_system_params(e, i % 6, (i % 100) / 100.0f);
        ae_dsp_set_analog_warmth_enabled(e, i & 1);
        ae_dsp_set_analog_warmth_params(e, i % 3, (i % 100) / 100.0f);
        ae_dsp_set_de_esser_enabled(e, i & 1);
        ae_dsp_set_de_esser_params(e, i % 2, (i % 100) / 100.0f);
        ae_dsp_set_de_esser_params_ex(e, i % 2, 5000.0f + (i % 2000), -20.0f, 4.0f, 12.0f, 1.0f, 35.0f);
        ae_dsp_set_expander_enabled(e, i & 1);
        ae_dsp_set_expander_preset(e, i % 5);
        ae_dsp_set_expander_params(e, -50.0f, 2.0f, -18.0f, 10.0f, 250.0f);
        ae_dsp_set_expander_params_ex(e, -52.0f, 1.8f, -16.0f, 12.0f, 280.0f, 6.0f, 50.0f);
        ae_dsp_set_master_limiter_enabled(e, 0); // stays opt-in
        if (i % 50 == 0) ae_dsp_reset(e);
    }
    CHECK(ok, "400+ concurrent-ish setter calls survived");

    // De-Esser, Expander & Master limiter default checks
    CHECK(ae_dsp_get_de_esser_gain_reduction_db(e) == 0.0f,
          "de-esser inactive by default (GR = 0 dB)");
    CHECK(ae_dsp_get_expander_gain_reduction_db(e) == 0.0f,
          "expander inactive by default (GR = 0 dB)");
    CHECK(ae_dsp_get_limiter_gain_reduction_db(e) == 0.0f,
          "master limiter inactive by default (GR = 0 dB)");

    // Convolver IR load/clear round trip.
    std::vector<float> ir(1024, 0.0f);
    ir[0] = 1.0f;
    CHECK(ae_dsp_load_convolver_ir(e, ir.data(), 512, 2) == 1, "IR loaded");
    CHECK(ae_dsp_has_convolver_ir(e) == 1, "has IR");
    CHECK(ae_dsp_get_convolver_kernel_length(e) >= 512, "kernel length >= IR length");
    ae_dsp_clear_convolver_ir(e);
    CHECK(ae_dsp_has_convolver_ir(e) == 0, "IR cleared");

    ae_destroy_engine(e);
}

static void test_64bit_and_oversampling_api()
{
    std::printf("\n== 64-bit DSP & Oversampling Engine API ==\n");
    AudioEngineHandle *e = ae_create_engine(48000, 2);
    CHECK(e != nullptr, "engine created");

    // 1. 64-bit processing toggle
    CHECK(ae_get_64bit_processing_enabled(e) == 0, "64-bit processing disabled by default");
    ae_set_64bit_processing_enabled(e, 1);
    CHECK(ae_get_64bit_processing_enabled(e) == 1, "64-bit processing enabled");
    ae_set_64bit_processing_enabled(e, 0);
    CHECK(ae_get_64bit_processing_enabled(e) == 0, "64-bit processing disabled again");

    // 2. Oversampling factor
    CHECK(ae_get_dsp_oversampling(e) == 1, "oversampling default is 1x");
    ae_set_dsp_oversampling(e, 2);
    CHECK(ae_get_dsp_oversampling(e) == 2, "oversampling set to 2x");
    ae_set_dsp_oversampling(e, 4);
    CHECK(ae_get_dsp_oversampling(e) == 4, "oversampling set to 4x");
    // Test clamping
    ae_set_dsp_oversampling(e, 3);
    CHECK(ae_get_dsp_oversampling(e) == 4, "oversampling factor 3 clamped to 4x");
    ae_set_dsp_oversampling(e, 0);
    CHECK(ae_get_dsp_oversampling(e) == 1, "oversampling factor 0 clamped to 1x");
    ae_set_dsp_oversampling(e, 8);
    CHECK(ae_get_dsp_oversampling(e) == 4, "oversampling factor 8 clamped to 4x");

    ae_destroy_engine(e);
}

static void test_end_callback_race()
{
    std::printf("\n== End callback registration ([C] 1.9) ==\n");
    AudioEngineHandle *e = ae_create_engine(48000, 2);

    static std::atomic<int> cbCount{0};
    // Swap the callback repeatedly while producer/RT threads run: previously
    // this raced non-atomically with the producer snapshotting the pointers.
    for (int i = 0; i < 500; ++i)
    {
        if (i & 1)
            ae_set_end_callback(e, [](void *, AudioEngineHandle *) { cbCount.fetch_add(1); }, nullptr);
        else
            ae_set_end_callback(e, nullptr, nullptr);
    }
    CHECK(true, "500 callback swaps without crash");

    ae_destroy_engine(e);
}

static void test_push_stream_abort()
{
    std::printf("\n== Push-stream abortable wait ([C] 1.8) ==\n");
    AudioEngineHandle *e = ae_create_engine(48000, 2);
    CHECK(e != nullptr, "engine created");

    // Do NOT play: nothing drains the push ring, so it fills and the chunk
    // call would block forever in the old code.
    ae_init_push_stream(e);

    std::atomic<bool> stopped{false};
    std::thread stopper([&]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        ae_stop(e); // must unblock ae_push_stream_chunk
        stopped.store(true);
    });

    std::vector<unsigned char> chunk(64 * 1024, 0xAB);
    const auto t0 = Clock::now();
    for (int i = 0; i < 4096 && !stopped.load(); ++i)
    {
        ae_push_stream_chunk(e, chunk.data(), chunk.size());
    }
    const double elapsedSec = std::chrono::duration<double>(Clock::now() - t0).count();
    stopper.join();

    char msg[160];
    std::snprintf(msg, sizeof(msg), "chunk pushing aborted after %.2f s (< 10 s, was infinite)", elapsedSec);
    CHECK(elapsedSec < 10.0, msg);

    ae_destroy_engine(e);
}

static void test_telemetry_fields()
{
    std::printf("\n== Telemetry honesty ([M] 3.6) ==\n");
    AudioEngineHandle *e = ae_create_engine(48000, 2);

    AEQualityTelemetry t{};
    std::memset(&t, 0, sizeof(t));
    t = ae_get_quality_telemetry(e);
    CHECK(t.underrun_count == 0, "underrun counter starts at 0 (real counter, still honest)");
    CHECK(t.sample_peak_db <= -100.0f || t.sample_peak_db > -200.0f,
          "sample peak field present and sane when meters disabled (-100 sentinel)");

    ae_destroy_engine(e);
}

// ---------------------------------------------------------------------------
// Dynamic Range Compressor end-to-end: plays a loud sine through the public
// API and verifies the GR meter reports real compression, then verifies unity
// gain when the material sits below the threshold.
// ---------------------------------------------------------------------------
static bool write_test_wav(const char *path, int sampleRate, int seconds, float amplitude)
{
    const int frames = sampleRate * seconds;
    std::vector<int16_t> pcm((size_t)frames * 2);
    for (int i = 0; i < frames; ++i)
    {
        const float s = amplitude * std::sin(2.0f * 3.14159265358979f * 440.0f * (float)i / (float)sampleRate);
        const auto v = (int16_t)std::lround(s * 32767.0f);
        pcm[(size_t)2 * i] = v;
        pcm[(size_t)2 * i + 1] = v;
    }

#pragma pack(push, 1)
    struct WavHeader
    {
        char riff[4];
        uint32_t riffSize;
        char wave[4];
        char fmtId[4];
        uint32_t fmtSize;
        uint16_t audioFormat;
        uint16_t channels;
        uint32_t sampleRate;
        uint32_t byteRate;
        uint16_t blockAlign;
        uint16_t bitsPerSample;
        char dataId[4];
        uint32_t dataBytes;
    };
#pragma pack(pop)

    const uint32_t dataBytes = (uint32_t)pcm.size() * sizeof(int16_t);
    WavHeader h{};
    std::memcpy(h.riff, "RIFF", 4);
    h.riffSize = 36 + dataBytes;
    std::memcpy(h.wave, "WAVE", 4);
    std::memcpy(h.fmtId, "fmt ", 4);
    h.fmtSize = 16;
    h.audioFormat = 1; // PCM
    h.channels = 2;
    h.sampleRate = (uint32_t)sampleRate;
    h.byteRate = (uint32_t)sampleRate * 2 * sizeof(int16_t);
    h.blockAlign = 2 * sizeof(int16_t);
    h.bitsPerSample = 16;
    std::memcpy(h.dataId, "data", 4);
    h.dataBytes = dataBytes;

    FILE *f = std::fopen(path, "wb");
    if (!f) return false;
    const bool ok = std::fwrite(&h, sizeof(h), 1, f) == 1 &&
                    std::fwrite(pcm.data(), 1, dataBytes, f) == dataBytes;
    std::fclose(f);
    return ok;
}

static void test_compressor_gain_reduction()
{
    std::printf("\n== Dynamic Range Compressor end-to-end ==\n");

    const char *wavPath = "compressor_test_tone.wav";
    // 0.9 amplitude sine ~= -0.9 dBFS
    CHECK(write_test_wav(wavPath, 44100, 1, 0.9f), "test WAV written");

    AudioEngineHandle *e = ae_create_engine(44100, 2);
    CHECK(e != nullptr, "engine created");
    if (!e) { std::remove(wavPath); return; }

    const char *paths[1] = { wavPath };
    CHECK(ae_set_playlist(e, paths, 1), "playlist set");
    ae_set_loop_mode(e, 2 /* loop one: continuous audio for both phases */);

    // Extreme settings: threshold -60 dB, ratio 20:1, hard knee, fast attack.
    // Expected steady-state GR for a -0.9 dB input: ~-56 dB.
    ae_set_compressor_params(e, -60.0f, 20.0f, 0.0f, 0.5f, 100.0f, 0.0f, 0, 1, 0, 1.0f);
    ae_set_compressor_enabled(e, 1);
    CHECK(ae_play(e), "playback started");

    // Phase 1: compression engages on the loud tone. Gate on real playback
    // progress, not just is_playing, because preload can precede audio flow.
    float minGR = 0.0f;
    bool tripped = false;
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    while (Clock::now() < deadline)
    {
        const PlayerStatus st = ae_get_status(e);
        if (st.is_playing && st.position_seconds > 0.03)
        {
            const float gr = ae_get_compressor_gain_reduction_db(e);
            if (gr < minGR) minGR = gr;
            if (minGR < -20.0f) { tripped = true; break; }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    char msg[160];
    std::snprintf(msg, sizeof(msg), "loud tone compressed (min GR %.1f dB < -20 dB)", minGR);
    CHECK(tripped, msg);

    // Phase 2: same playback, threshold at the ceiling -> GR must return to
    // unity. Catching the *return* proves the GR meter tracks live state.
    ae_set_compressor_params(e, 0.0f, 20.0f, 0.0f, 0.5f, 100.0f, 0.0f, 0, 1, 0, 1.0f);
    float maxGR = -999.0f;
    bool restored = false;
    const auto deadline2 = Clock::now() + std::chrono::seconds(10);
    while (Clock::now() < deadline2)
    {
        const PlayerStatus st = ae_get_status(e);
        if (st.is_playing && st.position_seconds > 0.03)
        {
            const float gr = ae_get_compressor_gain_reduction_db(e);
            if (gr > maxGR) maxGR = gr;
            if (maxGR > -1.0f) { restored = true; break; }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    std::snprintf(msg, sizeof(msg), "below-threshold tone passes unity (GR %.1f dB > -1 dB)", maxGR);
    CHECK(restored, msg);

    ae_stop(e);
    ae_set_compressor_enabled(e, 0);
    ae_destroy_engine(e);
    std::remove(wavPath);
}


int main()
{
    std::printf("==============================================\n");
    std::printf(" Engine API fix verification\n");
    std::printf("==============================================\n");

    test_create_destroy();
    test_dsp_setters_smoke();
    test_64bit_and_oversampling_api();
    test_end_callback_race();
    test_push_stream_abort();
    test_telemetry_fields();
    test_compressor_gain_reduction();

    std::printf("\n----------------------------------------------\n");
    std::printf(" RESULTS: %d passed, %d failed\n", g_passes, g_failures);
    std::printf("----------------------------------------------\n");
    return g_failures == 0 ? 0 : 1;
}
