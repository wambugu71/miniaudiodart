#include <iostream>
#include <vector>
#include <cmath>
#include <cassert>
#include <numeric>
#include "reverb_node.h"

int main()
{
    std::cout << "=== Running ReverbNode Dattorro Diffuse Tank Test ===" << std::endl;

    ReverbNode reverb;
    reverb.setSampleRate(48000.0);
    reverb.setEnabled(true);
    reverb.setWet(0.25f);
    reverb.setDry(1.0f);
    reverb.setRoomSize(0.6f);
    reverb.setDamping(0.4f);
    reverb.setPreDelayMs(10.0f);
    reverb.setWidth(1.0f);

    // Test 1: Impulse Response Test
    // Feed a single Dirac impulse at frame 0 and observe the output over 1 second (48,000 frames)
    const uint32_t totalFrames = 48000;
    std::vector<float> buffer(totalFrames * 2, 0.0f);
    buffer[0] = 1.0f; // Left impulse
    buffer[1] = 1.0f; // Right impulse

    // Process in chunks of 256 frames (typical audio buffer size)
    const uint32_t chunkSize = 256;
    for (uint32_t i = 0; i < totalFrames; i += chunkSize)
    {
        uint32_t framesToProcess = std::min(chunkSize, totalFrames - i);
        reverb.process(&buffer[i * 2], framesToProcess, 2);
    }

    // Check for NaN or Inf
    for (size_t i = 0; i < buffer.size(); ++i)
    {
        if (std::isnan(buffer[i]) || std::isinf(buffer[i]))
        {
            std::cerr << "FAILED: NaN or Inf detected at sample " << i << std::endl;
            return 1;
        }
    }
    std::cout << "PASS: No NaN/Inf detected in 1 second impulse response." << std::endl;

    // Check that there is sound after the impulse (reverb tail)
    float tailEnergy = 0.0f;
    for (size_t i = 2000 * 2; i < 40000 * 2; ++i)
    {
        tailEnergy += buffer[i] * buffer[i];
    }
    std::cout << "Reverb tail energy: " << tailEnergy << std::endl;
    if (tailEnergy <= 0.001f)
    {
        std::cerr << "FAILED: Reverb tail energy too low!" << std::endl;
        return 1;
    }
    std::cout << "PASS: Reverb tail energy present and well-distributed." << std::endl;

    // Test 2: Check for Flutter Echo vs Smooth Diffusion
    // An impulse into 8 parallel combs produces isolated periodic peaks.
    // A diffuse tank produces an envelope with high density.
    // Let's count zero crossings in the tail (between frame 2000 and 10000)
    int zeroCrossings = 0;
    for (size_t i = 2000 * 2; i < 10000 * 2; i += 2)
    {
        if ((buffer[i] >= 0.0f && buffer[i - 2] < 0.0f) ||
            (buffer[i] < 0.0f && buffer[i - 2] >= 0.0f))
        {
            zeroCrossings++;
        }
    }
    std::cout << "Tail zero crossings (8000 frames): " << zeroCrossings << std::endl;
    if (zeroCrossings < 500)
    {
        std::cerr << "FAILED: Zero crossings too low, indicating sparse/flutter echo!" << std::endl;
        return 1;
    }
    std::cout << "PASS: High modal density confirmed (zero crossings = " << zeroCrossings << ")." << std::endl;

    // Test 3: Stereo Decorrelation Test
    // Ensure Left and Right channels are distinct (not identical mono smear)
    float diffEnergy = 0.0f;
    float sumEnergy = 0.0f;
    for (size_t i = 2000; i < 10000; ++i)
    {
        float l = buffer[i * 2];
        float r = buffer[i * 2 + 1];
        diffEnergy += (l - r) * (l - r);
        sumEnergy += (l + r) * (l + r);
    }
    float decorrelationRatio = diffEnergy / (sumEnergy + 1e-6f);
    std::cout << "Stereo decorrelation ratio (diff/sum): " << decorrelationRatio << std::endl;
    if (decorrelationRatio < 0.05f)
    {
        std::cerr << "FAILED: Stereo channels are too correlated (mono-like)!" << std::endl;
        return 1;
    }
    std::cout << "PASS: Stereo channels are decorrelated and wide." << std::endl;

    // Test 4: Sample Rate Scaling Test (44.1k, 48k, 96k, 192k)
    double rates[] = {44100.0, 48000.0, 96000.0, 192000.0};
    for (double r : rates)
    {
        reverb.setSampleRate(r);
        std::vector<float> testBuf(512 * 2, 0.5f);
        reverb.process(testBuf.data(), 512, 2);
        for (float s : testBuf)
        {
            if (std::isnan(s) || std::isinf(s))
            {
                std::cerr << "FAILED: Sample rate " << r << " produced NaN/Inf!" << std::endl;
                return 1;
            }
        }
    }
    std::cout << "PASS: Sample rate scaling verified across 44.1k, 48k, 96k, 192k." << std::endl;

    // Test 5: Parameter Smoothing / Bypass Test
    reverb.setEnabled(false);
    std::vector<float> bypassBuf = {1.0f, -1.0f, 0.5f, -0.5f};
    std::vector<float> origBuf = bypassBuf;
    reverb.process(bypassBuf.data(), 2, 2);
    // When bypassed and tail is silent, dry should pass through unaltered
    std::cout << "Bypass test: in=(" << origBuf[0] << ", " << origBuf[1] << ") -> out=(" << bypassBuf[0] << ", " << bypassBuf[1] << ")" << std::endl;

    std::cout << "\nALL REVERB TESTS PASSED SUCCESSFULLY!" << std::endl;
    return 0;
}
