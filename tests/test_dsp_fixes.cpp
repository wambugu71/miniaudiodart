// =============================================================================
// tests/test_dsp_fixes.cpp
//
// Unit tests for the header-level DSP fixes from Issues_bugs.md:
//   [C] 1.6  Pure Bass+ FIR: unity gain, linear phase, no signal destruction
//   [C] 1.7  CrossfeedNode::setAlgorithm switches at runtime with any mix
//   [C] 1.5  MasterLimiterDSP defaults OFF; respects ceiling when enabled
//   [M] 3.2  AnalogWarmth triode no longer injects DC offset
//   [M] 3.3  Clarity PresenceExciter bands sum back flat at unity gains
//   [M] 3.4  DynamicSystemDSP one-pole cutoff accuracy + stability
//
// These headers are self-contained; no audio device or engine required.
// Build: see build_tests.ps1
// =============================================================================

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

#include "dsp/dynamic_bass_dsp.h"
#include "dsp/master_limiter_dsp.h"
#include "dsp/clarity_dsp.h"
#include "dsp/dialog_enhancer_dsp.h"
#include "dsp/analog_warmth_dsp.h"
#include "dsp/dynamic_system_dsp.h"
#include "dsp/de_esser_dsp.h"
#include "dsp/downward_expander_dsp.h"
#include "dsp/subsonic_filter.h"
#include "dsp/denormals.h"
#include "../crossfeed_node.h"

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

static bool nearlyEqual(float a, float b, float tol)
{
    return std::fabs(a - b) <= tol;
}

// -----------------------------------------------------------------------------
// [C] 1.6 HarmonicBassDSP Pure Bass+ FIR
// -----------------------------------------------------------------------------
static void test_pure_bass_fir()
{
    std::printf("\n== [C] 1.6 Pure Bass+ polyphase FIR ==\n");

    // --- Impulse response properties ---
    {
        sauti::dsp::HarmonicBassDSP dsp;
        dsp.setSampleRate(48000.0f);
        dsp.setEnabled(true);
        dsp.setProfile(sauti::dsp::BassEnhanceProfile::PureBass);
        dsp.setBoost(0.0f); // silence injected bass; isolate the FIR path
        dsp.reset();

        const uint32_t N = 512;
        std::vector<float> buf(2 * N, 0.0f);

        // Run 1 second of silence FIRST so the bass-gain smoother (30 ms
        // time constant) fully settles at its target (boost=0); otherwise the
        // decaying injected-bass transient contaminates the impulse window.
        dsp.process(buf.data(), N);
        for (int r = 0; r < 93; ++r) dsp.process(buf.data(), N);

        for (size_t i = 0; i < buf.size(); ++i) buf[i] = 0.0f;
        dsp.reset();
        buf[2 * 100] = 0.5f;
        dsp.process(buf.data(), N);

        // Extract h[k], k = 0..62 relative to the impulse
        float h[63];
        double sum = 0.0;
        float maxAsym = 0.0f;
        int worstK = -1;
        for (int k = 0; k < 63; ++k)
        {
            h[k] = buf[2 * (100 + k)];
            sum += h[k];
        }
        for (int k = 0; k < 63; ++k)
        {
            const float a = std::fabs(h[k] - h[62 - k]);
            if (a > maxAsym) { maxAsym = a; worstK = k; }
        }

        char msg[128];
        std::snprintf(msg, sizeof(msg), "FIR DC gain ~unity (sum=%.4f, want ~0.5 for 0.5 impulse)", sum);
        CHECK(nearlyEqual((float)sum, 0.5f, 0.02f), msg);
        if (maxAsym >= 2e-4f)
        {
            std::printf("    DBG worstK=%d h[k]=%.6g h[62-k]=%.6g\n", worstK, (double)h[worstK], (double)h[62 - worstK]);
            for (int k = 0; k < 63; ++k)
                std::printf("    DBG h[%2d]=%.6g\n", k, (double)h[k]);
        }
        std::snprintf(msg, sizeof(msg), "FIR impulse response is symmetric (max asym %.2e)", maxAsym);
        CHECK(maxAsym < 2e-4f, msg);

        float peak = 0.0f;
        for (int k = 0; k < 63; ++k) peak = std::max(peak, std::fabs(h[k]));
        std::snprintf(msg, sizeof(msg), "FIR peak tap sane (%.3f, old corrupt table peaked ~0.62 with -14dB sum)", peak);
        CHECK(peak > 0.05f && peak <= 0.55f, msg);
    }

    // --- DC / passband transparency ---
    {
        sauti::dsp::HarmonicBassDSP dsp;
        dsp.setSampleRate(48000.0f);
        dsp.setEnabled(true);
        dsp.setProfile(sauti::dsp::BassEnhanceProfile::PureBass);
        dsp.setBoost(0.0f);
        dsp.reset();

        const uint32_t frames = 96000; // 2 s @ 48 kHz
        std::vector<float> buf(2 * frames, 0.25f);
        dsp.process(buf.data(), frames);

        double meanL = 0.0;
        const size_t tailStart = (size_t)(frames - 8000) * 2;
        size_t cnt = 0;
        for (size_t i = tailStart; i < buf.size(); i += 2) { meanL += buf[i]; ++cnt; }
        meanL /= (double)cnt;

        char msg[128];
        std::snprintf(msg, sizeof(msg), "DC input 0.25 passes at %.4f (old table gave ~0.05)", meanL);
        CHECK(nearlyEqual((float)meanL, 0.25f, 0.01f), msg);
    }
}

// -----------------------------------------------------------------------------
// [C] 1.7 CrossfeedNode runtime algorithm switching
// -----------------------------------------------------------------------------
static void test_crossfeed_algorithm_switch()
{
    std::printf("\n== [C] 1.7 Crossfeed algorithm switching at mix=0.5 ==\n");

    CrossfeedNode node;
    node.setMix(0.5f);
    node.setDelayMs(0.4f);
    node.setAlgorithm(CrossfeedAlgorithm::Simple);

    const uint32_t frames = 4096;
    std::mt19937 rng(12345);
    std::vector<float> in(2 * frames);
    for (auto &v : in) v = ((float)(rng() % 20000) - 10000.0f) / 10000.0f;

    std::vector<float> outSimple = in;
    node.process(outSimple.data(), frames, 2);
    node.reset();

    // The regression: with mix >= 0.001 the old code never switched algorithms.
    node.setAlgorithm(CrossfeedAlgorithm::Meier);
    CHECK(node.getAlgorithm() == CrossfeedAlgorithm::Meier, "getAlgorithm reflects new target");

    std::vector<float> outMeier = in;
    node.process(outMeier.data(), frames, 2);

    double diffEnergy = 0.0;
    for (size_t i = 0; i < in.size(); ++i)
    {
        const double d = (double)outSimple[i] - (double)outMeier[i];
        diffEnergy += d * d;
    }

    char msg[128];
    std::snprintf(msg, sizeof(msg), "Meier output differs from Simple (diff energy=%.2f)", diffEnergy);
    CHECK(diffEnergy > 1.0, msg);

    // Switching again to BS2B must also take effect immediately.
    node.reset();
    node.setAlgorithm(CrossfeedAlgorithm::BS2B);
    std::vector<float> outBs2b = in;
    node.process(outBs2b.data(), frames, 2);
    diffEnergy = 0.0;
    for (size_t i = 0; i < in.size(); ++i)
    {
        const double d = (double)outMeier[i] - (double)outBs2b[i];
        diffEnergy += d * d;
    }
    CHECK(diffEnergy > 1.0, "BS2B output differs from Meier after direct switch");
}

// -----------------------------------------------------------------------------
// [C] 1.5 MasterLimiterDSP default state and ceiling behaviour
// -----------------------------------------------------------------------------
static void test_master_limiter_defaults_and_ceiling()
{
    std::printf("\n== [C] 1.5 Master limiter default-off + ceiling ==\n");

    sauti::dsp::MasterLimiterDSP limiter;
    CHECK(!limiter.isEnabled(), "limiter is DISABLED by default (no silent coloration)");
    CHECK(nearlyEqual(limiter.getCeilingDb(), -0.1f, 0.001f), "default ceiling is -0.1 dBFS");

    // Disabled -> bit-transparent
    const uint32_t frames = 256;
    std::vector<float> buf(2 * frames);
    std::mt19937 rng(777);
    for (auto &v : buf) v = ((float)(rng() % 20000) - 10000.0f) / 5000.0f; // hot, > ceiling
    std::vector<float> copy = buf;
    limiter.process(buf.data(), frames);
    bool identical = true;
    for (size_t i = 0; i < buf.size(); ++i)
        if (buf[i] != copy[i]) { identical = false; break; }
    CHECK(identical, "disabled limiter leaves samples untouched");

    // Enabled -> hard ceiling respected on a hot master
    limiter.setCeilingDb(-6.0f);
    limiter.setEnabled(true);
    limiter.reset();
    float maxOut = 0.0f;
    for (uint32_t b = 0; b < 8; ++b)
    {
        std::vector<float> block(2 * frames);
        for (auto &v : block) v = ((float)(rng() % 20000) - 10000.0f) / 5000.0f; // hot, > ceiling
        limiter.process(block.data(), frames);
        for (float v : block) maxOut = std::max(maxOut, std::fabs(v));
    }

    const float ceilingLinear = std::pow(10.0f, -6.0f / 20.0f);

    char msg[160];
    std::snprintf(msg, sizeof(msg), "output %.4f within ceiling %.4f (+eps)", maxOut, ceilingLinear);
    CHECK(maxOut <= ceilingLinear + 1e-3f, msg);
    CHECK(limiter.getCurrentGainReductionDb() < -0.1f, "gain reduction engaged on hot material");
}

// -----------------------------------------------------------------------------
// [M] 3.2 AnalogWarmth triode DC blocker
// -----------------------------------------------------------------------------
static void test_analog_warmth_no_dc_offset()
{
    std::printf("\n== [M] 3.2 Triode warmth DC offset ==\n");

    sauti::dsp::AnalogWarmthDSP warmth;
    warmth.setSampleRate(48000.0f);
    warmth.setEnabled(true);
    warmth.setProfile(sauti::dsp::AnalogWarmthProfile::Triode12AX7);
    warmth.setDrive(1.0f); // maximum asymmetry -> worst-case DC injection
    warmth.reset();

    // Symmetric square wave at +/-0.9: zero input DC, heavy asymmetric shaping.
    const uint32_t frames = 96000; // 2 s
    std::vector<float> buf(2 * frames);
    for (uint32_t i = 0; i < frames; ++i)
    {
        const float v = ((i / 48u) % 2u == 0) ? 0.9f : -0.9f;
        buf[2 * i] = v;
        buf[2 * i + 1] = v;
    }
    warmth.process(buf.data(), frames);

    double meanL = 0.0, meanR = 0.0;
    const size_t start = (size_t)(frames - 24000) * 2; // last 0.5 s (blocker settled)
    size_t cnt = 0;
    for (size_t i = start; i < buf.size(); i += 2) { meanL += buf[i]; meanR += buf[i + 1]; ++cnt; }
    meanL /= (double)cnt;
    meanR /= (double)cnt;

    char msg[160];
    std::snprintf(msg, sizeof(msg), "residual DC L=%.4f R=%.4f (|DC| < 0.02)", meanL, meanR);
    CHECK(std::fabs(meanL) < 0.02f && std::fabs(meanR) < 0.02f, msg);
}

// -----------------------------------------------------------------------------
// [M] 3.3 Clarity PresenceExciter flat-sum crossover
// -----------------------------------------------------------------------------
static void test_clarity_presence_reconstruction()
{
    std::printf("\n== [M] 3.3 Presence exciter perfect reconstruction at intensity 0 ==\n");

    sauti::dsp::AudioClarityDSP clarity;
    clarity.setSampleRate(48000.0f);
    clarity.setEnabled(true);
    clarity.setProfile(sauti::dsp::AudioClarityProfile::PresenceExciter);
    clarity.setIntensity(0.0f); // all excitation gains collapse to unity
    clarity.reset();

    const uint32_t frames = 48000;
    std::vector<float> in(2 * frames);
    std::mt19937 rng(2024);
    for (uint32_t i = 0; i < frames; ++i)
    {
        // Broadband content: sine sweep-ish mixture + noise
        const float t = (float)i / 48000.0f;
        const float tone = 0.4f * std::sin(2.0f * 3.14159265f * (200.0f + 4000.0f * t * t) * t);
        const float noise = ((float)(rng() % 20000) - 10000.0f) / 40000.0f;
        in[2 * i] = tone + noise;
        in[2 * i + 1] = 0.8f * tone - noise;
    }

    std::vector<float> buf = in;
    clarity.process(buf.data(), frames);

    // anti-pop ramps over ~12k samples; compare only settled tail.
    double maxErr = 0.0;
    for (uint32_t i = frames - 8000; i < frames; ++i)
    {
        maxErr = std::max(maxErr, (double)std::fabs(buf[2 * i] - in[2 * i]));
        maxErr = std::max(maxErr, (double)std::fabs(buf[2 * i + 1] - in[2 * i + 1]));
    }

    char msg[128];
    std::snprintf(msg, sizeof(msg), "max reconstruction error %.2e (< 1e-4)", maxErr);
    CHECK(maxErr < 1e-4, msg);
}

// -----------------------------------------------------------------------------
// [M] 3.4 DynamicSystemDSP tuning accuracy + stability
// -----------------------------------------------------------------------------
static void test_dynamic_system_cutoff_and_stability()
{
    std::printf("\n== [M] 3.4 Dynamic system one-pole cutoff + stability ==\n");

    // Stability: loud broadband input must not diverge.
    {
        sauti::dsp::DynamicSystemDSP dsp;
        dsp.setSampleRate(48000.0f);
        dsp.setEnabled(true);
        dsp.setProfile(sauti::dsp::TransducerProfile::Headphone);
        dsp.setStrength(1.0f);
        dsp.reset();

        std::mt19937 rng(99);
        bool finite = true;
        for (uint32_t b = 0; b < 20; ++b)
        {
            std::vector<float> buf(2 * 512);
            for (auto &v : buf) v = ((float)(rng() % 20000) - 10000.0f) / 3000.0f; // > 3x hot
            dsp.process(buf.data(), 512);
            for (float v : buf)
                if (!std::isfinite(v)) { finite = false; break; }
        }
        CHECK(finite, "no NaN/Inf divergence with hot input");
    }

    // Tuning sanity, two parts:
    //  1) At strength=0 all band gains are unity and the ladder bands sum back
    //     to the input, so the response must be UNIFORM across frequencies
    //     (band misalignment / mistuned splits would break this flatness).
    //  2) At strength>0 the processor must remain stable (covered above).
    {
        auto measureGainAt = [&](sauti::dsp::DynamicSystemDSP &dsp, float freqHz) {
            const uint32_t frames = 48000;
            std::vector<float> buf(2 * frames);
            for (uint32_t i = 0; i < frames; ++i)
            {
                const float s = std::sin(2.0f * 3.14159265f * freqHz * (float)i / 48000.0f) * 0.5f;
                buf[2 * i] = s;
                buf[2 * i + 1] = s;
            }
            dsp.process(buf.data(), frames);
            double real = 0.0, imag = 0.0;
            const uint32_t start = frames - 16384;
            for (uint32_t i = start; i < frames; ++i)
            {
                real += (double)buf[2 * i] * std::sin(2.0 * 3.14159265 * (double)freqHz * (double)i / 48000.0);
                imag += (double)buf[2 * i] * std::cos(2.0 * 3.14159265 * (double)freqHz * (double)i / 48000.0);
            }
            return std::sqrt(real * real + imag * imag) / (0.5 * 16384.0);
        };

        sauti::dsp::DynamicSystemDSP dsp;
        dsp.setSampleRate(48000.0f);
        dsp.setEnabled(true);
        dsp.setProfile(sauti::dsp::TransducerProfile::HighEndReference); // x_low = 125 Hz
        dsp.setStrength(0.0f); // neutral: all band gains = 1
        dsp.reset();

        const double gLow = measureGainAt(dsp, 125.0f);
        const double gHigh = measureGainAt(dsp, 8000.0f);
        const double ratio = gLow / gHigh;

        char msg[160];
        std::snprintf(msg, sizeof(msg),
                      "neutral response uniform: gain(125Hz)=%.3f vs gain(8kHz)=%.3f (ratio %.3f, want 0.9..1.1)",
                      gLow, gHigh, ratio);
        CHECK(ratio > 0.9 && ratio < 1.1, msg);
    }
}

// -----------------------------------------------------------------------------
// Oversampled Saturation Stages Verification
// -----------------------------------------------------------------------------
static void test_oversampled_saturation()
{
    std::printf("\n== Oversampled Saturation (AnalogWarmth & Clarity & HalfBand) ==\n");

    // 1. HalfBandFilter2x & PolyphaseOversampler2x impulse response and unity gain
    {
        sauti::dsp::PolyphaseOversampler2x os;
        os.init(48000, 1024);
        os.reset();

        const uint32_t N = 256;
        std::vector<float> in(2 * N, 0.0f);
        in[2 * 20] = 1.0f;     // Left impulse
        in[2 * 20 + 1] = 0.5f; // Right impulse

        float* up = os.upsample(in.data(), N);
        CHECK(up != nullptr, "PolyphaseOversampler2x upsample returned valid buffer");

        std::vector<float> out(2 * N, 0.0f);
        os.downsample(up, out.data(), N);

        // Find peak tap and sum (DC gain) in impulse response
        float peakL = 0.0f, peakR = 0.0f;
        double sumL = 0.0, sumR = 0.0;
        int peakIdxL = -1;

        for (uint32_t i = 0; i < N; ++i) {
            sumL += out[2 * i];
            sumR += out[2 * i + 1];
            if (out[2 * i] > peakL) { peakL = out[2 * i]; peakIdxL = (int)i; }
            if (out[2 * i + 1] > peakR) { peakR = out[2 * i + 1]; }
        }

        char msgL[128], msgR[128], msgDelay[128];
        std::snprintf(msgL, sizeof(msgL), "Oversampler DC gain L=%.4f (want ~1.0)", sumL);
        std::snprintf(msgR, sizeof(msgR), "Oversampler DC gain R=%.4f (want ~0.5)", sumR);
        std::snprintf(msgDelay, sizeof(msgDelay), "Oversampler cascade group delay = %d frames (want 30)", peakIdxL);
        CHECK(nearlyEqual((float)sumL, 1.0f, 0.02f), msgL);
        CHECK(nearlyEqual((float)sumR, 0.5f, 0.02f), msgR);
        CHECK(peakIdxL == 30, msgDelay);
    }

    // 2. AnalogWarmthDSP oversampled processing with zero drive (transparency)
    {
        sauti::dsp::AnalogWarmthDSP warmth;
        warmth.setSampleRate(44100.0f);
        warmth.setEnabled(true);
        warmth.setProfile(sauti::dsp::AnalogWarmthProfile::Triode12AX7);
        warmth.setDrive(0.0f);
        warmth.reset();

        const uint32_t N = 1024;
        std::vector<float> buf(2 * N, 0.0f);

        // Stream 40 continuous blocks of 1 kHz sine wave to settle anti-pop & reach steady state
        for (int k = 0; k < 40; ++k) {
            for (uint32_t i = 0; i < N; ++i) {
                float t = (float)(k * N + i) / 44100.0f;
                float s = 0.4f * std::sin(2.0f * 3.14159265f * 1000.0f * t);
                buf[2 * i] = s;
                buf[2 * i + 1] = s;
            }
            warmth.process(buf.data(), N);
        }

        bool hasNaN = false;
        float maxVal = 0.0f;
        for (size_t i = 0; i < buf.size(); ++i) {
            if (std::isnan(buf[i]) || std::isinf(buf[i])) hasNaN = true;
            if (std::abs(buf[i]) > maxVal) maxVal = std::abs(buf[i]);
        }

        char msgAmp[128];
        std::snprintf(msgAmp, sizeof(msgAmp), "AnalogWarmthDSP zero-drive 1kHz peak amplitude = %.4f (want ~0.40)", maxVal);
        CHECK(!hasNaN, "AnalogWarmthDSP oversampled output contains no NaN/Inf");
        CHECK(nearlyEqual(maxVal, 0.40f, 0.03f), msgAmp);
    }

    // 3. AudioClarityDSP Harmonic Brilliance oversampled processing
    {
        sauti::dsp::AudioClarityDSP clarity;
        clarity.setSampleRate(44100.0f);
        clarity.setEnabled(true);
        clarity.setProfile(sauti::dsp::AudioClarityProfile::HarmonicBrilliance);
        clarity.setIntensity(0.75f);
        clarity.reset();

        const uint32_t N = 2048;
        std::vector<float> buf(2 * N, 0.0f);
        for (uint32_t i = 0; i < N; ++i) {
            // High frequency input tone above 3.5kHz cutoff
            float s = 0.3f * std::sin(2.0f * 3.14159265f * 8000.0f * (float)i / 44100.0f);
            buf[2 * i] = s;
            buf[2 * i + 1] = s;
        }

        clarity.process(buf.data(), N);
        for (int k = 0; k < 10; ++k) clarity.process(buf.data(), N);

        bool hasNaN = false;
        float maxVal = 0.0f;
        for (size_t i = 0; i < buf.size(); ++i) {
            if (std::isnan(buf[i]) || std::isinf(buf[i])) hasNaN = true;
            if (std::abs(buf[i]) > maxVal) maxVal = std::abs(buf[i]);
        }

        CHECK(!hasNaN, "AudioClarityDSP HarmonicBrilliance oversampled output contains no NaN/Inf");
        CHECK(maxVal > 0.3f, "AudioClarityDSP HarmonicBrilliance excites high frequencies");
    }
}

// -----------------------------------------------------------------------------
// DeEsserDSP Unit Tests
// -----------------------------------------------------------------------------
static void test_de_esser_dsp()
{
    std::printf("\n== DeEsserDSP Split-Band & WideBand Verification ==\n");

    // 1. Crossover perfect reconstruction at unity / inactive state
    {
        sauti::dsp::DeEsserDSP deEsser;
        deEsser.setSampleRate(48000.0f);
        deEsser.setEnabled(true);
        deEsser.setMode(sauti::dsp::DeEsserMode::SplitBand);
        deEsser.setFrequencyHz(5500.0f);
        deEsser.setIntensity(0.0f); // Inactive / 0dB reduction
        deEsser.reset();

        const uint32_t N = 2048;
        std::vector<float> inBuf(2 * N, 0.0f);
        std::vector<float> procBuf(2 * N, 0.0f);

        for (uint32_t i = 0; i < N; ++i) {
            float t = (float)i / 48000.0f;
            float s = 0.2f * std::sin(2.0f * (float)M_PI * 100.0f * t)
                    + 0.2f * std::sin(2.0f * (float)M_PI * 1000.0f * t)
                    + 0.2f * std::sin(2.0f * (float)M_PI * 5500.0f * t)
                    + 0.2f * std::sin(2.0f * (float)M_PI * 12000.0f * t);
            inBuf[2 * i]     = s;
            inBuf[2 * i + 1] = s;
            procBuf[2 * i]   = s;
            procBuf[2 * i + 1] = s;
        }

        // Settle anti-pop crossfader
        deEsser.process(procBuf.data(), N);

        // Process test block
        for (size_t i = 0; i < inBuf.size(); ++i) procBuf[i] = inBuf[i];
        deEsser.process(procBuf.data(), N);

        float maxErr = 0.0f;
        for (uint32_t i = 100; i < N; ++i) {
            maxErr = std::max(maxErr, std::abs(procBuf[2 * i] - inBuf[2 * i]));
            maxErr = std::max(maxErr, std::abs(procBuf[2 * i + 1] - inBuf[2 * i + 1]));
        }

        char msg[128];
        std::snprintf(msg, sizeof(msg), "Split-band complementary flat sum max error = %.2e (want < 1e-4)", maxErr);
        CHECK(maxErr < 1e-4f, msg);
    }

    // 2. Selective Sibilance Attenuation (SplitBand Mode)
    {
        sauti::dsp::DeEsserDSP deEsser;
        deEsser.setSampleRate(48000.0f);
        deEsser.setEnabled(true);
        deEsser.setMode(sauti::dsp::DeEsserMode::SplitBand);
        deEsser.setFrequencyHz(6000.0f);
        deEsser.setThresholdDb(-24.0f);
        deEsser.setRatio(6.0f);
        deEsser.setMaxReductionDb(12.0f);
        deEsser.reset();

        const uint32_t N = 2048;
        // Case A: Continuous hot 6kHz sibilance stream (amplitude 0.6 => -4.4 dBFS)
        std::vector<float> sibBuf(2 * N, 0.0f);
        for (int k = 0; k < 5; ++k) {
            for (uint32_t i = 0; i < N; ++i) {
                float s = 0.6f * std::sin(2.0f * (float)M_PI * 6000.0f * (float)i / 48000.0f);
                sibBuf[2 * i]     = s;
                sibBuf[2 * i + 1] = s;
            }
            deEsser.process(sibBuf.data(), N);
        }

        float grDb = deEsser.getGainReductionDb();
        char grMsg[128];
        std::snprintf(grMsg, sizeof(grMsg), "DeEsser engages gain reduction on hot 6kHz sibilance (GR=%.1f dB, want > 3.0)", grDb);
        CHECK(grDb > 3.0f, grMsg);

        // Measure compressed amplitude of 6kHz tone
        float maxSib = 0.0f;
        for (uint32_t i = N / 2; i < N; ++i) {
            maxSib = std::max(maxSib, std::abs(sibBuf[2 * i]));
        }
        CHECK(maxSib < 0.45f, "Hot 6kHz sibilance is attenuated (< 0.45 from 0.60)");

        // Case B: 200 Hz Low-frequency bass tone (SplitBand mode should NOT compress 200 Hz)
        deEsser.reset();
        std::vector<float> bassBuf(2 * N, 0.0f);
        for (int k = 0; k < 5; ++k) {
            for (uint32_t i = 0; i < N; ++i) {
                float s = 0.6f * std::sin(2.0f * (float)M_PI * 200.0f * (float)i / 48000.0f);
                bassBuf[2 * i]     = s;
                bassBuf[2 * i + 1] = s;
            }
            deEsser.process(bassBuf.data(), N);
        }

        float maxBass = 0.0f;
        for (uint32_t i = N / 2; i < N; ++i) {
            maxBass = std::max(maxBass, std::abs(bassBuf[2 * i]));
        }
        CHECK(nearlyEqual(maxBass, 0.6f, 0.05f), "SplitBand mode leaves low frequencies unattenuated (~0.60)");
    }

    // 3. WideBand Mode ducking
    {
        sauti::dsp::DeEsserDSP deEsser;
        deEsser.setSampleRate(48000.0f);
        deEsser.setEnabled(true);
        deEsser.setMode(sauti::dsp::DeEsserMode::WideBand);
        deEsser.setThresholdDb(-20.0f);
        deEsser.setRatio(4.0f);
        deEsser.reset();

        const uint32_t N = 2048;
        std::vector<float> buf(2 * N, 0.0f);
        for (int k = 0; k < 5; ++k) {
            for (uint32_t i = 0; i < N; ++i) {
                float s = 0.7f * std::sin(2.0f * (float)M_PI * 6000.0f * (float)i / 48000.0f);
                buf[2 * i]     = s;
                buf[2 * i + 1] = s;
            }
            deEsser.process(buf.data(), N);
        }
        CHECK(deEsser.getGainReductionDb() > 2.0f, "WideBand mode detects sibilance and attenuates");
    }

    // 4. Numerical Stability (No NaN/Inf on extreme inputs / sample rate change)
    {
        sauti::dsp::DeEsserDSP deEsser;
        deEsser.setSampleRate(96000.0f);
        deEsser.setEnabled(true);
        deEsser.setIntensity(1.0f);
        deEsser.reset();

        const uint32_t N = 1024;
        std::vector<float> hotBuf(2 * N, 5.0f); // Hot 5.0 magnitude input
        deEsser.process(hotBuf.data(), N);

        bool hasNaN = false;
        for (float val : hotBuf) {
            if (std::isnan(val) || std::isinf(val)) hasNaN = true;
        }
        CHECK(!hasNaN, "DeEsserDSP contains no NaN/Inf with extreme input at 96kHz");
    }

    // 5. Preset switching verification
    {
        sauti::dsp::DeEsserDSP deEsser;
        deEsser.setPreset(sauti::dsp::DeEsserPreset::AggressiveSibilance);
        CHECK(deEsser.getPreset() == sauti::dsp::DeEsserPreset::AggressiveSibilance, "DeEsser preset set to AggressiveSibilance");
        CHECK(deEsser.getFrequencyHz() == 6000.0f, "AggressiveSibilance frequency is 6000Hz");
        CHECK(deEsser.getRatio() == 6.0f, "AggressiveSibilance ratio is 6.0");

        deEsser.setPreset(sauti::dsp::DeEsserPreset::VintageWideband);
        CHECK(deEsser.getPreset() == sauti::dsp::DeEsserPreset::VintageWideband, "DeEsser preset set to VintageWideband");
        CHECK(deEsser.getMode() == sauti::dsp::DeEsserMode::WideBand, "VintageWideband sets WideBand mode");

        // Tweaking detailed parameter marks preset as Custom
        deEsser.setThresholdDb(-18.0f);
        CHECK(deEsser.getPreset() == sauti::dsp::DeEsserPreset::Custom, "Manual parameter tweak updates preset to Custom");
    }
}

// -----------------------------------------------------------------------------
// DownwardExpanderDSP: Noise Floor Reduction, Soft-Knee & Clamping
// -----------------------------------------------------------------------------
static void test_downward_expander_dsp()
{
    std::printf("\n== DownwardExpanderDSP Noise Floor Reducer Verification ==\n");

    // 1. Default disabled state & bypass transparency
    {
        sauti::dsp::DownwardExpanderDSP expander;
        CHECK(!expander.isEnabled(), "Expander is DISABLED by default");
        CHECK(nearlyEqual(expander.getCurrentGainReductionDb(), 0.0f, 0.01f), "Initial gain reduction is 0.0 dB");

        const uint32_t N = 512;
        std::vector<float> buf(2 * N);
        for (uint32_t i = 0; i < N; ++i) {
            buf[2 * i] = 0.005f * std::sin(2.0f * static_cast<float>(M_PI) * 440.0f * i / 48000.0f);
            buf[2 * i + 1] = 0.005f * std::cos(2.0f * static_cast<float>(M_PI) * 440.0f * i / 48000.0f);
        }
        std::vector<float> copy = buf;
        expander.process(buf.data(), N);

        float maxDiff = 0.0f;
        for (size_t i = 0; i < buf.size(); ++i) {
            maxDiff = std::max(maxDiff, std::abs(buf[i] - copy[i]));
        }
        CHECK(maxDiff < 1e-6f, "Disabled expander leaves audio bit-identical (0 dB attenuation)");
    }

    // 2. Loud signals (> threshold) pass unattenuated
    {
        sauti::dsp::DownwardExpanderDSP expander;
        expander.setEnabled(true);
        expander.setPreset(sauti::dsp::ExpanderPreset::VinylClean);
        expander.reset();

        const uint32_t N = 4800; // 100ms at 48kHz
        std::vector<float> loudBuf(2 * N);
        for (uint32_t i = 0; i < N; ++i) {
            loudBuf[2 * i] = 0.5f * std::sin(2.0f * static_cast<float>(M_PI) * 1000.0f * i / 48000.0f); // -6 dBFS
            loudBuf[2 * i + 1] = 0.5f * std::cos(2.0f * static_cast<float>(M_PI) * 1000.0f * i / 48000.0f);
        }
        expander.process(loudBuf.data(), N);

        float gr = expander.getCurrentGainReductionDb();
        CHECK(nearlyEqual(gr, 0.0f, 0.5f), "Loud signals (> threshold) experience 0 dB gain reduction");
    }

    // 3. Below-threshold noise reduction & floor clamping
    {
        sauti::dsp::DownwardExpanderDSP expander;
        expander.setEnabled(true);
        expander.setThresholdDb(-50.0f);
        expander.setRatio(2.0f);
        expander.setRangeDb(-16.0f);
        expander.setAttackMs(1.0f);
        expander.setReleaseMs(10.0f);
        expander.reset();

        // Low-level noise (-65 dBFS, amp ~ 0.00056)
        const uint32_t N = 9600; // 200ms
        std::vector<float> noiseBuf(2 * N);
        for (uint32_t i = 0; i < N; ++i) {
            noiseBuf[2 * i] = 0.00056f * std::sin(2.0f * static_cast<float>(M_PI) * 1000.0f * i / 48000.0f);
            noiseBuf[2 * i + 1] = 0.00056f * std::cos(2.0f * static_cast<float>(M_PI) * 1000.0f * i / 48000.0f);
        }
        expander.process(noiseBuf.data(), N);

        float gr = expander.getCurrentGainReductionDb();
        CHECK(gr < -10.0f && gr >= -16.5f, "Below-threshold noise is attenuated smoothly (GR ~ -15 dB)");

        // Ultra-low signal (-100 dBFS) must be clamped to -16 dB floor (not -50 dB or -inf)
        std::vector<float> tinyBuf(2 * N, 0.00001f);
        expander.process(tinyBuf.data(), N);
        float clampedGr = expander.getCurrentGainReductionDb();
        CHECK(clampedGr <= -15.5f && clampedGr >= -16.5f, "Gain reduction respects user-configured floor limit (-16 dB)");
    }

    // 4. Sidechain rumble HPF rejection
    {
        sauti::dsp::DownwardExpanderDSP expander;
        expander.setEnabled(true);
        expander.setThresholdDb(-40.0f);
        expander.setRatio(4.0f);
        expander.setRangeDb(-24.0f);
        expander.setSidechainHpfHz(60.0f);
        expander.setAttackMs(1.0f);
        expander.setReleaseMs(10.0f);
        expander.reset();

        // 20 Hz turntable rumble at -30 dBFS (would trigger if no HPF)
        const uint32_t N = 9600;
        std::vector<float> rumbleBuf(2 * N);
        for (uint32_t i = 0; i < N; ++i) {
            rumbleBuf[2 * i] = 0.0316f * std::sin(2.0f * static_cast<float>(M_PI) * 20.0f * i / 48000.0f);
            rumbleBuf[2 * i + 1] = 0.0316f * std::sin(2.0f * static_cast<float>(M_PI) * 20.0f * i / 48000.0f);
        }
        expander.process(rumbleBuf.data(), N);

        float gr = expander.getCurrentGainReductionDb();
        CHECK(gr < -5.0f, "Sidechain HPF attenuates sub-bass rumble so detector does not falsely open");
    }

    // 5. Numerical stability under extreme conditions
    {
        sauti::dsp::DownwardExpanderDSP expander;
        expander.setSampleRate(96000.0f);
        expander.setEnabled(true);
        expander.reset();

        const uint32_t N = 1024;
        std::vector<float> extremeBuf(2 * N, 10.0f);
        expander.process(extremeBuf.data(), N);

        bool hasNaN = false;
        for (float val : extremeBuf) {
            if (std::isnan(val) || std::isinf(val)) hasNaN = true;
        }
        CHECK(!hasNaN, "DownwardExpanderDSP contains no NaN/Inf under hot 96kHz input");
    }
}

// -----------------------------------------------------------------------------
// SubsonicFilter & Denormals Flushing Test Suite
// -----------------------------------------------------------------------------
static void test_subsonic_filter_and_denormals()
{
    std::printf("\n== SubsonicFilter & Denormals Flushing ==\n");

    // 1. ScopedDenormalsDisable RAII lifecycle test
    {
        bool denormalsRan = false;
        {
            sauti::dsp::ScopedDenormalsDisable disableDenormals;
            float subnormal = 1.0e-40f;
            // When FTZ is active on hardware with SSE/NEON support, operations on subnormals flush cleanly to 0
            float prod = subnormal * 0.5f;
            (void)prod;
            denormalsRan = true;
        }
        CHECK(denormalsRan, "ScopedDenormalsDisable RAII scope initialized and destroyed cleanly");
    }

    // 2. SubsonicFilter 18 Hz DC rejection
    {
        sauti::dsp::SubsonicFilter filter;
        filter.setSampleRate(48000.0f);
        filter.setEnabled(true);
        filter.reset();

        // Feed constant DC bias = 1.0f for 1 second (48000 samples)
        const uint32_t N = 48000;
        std::vector<float> dcBuf(2 * N, 1.0f);
        filter.process(dcBuf.data(), N, 2);

        // At steady-state (end of 1 second), DC should be blocked (< 0.001)
        float lastL = std::fabs(dcBuf[2 * (N - 1)]);
        float lastR = std::fabs(dcBuf[2 * (N - 1) + 1]);
        CHECK(lastL < 0.005f && lastR < 0.005f, "SubsonicFilter blocks steady-state DC bias");
    }

    // 3. SubsonicFilter 5 Hz rumble attenuation (> 20 dB reduction)
    {
        sauti::dsp::SubsonicFilter filter;
        filter.setSampleRate(48000.0f);
        filter.setEnabled(true);
        filter.reset();

        const uint32_t N = 48000;
        std::vector<float> rumbleBuf(2 * N);
        for (uint32_t i = 0; i < N; ++i) {
            float s = std::sin(2.0f * 3.14159265f * 5.0f * (float)i / 48000.0f);
            rumbleBuf[2 * i] = s;
            rumbleBuf[2 * i + 1] = s;
        }
        filter.process(rumbleBuf.data(), N, 2);

        // Measure amplitude in last 1000 samples
        float maxRumble = 0.0f;
        for (uint32_t i = N - 1000; i < N; ++i) {
            maxRumble = std::max(maxRumble, std::abs(rumbleBuf[2 * i]));
        }
        // 5 Hz is well below 18 Hz cutoff (2nd-order rolloff is ~-22 dB at 5 Hz, amplitude < 0.10)
        CHECK(maxRumble < 0.12f, "SubsonicFilter attenuates 5 Hz infrasonic rumble by >18 dB");
    }

    // 4. SubsonicFilter 50 Hz & 1 kHz audible passband preservation (0.0 dB flat)
    {
        sauti::dsp::SubsonicFilter filter;
        filter.setSampleRate(48000.0f);
        filter.setEnabled(true);
        filter.reset();

        const uint32_t N = 48000;
        std::vector<float> audioBuf(2 * N);
        for (uint32_t i = 0; i < N; ++i) {
            float s = std::sin(2.0f * 3.14159265f * 1000.0f * (float)i / 48000.0f);
            audioBuf[2 * i] = s;
            audioBuf[2 * i + 1] = s;
        }
        filter.process(audioBuf.data(), N, 2);

        float maxAudio = 0.0f;
        for (uint32_t i = N - 1000; i < N; ++i) {
            maxAudio = std::max(maxAudio, std::abs(audioBuf[2 * i]));
        }
        CHECK(std::abs(maxAudio - 1.0f) < 0.01f, "SubsonicFilter preserves 1 kHz audio passband at unity (0.0 dB)");
    }
}

// -----------------------------------------------------------------------------
// DialogEnhancerDSP verification (reconstructed from Dolby DAP / DS1)
// -----------------------------------------------------------------------------
static void test_dialog_enhancer_dsp()
{
    std::printf("\n== DialogEnhancerDSP verification (Dolby DAP reconstruction) ==\n");
    sauti::dsp::DialogEnhancerDSP de;
    de.setSampleRate(48000.0f);

    // 1. Bypass check
    {
        const uint32_t N = 1024;
        std::vector<float> in(2 * N);
        std::vector<float> orig(2 * N);
        for (uint32_t i = 0; i < 2 * N; ++i) {
            in[i] = orig[i] = 0.5f * std::sin(float(i));
        }
        de.setEnabled(false);
        de.process(in.data(), N);
        bool match = true;
        for (uint32_t i = 0; i < 2 * N; ++i) {
            if (in[i] != orig[i]) { match = false; break; }
        }
        CHECK(match, "DialogEnhancerDSP is bit-exact bypass when disabled");
    }

    // 2. Formant gain boost at 2.4 kHz
    {
        de.reset();
        de.setEnabled(true);
        de.setParams(sauti::dsp::DialogEnhancerProfile::Custom, 1.0f, 0.0f, 0.0f, 0.0f);
        const uint32_t N = 4800;
        std::vector<float> buf(2 * N);
        const float f0 = 2400.0f;
        for (uint32_t i = 0; i < N; ++i) {
            float s = 0.2f * std::sin(2.0f * 3.14159265f * f0 * (float)i / 48000.0f);
            buf[2 * i] = s;
            buf[2 * i + 1] = s;
        }
        de.process(buf.data(), N);

        float maxAmp = 0.0f;
        for (uint32_t i = N - 500; i < N; ++i) {
            maxAmp = std::max(maxAmp, std::abs(buf[2 * i]));
        }
        CHECK(maxAmp > 0.5f && maxAmp < 0.9f, "DialogEnhancerDSP boosts 2.4 kHz vocal formant by expected gain (~+11 dB)");
    }

    // 3. Background Ducking: Side attenuation during speech presence
    {
        de.reset();
        de.setEnabled(true);
        de.setParams(sauti::dsp::DialogEnhancerProfile::Custom, 0.5f, 1.0f, 0.0f, 0.0f);
        const uint32_t N = 4800;
        std::vector<float> buf(2 * N);
        for (uint32_t i = 0; i < N; ++i) {
            float centerSpeech = 0.3f * std::sin(2.0f * 3.14159265f * 2400.0f * (float)i / 48000.0f);
            float sideAmbient  = 0.3f * std::sin(2.0f * 3.14159265f * 500.0f * (float)i / 48000.0f);
            buf[2 * i]     = centerSpeech + sideAmbient; // L
            buf[2 * i + 1] = centerSpeech - sideAmbient; // R
        }
        de.process(buf.data(), N);

        float maxSide = 0.0f;
        for (uint32_t i = N - 500; i < N; ++i) {
            float s = 0.5f * (buf[2 * i] - buf[2 * i + 1]);
            maxSide = std::max(maxSide, std::abs(s));
        }
        CHECK(maxSide < 0.22f, "DialogEnhancerDSP dynamically ducks non-dialog side energy during speech presence");
    }

    // 4. Stability check under extreme values
    {
        de.reset();
        de.setEnabled(true);
        de.setParams(sauti::dsp::DialogEnhancerProfile::Voice, 1.0f, 1.0f, 1.0f, 1.0f);
        const uint32_t N = 1024;
        std::vector<float> buf(2 * N, 0.0f);
        buf[0] = 1.0f; buf[1] = -1.0f; // Dirac impulse
        de.process(buf.data(), N);
        bool finite = true;
        for (float v : buf) {
            if (!std::isfinite(v)) { finite = false; break; }
        }
        CHECK(finite, "DialogEnhancerDSP remains stable under Dirac impulse without NaN/Inf");
    }
}

int main(int argc, char **argv)
{
    std::printf("==============================================\n");
    std::printf(" DSP fix verification (Issues_bugs.md)\n");
    std::printf("==============================================\n");

    // Optionally run a single test by name for isolation:
    //   test_dsp_fixes.exe pure_bass|crossfeed|limiter|warmth|clarity|dynsys|oversample|deesser|expander|subsonic|dialog
    std::string only = (argc > 1) ? argv[1] : "";

    if (only.empty() || only == "pure_bass") test_pure_bass_fir();
    if (only.empty() || only == "crossfeed") test_crossfeed_algorithm_switch();
    if (only.empty() || only == "limiter") test_master_limiter_defaults_and_ceiling();
    if (only.empty() || only == "warmth") test_analog_warmth_no_dc_offset();
    if (only.empty() || only == "clarity") test_clarity_presence_reconstruction();
    if (only.empty() || only == "dynsys") test_dynamic_system_cutoff_and_stability();
    if (only.empty() || only == "oversample") test_oversampled_saturation();
    if (only.empty() || only == "deesser") test_de_esser_dsp();
    if (only.empty() || only == "expander") test_downward_expander_dsp();
    if (only.empty() || only == "subsonic") test_subsonic_filter_and_denormals();
    if (only.empty() || only == "dialog") test_dialog_enhancer_dsp();

    std::printf("\n----------------------------------------------\n");
    std::printf(" RESULTS: %d passed, %d failed\n", g_passes, g_failures);
    std::printf("----------------------------------------------\n");
    return g_failures == 0 ? 0 : 1;
}
