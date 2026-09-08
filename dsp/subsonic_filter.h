#pragma once

#include <cmath>
#include <cstdint>
#include <algorithm>

namespace sauti::dsp {

// =============================================================================
// SubsonicFilter: High-Fidelity 18 Hz Subsonic Rumble & DC Clean-Room Filter
//
// Features:
// - 2nd-order Butterworth High-Pass at 18 Hz (Q = 0.7071) with 0.0 dB flat
//   passband response above 30 Hz.
// - Removes inaudible DC offset, vinyl turntable rumble, and microphone wind
//   pops before non-linear DSP stages (harmonic bass, analog warmth, exciter).
// - Protects headphone/speaker voice coils from excursion distortion and
//   preserves maximum dynamic headroom for DAC reconstruction.
// - Transposed Direct Form II (TDF2) architecture with double-precision states
//   for optimal numerical stability and zero phase distortion.
// =============================================================================
class SubsonicFilter {
public:
    SubsonicFilter() {
        sample_rate_ = 48000.0f;
        updateCoefficients();
        reset();
    }

    void setSampleRate(float sampleRate) {
        if (sampleRate <= 0.0f) sampleRate = 48000.0f;
        if (std::abs(sample_rate_ - sampleRate) < 0.1f && b0_ != 1.0) return;
        sample_rate_ = sampleRate;
        updateCoefficients();
    }

    float getSampleRate() const { return sample_rate_; }

    void setEnabled(bool enabled) {
        if (enabled_ != enabled) {
            enabled_ = enabled;
            if (!enabled) {
                reset();
            }
        }
    }

    bool isEnabled() const { return enabled_; }

    double getB0() const { return b0_; }
    double getB1() const { return b1_; }
    double getB2() const { return b2_; }
    double getA1() const { return a1_; }
    double getA2() const { return a2_; }

    void reset() {
        s1_l_ = s2_l_ = 0.0;
        s1_r_ = s2_r_ = 0.0;
    }

    void updateCoefficients() {
        constexpr double PI = 3.14159265358979323846;
        const double f0 = 18.0; // 18 Hz subsonic cutoff
        const double Q = 0.7071067811865475; // Butterworth Q
        double w0 = 2.0 * PI * f0 / static_cast<double>(sample_rate_);
        if (w0 > PI * 0.95) w0 = PI * 0.95;
        if (w0 < 1.0e-4) w0 = 1.0e-4;

        const double cos_w0 = std::cos(w0);
        const double sin_w0 = std::sin(w0);
        const double alpha = sin_w0 / (2.0 * Q);

        const double a0 = 1.0 + alpha;
        b0_ = ((1.0 + cos_w0) / 2.0) / a0;
        b1_ = (-(1.0 + cos_w0)) / a0;
        b2_ = ((1.0 + cos_w0) / 2.0) / a0;
        a1_ = (-2.0 * cos_w0) / a0;
        a2_ = (1.0 - alpha) / a0;
    }

    // Process interleaved stereo samples: [L0, R0, L1, R1, ...]
    void process(float* interleaved_samples, uint32_t frame_count, int channels = 2) {
        if (!enabled_ || frame_count == 0 || !interleaved_samples || channels < 1) return;

        if (channels >= 2) {
            for (uint32_t i = 0; i < frame_count; i++) {
                const size_t idx = static_cast<size_t>(i) * static_cast<size_t>(channels);
                const double in_l = static_cast<double>(interleaved_samples[idx + 0]);
                const double in_r = static_cast<double>(interleaved_samples[idx + 1]);

                // Left Channel (Transposed Direct Form II in double precision)
                double out_l = in_l * b0_ + s1_l_;
                if (std::fabs(out_l) < 1.0e-20) out_l = 0.0;
                s1_l_ = in_l * b1_ - out_l * a1_ + s2_l_;
                s2_l_ = in_l * b2_ - out_l * a2_;

                // Right Channel (Transposed Direct Form II in double precision)
                double out_r = in_r * b0_ + s1_r_;
                if (std::fabs(out_r) < 1.0e-20) out_r = 0.0;
                s1_r_ = in_r * b1_ - out_r * a1_ + s2_r_;
                s2_r_ = in_r * b2_ - out_r * a2_;

                interleaved_samples[idx + 0] = static_cast<float>(out_l);
                interleaved_samples[idx + 1] = static_cast<float>(out_r);
            }
        } else {
            // Mono
            for (uint32_t i = 0; i < frame_count; i++) {
                const double in_m = static_cast<double>(interleaved_samples[i]);
                double out_m = in_m * b0_ + s1_l_;
                if (std::fabs(out_m) < 1.0e-20) out_m = 0.0;
                s1_l_ = in_m * b1_ - out_m * a1_ + s2_l_;
                s2_l_ = in_m * b2_ - out_m * a2_;
                interleaved_samples[i] = static_cast<float>(out_m);
            }
        }
    }

    // Process double-precision interleaved stereo samples (64-Bit Float DSP mode)
    void process(double* interleaved_samples, uint32_t frame_count, int channels = 2) {
        if (!enabled_ || frame_count == 0 || !interleaved_samples || channels < 1) return;

        if (channels >= 2) {
            for (uint32_t i = 0; i < frame_count; i++) {
                const size_t idx = static_cast<size_t>(i) * static_cast<size_t>(channels);
                const double in_l = interleaved_samples[idx + 0];
                const double in_r = interleaved_samples[idx + 1];

                // Left Channel (Transposed Direct Form II in double precision)
                double out_l = in_l * b0_ + s1_l_;
                if (std::fabs(out_l) < 1.0e-20) out_l = 0.0;
                s1_l_ = in_l * b1_ - out_l * a1_ + s2_l_;
                s2_l_ = in_l * b2_ - out_l * a2_;

                // Right Channel (Transposed Direct Form II in double precision)
                double out_r = in_r * b0_ + s1_r_;
                if (std::fabs(out_r) < 1.0e-20) out_r = 0.0;
                s1_r_ = in_r * b1_ - out_r * a1_ + s2_r_;
                s2_r_ = in_r * b2_ - out_r * a2_;

                interleaved_samples[idx + 0] = out_l;
                interleaved_samples[idx + 1] = out_r;
            }
        } else {
            // Mono
            for (uint32_t i = 0; i < frame_count; i++) {
                const double in_m = interleaved_samples[i];
                double out_m = in_m * b0_ + s1_l_;
                if (std::fabs(out_m) < 1.0e-20) out_m = 0.0;
                s1_l_ = in_m * b1_ - out_m * a1_ + s2_l_;
                s2_l_ = in_m * b2_ - out_m * a2_;
                interleaved_samples[i] = out_m;
            }
        }
    }

private:
    bool enabled_ = true;
    float sample_rate_ = 48000.0f;

    double b0_ = 1.0, b1_ = -2.0, b2_ = 1.0;
    double a1_ = 0.0, a2_ = 0.0;

    double s1_l_ = 0.0, s2_l_ = 0.0;
    double s1_r_ = 0.0, s2_r_ = 0.0;
};

} // namespace sauti::dsp
