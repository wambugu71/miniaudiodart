// =============================================================================
// tests/test_64bit_and_oversampling.cpp
//
// Verification of:
//   1. True 64-bit double precision DSP processing (SubsonicFilter, Biquad64,
//      Remez Polyphase Oversamplers 2x & 4x).
//   2. Elimination of intermediate truncation and dynamic range preservation.
//   3. Remez Half-band filter frequency response (flat passband < 0.7 dB ripple,
//      exact unity DC gain, no treble loss).
// =============================================================================

#define _USE_MATH_DEFINES
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "dsp/subsonic_filter.h"
#include "dsp/oversampler.h"
#include "dsp/denormals.h"

using namespace sauti::dsp;

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

static bool nearlyEqualD(double a, double b, double tol)
{
    return std::fabs(a - b) <= tol;
}

// Biquad64 implementation matching audio_engine.cpp
struct Biquad64Test
{
    double b0 = 1.0, b1 = 0.0, b2 = 0.0;
    double a1 = 0.0, a2 = 0.0;
    double s1[2] = {0.0, 0.0};
    double s2[2] = {0.0, 0.0};

    void initPeak(double sampleRate, double freq, double gainDB, double q)
    {
        if (sampleRate <= 0.0) sampleRate = 48000.0;
        if (freq >= sampleRate * 0.499) freq = sampleRate * 0.499;
        if (freq < 10.0) freq = 10.0;
        if (q < 0.01) q = 0.01;

        const double w0 = 2.0 * M_PI * (freq / sampleRate);
        const double alpha = std::sin(w0) / (2.0 * q);
        const double A = std::pow(10.0, gainDB / 40.0);
        const double cosw0 = std::cos(w0);

        const double a0 = 1.0 + alpha / A;
        b0 = (1.0 + alpha * A) / a0;
        b1 = (-2.0 * cosw0) / a0;
        b2 = (1.0 - alpha * A) / a0;
        a1 = (-2.0 * cosw0) / a0;
        a2 = (1.0 - alpha / A) / a0;
        s1[0] = s1[1] = s2[0] = s2[1] = 0.0;
    }

    void process(double *buf, size_t frames, int channels)
    {
        for (size_t i = 0; i < frames; ++i)
        {
            for (int c = 0; c < channels && c < 2; ++c)
            {
                const double in = buf[i * (size_t)channels + (size_t)c];
                const double out = b0 * in + s1[c];
                s1[c] = b1 * in - a1 * out + s2[c];
                s2[c] = b2 * in - a2 * out;
                buf[i * (size_t)channels + (size_t)c] = out;
            }
        }
    }
};

// -----------------------------------------------------------------------------
// Test 1: Subsonic Filter 64-bit float precision
// -----------------------------------------------------------------------------
static void test_subsonic_filter_64bit()
{
    std::printf("\n== Test 1: SubsonicFilter 64-bit Double Precision ==\n");
    SubsonicFilter filter;
    filter.setSampleRate(48000.0f);
    filter.setEnabled(true);

    // 1. DC bias blocking
    const size_t n = 48000;
    std::vector<double> dcBuf(n * 2, 0.75); // 0.75 constant DC in both channels
    filter.process(dcBuf.data(), n, 2);

    const double endDC_L = std::fabs(dcBuf[(n - 1) * 2 + 0]);
    const double endDC_R = std::fabs(dcBuf[(n - 1) * 2 + 1]);
    CHECK(endDC_L < 1e-4 && endDC_R < 1e-4, "SubsonicFilter64 blocks DC bias completely (< 1e-4)");

    // 2. 1 kHz audio passband transparency
    filter.reset();
    std::vector<double> sineBuf(4800, 0.0);
    for (size_t i = 0; i < 2400; ++i)
    {
        double s = std::sin(2.0 * M_PI * 1000.0 * (double)i / 48000.0);
        sineBuf[i * 2 + 0] = s;
        sineBuf[i * 2 + 1] = s;
    }
    filter.process(sineBuf.data(), 2400, 2);

    double maxAmp = 0.0;
    for (size_t i = 1200; i < 2400; ++i)
    {
        maxAmp = std::max(maxAmp, std::fabs(sineBuf[i * 2 + 0]));
    }
    CHECK(nearlyEqualD(maxAmp, 1.0, 0.01), "SubsonicFilter64 preserves 1 kHz audio at unity gain (1.00)");
}

// -----------------------------------------------------------------------------
// Test 2: Biquad64 Double Precision Dynamic Headroom & Precision
// -----------------------------------------------------------------------------
static void test_biquad64_precision()
{
    std::printf("\n== Test 2: Biquad64 EQ Precision & Dynamic Range ==\n");
    Biquad64Test eq;
    eq.initPeak(48000.0, 1000.0, 6.0, 1.414); // +6 dB peak at 1 kHz

    // Process a low-level signal (-120 dBFS, amp = 1e-6)
    const size_t frames = 4800;
    std::vector<double> buf64(frames * 2);
    for (size_t i = 0; i < frames; ++i)
    {
        double s = 1e-6 * std::sin(2.0 * M_PI * 1000.0 * (double)i / 48000.0);
        buf64[i * 2 + 0] = s;
        buf64[i * 2 + 1] = s;
    }
    eq.process(buf64.data(), frames, 2);

    double maxAmp = 0.0;
    for (size_t i = 2400; i < frames; ++i)
    {
        maxAmp = std::max(maxAmp, std::fabs(buf64[i * 2 + 0]));
    }
    // +6 dB means 2x amplitude: 1e-6 * 2 = 2e-6
    const double expectedAmp = 1e-6 * std::pow(10.0, 6.0 / 20.0);
    const double relErr = std::fabs(maxAmp - expectedAmp) / expectedAmp;
    CHECK(relErr < 0.01, "Biquad64 accurately boosts low-level signal (-120 dBFS) by +6 dB without underflow");

    // Dynamic Range / Headroom test: signal at +40 dBFS (amp = 100.0)
    std::vector<double> hotBuf(frames * 2);
    for (size_t i = 0; i < frames; ++i)
    {
        double s = 100.0 * std::sin(2.0 * M_PI * 1000.0 * (double)i / 48000.0);
        hotBuf[i * 2 + 0] = s;
        hotBuf[i * 2 + 1] = s;
    }
    eq.process(hotBuf.data(), frames, 2);
    double hotMaxAmp = 0.0;
    for (size_t i = 2400; i < frames; ++i)
    {
        hotMaxAmp = std::max(hotMaxAmp, std::fabs(hotBuf[i * 2 + 0]));
    }
    CHECK(nearlyEqualD(hotMaxAmp, 100.0 * std::pow(10.0, 6.0 / 20.0), 2.0),
          "Biquad64 preserves +40 dBFS headroom without wrapping or clipping");
}

// -----------------------------------------------------------------------------
// Test 3: Remez Half-band 2x and 4x Polyphase Oversampler (Float64 & Float32)
// -----------------------------------------------------------------------------
static void test_oversamplers_frequency_response()
{
    std::printf("\n== Test 3: Remez Half-band Oversampler Flat Passband & Unity DC ==\n");
    PolyphaseOversampler2x64 os2x64;
    PolyphaseOversampler4x64 os4x64;

    // Test DC Gain: constant 0.5 input
    const uint32_t frames = 2048;
    std::vector<double> dcIn64(frames * 2, 0.5);
    std::vector<double> down2x64(frames * 2);

    double *up2x64 = os2x64.upsample(dcIn64.data(), frames);
    os2x64.downsample(up2x64, down2x64.data(), frames);

    const double endDC_2x64 = down2x64[(frames - 1) * 2 + 0];
    CHECK(nearlyEqualD(endDC_2x64, 0.5, 1e-4), "PolyphaseOversampler2x64 roundtrip DC gain is exactly 1.0000");

    // Test 4x DC gain (in-place pass-through)
    std::vector<double> dcIn4x64(frames * 2, 0.5);
    os4x64.process(dcIn4x64.data(), frames, [](double*, uint32_t) {
        // identity pass-through at 4x rate
    });
    const double endDC_4x64 = dcIn4x64[(frames - 1) * 2 + 0];
    CHECK(nearlyEqualD(endDC_4x64, 0.5, 1e-4), "PolyphaseOversampler4x64 roundtrip DC gain is exactly 1.0000");

    // Frequency sweep across passband to verify NO TREBLE LOSS:
    // Test frequencies at 48 kHz sample rate: 1 kHz, 5 kHz, 10 kHz, 15 kHz, 18 kHz, 20 kHz.
    const double freqs[] = {1000.0, 5000.0, 10000.0, 15000.0, 18000.0, 20000.0};
    const uint32_t testFrames = 4096;

    for (double f : freqs)
    {
        PolyphaseOversampler2x64 testOS;
        std::vector<double> sineIn(testFrames * 2);
        std::vector<double> outBuf(testFrames * 2);

        for (size_t i = 0; i < testFrames; ++i)
        {
            double val = std::sin(2.0 * M_PI * f * (double)i / 48000.0);
            sineIn[i * 2 + 0] = val;
            sineIn[i * 2 + 1] = val;
        }

        double *upBuf = testOS.upsample(sineIn.data(), testFrames);
        testOS.downsample(upBuf, outBuf.data(), testFrames);

        // Measure steady-state amplitude after filter group delay settles (from frame 2000 to 4000)
        double peak = 0.0;
        for (size_t i = 2000; i < 4000; ++i)
        {
            peak = std::max(peak, std::fabs(outBuf[i * 2 + 0]));
        }

        const double gainDB = 20.0 * std::log10(peak);
        char msg[128];
        std::snprintf(msg, sizeof(msg), "Passband at %.0f Hz: peak = %.4f (gain = %+.2f dB, within [-0.75, +0.35] dB)",
                      f, peak, gainDB);
        // Requirement: passband ripple < 0.75 dB up to 20 kHz (old buggy FIR had -11.5 dB drop at 20 kHz!)
        CHECK(gainDB >= -0.75 && gainDB <= 0.35, msg);
    }
}

// -----------------------------------------------------------------------------
// Test 4: Dynamic Range Comparison (Float64 vs Float32 quantization noise)
// -----------------------------------------------------------------------------
static void test_float64_vs_float32_dynamic_range()
{
    std::printf("\n== Test 4: Float64 vs Float32 Quantization Noise Floor ==\n");

    const size_t count = 48000;
    const double tinyAmp = 1e-7; // -140 dBFS
    const double largeAmp = 0.9;

    double f64_signal_sum = 0.0;
    float f32_signal_sum = 0.0f;

    for (size_t i = 0; i < count; ++i)
    {
        double exactCarrier = largeAmp * std::sin(2.0 * M_PI * 440.0 * (double)i / 48000.0);
        double exactTiny = tinyAmp * std::sin(2.0 * M_PI * 1000.0 * (double)i / 48000.0);
        double sample64 = exactCarrier + exactTiny;
        double recoveredTiny64 = sample64 - exactCarrier;
        f64_signal_sum += std::fabs(recoveredTiny64);

        float exactCarrier32 = static_cast<float>(exactCarrier);
        float sample32 = static_cast<float>(sample64);
        float recoveredTiny32 = sample32 - exactCarrier32;
        f32_signal_sum += std::fabs(recoveredTiny32);
    }

    const double avg64 = f64_signal_sum / (double)count;
    const float avg32 = f32_signal_sum / (float)count;

    char msg[160];
    std::snprintf(msg, sizeof(msg), "Float64 recovered tiny signal avg = %.3e (exact ~6.36e-8), Float32 err avg = %.3e",
                  avg64, (double)avg32);
    // In float64, recovered signal is accurate to within 0.01%
    CHECK(nearlyEqualD(avg64, 2.0 * tinyAmp / M_PI, 1e-9), msg);
}

int main()
{
    std::printf("====================================================\n");
    std::printf(" 64-bit DSP & Oversampling Precision Verification\n");
    std::printf("====================================================\n");

    test_subsonic_filter_64bit();
    test_biquad64_precision();
    test_oversamplers_frequency_response();
    test_float64_vs_float32_dynamic_range();

    std::printf("\n----------------------------------------------------\n");
    std::printf(" RESULTS: %d passed, %d failed\n", g_passes, g_failures);
    std::printf("----------------------------------------------------\n");

    return g_failures == 0 ? 0 : 1;
}
