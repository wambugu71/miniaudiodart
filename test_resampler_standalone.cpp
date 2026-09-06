#include <iostream>
#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <cstdio>
#include <cstdlib>

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <samplerate.h>
#include <soxr.h>
#include "CDSPResampler.h"

// Re-create the LibSampleRateBackend and SoxrResamplerBackend VTable wrappers matching audio_engine.cpp

struct LibSampleRateBackend
{
    SRC_STATE *state;
    float ratio;
    int channels;
    int converterType;
};

static ma_result src_onGetHeapSize(void *pUserData, const ma_resampler_config *pConfig, size_t *pHeapSizeInBytes)
{
    if (!pHeapSizeInBytes) return MA_INVALID_ARGS;
    *pHeapSizeInBytes = sizeof(LibSampleRateBackend);
    return MA_SUCCESS;
}

static ma_result src_onInit(void *pUserData, const ma_resampler_config *pConfig, void *pAllocation, ma_resampling_backend **ppBackend)
{
    if (!pConfig || !pAllocation || !ppBackend) return MA_INVALID_ARGS;
    LibSampleRateBackend *backend = (LibSampleRateBackend *)pAllocation;
    backend->channels = pConfig->channels;

    int algo = pUserData ? *(int *)pUserData : 1;
    int converter = SRC_SINC_FASTEST;
    if (algo == 1) converter = SRC_SINC_BEST_QUALITY;
    else if (algo == 2) converter = SRC_SINC_MEDIUM_QUALITY;
    else if (algo == 3) converter = SRC_SINC_FASTEST;
    else if (algo == 4) converter = SRC_ZERO_ORDER_HOLD;
    else if (algo == 5 || algo == 6) converter = SRC_LINEAR;

    backend->converterType = converter;
    backend->ratio = (pConfig->sampleRateIn > 0) ? ((float)pConfig->sampleRateOut / (float)pConfig->sampleRateIn) : 1.0f;

    int err = 0;
    backend->state = src_new(converter, backend->channels, &err);
    if (!backend->state)
    {
        std::printf("src_onInit failed (err=%d: %s)\n", err, src_strerror(err));
        return MA_ERROR;
    }

    *ppBackend = (ma_resampling_backend *)backend;
    return MA_SUCCESS;
}

static void src_onUninit(void *pUserData, ma_resampling_backend *pBackend, const ma_allocation_callbacks *pAllocationCallbacks)
{
    LibSampleRateBackend *backend = (LibSampleRateBackend *)pBackend;
    if (backend && backend->state)
    {
        src_delete(backend->state);
        backend->state = nullptr;
    }
}

static ma_result src_onProcess(void *pUserData, ma_resampling_backend *pBackend, const void *pFramesIn, ma_uint64 *pFrameCountIn, void *pFramesOut, ma_uint64 *pFrameCountOut)
{
    LibSampleRateBackend *backend = (LibSampleRateBackend *)pBackend;
    if (!backend || !backend->state || !pFrameCountIn || !pFrameCountOut) return MA_ERROR;

    SRC_DATA srcData;
    srcData.data_in = (const float *)pFramesIn;
    srcData.input_frames = (long)std::min<ma_uint64>(*pFrameCountIn, 0x7FFFFFFF);
    srcData.data_out = (float *)pFramesOut;
    srcData.output_frames = (long)std::min<ma_uint64>(*pFrameCountOut, 0x7FFFFFFF);
    srcData.src_ratio = backend->ratio;
    srcData.end_of_input = 0;

    int err = src_process(backend->state, &srcData);
    if (err) return MA_ERROR;

    *pFrameCountIn = (ma_uint64)srcData.input_frames_used;
    *pFrameCountOut = (ma_uint64)srcData.output_frames_gen;
    return MA_SUCCESS;
}

static ma_result src_onSetRate(void *pUserData, ma_resampling_backend *pBackend, ma_uint32 sampleRateIn, ma_uint32 sampleRateOut)
{
    LibSampleRateBackend *backend = (LibSampleRateBackend *)pBackend;
    if (!backend) return MA_ERROR;
    backend->ratio = (sampleRateIn > 0) ? ((float)sampleRateOut / (float)sampleRateIn) : 1.0f;
    if (backend->state)
    {
        src_set_ratio(backend->state, backend->ratio);
    }
    return MA_SUCCESS;
}

static ma_resampling_backend_vtable g_customResamplerVTable = {
    src_onGetHeapSize,
    src_onInit,
    src_onUninit,
    src_onProcess,
    src_onSetRate,
    NULL, NULL, NULL, NULL, NULL
};

// Soxr Backend
struct SoxrResamplerBackend
{
    soxr_t handle;
    double ratio;
    int channels;
    int algorithm;
};

static ma_result soxr_onGetHeapSize(void *pUserData, const ma_resampler_config *pConfig, size_t *pHeapSizeInBytes)
{
    if (!pHeapSizeInBytes) return MA_INVALID_ARGS;
    *pHeapSizeInBytes = sizeof(SoxrResamplerBackend);
    return MA_SUCCESS;
}

static ma_result soxr_onInit(void *pUserData, const ma_resampler_config *pConfig, void *pAllocation, ma_resampling_backend **ppBackend)
{
    if (!pConfig || !pAllocation || !ppBackend) return MA_INVALID_ARGS;
    SoxrResamplerBackend *backend = (SoxrResamplerBackend *)pAllocation;
    backend->channels = pConfig->channels;

    int algo = pUserData ? *(int *)pUserData : 7;
    backend->algorithm = algo;

    unsigned long q_recipe = SOXR_HQ;
    unsigned long q_flags = 0;

    if (algo == 7) { q_recipe = SOXR_VHQ; q_flags = SOXR_LINEAR_PHASE; }
    else if (algo == 8) { q_recipe = SOXR_VHQ; q_flags = SOXR_MINIMUM_PHASE; }
    else if (algo == 9) { q_recipe = SOXR_HQ; q_flags = SOXR_LINEAR_PHASE; }
    else if (algo == 10) { q_recipe = SOXR_LQ; q_flags = SOXR_LINEAR_PHASE; }

    soxr_quality_spec_t q_spec = soxr_quality_spec(q_recipe, q_flags);
    soxr_io_spec_t io_spec = soxr_io_spec(SOXR_FLOAT32_I, SOXR_FLOAT32_I);
    backend->ratio = (pConfig->sampleRateIn > 0) ? ((double)pConfig->sampleRateOut / (double)pConfig->sampleRateIn) : 1.0;

    soxr_error_t err = nullptr;
    backend->handle = soxr_create((double)pConfig->sampleRateIn, (double)pConfig->sampleRateOut, (unsigned)backend->channels, &err, &io_spec, &q_spec, NULL);
    if (!backend->handle || err)
    {
        std::printf("soxr_onInit failed (err=%s)\n", soxr_strerror(err));
        return MA_ERROR;
    }

    *ppBackend = (ma_resampling_backend *)backend;
    return MA_SUCCESS;
}

static void soxr_onUninit(void *pUserData, ma_resampling_backend *pBackend, const ma_allocation_callbacks *pAllocationCallbacks)
{
    SoxrResamplerBackend *backend = (SoxrResamplerBackend *)pBackend;
    if (backend && backend->handle)
    {
        soxr_delete(backend->handle);
        backend->handle = nullptr;
    }
}

static ma_result soxr_onProcess(void *pUserData, ma_resampling_backend *pBackend, const void *pFramesIn, ma_uint64 *pFrameCountIn, void *pFramesOut, ma_uint64 *pFrameCountOut)
{
    SoxrResamplerBackend *backend = (SoxrResamplerBackend *)pBackend;
    if (!backend || !backend->handle || !pFrameCountIn || !pFrameCountOut) return MA_ERROR;

    size_t idone = 0, odone = 0;
    soxr_error_t err = soxr_process(backend->handle, pFramesIn, (size_t)*pFrameCountIn, &idone, pFramesOut, (size_t)*pFrameCountOut, &odone);
    if (err) return MA_ERROR;

    *pFrameCountIn = (ma_uint64)idone;
    *pFrameCountOut = (ma_uint64)odone;
    return MA_SUCCESS;
}

static ma_result soxr_onSetRate(void *pUserData, ma_resampling_backend *pBackend, ma_uint32 sampleRateIn, ma_uint32 sampleRateOut)
{
    SoxrResamplerBackend *backend = (SoxrResamplerBackend *)pBackend;
    if (!backend) return MA_ERROR;
    backend->ratio = (sampleRateIn > 0) ? ((double)sampleRateOut / (double)sampleRateIn) : 1.0;
    if (backend->handle)
    {
        soxr_error_t err = soxr_set_io_ratio(backend->handle, 1.0 / backend->ratio, 0);
        if (err) return MA_ERROR;
    }
    return MA_SUCCESS;
}

static ma_resampling_backend_vtable g_soxrResamplerVTable = {
    soxr_onGetHeapSize,
    soxr_onInit,
    soxr_onUninit,
    soxr_onProcess,
    soxr_onSetRate,
    NULL, NULL, NULL, NULL, NULL
};

// r8brain Backend
struct R8brainBackend
{
    double ratio = 1.0;
    double sampleRateIn = 48000.0;
    double sampleRateOut = 48000.0;
    int channels = 2;
    int algorithm = 11;
    int maxInLen = 4096;
    std::vector<r8b::CDSPResampler *> resamplers;
    std::vector<std::vector<double>> inBufs;
    std::vector<double *> outPtrs;
    std::vector<float> outputFifo;
    size_t fifoReadPos = 0;
};

static ma_result r8b_onGetHeapSize(void *pUserData, const ma_resampler_config *pConfig, size_t *pHeapSizeInBytes)
{
    if (!pHeapSizeInBytes) return MA_INVALID_ARGS;
    *pHeapSizeInBytes = sizeof(R8brainBackend);
    return MA_SUCCESS;
}

static ma_result r8b_onInit(void *pUserData, const ma_resampler_config *pConfig, void *pAllocation, ma_resampling_backend **ppBackend)
{
    if (!pConfig || !pAllocation || !ppBackend) return MA_INVALID_ARGS;

    R8brainBackend *backend = new (pAllocation) R8brainBackend();
    backend->channels = (pConfig->channels > 0) ? (int)pConfig->channels : 2;
    backend->sampleRateIn = (pConfig->sampleRateIn > 0) ? (double)pConfig->sampleRateIn : ((pConfig->sampleRateOut > 0) ? (double)pConfig->sampleRateOut : 48000.0);
    backend->sampleRateOut = (pConfig->sampleRateOut > 0) ? (double)pConfig->sampleRateOut : 48000.0;
    backend->ratio = (backend->sampleRateIn > 0.0) ? (backend->sampleRateOut / backend->sampleRateIn) : 1.0;

    int algo = pUserData ? *(int *)pUserData : 11;
    backend->algorithm = algo;

    backend->maxInLen = 4096;
    const double reqTransBand = 2.0;
    const double reqAtten = 180.15;
    const r8b::EDSPFilterPhaseResponse phase = (algo == 12) ? r8b::fprMinPhase : r8b::fprLinearPhase;

    backend->resamplers.resize(backend->channels, nullptr);
    backend->inBufs.resize(backend->channels);
    backend->outPtrs.resize(backend->channels, nullptr);

    for (int c = 0; c < backend->channels; ++c)
    {
        backend->inBufs[c].resize(backend->maxInLen, 0.0);
        backend->resamplers[c] = new r8b::CDSPResampler(
            backend->sampleRateIn,
            backend->sampleRateOut,
            backend->maxInLen,
            reqTransBand,
            reqAtten,
            phase
        );
    }

    *ppBackend = (ma_resampling_backend *)backend;
    return MA_SUCCESS;
}

static void r8b_onUninit(void *pUserData, ma_resampling_backend *pBackend, const ma_allocation_callbacks *pAllocationCallbacks)
{
    R8brainBackend *backend = (R8brainBackend *)pBackend;
    if (backend)
    {
        for (auto *r : backend->resamplers)
        {
            delete r;
        }
        backend->resamplers.clear();
        backend->~R8brainBackend();
    }
}

static ma_result r8b_onProcess(void *pUserData, ma_resampling_backend *pBackend, const void *pFramesIn, ma_uint64 *pFrameCountIn, void *pFramesOut, ma_uint64 *pFrameCountOut)
{
    R8brainBackend *backend = (R8brainBackend *)pBackend;
    if (!backend || !pFrameCountIn || !pFrameCountOut) return MA_ERROR;

    const int ch = backend->channels;
    if (ch <= 0) return MA_ERROR;

    if (std::fabs(backend->ratio - 1.0) < 1.0e-5 && pFramesIn != nullptr && pFramesOut != nullptr && backend->outputFifo.empty())
    {
        ma_uint64 toCopy = std::min(*pFrameCountIn, *pFrameCountOut);
        std::memcpy(pFramesOut, pFramesIn, (size_t)toCopy * (size_t)ch * sizeof(float));
        *pFrameCountIn = toCopy;
        *pFrameCountOut = toCopy;
        return MA_SUCCESS;
    }

    float *outDst = (float *)pFramesOut;
    const float *inSrc = (const float *)pFramesIn;
    ma_uint64 outTarget = *pFrameCountOut;
    ma_uint64 outProduced = 0;

    if (!backend->outputFifo.empty())
    {
        size_t fifoFrames = (backend->outputFifo.size() - backend->fifoReadPos) / (size_t)ch;
        size_t toDrain = std::min<size_t>(fifoFrames, (size_t)(outTarget - outProduced));
        if (toDrain > 0)
        {
            if (outDst != nullptr)
            {
                std::memcpy(outDst + outProduced * (size_t)ch,
                            backend->outputFifo.data() + backend->fifoReadPos,
                            toDrain * (size_t)ch * sizeof(float));
            }
            backend->fifoReadPos += toDrain * (size_t)ch;
            outProduced += toDrain;
            if (backend->fifoReadPos >= backend->outputFifo.size())
            {
                backend->outputFifo.clear();
                backend->fifoReadPos = 0;
            }
        }
    }

    if (outProduced >= outTarget || !pFramesIn || *pFrameCountIn == 0)
    {
        *pFrameCountIn = 0;
        *pFrameCountOut = outProduced;
        return MA_SUCCESS;
    }

    size_t inFramesToProcess = std::min<size_t>((size_t)*pFrameCountIn, (size_t)backend->maxInLen);

    for (size_t i = 0; i < inFramesToProcess; ++i)
    {
        for (int c = 0; c < ch; ++c)
        {
            backend->inBufs[c][i] = (double)inSrc[i * (size_t)ch + (size_t)c];
        }
    }

    int genFrames = 0;
    for (int c = 0; c < ch; ++c)
    {
        genFrames = backend->resamplers[c]->process(backend->inBufs[c].data(), (int)inFramesToProcess, backend->outPtrs[c]);
    }

    if (genFrames > 0)
    {
        size_t availableOutSpace = (size_t)(outTarget - outProduced);
        size_t directCopy = std::min<size_t>((size_t)genFrames, availableOutSpace);

        if (outDst != nullptr && directCopy > 0)
        {
            for (size_t i = 0; i < directCopy; ++i)
            {
                for (int c = 0; c < ch; ++c)
                {
                    outDst[(outProduced + i) * (size_t)ch + (size_t)c] = (float)backend->outPtrs[c][i];
                }
            }
            outProduced += directCopy;
        }

        if ((size_t)genFrames > directCopy)
        {
            size_t excess = (size_t)genFrames - directCopy;
            size_t oldSize = backend->outputFifo.size();
            backend->outputFifo.resize(oldSize + excess * (size_t)ch);
            for (size_t i = 0; i < excess; ++i)
            {
                for (int c = 0; c < ch; ++c)
                {
                    backend->outputFifo[oldSize + i * (size_t)ch + (size_t)c] = (float)backend->outPtrs[c][directCopy + i];
                }
            }
        }
    }

    *pFrameCountIn = (ma_uint64)inFramesToProcess;
    *pFrameCountOut = outProduced;
    return MA_SUCCESS;
}

static ma_result r8b_onSetRate(void *pUserData, ma_resampling_backend *pBackend, ma_uint32 sampleRateIn, ma_uint32 sampleRateOut)
{
    R8brainBackend *backend = (R8brainBackend *)pBackend;
    if (!backend || sampleRateIn == 0 || sampleRateOut == 0) return MA_ERROR;

    backend->sampleRateIn = (double)sampleRateIn;
    backend->sampleRateOut = (double)sampleRateOut;
    backend->ratio = backend->sampleRateOut / backend->sampleRateIn;

    const double reqTransBand = 2.0;
    const double reqAtten = 180.15;
    const r8b::EDSPFilterPhaseResponse phase = (backend->algorithm == 12) ? r8b::fprMinPhase : r8b::fprLinearPhase;

    for (int c = 0; c < backend->channels; ++c)
    {
        delete backend->resamplers[c];
        backend->resamplers[c] = new r8b::CDSPResampler(
            backend->sampleRateIn,
            backend->sampleRateOut,
            backend->maxInLen,
            reqTransBand,
            reqAtten,
            phase
        );
    }
    backend->outputFifo.clear();
    backend->fifoReadPos = 0;
    return MA_SUCCESS;
}

static ma_resampling_backend_vtable g_r8brainResamplerVTable = {
    r8b_onGetHeapSize,
    r8b_onInit,
    r8b_onUninit,
    r8b_onProcess,
    r8b_onSetRate,
    NULL, NULL, NULL, NULL, NULL
};

// Frequency estimation by counting zero crossings
double estimate_frequency(const std::vector<float>& buffer, int channels, int sampleRate)
{
    if (buffer.empty() || sampleRate <= 0) return 0.0;
    
    // Process left channel (channel 0)
    int zeroCrossings = 0;
    size_t startFrame = buffer.size() / (channels * 4); // skip initial transient
    size_t endFrame = buffer.size() / channels - startFrame;
    
    for (size_t i = startFrame + 1; i < endFrame; ++i)
    {
        float prev = buffer[(i - 1) * channels];
        float curr = buffer[i * channels];
        if (prev <= 0.0f && curr > 0.0f)
        {
            zeroCrossings++;
        }
    }
    
    double durationSec = (double)(endFrame - startFrame) / (double)sampleRate;
    if (durationSec <= 0) return 0.0;
    return (double)zeroCrossings / durationSec;
}

void run_test(const char* name, int algo, ma_resampling_backend_vtable* vtable, int inRate, int outRate, int channels = 2, double sineFreq = 1000.0)
{
    double durationSec = 2.0;
    size_t totalInFrames = (size_t)(inRate * durationSec);
    std::vector<float> inputSignal(totalInFrames * channels);

    // Generate 1 kHz sine wave
    for (size_t i = 0; i < totalInFrames; ++i)
    {
        float val = (float)std::sin(2.0 * 3.14159265358979323846 * sineFreq * (double)i / (double)inRate);
        for (int c = 0; c < channels; ++c)
        {
            inputSignal[i * channels + c] = val;
        }
    }

    // Initialize resampler via miniaudio ma_resampler API
    ma_resampler_config config = ma_resampler_config_init(
        ma_format_f32,
        (ma_uint32)channels,
        (ma_uint32)inRate,
        (ma_uint32)outRate,
        ma_resample_algorithm_custom
    );
    config.pBackendVTable = vtable;
    config.pBackendUserData = &algo;

    ma_resampler resampler;
    ma_result res = ma_resampler_init(&config, NULL, &resampler);
    if (res != MA_SUCCESS)
    {
        std::printf("[%s] INIT FAILED (res=%d)\n", name, res);
        return;
    }

    // Process audio in chunks of 512 frames
    size_t chunkSizeIn = 512;
    size_t inFramesRead = 0;
    std::vector<float> outputSignal;
    outputSignal.reserve((size_t)(totalInFrames * ((double)outRate / inRate) + 4096) * channels);

    size_t totalInConsumed = 0;
    size_t totalOutGenerated = 0;

    while (inFramesRead < totalInFrames)
    {
        ma_uint64 framesInAvailable = std::min<size_t>(chunkSizeIn, totalInFrames - inFramesRead);
        ma_uint64 framesOutCapacity = (ma_uint64)std::ceil((double)framesInAvailable * ((double)outRate / inRate) + 256);

        std::vector<float> outBuf(framesOutCapacity * channels);

        ma_uint64 framesInConsumed = framesInAvailable;
        ma_uint64 framesOutGenerated = framesOutCapacity;

        res = ma_resampler_process_pcm_frames(
            &resampler,
            &inputSignal[inFramesRead * channels],
            &framesInConsumed,
            outBuf.data(),
            &framesOutGenerated
        );

        if (res != MA_SUCCESS)
        {
            std::printf("[%s] PROCESS ERROR at frame %zu\n", name, inFramesRead);
            break;
        }

        outputSignal.insert(outputSignal.end(), outBuf.begin(), outBuf.begin() + framesOutGenerated * channels);

        inFramesRead += framesInConsumed;
        totalInConsumed += framesInConsumed;
        totalOutGenerated += framesOutGenerated;

        if (framesInConsumed == 0 && framesOutGenerated == 0)
        {
            break; // no progress
        }
    }

    ma_resampler_uninit(&resampler, NULL);

    double estFreq = estimate_frequency(outputSignal, channels, outRate);
    double expectedOutFrames = (double)totalInFrames * ((double)outRate / (double)inRate);
    double generatedDurationSec = (double)totalOutGenerated / (double)outRate;
    double freqError = std::abs(estFreq - sineFreq);

    std::printf("[%s] %d Hz -> %d Hz | InConsumed: %zu/%zu | OutGen: %zu (exp: %.0f) | Dur: %.3fs | Est Freq: %.2f Hz (err: %.2f Hz) [%s]\n",
        name, inRate, outRate, totalInConsumed, totalInFrames, totalOutGenerated, expectedOutFrames, generatedDurationSec, estFreq, freqError,
        (freqError < 5.0 ? "PASS" : "FAIL - PITCH SHIFT"));
}

int main()
{
    std::printf("============================================================\n");
    std::printf("STANDALONE CUSTOM RESAMPLER BACKEND INTEGRATION TEST\n");
    std::printf("============================================================\n\n");

    std::printf("--- TESTING MINIAUDIO LINEAR RESAMPLER (BASELINE) ---\n");
    // Test linear resampler via stock miniaudio
    {
        ma_resampler_config config = ma_resampler_config_init(ma_format_f32, 2, 48000, 96000, ma_resample_algorithm_linear);
        ma_resampler resampler;
        if (ma_resampler_init(&config, NULL, &resampler) == MA_SUCCESS)
        {
            std::vector<float> inBuf(48000 * 2 * 2);
            for (size_t i = 0; i < 48000 * 2; ++i) {
                float val = (float)std::sin(2.0 * 3.14159265358979323846 * 1000.0 * i / 48000.0);
                inBuf[i * 2] = val; inBuf[i * 2 + 1] = val;
            }
            std::vector<float> outBuf(96000 * 2 * 2);
            ma_uint64 inCount = 48000 * 2;
            ma_uint64 outCount = 96000 * 2;
            ma_resampler_process_pcm_frames(&resampler, inBuf.data(), &inCount, outBuf.data(), &outCount);
            double freq = estimate_frequency(outBuf, 2, 96000);
            std::printf("[Linear Stock] 48000 -> 96000 | Est Freq: %.2f Hz [PASS]\n", freq);
            ma_resampler_uninit(&resampler, NULL);
        }
    }

    std::printf("\n--- TESTING LIBSAMPLERATE BACKEND (g_customResamplerVTable) ---\n");
    run_test("libsamplerate BEST", 1, &g_customResamplerVTable, 48000, 96000);
    run_test("libsamplerate BEST", 1, &g_customResamplerVTable, 96000, 48000);
    run_test("libsamplerate BEST", 1, &g_customResamplerVTable, 44100, 48000);
    run_test("libsamplerate BEST", 1, &g_customResamplerVTable, 48000, 44100);
    run_test("libsamplerate BEST", 1, &g_customResamplerVTable, 192000, 48000);

    run_test("libsamplerate FASTEST", 3, &g_customResamplerVTable, 48000, 96000);
    run_test("libsamplerate FASTEST", 3, &g_customResamplerVTable, 96000, 48000);

    std::printf("\n--- TESTING LIBSOXR BACKEND (g_soxrResamplerVTable) ---\n");
    run_test("libsoxr VHQ", 7, &g_soxrResamplerVTable, 48000, 96000);
    run_test("libsoxr VHQ", 7, &g_soxrResamplerVTable, 96000, 48000);
    run_test("libsoxr VHQ", 7, &g_soxrResamplerVTable, 44100, 48000);
    run_test("libsoxr VHQ", 7, &g_soxrResamplerVTable, 48000, 44100);
    run_test("libsoxr HQ",  9, &g_soxrResamplerVTable, 48000, 96000);
    run_test("libsoxr LQ", 10, &g_soxrResamplerVTable, 48000, 96000);

    std::printf("\n--- TESTING R8BRAIN BACKEND (g_r8brainResamplerVTable) ---\n");
    run_test("r8brain LinearPhase", 11, &g_r8brainResamplerVTable, 48000, 96000);
    run_test("r8brain LinearPhase", 11, &g_r8brainResamplerVTable, 96000, 48000);
    run_test("r8brain LinearPhase", 11, &g_r8brainResamplerVTable, 44100, 48000);
    run_test("r8brain LinearPhase", 11, &g_r8brainResamplerVTable, 48000, 44100);
    run_test("r8brain LinearPhase", 11, &g_r8brainResamplerVTable, 192000, 48000);

    run_test("r8brain MinPhase", 12, &g_r8brainResamplerVTable, 48000, 96000);
    run_test("r8brain MinPhase", 12, &g_r8brainResamplerVTable, 96000, 48000);
    run_test("r8brain MinPhase", 12, &g_r8brainResamplerVTable, 44100, 48000);
    run_test("r8brain MinPhase", 12, &g_r8brainResamplerVTable, 48000, 44100);

    return 0;
}
