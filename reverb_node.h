#pragma once

// High-Definition Dattorro Figure-8 Diffuse Tank Stereo Reverb Node.
//
// Replaces legacy 1960s/1990s parallel Schroeder/Freeverb comb architecture.
//
// Signal Flow:
//   Input (Stereo)
//     -> Smooth Pre-Delay Line (0 .. 250 ms)
//     -> Abbey Road Pre-Filtering (160 Hz HPF + 7.5 kHz LPF to cut mud & digital glare)
//     -> Dual-Channel Input Diffusers (4 cascaded allpasses per channel; smears
//        sharp transients into a dense, silky cloud before entering the tank)
//     -> Coupled Figure-8 Tank (Tank 1 <-> Tank 2):
//          * Dual-Phase Quadrature LFO Modulated Allpass (eliminates metallic ringing)
//          * Primary Tank Delay
//          * Frequency-Dependent Damping Absorption One-Pole Filter
//          * Room Size Decay Attenuation
//          * Secondary Allpass Diffuser
//          * Secondary Tank Delay
//          * Full Cross-Coupling between Left and Right loops
//     -> 14 Mutually Prime Multi-Tap Output Matrix
//     -> True Stereo Width M/S Balance
//     -> Per-sample smoothed wet/dry mix stage (click & zipper free)

#include <cmath>
#include <cstdint>
#include <vector>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

class ReverbNode
{
public:
    static constexpr float MAX_PRE_DELAY_MS = 250.0f;

    ReverbNode()
    {
        buildBuffers();
        reset();
    }

    void setSampleRate(double rate)
    {
        if (rate <= 0.0)
            rate = 48000.0;
        if (std::abs(sampleRate - rate) < 0.1)
            return;

        sampleRate = rate;
        buildBuffers();
        reset();
    }

    void setEnabled(bool e)
    {
        targetEnabled = e;
    }

    bool getEnabled() const { return targetEnabled; }

    void setMix(float m)
    {
        setWet(m);
        setDry(1.0f - m);
    }

    void setWet(float w)
    {
        targetWet = std::max(0.0f, std::min(w, 2.0f));
    }

    void setDry(float d)
    {
        targetDry = std::max(0.0f, std::min(d, 2.0f));
    }

    void setRoomSize(float r)
    {
        targetRoomSize = std::max(0.0f, std::min(r, 1.0f));
    }

    void setDamping(float d)
    {
        targetDamping = std::max(0.0f, std::min(d, 1.0f));
    }

    void setPreDelayMs(float ms)
    {
        targetPreDelayMs = std::max(0.0f, std::min(ms, MAX_PRE_DELAY_MS));
    }

    void setWidth(float w)
    {
        targetWidth = std::max(0.0f, std::min(w, 1.0f));
    }

    float getWet() const { return targetWet; }
    float getDry() const { return targetDry; }
    float getRoomSize() const { return targetRoomSize; }
    float getDamping() const { return targetDamping; }
    float getPreDelayMs() const { return targetPreDelayMs; }
    float getWidth() const { return targetWidth; }

    // Latency contributed by the pre-delay stage (samples).
    double getLatencySamples() const
    {
        if (!targetEnabled && currentWet < 0.0001f)
            return 0.0;
        return (double)(currentPreDelayMs * 0.001f) * sampleRate;
    }

    void reset()
    {
        for (int ch = 0; ch < 2; ++ch)
        {
            if (!preDelayBuf[ch].empty())
            {
                std::fill(preDelayBuf[ch].begin(), preDelayBuf[ch].end(), 0.0f);
            }
            preDelayWriteIdx[ch] = 0;

            hpPrevIn[ch] = 0.0f;
            hpState[ch] = 0.0f;
            lpState[ch] = 0.0f;

            for (int i = 0; i < 4; ++i)
            {
                diffusers[ch][i].clear();
            }
        }

        tank1_modAp.clear();
        tank1_del1.clear();
        tank1_ap2.clear();
        tank1_del2.clear();
        tank1_dampState = 0.0f;

        tank2_modAp.clear();
        tank2_del1.clear();
        tank2_ap2.clear();
        tank2_del2.clear();
        tank2_dampState = 0.0f;

        tank1_lastOut = 0.0f;
        tank2_lastOut = 0.0f;

        lfoPhase1 = 0.0f;
        lfoPhase2 = 0.25f * (float)(2.0 * M_PI); // 90 degree quadrature phase offset

        currentWet = targetWet;
        currentDry = targetDry;
        currentRoomSize = targetRoomSize;
        currentDamping = targetDamping;
        currentPreDelayMs = targetPreDelayMs;
        currentWidth = targetWidth;
        currentEnabled = targetEnabled;
    }

    void process(float *interleaved, uint32_t frames, int channels)
    {
        if (!interleaved || frames == 0 || channels < 2)
            return;

        if (!targetEnabled && currentWet < 0.0001f)
        {
            currentEnabled = false;
            return;
        }
        currentEnabled = true;

        if (tank1_del1.empty())
            return;

        // 15ms parameter smoothing time constant.
        const float alphaSmooth =
            1.0f - std::exp(-1.0f / (0.015f * (float)sampleRate));

        const size_t preDelayLen = preDelayBuf[0].size();

        // LFO phase increments
        const float lfoInc1 = (float)(2.0 * M_PI * 0.73 / sampleRate);
        const float lfoInc2 = (float)(2.0 * M_PI * 0.91 / sampleRate);

        // Pre-filter coefficients (Abbey Road: 160 Hz HPF + 7.5 kHz LPF)
        const float wHp = (float)(2.0 * M_PI * 160.0 / sampleRate);
        const float alphaHp = 1.0f / (1.0f + wHp);

        const float wLp = (float)(2.0 * M_PI * 7500.0 / sampleRate);
        const float alphaLp = wLp / (1.0f + wLp);

        // Modulated allpass excursion in samples scaled by sample rate
        const float modDepth = (float)(8.0 * (sampleRate / 29761.0));

        for (uint32_t i = 0; i < frames; ++i)
        {
            // Smooth parameters toward targets
            currentWet += alphaSmooth * (targetWet - currentWet);
            currentDry += alphaSmooth * (targetDry - currentDry);
            currentRoomSize += alphaSmooth * (targetRoomSize - currentRoomSize);
            currentDamping += alphaSmooth * (targetDamping - currentDamping);
            currentPreDelayMs += alphaSmooth * (targetPreDelayMs - currentPreDelayMs);
            currentWidth += alphaSmooth * (targetWidth - currentWidth);

            // Decay calculation from room size (RT60 mapped from 0.5s to 16s)
            const float decay = 0.35f + currentRoomSize * 0.63f; // 0.35 .. 0.98

            // Frequency-dependent damping filter cutoff:
            // 0.0 damping -> ~16.0 kHz cutoff (airy, bright)
            // 0.5 damping -> ~4.9 kHz cutoff (natural acoustic room)
            // 1.0 damping -> ~1.5 kHz cutoff (warm, plush, dark hall)
            const float dampHz = 16000.0f * std::pow(0.09375f, currentDamping);
            const float wDamp = std::min(1.5f, (float)(2.0 * M_PI * dampHz / sampleRate));
            const float dampCoeff = 1.0f - std::exp(-wDamp);

            const size_t base = (size_t)i * (size_t)channels;
            const float inL = interleaved[base];
            const float inR = interleaved[base + 1];

            // 1. Pre-Delay
            float pdL = inL;
            float pdR = inR;
            if (preDelayLen > 0)
            {
                const size_t delaySamples = std::min(
                    preDelayLen - 1,
                    (size_t)((currentPreDelayMs * 0.001f) * (float)sampleRate));

                preDelayBuf[0][preDelayWriteIdx[0]] = inL;
                preDelayBuf[1][preDelayWriteIdx[1]] = inR;

                pdL = preDelayBuf[0]
                    [(preDelayWriteIdx[0] + preDelayLen - delaySamples) % preDelayLen];
                pdR = preDelayBuf[1]
                    [(preDelayWriteIdx[1] + preDelayLen - delaySamples) % preDelayLen];

                preDelayWriteIdx[0] = (preDelayWriteIdx[0] + 1) % preDelayLen;
                preDelayWriteIdx[1] = (preDelayWriteIdx[1] + 1) % preDelayLen;
            }

            // 2. Abbey Road Pre-Filtering (HPF + LPF)
            // Channel Left
            hpState[0] = alphaHp * (hpState[0] + pdL - hpPrevIn[0]);
            hpPrevIn[0] = pdL;
            lpState[0] += alphaLp * (hpState[0] - lpState[0]);
            float filtL = lpState[0];

            // Channel Right
            hpState[1] = alphaHp * (hpState[1] + pdR - hpPrevIn[1]);
            hpPrevIn[1] = pdR;
            lpState[1] += alphaLp * (hpState[1] - lpState[1]);
            float filtR = lpState[1];

            // 3. Dual Cascaded Input Diffusers (4 Allpasses per channel)
            // Subtle cross-feed gives 3D depth even from mono/panned sources
            float diffIn1 = filtL + 0.20f * filtR;
            float diffIn2 = filtR + 0.20f * filtL;

            for (int d = 0; d < 4; ++d)
            {
                diffIn1 = diffusers[0][d].process(diffIn1);
                diffIn2 = diffusers[1][d].process(diffIn2);
            }

            // 4. Figure-8 Coupled Tank Loops
            // Tank 1 receives Diffuser 1 + Tank 2 cross-feedback
            // Tank 2 receives Diffuser 2 + Tank 1 cross-feedback
            float tank1In = diffIn1 + tank2_lastOut * decay;
            float tank2In = diffIn2 + tank1_lastOut * decay;

            tank1In = flushDenormal(tank1In);
            tank2In = flushDenormal(tank2In);

            // Advance LFOs
            const float mod1 = modDepth * std::sin(lfoPhase1);
            const float mod2 = modDepth * std::sin(lfoPhase2);
            lfoPhase1 += lfoInc1;
            if (lfoPhase1 >= (float)(2.0 * M_PI)) lfoPhase1 -= (float)(2.0 * M_PI);
            lfoPhase2 += lfoInc2;
            if (lfoPhase2 >= (float)(2.0 * M_PI)) lfoPhase2 -= (float)(2.0 * M_PI);

            // --- TANK 1 LOOP ---
            // Modulated Allpass 1
            float t1_node = tank1_modAp.processModulated(tank1In, mod1);
            // Delay 1
            tank1_del1.write(t1_node);
            float t1_del1_out = tank1_del1.readOldest();
            // Lowpass Damping Filter
            tank1_dampState += dampCoeff * (t1_del1_out - tank1_dampState);
            tank1_dampState = flushDenormal(tank1_dampState);
            // Allpass 2
            float t1_ap2_out = tank1_ap2.process(tank1_dampState);
            // Delay 2
            tank1_del2.write(t1_ap2_out);
            tank1_lastOut = tank1_del2.readOldest();

            // --- TANK 2 LOOP ---
            // Modulated Allpass 1
            float t2_node = tank2_modAp.processModulated(tank2In, mod2);
            // Delay 1
            tank2_del1.write(t2_node);
            float t2_del1_out = tank2_del1.readOldest();
            // Lowpass Damping Filter
            tank2_dampState += dampCoeff * (t2_del1_out - tank2_dampState);
            tank2_dampState = flushDenormal(tank2_dampState);
            // Allpass 2
            float t2_ap2_out = tank2_ap2.process(tank2_dampState);
            // Delay 2
            tank2_del2.write(t2_ap2_out);
            tank2_lastOut = tank2_del2.readOldest();

            // 5. Multi-Tap Stereo Output Matrix (14 Mutually Prime Taps)
            float outL = tank2_del1.read(tap_t2_d1_1)
                       + tank2_del1.read(tap_t2_d1_2)
                       - tank2_ap2.read(tap_t2_ap2_1)
                       + tank2_del2.read(tap_t2_d2_1)
                       - tank1_del1.read(tap_t1_d1_1)
                       - tank1_ap2.read(tap_t1_ap2_1)
                       - tank1_del2.read(tap_t1_d2_1);

            float outR = tank1_del1.read(tap_t1_d1_2)
                       + tank1_del1.read(tap_t1_d1_3)
                       - tank1_ap2.read(tap_t1_ap2_2)
                       + tank1_del2.read(tap_t1_d2_2)
                       - tank2_del1.read(tap_t2_d1_3)
                       - tank2_ap2.read(tap_t2_ap2_2)
                       - tank2_del2.read(tap_t2_d2_2);

            // Normalized tank output scaling
            outL *= 0.36f;
            outR *= 0.36f;

            // 6. Stereo Width Processing (Mid/Side Matrix)
            const float mid = (outL + outR) * 0.5f;
            const float side = (outL - outR) * 0.5f;
            const float sideGain = currentWidth * 1.35f;

            const float wetL = mid + side * sideGain;
            const float wetR = mid - side * sideGain;

            // 7. Final Wet/Dry Mix
            interleaved[base] = inL * currentDry + wetL * currentWet;
            interleaved[base + 1] = inR * currentDry + wetR * currentWet;
        }
    }

private:
    static inline float flushDenormal(float val)
    {
        return (std::abs(val) < 1.0e-15f) ? 0.0f : val;
    }

    // Delay Line with fractional linear-interpolated and indexed read
    class DelayLine
    {
    public:
        void resize(size_t len)
        {
            buf.assign(std::max<size_t>(2, len), 0.0f);
            writeIdx = 0;
        }

        void clear()
        {
            std::fill(buf.begin(), buf.end(), 0.0f);
            writeIdx = 0;
        }

        bool empty() const { return buf.empty(); }
        size_t size() const { return buf.size(); }

        void write(float sample)
        {
            buf[writeIdx] = sample;
            if (++writeIdx >= buf.size())
                writeIdx = 0;
        }

        float readOldest() const
        {
            return buf[writeIdx];
        }

        float read(size_t delaySamples) const
        {
            if (buf.empty()) return 0.0f;
            const size_t sz = buf.size();
            delaySamples = std::min(delaySamples, sz - 1);
            const size_t rIdx = (writeIdx + sz - 1 - delaySamples) % sz;
            return buf[rIdx];
        }

        float readInterpolated(float delaySamples) const
        {
            if (buf.empty()) return 0.0f;
            const size_t sz = buf.size();
            if (delaySamples < 0.0f) delaySamples = 0.0f;
            if (delaySamples > (float)(sz - 2)) delaySamples = (float)(sz - 2);

            const size_t dFloor = (size_t)delaySamples;
            const float frac = delaySamples - (float)dFloor;

            const size_t idx0 = (writeIdx + sz - 1 - dFloor) % sz;
            const size_t idx1 = (writeIdx + sz - 2 - dFloor) % sz;

            return buf[idx0] * (1.0f - frac) + buf[idx1] * frac;
        }

    private:
        std::vector<float> buf;
        size_t writeIdx = 0;
    };

    // Standard Canonical Allpass Filter: H(z) = (-g + z^-D) / (1 - g * z^-D)
    class AllpassFilter
    {
    public:
        void init(size_t delayLen, float feedbackGain)
        {
            delay.resize(delayLen);
            gain = feedbackGain;
        }

        void clear()
        {
            delay.clear();
        }

        float process(float input)
        {
            const float bufOut = delay.readOldest();
            const float output = -gain * input + bufOut;
            delay.write(flushDenormal(input + gain * output));
            return output;
        }

        float read(size_t tap) const
        {
            return delay.read(tap);
        }

        float processModulated(float input, float modSamples)
        {
            const float nominalDelay = (float)(delay.size() - 1);
            const float readPos = std::max(0.0f, std::min(nominalDelay + modSamples, nominalDelay));
            const float bufOut = delay.readInterpolated(readPos);
            const float output = -gain * input + bufOut;
            delay.write(flushDenormal(input + gain * output));
            return output;
        }

    private:
        DelayLine delay;
        float gain = 0.5f;
    };

    static size_t scaleSamples(float samplesAt29k, double rate)
    {
        const size_t n = (size_t)std::lround(samplesAt29k * (rate / 29761.0));
        return std::max<size_t>(4, n);
    }

    void buildBuffers()
    {
        const double rate = sampleRate;

        // 1. Pre-delay buffers (250 ms max)
        const size_t preDelaySamples = (size_t)std::lround((MAX_PRE_DELAY_MS * 0.001) * rate);
        for (int ch = 0; ch < 2; ++ch)
        {
            preDelayBuf[ch].assign(std::max<size_t>(2, preDelaySamples), 0.0f);
            preDelayWriteIdx[ch] = 0;
        }

        // 2. Input Diffusers (Dattorro tunings: 142, 107, 379, 277 @ 29.761 kHz)
        // Ch 0 uses nominal prime lengths, Ch 1 uses slightly offset prime lengths
        diffusers[0][0].init(scaleSamples(142.0f, rate), 0.75f);
        diffusers[0][1].init(scaleSamples(107.0f, rate), 0.75f);
        diffusers[0][2].init(scaleSamples(379.0f, rate), 0.625f);
        diffusers[0][3].init(scaleSamples(277.0f, rate), 0.625f);

        diffusers[1][0].init(scaleSamples(149.0f, rate), 0.75f);
        diffusers[1][1].init(scaleSamples(113.0f, rate), 0.75f);
        diffusers[1][2].init(scaleSamples(389.0f, rate), 0.625f);
        diffusers[1][3].init(scaleSamples(283.0f, rate), 0.625f);

        // 3. Tank 1 (Modulated AP 672, Delay 4453, AP 1800, Delay 3720)
        // Extra margin added to modulated allpass for LFO excursion
        tank1_modAp.init(scaleSamples(672.0f + 24.0f, rate), 0.70f);
        tank1_del1.resize(scaleSamples(4453.0f, rate));
        tank1_ap2.init(scaleSamples(1800.0f, rate), 0.50f);
        tank1_del2.resize(scaleSamples(3720.0f, rate));

        // 4. Tank 2 (Modulated AP 908, Delay 4217, AP 2656, Delay 3163)
        tank2_modAp.init(scaleSamples(908.0f + 24.0f, rate), 0.70f);
        tank2_del1.resize(scaleSamples(4217.0f, rate));
        tank2_ap2.init(scaleSamples(2656.0f, rate), 0.50f);
        tank2_del2.resize(scaleSamples(3163.0f, rate));

        // 5. Output Tap Positions
        tap_t1_d1_1  = scaleSamples(1990.0f, rate);
        tap_t1_d1_2  = scaleSamples(353.0f, rate);
        tap_t1_d1_3  = scaleSamples(3627.0f, rate);
        tap_t1_ap2_1 = scaleSamples(187.0f, rate);
        tap_t1_ap2_2 = scaleSamples(1228.0f, rate);
        tap_t1_d2_1  = scaleSamples(1066.0f, rate);
        tap_t1_d2_2  = scaleSamples(2673.0f, rate);

        tap_t2_d1_1  = scaleSamples(266.0f, rate);
        tap_t2_d1_2  = scaleSamples(2974.0f, rate);
        tap_t2_d1_3  = scaleSamples(2111.0f, rate);
        tap_t2_ap2_1 = scaleSamples(1913.0f, rate);
        tap_t2_ap2_2 = scaleSamples(335.0f, rate);
        tap_t2_d2_1  = scaleSamples(1996.0f, rate);
        tap_t2_d2_2  = scaleSamples(121.0f, rate);
    }

    double sampleRate = 48000.0;

    bool targetEnabled = false;
    bool currentEnabled = false;

    float targetWet = 0.0f;
    float currentWet = 0.0f;

    float targetDry = 1.0f;
    float currentDry = 1.0f;

    float targetRoomSize = 0.5f;
    float currentRoomSize = 0.5f;

    float targetDamping = 0.5f;
    float currentDamping = 0.5f;

    float targetPreDelayMs = 10.0f;
    float currentPreDelayMs = 10.0f;

    float targetWidth = 1.0f;
    float currentWidth = 1.0f;

    // Pre-delay
    std::vector<float> preDelayBuf[2];
    size_t preDelayWriteIdx[2] = {0, 0};

    // Abbey Road input filter states
    float hpPrevIn[2] = {0.0f, 0.0f};
    float hpState[2]  = {0.0f, 0.0f};
    float lpState[2]  = {0.0f, 0.0f};

    // Input diffusers (4 per channel)
    AllpassFilter diffusers[2][4];

    // Figure-8 Tank 1
    AllpassFilter tank1_modAp;
    DelayLine tank1_del1;
    AllpassFilter tank1_ap2;
    DelayLine tank1_del2;
    float tank1_dampState = 0.0f;
    float tank1_lastOut = 0.0f;

    // Figure-8 Tank 2
    AllpassFilter tank2_modAp;
    DelayLine tank2_del1;
    AllpassFilter tank2_ap2;
    DelayLine tank2_del2;
    float tank2_dampState = 0.0f;
    float tank2_lastOut = 0.0f;

    // Quadrature Dual-Phase LFO
    float lfoPhase1 = 0.0f;
    float lfoPhase2 = 0.0f;

    // Mutually prime tap points
    size_t tap_t1_d1_1 = 0, tap_t1_d1_2 = 0, tap_t1_d1_3 = 0;
    size_t tap_t1_ap2_1 = 0, tap_t1_ap2_2 = 0;
    size_t tap_t1_d2_1 = 0, tap_t1_d2_2 = 0;

    size_t tap_t2_d1_1 = 0, tap_t2_d1_2 = 0, tap_t2_d1_3 = 0;
    size_t tap_t2_ap2_1 = 0, tap_t2_ap2_2 = 0;
    size_t tap_t2_d2_1 = 0, tap_t2_d2_2 = 0;
};
