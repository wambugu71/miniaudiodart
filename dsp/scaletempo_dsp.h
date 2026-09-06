#pragma once

#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <cstdint>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace sauti
{
namespace dsp
{

/**
 * ScaleTempoDSP implements the Waveform Similarity Overlap-Add (WSOLA)
 * time-stretching algorithm, enabling tempo/speed scaling without altering pitch
 * or pitch shifting when combined with a resampler.
 *
 * Designed for low-latency, real-time audio playback engines.
 */
class ScaleTempoDSP
{
public:
    ScaleTempoDSP() = default;
    ~ScaleTempoDSP() = default;

    void init(int sampleRate, int channels, float strideMs = 30.0f, float overlapRatio = 0.20f, float searchMs = 14.0f)
    {
        m_sampleRate = (sampleRate > 0) ? sampleRate : 48000;
        m_channels = (channels > 0) ? channels : 2;

        m_strideFrames = std::max<size_t>(32, (size_t)std::round((double)m_sampleRate * (double)strideMs / 1000.0));
        m_overlapFrames = std::max<size_t>(16, (size_t)std::round((double)m_strideFrames * (double)overlapRatio));
        if (m_overlapFrames >= m_strideFrames)
        {
            m_overlapFrames = m_strideFrames / 2;
        }
        m_stepFrames = m_strideFrames - m_overlapFrames;

        m_searchFrames = std::max<size_t>(16, (size_t)std::round((double)m_sampleRate * (double)searchMs / 1000.0));

        // Generate Hann blending window
        m_blendTable.resize(m_overlapFrames);
        for (size_t i = 0; i < m_overlapFrames; ++i)
        {
            // Raised-cosine (Hann) ramp from 0.0 to 1.0
            double phase = M_PI * ((double)i + 0.5) / (double)m_overlapFrames;
            m_blendTable[i] = (float)(0.5 * (1.0 - std::cos(phase)));
        }

        m_overlapBuffer.assign(m_overlapFrames * m_channels, 0.0f);
        m_inputBuffer.clear();
        m_outputBuffer.clear();
        m_monoInput.clear();
        m_monoOverlap.assign(m_overlapFrames, 0.0f);

        m_scale = 1.0f;
        m_nominalPosition = 0.0;
        m_hasOverlap = false;
        m_initialized = true;
    }

    void reset()
    {
        m_inputBuffer.clear();
        m_outputBuffer.clear();
        if (m_channels > 0 && m_overlapFrames > 0)
        {
            m_overlapBuffer.assign(m_overlapFrames * m_channels, 0.0f);
            m_monoOverlap.assign(m_overlapFrames, 0.0f);
        }
        m_nominalPosition = 0.0;
        m_hasOverlap = false;
    }

    void setScale(float scale)
    {
        // Clamp scale to reasonable playback range (0.05x to 10.0x)
        m_scale = std::clamp(scale, 0.05f, 10.0f);
    }

    float getScale() const
    {
        return m_scale;
    }

    int getSampleRate() const
    {
        return m_sampleRate;
    }

    int getChannels() const
    {
        return m_channels;
    }

    bool isInitialized() const
    {
        return m_initialized;
    }

    /**
     * Feeds input frames into the processor.
     * @param input Interleaved float PCM samples.
     * @param inputFrames Number of frames (samples / channels) provided.
     */
    void writeInput(const float *input, size_t inputFrames)
    {
        if (!m_initialized || input == nullptr || inputFrames == 0)
            return;

        const size_t numSamples = inputFrames * m_channels;
        const size_t oldSize = m_inputBuffer.size();
        m_inputBuffer.resize(oldSize + numSamples);
        std::memcpy(m_inputBuffer.data() + oldSize, input, numSamples * sizeof(float));

        processInternal();
    }

    /**
     * Reads available output frames from the processor.
     * @param output Destination buffer for interleaved float PCM samples.
     * @param maxFrames Maximum number of frames to read.
     * @return Number of frames read.
     */
    size_t readOutput(float *output, size_t maxFrames)
    {
        if (!m_initialized || output == nullptr || maxFrames == 0)
            return 0;

        const size_t availableFrames = m_outputBuffer.size() / m_channels;
        const size_t framesToRead = std::min(maxFrames, availableFrames);
        if (framesToRead == 0)
            return 0;

        const size_t samplesToRead = framesToRead * m_channels;
        std::memcpy(output, m_outputBuffer.data(), samplesToRead * sizeof(float));

        const size_t remainingSamples = m_outputBuffer.size() - samplesToRead;
        if (remainingSamples > 0)
        {
            std::memmove(m_outputBuffer.data(), m_outputBuffer.data() + samplesToRead, remainingSamples * sizeof(float));
            m_outputBuffer.resize(remainingSamples);
        }
        else
        {
            m_outputBuffer.clear();
        }

        return framesToRead;
    }

    size_t availableOutputFrames() const
    {
        if (!m_initialized || m_channels == 0)
            return 0;
        return m_outputBuffer.size() / m_channels;
    }

    size_t availableInputFrames() const
    {
        if (!m_initialized || m_channels == 0)
            return 0;
        return m_inputBuffer.size() / m_channels;
    }

private:
    void processInternal()
    {
        // If scale is nominally 1.0 (within 0.001) and we have no pending overlap,
        // we can transfer frames directly from input to output.
        if (std::abs(m_scale - 1.0f) < 0.001f && !m_hasOverlap)
        {
            const size_t inSamples = m_inputBuffer.size();
            if (inSamples > 0)
            {
                const size_t outOld = m_outputBuffer.size();
                m_outputBuffer.resize(outOld + inSamples);
                std::memcpy(m_outputBuffer.data() + outOld, m_inputBuffer.data(), inSamples * sizeof(float));
                m_inputBuffer.clear();
                m_nominalPosition = 0.0;
            }
            return;
        }

        while (true)
        {
            const size_t totalInputFrames = m_inputBuffer.size() / m_channels;

            if (!m_hasOverlap)
            {
                if (totalInputFrames < m_strideFrames)
                    break;

                // Prime initial stride: output first stride directly and store overlap
                const size_t copyFrames = m_strideFrames;
                const size_t outOld = m_outputBuffer.size();
                m_outputBuffer.resize(outOld + copyFrames * m_channels);
                std::memcpy(m_outputBuffer.data() + outOld, m_inputBuffer.data(), copyFrames * m_channels * sizeof(float));

                // Save tail for overlap
                const size_t overlapOffset = (m_strideFrames - m_overlapFrames) * m_channels;
                std::memcpy(m_overlapBuffer.data(), m_inputBuffer.data() + overlapOffset, m_overlapFrames * m_channels * sizeof(float));
                updateMonoOverlap();

                // Advance by stride
                consumeInputFrames(m_strideFrames);
                m_nominalPosition = (double)m_stepFrames * (double)m_scale;
                m_hasOverlap = true;
                continue;
            }

            // Target search center is nominalPosition
            long centerOffset = (long)std::round(m_nominalPosition);
            long searchMin = std::max(0L, centerOffset - (long)m_searchFrames);
            long searchMax = centerOffset + (long)m_searchFrames;

            // Ensure we have enough frames in inputBuffer for the search range + stride
            if (totalInputFrames < (size_t)(searchMax + (long)m_strideFrames))
            {
                break;
            }

            // Prepare downmixed mono input buffer for correlation search
            updateMonoInput(searchMax + m_overlapFrames);

            long bestOffset = searchMin;
            float bestCorr = -1e30f;

            // Two-pass search: coarse search with stride of 4, then fine search ±3
            const long coarseStep = 4;
            long coarseBest = searchMin;
            for (long k = searchMin; k <= searchMax; k += coarseStep)
            {
                float corr = computeCorrelation(k);
                if (corr > bestCorr)
                {
                    bestCorr = corr;
                    coarseBest = k;
                }
            }

            bestOffset = coarseBest;
            long fineStart = std::max(searchMin, coarseBest - (coarseStep - 1));
            long fineEnd = std::min(searchMax, coarseBest + (coarseStep - 1));
            for (long k = fineStart; k <= fineEnd; ++k)
            {
                if (k == coarseBest)
                    continue;
                float corr = computeCorrelation(k);
                if (corr > bestCorr)
                {
                    bestCorr = corr;
                    bestOffset = k;
                }
            }

            // Perform WSOLA overlap-add into output buffer
            const size_t outOld = m_outputBuffer.size();
            m_outputBuffer.resize(outOld + m_stepFrames * m_channels);
            float *outPtr = m_outputBuffer.data() + outOld;
            const float *inPtr = m_inputBuffer.data() + (bestOffset * m_channels);

            // 1. Crossfade the overlap region (first overlapFrames)
            // Note: overlap from previous block was stored in m_overlapBuffer
            for (size_t i = 0; i < m_overlapFrames; ++i)
            {
                const float w = m_blendTable[i];
                const float invW = 1.0f - w;
                for (size_t c = 0; c < m_channels; ++c)
                {
                    outPtr[i * m_channels + c] = m_overlapBuffer[i * m_channels + c] * invW + inPtr[i * m_channels + c] * w;
                }
            }

            // 2. Direct copy remainder of step (from overlapFrames to m_stepFrames)
            if (m_stepFrames > m_overlapFrames)
            {
                const size_t remFrames = m_stepFrames - m_overlapFrames;
                std::memcpy(outPtr + (m_overlapFrames * m_channels),
                            inPtr + (m_overlapFrames * m_channels),
                            remFrames * m_channels * sizeof(float));
            }

            // 3. Save new tail into overlap buffer
            const size_t tailOffset = m_stepFrames * m_channels;
            std::memcpy(m_overlapBuffer.data(), inPtr + tailOffset, m_overlapFrames * m_channels * sizeof(float));
            updateMonoOverlap();

            // 4. Consume bestOffset frames from input
            consumeInputFrames(bestOffset);

            // 5. Update nominal position: advance by stepFrames * scale, minus consumed frames
            m_nominalPosition += ((double)m_stepFrames * (double)m_scale) - (double)bestOffset;
        }
    }

    void consumeInputFrames(size_t frames)
    {
        if (frames == 0)
            return;
        const size_t totalFrames = m_inputBuffer.size() / m_channels;
        if (frames >= totalFrames)
        {
            m_inputBuffer.clear();
            return;
        }

        const size_t samplesToDrop = frames * m_channels;
        const size_t remainingSamples = m_inputBuffer.size() - samplesToDrop;
        std::memmove(m_inputBuffer.data(), m_inputBuffer.data() + samplesToDrop, remainingSamples * sizeof(float));
        m_inputBuffer.resize(remainingSamples);
    }

    void updateMonoOverlap()
    {
        const float invCh = 1.0f / (float)m_channels;
        for (size_t i = 0; i < m_overlapFrames; ++i)
        {
            float sum = 0.0f;
            for (size_t c = 0; c < m_channels; ++c)
            {
                sum += m_overlapBuffer[i * m_channels + c];
            }
            m_monoOverlap[i] = sum * invCh;
        }
    }

    void updateMonoInput(size_t neededFrames)
    {
        const size_t curFrames = m_inputBuffer.size() / m_channels;
        const size_t count = std::min(neededFrames, curFrames);
        m_monoInput.resize(count);

        const float invCh = 1.0f / (float)m_channels;
        for (size_t i = 0; i < count; ++i)
        {
            float sum = 0.0f;
            for (size_t c = 0; c < m_channels; ++c)
            {
                sum += m_inputBuffer[i * m_channels + c];
            }
            m_monoInput[i] = sum * invCh;
        }
    }

    float computeCorrelation(long offset) const
    {
        if (offset < 0 || (size_t)(offset + m_overlapFrames) > m_monoInput.size())
            return -1e30f;

        const float *inPtr = m_monoInput.data() + offset;
        const float *ovPtr = m_monoOverlap.data();

        float corr = 0.0f;
        float norm = 1e-6f;

        // Vectorizable dot product
        for (size_t i = 0; i < m_overlapFrames; ++i)
        {
            const float s = inPtr[i];
            corr += ovPtr[i] * s;
            norm += s * s;
        }

        // Normalized cross-correlation score
        return corr / std::sqrt(norm);
    }

    int m_sampleRate = 48000;
    int m_channels = 2;
    size_t m_strideFrames = 1440;
    size_t m_overlapFrames = 384;
    size_t m_stepFrames = 1056;
    size_t m_searchFrames = 672;

    float m_scale = 1.0f;
    double m_nominalPosition = 0.0;
    bool m_hasOverlap = false;
    bool m_initialized = false;

    std::vector<float> m_blendTable;
    std::vector<float> m_overlapBuffer;
    std::vector<float> m_monoOverlap;
    std::vector<float> m_inputBuffer;
    std::vector<float> m_monoInput;
    std::vector<float> m_outputBuffer;
};

} // namespace dsp
} // namespace sauti
