#ifndef NOMINMAX
#define NOMINMAX
#endif

#if defined(_WIN32) || defined(_WIN64)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#ifndef MA_NO_ASSERT
#define MA_NO_ASSERT
#endif
#ifndef MA_ASSERT
#define MA_ASSERT(condition) ((void)0)
#endif
#ifndef MA_DR_WAV_ASSERT
#define MA_DR_WAV_ASSERT(expression) ((void)0)
#endif
#ifndef MA_DR_FLAC_ASSERT
#define MA_DR_FLAC_ASSERT(expression) ((void)0)
#endif
#ifndef MA_DR_MP3_ASSERT
#define MA_DR_MP3_ASSERT(expression) ((void)0)
#endif

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "audio_engine.h"
#include "crossfeed_node.h"
#include "reverb_node.h"
#include <samplerate.h>
#include <soxr.h>
#include "CDSPResampler.h"
#include "mp4_aac_decoder.h"
#include "ffmpeg_stream_decoder.h"
#include "dsp/clarity_dsp.h"
#include "dsp/dialog_enhancer_dsp.h"
#include "dsp/dynamic_bass_dsp.h"
#include "dsp/dynamic_system_dsp.h"
#include "dsp/analog_warmth_dsp.h"
#include "dsp/de_esser_dsp.h"
#include "dsp/downward_expander_dsp.h"
#include "dsp/fft_convolver_dsp.h"
#include "dsp/master_limiter_dsp.h"
#include "dsp/spatial_surround_dsp.h"
#include "dsp/denormals.h"
#include "dsp/subsonic_filter.h"
#include "dsp/scaletempo_dsp.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <numeric>
#include <random>
#include <string>
#include <thread>
#include <vector>

#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
#include <curl/curl.h>
#endif

namespace
{

    static std::mutex g_logMutex;

    static void engine_log(const char *fmt, ...)
    {
        std::lock_guard<std::mutex> lk(g_logMutex);

        const auto now = std::chrono::system_clock::now();
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();

        std::fprintf(stderr, "[audio_engine %lld] ", (long long)ms);

        va_list args;
        va_start(args, fmt);
        std::vfprintf(stderr, fmt, args);
        va_end(args);

        std::fputc('\n', stderr);
        std::fflush(stderr);
    }

    static bool is_network_url(const std::string &s)
    {
        return s.rfind("http://", 0) == 0 || s.rfind("https://", 0) == 0;
    }

#if defined(_WIN32) || defined(_WIN64)
    // Convert a UTF-8 std::string to a UTF-16 std::wstring for Windows API calls.
    // This allows filenames containing Unicode characters (CJK, fullwidth quotes, emoji…)
    // to be opened correctly via ma_decoder_init_file_w.
    static std::wstring utf8_to_wstring(const std::string &utf8)
    {
        if (utf8.empty())
            return {};
        int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), nullptr, 0);
        if (len <= 0)
            return {};
        std::wstring wide(len, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), &wide[0], len);
        return wide;
    }
#endif

    struct PushStreamContext
    {
        ma_rb rb{};
        void *rbBuffer = nullptr; // Raw memory for the ring buffer
        std::atomic<bool> initialized{false};
        std::atomic<bool> isDone{false};
        std::mutex mtx; // Just in case we need coord
    };

    static ma_result push_stream_on_read(ma_decoder *pDecoder, void *pBufferOut, size_t bytesToRead, size_t *pBytesRead)
    {
        auto *ctx = reinterpret_cast<PushStreamContext *>(pDecoder->pUserData);
        if (!ctx || !ctx->initialized)
            return MA_INVALID_ARGS;

        *pBytesRead = 0;

        // Non-blocking read from RB
        size_t available = ma_rb_available_read(&ctx->rb);
        if (available == 0)
        {
            if (ctx->isDone)
            {
                return MA_SUCCESS; // EOF
            }
            // Buffer underrun - just return 0 bytes read, miniaudio might interpret as EOF or silence?
            // If we return 0 bytes and not EOF, decoder might stop.
            // We should block slightly or return silence?
            // Standard behavior: if 0 bytes read, it assumes EOF.
            // workaround: we need to block if not done.
            // But blocking in audio thread is bad.
            // However, this is the DECODING thread usually.
            // If `ma_decoder_read` is called from the audio callback directly, blocking is bad.
            // But we are in a custom `onRead`.

            // For now, let's just wait a tiny bit to see if data arrives
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            available = ma_rb_available_read(&ctx->rb);
            if (available == 0)
                return MA_SUCCESS; // Still empty
        }

        size_t toRead = (bytesToRead < available) ? bytesToRead : available;
        void *pReadBuf = nullptr;
        if (ma_rb_acquire_read(&ctx->rb, &toRead, &pReadBuf) == MA_SUCCESS)
        {
            std::memcpy(pBufferOut, pReadBuf, toRead);
            ma_rb_commit_read(&ctx->rb, toRead);
            *pBytesRead = toRead;
        }

        return MA_SUCCESS;
    }
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
    struct NetworkStreamState
    {
        ma_rb encodedRB{};
        std::mutex mtx;
        std::condition_variable cv;
        std::atomic<bool> stopRequested{false};
        std::atomic<bool> networkDone{false};
        std::atomic<bool> hasError{false};
        std::string url;
        std::thread networkThread;
    };

    static ma_result stream_on_read(ma_decoder *pDecoder, void *pBufferOut, size_t bytesToRead, size_t *pBytesRead)
    {
        if (pDecoder == nullptr || pBufferOut == nullptr || pBytesRead == nullptr)
            return MA_INVALID_ARGS;

        auto *st = reinterpret_cast<NetworkStreamState *>(pDecoder->pUserData);
        if (st == nullptr)
            return MA_INVALID_ARGS;

        *pBytesRead = 0;
        size_t totalRead = 0;

        while (totalRead < bytesToRead)
        {
            void *pRead = nullptr;
            size_t toRead = bytesToRead - totalRead;

            if (ma_rb_acquire_read(&st->encodedRB, &toRead, &pRead) == MA_SUCCESS && toRead > 0)
            {
                std::memcpy((char *)pBufferOut + totalRead, pRead, toRead);
                ma_rb_commit_read(&st->encodedRB, toRead);
                totalRead += toRead;
                continue;
            }

            if (st->stopRequested || (st->networkDone && ma_rb_available_read(&st->encodedRB) == 0))
                break;

            std::unique_lock<std::mutex> lk(st->mtx);
            st->cv.wait_for(lk, std::chrono::milliseconds(40));
        }

        *pBytesRead = totalRead;
        return MA_SUCCESS;
    }

    static ma_result stream_on_seek(ma_decoder *, ma_int64, ma_seek_origin)
    {
        return MA_NOT_IMPLEMENTED;
    }

    static size_t curl_on_write(char *contents, size_t size, size_t nmemb, void *userp)
    {
        auto *st = reinterpret_cast<NetworkStreamState *>(userp);
        if (st == nullptr)
            return 0;

        const size_t total = size * nmemb;
        size_t written = 0;

        while (written < total && !st->stopRequested)
        {
            void *pWrite = nullptr;
            size_t toWrite = total - written;

            if (ma_rb_acquire_write(&st->encodedRB, &toWrite, &pWrite) == MA_SUCCESS && toWrite > 0)
            {
                std::memcpy(pWrite, contents + written, toWrite);
                ma_rb_commit_write(&st->encodedRB, toWrite);
                written += toWrite;
                st->cv.notify_one();
                continue;
            }

            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }

        return written;
    }

    static int curl_on_progress(void *clientp, curl_off_t, curl_off_t, curl_off_t, curl_off_t)
    {
        auto *st = reinterpret_cast<NetworkStreamState *>(clientp);
        return (st != nullptr && st->stopRequested) ? 1 : 0;
    }

    static NetworkStreamState *create_network_stream(const std::string &url)
    {
        constexpr size_t kEncodedBufferSize = 2 * 1024 * 1024;

        auto *st = new NetworkStreamState();
        st->url = url;
        if (ma_rb_init(kEncodedBufferSize, nullptr, nullptr, &st->encodedRB) != MA_SUCCESS)
        {
            delete st;
            return nullptr;
        }

        st->networkThread = std::thread([st]()
                                        {
            CURL *curl = curl_easy_init();
            if (curl == nullptr)
            {
                st->hasError = true;
                st->networkDone = true;
                st->cv.notify_all();
                return;
            }

            curl_easy_setopt(curl, CURLOPT_URL, st->url.c_str());
            curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
            curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
            curl_easy_setopt(curl, CURLOPT_TIMEOUT, 0L);
            curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_on_write);
            curl_easy_setopt(curl, CURLOPT_WRITEDATA, st);
            curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
            curl_easy_setopt(curl, CURLOPT_USERAGENT, "MiniAudioDart/1.0");
            curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
            curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
            curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, curl_on_progress);
            curl_easy_setopt(curl, CURLOPT_XFERINFODATA, st);

            engine_log("network thread start: %s", st->url.c_str());
            CURLcode rc = curl_easy_perform(curl);
            if (rc != CURLE_OK && !st->stopRequested)
            {
                st->hasError = true;
                engine_log("network thread curl error: %s", curl_easy_strerror(rc));
            }

            curl_easy_cleanup(curl);
            st->networkDone = true;
            st->cv.notify_all();
            engine_log("network thread done: %s", st->url.c_str()); });

        return st;
    }

    static void destroy_network_stream(NetworkStreamState *st)
    {
        if (st == nullptr)
            return;
        st->stopRequested = true;
        st->cv.notify_all();
        if (st->networkThread.joinable())
        {
            st->networkThread.join();
        }
        ma_rb_uninit(&st->encodedRB);
        delete st;
    }
#endif

    static inline float clampf(float v, float lo, float hi)
    {
        return (v < lo) ? lo : ((v > hi) ? hi : v);
    }

    static inline double clampd(double v, double lo, double hi)
    {
        return (v < lo) ? lo : ((v > hi) ? hi : v);
    }

    static inline int clampi(int v, int lo, int hi)
    {
        return (v < lo) ? lo : ((v > hi) ? hi : v);
    }

    struct EqState
    {
        float lowGain = 1.0f;
        float midGain = 1.0f;
        float highGain = 1.0f;

        // 2nd-Order SVF Crossover for up to 8 channels
        struct SVF
        {
            float ic1eq = 0.0f, ic2eq = 0.0f;
            float a1 = 0.0f, a2 = 0.0f, a3 = 0.0f, k = 0.0f;
            void set(float cutoff, float sampleRate)
            {
                float g = std::tan(3.14159265358979323846f * cutoff / sampleRate);
                k = 1.0f / 0.5f; // Linkwitz-Riley-like Q = 0.5 for flat summing
                a1 = 1.0f / (1.0f + g * (g + k));
                a2 = g * a1;
                a3 = g * a2;
            }
            void process(float input, float &lp, float &hp)
            {
                float v3 = input - ic2eq;
                float v1 = a1 * ic1eq + a2 * v3;
                float v2 = ic2eq + a2 * ic1eq + a3 * v3;
                ic1eq = 2.0f * v1 - ic1eq;
                ic2eq = 2.0f * v2 - ic2eq;
                lp = v2;
                hp = input - k * v1 - v2;
            }
        };

        SVF lowCross[8];  // Splits Bass from (Mid+High)
        SVF highCross[8]; // Splits Mid from High

        void updateCoefficients(int sampleRate)
        {
            const float lowCut = 250.0f;   // Tighten bass crossover to focus on low punch
            const float highCut = 2500.0f; // Separate harsh highs from warm mids

            for (int c = 0; c < 8; ++c)
            {
                lowCross[c].set(lowCut, (float)sampleRate);
                highCross[c].set(highCut, (float)sampleRate);
            }
        }

        void process(float *interleaved, ma_uint32 frames, int channels)
        {
            const int ch = std::min(channels, 8);

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                for (int c = 0; c < ch; ++c)
                {
                    const size_t idx = (size_t)i * (size_t)channels + (size_t)c;
                    const float x = interleaved[idx];

                    float low, midHigh;
                    float mid, high;

                    // 1. Split x into Bass (low) and everything else (midHigh)
                    lowCross[c].process(x, low, midHigh);

                    // 2. Split everything else into Mid and High
                    highCross[c].process(midHigh, mid, high);

                    // Reconstruct with individual gains
                    interleaved[idx] = (low * lowGain) + (mid * midGain) + (high * highGain);
                }
            }
        }
    };

    struct ReverbState
    {
        std::vector<float> delayL;
        std::vector<float> delayR;
        size_t idxL = 0;
        size_t idxR = 0;

        float mix = 0.15f;      // Wet/Dry
        float feedback = 0.65f; // Room decay
        float delayMs = 95.0f;  // Base delay

        void reset(int sampleRate)
        {
            const size_t delaySamples = std::max<size_t>(64, (size_t)((delayMs / 1000.0f) * (float)sampleRate));
            delayL.assign(delaySamples, 0.0f);
            delayR.assign(delaySamples + 137, 0.0f); // Slight decorrelation
            idxL = 0;
            idxR = 0;
        }

        void updateParams(int sampleRate, float newMix, float newFeedback, float newDelayMs)
        {
            mix = clampf(newMix, 0.0f, 1.0f);
            feedback = clampf(newFeedback, 0.0f, 0.98f);
            delayMs = clampf(newDelayMs, 20.0f, 350.0f);
            reset(sampleRate);
        }

        void process(float *interleaved, ma_uint32 frames, int channels)
        {
            if (channels < 1 || delayL.empty() || delayR.empty())
            {
                return;
            }

            const bool stereo = channels >= 2;

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                size_t base = (size_t)i * (size_t)channels;

                float inL = interleaved[base];
                float wetL = delayL[idxL];
                delayL[idxL] = inL + wetL * feedback;
                interleaved[base] = inL * (1.0f - mix) + wetL * mix;
                idxL++;
                if (idxL >= delayL.size())
                    idxL = 0;

                if (stereo)
                {
                    float inR = interleaved[base + 1];
                    float wetR = delayR[idxR];
                    delayR[idxR] = inR + wetR * feedback;
                    interleaved[base + 1] = inR * (1.0f - mix) + wetR * mix;
                    idxR++;
                    if (idxR >= delayR.size())
                        idxR = 0;
                }
            }
        }
    };

    struct OnePoleState
    {
        float alpha = 0.0f;
        float z[8] = {0};
        float prevIn[8] = {0};

        void setLowpassCutoff(float hz, int sampleRate)
        {
            const float twoPi = 6.28318530718f;
            alpha = clampf((twoPi * hz) / (twoPi * hz + (float)sampleRate), 0.0001f, 0.9999f);
        }

        void setHighpassCutoff(float hz, int sampleRate)
        {
            const float twoPi = 6.28318530718f;
            alpha = clampf((float)sampleRate / ((float)sampleRate + twoPi * hz), 0.0001f, 0.9999f);
        }

        void processLowpass(float *interleaved, ma_uint32 frames, int channels)
        {
            const int ch = std::min(channels, 8);
            for (ma_uint32 i = 0; i < frames; ++i)
            {
                for (int c = 0; c < ch; ++c)
                {
                    const size_t idx = (size_t)i * (size_t)channels + (size_t)c;
                    z[c] = z[c] + alpha * (interleaved[idx] - z[c]);
                    interleaved[idx] = z[c];
                }
            }
        }

        void processHighpass(float *interleaved, ma_uint32 frames, int channels)
        {
            const int ch = std::min(channels, 8);
            for (ma_uint32 i = 0; i < frames; ++i)
            {
                for (int c = 0; c < ch; ++c)
                {
                    const size_t idx = (size_t)i * (size_t)channels + (size_t)c;
                    const float x = interleaved[idx];
                    const float y = alpha * (z[c] + x - prevIn[c]);
                    z[c] = y;
                    prevIn[c] = x;
                    interleaved[idx] = y;
                }
            }
        }
    };

    struct DelayState
    {
        std::vector<float> ring;
        size_t idx = 0;
        float mix = 0.2f;
        float feedback = 0.35f;
        float delayMs = 240.0f;
        int channels = 2;

        void reset(int sampleRate, int ch)
        {
            channels = std::max(1, ch);
            const size_t delaySamples = std::max<size_t>(64, (size_t)((delayMs / 1000.0f) * (float)sampleRate));
            ring.assign(delaySamples * (size_t)channels, 0.0f);
            idx = 0;
        }

        void updateParams(int sampleRate, int ch, float m, float fb, float dMs)
        {
            mix = clampf(m, 0.0f, 1.0f);
            feedback = clampf(fb, 0.0f, 0.98f);
            delayMs = clampf(dMs, 10.0f, 1200.0f);
            reset(sampleRate, ch);
        }

        void process(float *interleaved, ma_uint32 frames, int ch)
        {
            if (ring.empty())
                return;
            const int useCh = std::min(ch, channels);
            const size_t stride = (size_t)channels;

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                for (int c = 0; c < useCh; ++c)
                {
                    const size_t outIdx = (size_t)i * (size_t)ch + (size_t)c;
                    const size_t dIdx = idx + (size_t)c;
                    const float dry = interleaved[outIdx];
                    const float wet = ring[dIdx];
                    ring[dIdx] = dry + wet * feedback;
                    interleaved[outIdx] = dry * (1.0f - mix) + wet * mix;
                }
                idx += stride;
                if (idx >= ring.size())
                    idx = 0;
            }
        }
    };

    struct LibSampleRateBackend
    {
        SRC_STATE *state;
        float ratio;
        int channels;
        int converterType;
    };

    static ma_result src_onGetHeapSize(void *pUserData, const ma_resampler_config *pConfig, size_t *pHeapSizeInBytes)
    {
        if (!pHeapSizeInBytes)
            return MA_INVALID_ARGS;
        *pHeapSizeInBytes = sizeof(LibSampleRateBackend);
        return MA_SUCCESS;
    }

    static ma_result src_onInit(void *pUserData, const ma_resampler_config *pConfig, void *pAllocation, ma_resampling_backend **ppBackend)
    {
        if (!pConfig || !pAllocation || !ppBackend)
            return MA_INVALID_ARGS;
        LibSampleRateBackend *backend = (LibSampleRateBackend *)pAllocation;
        backend->channels = pConfig->channels;

        // pUserData points to the algorithm int (from AudioEngineHandle or AEResampler)
        int algo = pUserData ? *(int *)pUserData : 1;
        int converter = SRC_SINC_FASTEST;
        if (algo == 1)
            converter = SRC_SINC_BEST_QUALITY;
        else if (algo == 2)
            converter = SRC_SINC_MEDIUM_QUALITY;
        else if (algo == 3)
            converter = SRC_SINC_FASTEST;
        else if (algo == 4)
            converter = SRC_ZERO_ORDER_HOLD;
        else if (algo == 5 || algo == 6)
            converter = SRC_LINEAR;

        backend->converterType = converter;
        float rateIn = (pConfig->sampleRateIn > 0) ? (float)pConfig->sampleRateIn : ((pConfig->sampleRateOut > 0) ? (float)pConfig->sampleRateOut : 48000.0f);
        float rateOut = (pConfig->sampleRateOut > 0) ? (float)pConfig->sampleRateOut : 48000.0f;
        int ch = (backend->channels > 0) ? backend->channels : 2;
        backend->channels = ch;
        backend->ratio = (rateIn > 0) ? (rateOut / rateIn) : 1.0f;

        int err = 0;
        backend->state = src_new(converter, backend->channels, &err);
        if (!backend->state)
        {
            engine_log("src_onInit: src_new failed (err=%d: %s) for converter=%d channels=%d",
                       err, src_strerror(err), converter, backend->channels);
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
        if (!backend || !backend->state || !pFrameCountIn || !pFrameCountOut)
            return MA_ERROR;

        if (std::fabs(backend->ratio - 1.0f) < 1.0e-5f && pFramesIn != nullptr && pFramesOut != nullptr)
        {
            ma_uint64 toCopy = std::min(*pFrameCountIn, *pFrameCountOut);
            std::memcpy(pFramesOut, pFramesIn, (size_t)toCopy * (size_t)backend->channels * sizeof(float));
            *pFrameCountIn = toCopy;
            *pFrameCountOut = toCopy;
            return MA_SUCCESS;
        }

        ma_uint64 inAvail = *pFrameCountIn;
        ma_uint64 outReq = *pFrameCountOut;

        SRC_DATA srcData;
        srcData.data_in = (const float *)pFramesIn;
        srcData.input_frames = (long)std::min<ma_uint64>(*pFrameCountIn, 0x7FFFFFFF);
        srcData.data_out = (float *)pFramesOut;
        srcData.output_frames = (long)std::min<ma_uint64>(*pFrameCountOut, 0x7FFFFFFF);
        srcData.src_ratio = backend->ratio;
        srcData.end_of_input = 0;

        int err = src_process(backend->state, &srcData);
        if (err)
        {
            engine_log("src_onProcess error: %d (%s)", err, src_strerror(err));
            return MA_ERROR;
        }

        *pFrameCountIn = (ma_uint64)srcData.input_frames_used;
        *pFrameCountOut = (ma_uint64)srcData.output_frames_gen;

        // No logging here: this runs on the realtime audio thread, and even a
        // once-per-500-calls fprintf + fflush + global log mutex causes
        // periodic latency spikes.

        return MA_SUCCESS;
    }

    static ma_result src_onSetRate(void *pUserData, ma_resampling_backend *pBackend, ma_uint32 sampleRateIn, ma_uint32 sampleRateOut)
    {
        LibSampleRateBackend *backend = (LibSampleRateBackend *)pBackend;
        if (!backend)
            return MA_ERROR;
        backend->ratio = (sampleRateIn > 0) ? ((float)sampleRateOut / (float)sampleRateIn) : 1.0f;
        engine_log("src_onSetRate: sampleRateIn=%u sampleRateOut=%u -> new ratio=%.4f", sampleRateIn, sampleRateOut, backend->ratio);
        if (backend->state)
        {
            src_set_ratio(backend->state, backend->ratio);
        }
        return MA_SUCCESS;
    }

    static ma_uint64 get_src_latency_frames(int converterType)
    {
        switch (converterType)
        {
        case SRC_SINC_BEST_QUALITY:
            return 322;
        case SRC_SINC_MEDIUM_QUALITY:
            return 82;
        case SRC_SINC_FASTEST:
            return 18;
        default:
            return 0;
        }
    }

    static ma_uint64 src_onGetInputLatency(void *pUserData, const ma_resampling_backend *pBackend)
    {
        const LibSampleRateBackend *backend = (const LibSampleRateBackend *)pBackend;
        if (!backend)
            return 0;
        return get_src_latency_frames(backend->converterType);
    }

    static ma_uint64 src_onGetOutputLatency(void *pUserData, const ma_resampling_backend *pBackend)
    {
        const LibSampleRateBackend *backend = (const LibSampleRateBackend *)pBackend;
        if (!backend || backend->ratio <= 0.0f)
            return 0;
        ma_uint64 inLat = get_src_latency_frames(backend->converterType);
        return (ma_uint64)std::ceil((double)inLat * (double)backend->ratio);
    }

    static ma_result src_onGetRequiredInputFrameCount(void *pUserData, const ma_resampling_backend *pBackend, ma_uint64 outputFrameCount, ma_uint64 *pInputFrameCount)
    {
        const LibSampleRateBackend *backend = (const LibSampleRateBackend *)pBackend;
        if (!pInputFrameCount)
            return MA_INVALID_ARGS;
        if (!backend || backend->ratio <= 0.0f)
        {
            *pInputFrameCount = outputFrameCount;
        }
        else
        {
            *pInputFrameCount = (ma_uint64)std::ceil((double)outputFrameCount / (double)backend->ratio);
        }
        return MA_SUCCESS;
    }

    static ma_result src_onGetExpectedOutputFrameCount(void *pUserData, const ma_resampling_backend *pBackend, ma_uint64 inputFrameCount, ma_uint64 *pOutputFrameCount)
    {
        const LibSampleRateBackend *backend = (const LibSampleRateBackend *)pBackend;
        if (!pOutputFrameCount)
            return MA_INVALID_ARGS;
        if (!backend || backend->ratio <= 0.0f)
        {
            *pOutputFrameCount = inputFrameCount;
        }
        else
        {
            *pOutputFrameCount = (ma_uint64)std::floor((double)inputFrameCount * (double)backend->ratio);
        }
        return MA_SUCCESS;
    }

    static ma_result src_onReset(void *pUserData, ma_resampling_backend *pBackend)
    {
        LibSampleRateBackend *backend = (LibSampleRateBackend *)pBackend;
        if (backend && backend->state)
        {
            src_reset(backend->state);
        }
        return MA_SUCCESS;
    }

    static ma_resampling_backend_vtable g_customResamplerVTable = {
        src_onGetHeapSize,
        src_onInit,
        src_onUninit,
        src_onProcess,
        src_onSetRate,
        src_onGetInputLatency,
        src_onGetOutputLatency,
        src_onGetRequiredInputFrameCount,
        src_onGetExpectedOutputFrameCount,
        src_onReset
    };

    struct SoxrResamplerBackend
    {
        soxr_t handle;
        double ratio;
        int channels;
        int algorithm;
    };

    static ma_result soxr_onGetHeapSize(void *pUserData, const ma_resampler_config *pConfig, size_t *pHeapSizeInBytes)
    {
        if (!pHeapSizeInBytes)
            return MA_INVALID_ARGS;
        *pHeapSizeInBytes = sizeof(SoxrResamplerBackend);
        return MA_SUCCESS;
    }

    static ma_result soxr_onInit(void *pUserData, const ma_resampler_config *pConfig, void *pAllocation, ma_resampling_backend **ppBackend)
    {
        if (!pConfig || !pAllocation || !ppBackend)
            return MA_INVALID_ARGS;
        SoxrResamplerBackend *backend = (SoxrResamplerBackend *)pAllocation;
        backend->channels = pConfig->channels;

        int algo = pUserData ? *(int *)pUserData : 7;
        backend->algorithm = algo;

        unsigned long q_recipe = SOXR_HQ;
        unsigned long q_flags = 0;

        if (algo == 7) { // soxrVHQLinearPhase
            q_recipe = SOXR_VHQ;
            q_flags = SOXR_LINEAR_PHASE;
        } else if (algo == 8) { // soxrVHQMinimumPhase
            q_recipe = SOXR_VHQ;
            q_flags = SOXR_MINIMUM_PHASE;
        } else if (algo == 9) { // soxrHQ
            q_recipe = SOXR_HQ;
            q_flags = SOXR_LINEAR_PHASE;
        } else if (algo == 10) { // soxrFast
            q_recipe = SOXR_LQ;
            q_flags = SOXR_LINEAR_PHASE;
        }

        soxr_quality_spec_t q_spec = soxr_quality_spec(q_recipe, q_flags);
        soxr_io_spec_t io_spec = soxr_io_spec(SOXR_FLOAT32_I, SOXR_FLOAT32_I);
        double rateIn = (pConfig->sampleRateIn > 0) ? (double)pConfig->sampleRateIn : ((pConfig->sampleRateOut > 0) ? (double)pConfig->sampleRateOut : 48000.0);
        double rateOut = (pConfig->sampleRateOut > 0) ? (double)pConfig->sampleRateOut : 48000.0;
        int ch = (backend->channels > 0) ? backend->channels : 2;
        backend->channels = ch;
        backend->ratio = (rateIn > 0) ? (rateOut / rateIn) : 1.0;

        soxr_error_t err = nullptr;
        backend->handle = soxr_create(rateIn, rateOut, (unsigned)backend->channels, &err, &io_spec, &q_spec, NULL);
        if (!backend->handle || err)
        {
            engine_log("soxr_onInit: soxr_create failed (err=%s) for algo=%d channels=%d rateIn=%.0f rateOut=%.0f",
                       soxr_strerror(err), algo, backend->channels, rateIn, rateOut);
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
        if (!backend || !backend->handle || !pFrameCountIn || !pFrameCountOut)
            return MA_ERROR;

        if (std::fabs(backend->ratio - 1.0) < 1.0e-5 && pFramesIn != nullptr && pFramesOut != nullptr)
        {
            ma_uint64 toCopy = std::min(*pFrameCountIn, *pFrameCountOut);
            std::memcpy(pFramesOut, pFramesIn, (size_t)toCopy * (size_t)backend->channels * sizeof(float));
            *pFrameCountIn = toCopy;
            *pFrameCountOut = toCopy;
            return MA_SUCCESS;
        }

        ma_uint64 inAvail = *pFrameCountIn;
        ma_uint64 outReq = *pFrameCountOut;

        size_t idone = 0, odone = 0;
        soxr_error_t err = soxr_process(backend->handle, pFramesIn, (size_t)*pFrameCountIn, &idone, pFramesOut, (size_t)*pFrameCountOut, &odone);
        if (err) {
            engine_log("soxr_onProcess error: %s", soxr_strerror(err));
            return MA_ERROR;
        }

        *pFrameCountIn = (ma_uint64)idone;
        *pFrameCountOut = (ma_uint64)odone;

        // No logging here: realtime thread (see src_onProcess).

        return MA_SUCCESS;
    }

    static ma_result soxr_onSetRate(void *pUserData, ma_resampling_backend *pBackend, ma_uint32 sampleRateIn, ma_uint32 sampleRateOut)
    {
        SoxrResamplerBackend *backend = (SoxrResamplerBackend *)pBackend;
        if (!backend)
            return MA_ERROR;
        backend->ratio = (sampleRateIn > 0) ? ((double)sampleRateOut / (double)sampleRateIn) : 1.0;
        engine_log("soxr_onSetRate: sampleRateIn=%u sampleRateOut=%u -> new ratio=%.4f", sampleRateIn, sampleRateOut, backend->ratio);
        if (backend->handle)
        {
            soxr_error_t err = soxr_set_io_ratio(backend->handle, 1.0 / backend->ratio, 0);
            if (err) return MA_ERROR;
        }
        return MA_SUCCESS;
    }

    static ma_uint64 soxr_onGetInputLatency(void *pUserData, const ma_resampling_backend *pBackend)
    {
        const SoxrResamplerBackend *backend = (const SoxrResamplerBackend *)pBackend;
        if (!backend || !backend->handle)
            return 0;
        double delay = soxr_delay(backend->handle);
        return (ma_uint64)std::ceil(delay);
    }

    static ma_uint64 soxr_onGetOutputLatency(void *pUserData, const ma_resampling_backend *pBackend)
    {
        const SoxrResamplerBackend *backend = (const SoxrResamplerBackend *)pBackend;
        if (!backend || !backend->handle || backend->ratio <= 0.0)
            return 0;
        double delay = soxr_delay(backend->handle);
        return (ma_uint64)std::ceil(delay * backend->ratio);
    }

    static ma_result soxr_onGetRequiredInputFrameCount(void *pUserData, const ma_resampling_backend *pBackend, ma_uint64 outputFrameCount, ma_uint64 *pInputFrameCount)
    {
        const SoxrResamplerBackend *backend = (const SoxrResamplerBackend *)pBackend;
        if (!pInputFrameCount)
            return MA_INVALID_ARGS;
        if (!backend || backend->ratio <= 0.0)
        {
            *pInputFrameCount = outputFrameCount;
        }
        else
        {
            *pInputFrameCount = (ma_uint64)std::ceil((double)outputFrameCount / backend->ratio);
        }
        return MA_SUCCESS;
    }

    static ma_result soxr_onGetExpectedOutputFrameCount(void *pUserData, const ma_resampling_backend *pBackend, ma_uint64 inputFrameCount, ma_uint64 *pOutputFrameCount)
    {
        const SoxrResamplerBackend *backend = (const SoxrResamplerBackend *)pBackend;
        if (!pOutputFrameCount)
            return MA_INVALID_ARGS;
        if (!backend || backend->ratio <= 0.0)
        {
            *pOutputFrameCount = inputFrameCount;
        }
        else
        {
            *pOutputFrameCount = (ma_uint64)std::floor((double)inputFrameCount * backend->ratio);
        }
        return MA_SUCCESS;
    }

    static ma_result soxr_onReset(void *pUserData, ma_resampling_backend *pBackend)
    {
        SoxrResamplerBackend *backend = (SoxrResamplerBackend *)pBackend;
        if (backend && backend->handle)
        {
            soxr_clear(backend->handle);
        }
        return MA_SUCCESS;
    }

    static ma_resampling_backend_vtable g_soxrResamplerVTable = {
        soxr_onGetHeapSize,
        soxr_onInit,
        soxr_onUninit,
        soxr_onProcess,
        soxr_onSetRate,
        soxr_onGetInputLatency,
        soxr_onGetOutputLatency,
        soxr_onGetRequiredInputFrameCount,
        soxr_onGetExpectedOutputFrameCount,
        soxr_onReset
    };

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
        if (!pHeapSizeInBytes)
            return MA_INVALID_ARGS;
        *pHeapSizeInBytes = sizeof(R8brainBackend);
        return MA_SUCCESS;
    }

    static ma_result r8b_onInit(void *pUserData, const ma_resampler_config *pConfig, void *pAllocation, ma_resampling_backend **ppBackend)
    {
        if (!pConfig || !pAllocation || !ppBackend)
            return MA_INVALID_ARGS;

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
        if (!backend || !pFrameCountIn || !pFrameCountOut)
            return MA_ERROR;

        const int ch = backend->channels;
        if (ch <= 0)
            return MA_ERROR;

        // 1:1 Fast-path identity copy
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

        // Step 1: Drain any previously buffered frames from outputFifo
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

        // Step 2: Feed input chunk to r8brain
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
        if (!backend || sampleRateIn == 0 || sampleRateOut == 0)
            return MA_ERROR;

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

    static ma_uint64 r8b_onGetInputLatency(void *pUserData, const ma_resampling_backend *pBackend)
    {
        const R8brainBackend *backend = (const R8brainBackend *)pBackend;
        if (!backend || backend->resamplers.empty() || !backend->resamplers[0])
            return 0;
        int lat = backend->resamplers[0]->getInLenBeforeOutPos(0);
        return (ma_uint64)(lat >= 0 ? lat : 0);
    }

    static ma_uint64 r8b_onGetOutputLatency(void *pUserData, const ma_resampling_backend *pBackend)
    {
        const R8brainBackend *backend = (const R8brainBackend *)pBackend;
        if (!backend || backend->resamplers.empty() || !backend->resamplers[0] || backend->ratio <= 0.0)
            return 0;
        int lat = backend->resamplers[0]->getLatency();
        return (ma_uint64)(lat >= 0 ? lat : 0);
    }

    static ma_result r8b_onGetRequiredInputFrameCount(void *pUserData, const ma_resampling_backend *pBackend, ma_uint64 outputFrameCount, ma_uint64 *pInputFrameCount)
    {
        const R8brainBackend *backend = (const R8brainBackend *)pBackend;
        if (!pInputFrameCount)
            return MA_INVALID_ARGS;
        if (!backend || backend->ratio <= 0.0)
        {
            *pInputFrameCount = outputFrameCount;
        }
        else
        {
            *pInputFrameCount = (ma_uint64)std::ceil((double)outputFrameCount / backend->ratio);
        }
        return MA_SUCCESS;
    }

    static ma_result r8b_onGetExpectedOutputFrameCount(void *pUserData, const ma_resampling_backend *pBackend, ma_uint64 inputFrameCount, ma_uint64 *pOutputFrameCount)
    {
        const R8brainBackend *backend = (const R8brainBackend *)pBackend;
        if (!pOutputFrameCount)
            return MA_INVALID_ARGS;
        if (!backend || backend->ratio <= 0.0)
        {
            *pOutputFrameCount = inputFrameCount;
        }
        else
        {
            *pOutputFrameCount = (ma_uint64)std::floor((double)inputFrameCount * backend->ratio);
        }
        return MA_SUCCESS;
    }

    static ma_result r8b_onReset(void *pUserData, ma_resampling_backend *pBackend)
    {
        R8brainBackend *backend = (R8brainBackend *)pBackend;
        if (backend)
        {
            for (auto *r : backend->resamplers)
            {
                if (r) r->clear();
            }
            backend->outputFifo.clear();
            backend->fifoReadPos = 0;
        }
        return MA_SUCCESS;
    }

    static ma_resampling_backend_vtable g_r8brainResamplerVTable = {
        r8b_onGetHeapSize,
        r8b_onInit,
        r8b_onUninit,
        r8b_onProcess,
        r8b_onSetRate,
        r8b_onGetInputLatency,
        r8b_onGetOutputLatency,
        r8b_onGetRequiredInputFrameCount,
        r8b_onGetExpectedOutputFrameCount,
        r8b_onReset
    };

    static inline ma_resampling_backend_vtable *get_resampler_vtable_for_algorithm(int algo)
    {
        if (algo >= 7 && algo <= 10)
            return &g_soxrResamplerVTable;
        if (algo == 11 || algo == 12)
            return &g_r8brainResamplerVTable;
        return &g_customResamplerVTable;
    };

    struct LimiterState
    {
        float threshold = 0.95f; // Level above which gain reduction starts (linear)
        float attackMs = 2.0f;   // Attack time in ms
        float releaseMs = 50.0f; // Release time in ms

        float attackCoeff = 0.0f;
        float releaseCoeff = 0.0f;
        float gainEnvelope = 1.0f;

        // This limiter is a zero-latency gain smoother (no delay line).
        // Reporting attackMs here was fictional and shifted position reporting.
        double getLatencySamples(int) const
        {
            return 0.0;
        }

        void updateCoefficients(int sampleRate)
        {
            // Simple 1-pole exponential moving average coefficients
            attackCoeff = std::exp(-1.0f / (attackMs * 0.001f * (float)sampleRate));
            releaseCoeff = std::exp(-1.0f / (releaseMs * 0.001f * (float)sampleRate));
        }

        void updateParams(int sampleRate, float newThreshold, float newAttackMs, float newReleaseMs)
        {
            threshold = clampf(newThreshold, 0.1f, 1.0f);
            attackMs = clampf(newAttackMs, 0.1f, 100.0f);
            releaseMs = clampf(newReleaseMs, 10.0f, 1000.0f);
            updateCoefficients(sampleRate);
        }

        void process(float *interleaved, ma_uint32 frames, int channels)
        {
            if (channels < 1)
                return;

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                // Find peak absolute value across all channels for this frame (linked channels)
                float peak = 0.0f;
                size_t base = (size_t)i * (size_t)channels;
                for (int c = 0; c < channels; ++c)
                {
                    float absVal = std::abs(interleaved[base + (size_t)c]);
                    if (absVal > peak)
                        peak = absVal;
                }

                // Calculate desired gain
                float targetGain = 1.0f;
                if (peak > threshold)
                {
                    targetGain = threshold / peak;
                }

                // Smooth the gain matching attack/release (Averaging the bulk volume)
                if (targetGain < gainEnvelope)
                {
                    // Attack phase (gain is reducing)
                    gainEnvelope = attackCoeff * gainEnvelope + (1.0f - attackCoeff) * targetGain;
                }
                else
                {
                    // Release phase (gain is recovering)
                    gainEnvelope = releaseCoeff * gainEnvelope + (1.0f - releaseCoeff) * targetGain;
                }

                // Apply gain reduction and Analog Soft-Knee Saturation to catch the 2ms transient escapes
                for (int c = 0; c < channels; ++c)
                {
                    float sample = interleaved[base + (size_t)c] * gainEnvelope;

                    // The Soft-Knee Saturator guarantees that no transient escaping the 2ms attack can ever cross 1.0 (Digital 0dBFS)
                    // We use poly saturation for absolute mathematical safety without harsh digital crackling
                    if (sample > 1.0f)
                        sample = 1.0f;
                    else if (sample < -1.0f)
                        sample = -1.0f;
                    else if (sample > threshold)
                    {
                        float overshoot = sample - threshold;
                        sample = threshold + (overshoot / (1.0f + (overshoot / (1.0f - threshold))));
                    }
                    else if (sample < -threshold)
                    {
                        float overshoot = -sample - threshold;
                        sample = -(threshold + (overshoot / (1.0f + (overshoot / (1.0f - threshold)))));
                    }

                    interleaved[base + (size_t)c] = sample;
                }
            }
        }
    };

    // Dynamic Range Compressor (zero-latency feed-forward design).
    // dB-domain soft-knee transfer function, peak or RMS detector, linked or
    // dual-mono gain computation, static or auto make-up gain, dry/wet mix.
    struct CompressorState
    {
        static constexpr int MAX_CHANNELS = 16;

        float thresholdDb = -20.0f; // [-60, 0] level where compression starts
        float ratio = 4.0f;         // [1, 20]
        float kneeDb = 6.0f;        // [0, 24] soft knee width
        float attackMs = 10.0f;     // [0.1, 100]
        float releaseMs = 100.0f;   // [10, 1000]
        float makeupGainDb = 0.0f;  // [0, 24]
        bool autoMakeup = false;    // derive makeup from threshold/ratio
        int detector = 0;           // 0 = peak, 1 = RMS
        bool stereoLink = true;     // linked / dual-mono gain computation
        float mix = 1.0f;           // [0, 1] dry/wet

        float attackCoeff = 0.0f;
        float releaseCoeff = 0.0f;
        float makeupGainLinear = 1.0f;
        std::vector<float> rmsEnv;  // per-channel squared envelope (RMS detector)
        std::vector<float> gainEnv; // per-channel smoothed gain
        std::atomic<float> currentGainReductionDB{0.0f};

        void updateCoefficients(int sampleRate)
        {
            if (sampleRate <= 0)
                return;
            attackCoeff = std::exp(-1.0f / (attackMs * 0.001f * (float)sampleRate));
            releaseCoeff = std::exp(-1.0f / (releaseMs * 0.001f * (float)sampleRate));
        }

        void updateParams(int sampleRate, int channels, float newThresholdDb, float newRatio,
                          float newKneeDb, float newAttackMs, float newReleaseMs,
                          float newMakeupGainDb, int newDetector, int newStereoLink,
                          int newAutoMakeup, float newMix)
        {
            thresholdDb = clampf(newThresholdDb, -60.0f, 0.0f);
            ratio = clampf(newRatio, 1.0f, 20.0f);
            kneeDb = clampf(newKneeDb, 0.0f, 24.0f);
            attackMs = clampf(newAttackMs, 0.1f, 100.0f);
            releaseMs = clampf(newReleaseMs, 10.0f, 1000.0f);
            makeupGainDb = clampf(newMakeupGainDb, 0.0f, 24.0f);
            detector = (newDetector == 1) ? 1 : 0;
            stereoLink = (newStereoLink != 0);
            autoMakeup = (newAutoMakeup != 0);
            mix = clampf(newMix, 0.0f, 1.0f);

            // Auto makeup: rough fixed estimate of the average reduction
            // (half of the max possible reduction at the threshold). Stable
            // and click-free; fine trimming stays manual.
            const float effMakeupDb = autoMakeup
                ? (-thresholdDb * (1.0f - 1.0f / ratio) * 0.5f)
                : makeupGainDb;
            makeupGainLinear = std::pow(10.0f, effMakeupDb / 20.0f);

            const int ch = std::max(1, channels);
            if (rmsEnv.size() != (size_t)ch) rmsEnv.assign((size_t)ch, 0.0f);
            if (gainEnv.size() != (size_t)ch) gainEnv.assign((size_t)ch, 1.0f);
            updateCoefficients(sampleRate);
        }

        // dB-domain soft-knee transfer: output dB for input dB.
        inline float transferDb(float inDb) const
        {
            const float halfKnee = kneeDb * 0.5f;
            if (inDb <= thresholdDb - halfKnee)
                return inDb;
            if (inDb >= thresholdDb + halfKnee)
                return thresholdDb + (inDb - thresholdDb) / ratio;
            // Quadratic interpolation inside the knee
            const float slope = 1.0f / ratio - 1.0f;
            const float x = inDb - (thresholdDb - halfKnee);
            return inDb + slope * (x * x) / (2.0f * kneeDb);
        }

        void process(float *interleaved, ma_uint32 frames, int channels, int sampleRate)
        {
            if (channels < 1)
                return;
            if (rmsEnv.size() != (size_t)channels || gainEnv.size() != (size_t)channels)
            {
                rmsEnv.assign((size_t)channels, 0.0f);
                gainEnv.assign((size_t)channels, 1.0f);
            }
            updateCoefficients(sampleRate);

            const bool isRms = (detector == 1);
            const int ch = std::min(channels, MAX_CHANNELS);
            const float kneeLo = thresholdDb - kneeDb * 0.5f;
            float maxGrThisBlock = 1.0f;

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                const size_t base = (size_t)i * (size_t)channels;

                // Detector: per-channel level in dB
                float levelDb[MAX_CHANNELS];
                for (int c = 0; c < ch; ++c)
                {
                    const float x = interleaved[base + (size_t)c];
                    float lvl;
                    if (isRms)
                    {
                        const float sq = x * x;
                        rmsEnv[c] = (sq > rmsEnv[c])
                            ? attackCoeff * rmsEnv[c] + (1.0f - attackCoeff) * sq
                            : releaseCoeff * rmsEnv[c] + (1.0f - releaseCoeff) * sq;
                        lvl = std::sqrt(rmsEnv[c]) + 1e-9f;
                    }
                    else
                    {
                        lvl = std::abs(x) + 1e-9f;
                    }
                    levelDb[c] = 20.0f * std::log10(lvl);
                }

                // Transfer function -> desired gain per channel
                float targetGain[MAX_CHANNELS];
                if (stereoLink)
                {
                    float maxDb = -120.0f;
                    for (int c = 0; c < ch; ++c)
                        if (levelDb[c] > maxDb) maxDb = levelDb[c];
                    const float g = (maxDb <= kneeLo)
                        ? 1.0f
                        : std::pow(10.0f, (transferDb(maxDb) - maxDb) / 20.0f);
                    for (int c = 0; c < ch; ++c) targetGain[c] = g;
                }
                else
                {
                    for (int c = 0; c < ch; ++c)
                    {
                        targetGain[c] = (levelDb[c] <= kneeLo)
                            ? 1.0f
                            : std::pow(10.0f, (transferDb(levelDb[c]) - levelDb[c]) / 20.0f);
                    }
                }
                for (int c = ch; c < channels; ++c) targetGain[c] = 1.0f;

                // Smooth the gain matching attack/release, then apply
                for (int c = 0; c < channels; ++c)
                {
                    const size_t idx = (size_t)c;
                    float g = gainEnv[idx];
                    const float t = targetGain[c];
                    g = (t < g) ? attackCoeff * g + (1.0f - attackCoeff) * t
                                : releaseCoeff * g + (1.0f - releaseCoeff) * t;
                    gainEnv[idx] = g;

                    if (g < maxGrThisBlock) maxGrThisBlock = g;

                    const float x = interleaved[base + (size_t)c];
                    const float wet = x * g * makeupGainLinear;
                    interleaved[base + (size_t)c] = mix * wet + (1.0f - mix) * x;
                }
            }

            const float grDB = (maxGrThisBlock < 1.0f)
                ? 20.0f * std::log10(maxGrThisBlock) : 0.0f;
            currentGainReductionDB.store(grDB, std::memory_order_relaxed);
        }

        void reset()
        {
            std::fill(rmsEnv.begin(), rmsEnv.end(), 0.0f);
            std::fill(gainEnv.begin(), gainEnv.end(), 1.0f);
        }
    };

    struct TruePeakMeterState
    {
        static constexpr int TAPS = 12;
        static constexpr int PHASES = 4;

        float polyphaseCoeffs[4][12] = {
            { 0.0f,    0.0f,    0.0f,    0.0f,    0.0f,   1.0f,   0.0f,    0.0f,    0.0f,    0.0f,    0.0f,    0.0f},
            {-0.008f,  0.024f, -0.056f,  0.120f, -0.240f, 0.880f, 0.360f, -0.120f,  0.056f, -0.024f,  0.008f,  0.000f},
            {-0.012f,  0.040f, -0.096f,  0.200f, -0.400f, 0.760f, 0.600f, -0.200f,  0.096f, -0.040f,  0.012f,  0.000f},
            { 0.000f,  0.008f, -0.024f,  0.056f, -0.120f, 0.360f, 0.880f, -0.240f,  0.120f, -0.056f,  0.024f, -0.008f}
        };

        float history[8][12] = {0};
        int histIdx = 0;

        std::atomic<float> peakLeftDBTP{-100.0f};
        std::atomic<float> peakRightDBTP{-100.0f};
        std::atomic<float> maxTruePeakDBTP{-100.0f};
        // True sample peak (no interpolation) - reported honestly instead of the
        // old "truepeak - 0.5 dB" fabrication.
        std::atomic<float> samplePeakDBTP{-100.0f};

        void process(const float *interleaved, ma_uint32 frames, int channels)
        {
            if (channels < 1) return;
            const int ch = std::min(channels, 8);

            float maxL = 0.0f, maxR = 0.0f;
            float maxSample = 0.0f;
            float maxExtra = 0.0f;

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                for (int c = 0; c < ch; ++c)
                {
                    float x = interleaved[i * (size_t)channels + c];
                    const float absX = std::abs(x);
                    if (absX > maxSample) maxSample = absX;
                    history[c][histIdx] = x;

                    for (int p = 0; p < PHASES; ++p)
                    {
                        float y = 0.0f;
                        for (int t = 0; t < TAPS; ++t)
                        {
                            int tapIdx = (histIdx - t + TAPS) % TAPS;
                            y += history[c][tapIdx] * polyphaseCoeffs[p][t];
                        }
                        float absY = std::abs(y);
                        // Keep L/R metrics honest per channel; multichannel peaks
                        // (c > 1) feed the aggregate instead of polluting "left".
                        if (c == 0 && absY > maxL) maxL = absY;
                        else if (c == 1 && absY > maxR) maxR = absY;
                        else if (c > 1 && absY > maxExtra) maxExtra = absY;
                    }
                }
                histIdx = (histIdx + 1) % TAPS;
            }

            float leftDBTP  = (maxL > 1e-5f) ? 20.0f * std::log10(maxL) : -100.0f;
            float rightDBTP = (maxR > 1e-5f) ? 20.0f * std::log10(maxR) : -100.0f;
            const float extraDBTP = (maxExtra > 1e-5f) ? 20.0f * std::log10(maxExtra) : -100.0f;

            float prevL = peakLeftDBTP.load(std::memory_order_relaxed);
            float prevR = peakRightDBTP.load(std::memory_order_relaxed);
            peakLeftDBTP.store(std::max(leftDBTP, prevL - 0.2f), std::memory_order_relaxed);
            peakRightDBTP.store(std::max(rightDBTP, prevR - 0.2f), std::memory_order_relaxed);
            maxTruePeakDBTP.store(std::max({peakLeftDBTP.load(std::memory_order_relaxed),
                                            peakRightDBTP.load(std::memory_order_relaxed),
                                            extraDBTP}), std::memory_order_relaxed);

            const float samplePeakDB = (maxSample > 1e-5f) ? 20.0f * std::log10(maxSample) : -100.0f;
            samplePeakDBTP.store(std::max(samplePeakDB, samplePeakDBTP.load(std::memory_order_relaxed) - 0.2f), std::memory_order_relaxed);
        }
    };

    struct LookAheadLimiterState
    {
        float ceilingDBTP = -1.0f;
        float attackMs = 2.0f;
        float releaseMs = 50.0f;

        std::vector<float> delayBuffer;
        size_t writeIdx = 0;
        size_t lookAheadSamples = 0;
        float gainEnvelope = 1.0f;
        std::atomic<float> currentGainReductionDB{0.0f};

        uint64_t getLatencySamples(int sampleRate) const
        {
            return (sampleRate > 0) ? (uint64_t)((double)attackMs * 0.001 * (double)sampleRate) : 0;
        }

        void updateParams(int sampleRate, int channels, float ceiling, float attack, float release)
        {
            ceilingDBTP = clampf(ceiling, -12.0f, 0.0f);
            attackMs = clampf(attack, 0.5f, 10.0f);
            releaseMs = clampf(release, 10.0f, 1000.0f);

            int ch = std::max(1, channels);
            lookAheadSamples = (size_t)((attackMs * 0.001f) * (float)sampleRate);
            if (lookAheadSamples < 1) lookAheadSamples = 1;

            size_t neededBufSize = lookAheadSamples * (size_t)ch;
            if (delayBuffer.size() != neededBufSize)
            {
                delayBuffer.assign(neededBufSize, 0.0f);
                writeIdx = 0;
            }
            gainEnvelope = 1.0f;
        }

        void process(float *interleaved, ma_uint32 frames, int channels, int sampleRate)
        {
            if (channels < 1 || delayBuffer.empty()) return;
            const float linearCeiling = std::pow(10.0f, ceilingDBTP / 20.0f);

            const float releaseCoeff = std::exp(-1.0f / (releaseMs * 0.001f * (float)sampleRate));

            float maxGRThisBlock = 1.0f;

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                float peak = 0.0f;
                size_t base = (size_t)i * (size_t)channels;
                for (int c = 0; c < channels; ++c)
                {
                    float absVal = std::abs(interleaved[base + (size_t)c]);
                    if (absVal > peak) peak = absVal;
                }

                float targetGain = (peak > linearCeiling) ? (linearCeiling / peak) : 1.0f;

                if (targetGain < gainEnvelope)
                {
                    // Instant attack: a transient must be attenuated on the very
                    // first sample it appears, otherwise the first ~1-2 ms shoot
                    // past the ceiling and the final hard clamp does the work
                    // (pumping / distortion).
                    gainEnvelope = targetGain;
                }
                else
                {
                    gainEnvelope = releaseCoeff * gainEnvelope + (1.0f - releaseCoeff) * targetGain;
                }

                if (gainEnvelope < maxGRThisBlock) maxGRThisBlock = gainEnvelope;

                size_t readIdx = (writeIdx + delayBuffer.size() - lookAheadSamples * (size_t)channels) % delayBuffer.size();

                for (int c = 0; c < channels; ++c)
                {
                    float delayedSample = delayBuffer[readIdx + (size_t)c];
                    delayBuffer[writeIdx + (size_t)c] = interleaved[base + (size_t)c];
                    interleaved[base + (size_t)c] = delayedSample * gainEnvelope;
                }

                writeIdx = (writeIdx + (size_t)channels) % delayBuffer.size();
            }

            float grDB = (maxGRThisBlock < 1.0f) ? 20.0f * std::log10(maxGRThisBlock) : 0.0f;
            currentGainReductionDB.store(grDB, std::memory_order_relaxed);
        }
    };

    struct BS1770LoudnessMeter
    {
        struct KWeightState
        {
            double hs_b0=1.53512485958697, hs_b1=-2.69169618940638, hs_b2=1.19839281085285;
            double hs_a1=-1.69065929318241, hs_a2=0.73248077421585;
            double hs_z1=0.0, hs_z2=0.0;

            double hp_b0=1.0, hp_b1=-2.0, hp_b2=1.0;
            double hp_a1=-1.99004745483398, hp_a2=0.99007225036621;
            double hp_z1=0.0, hp_z2=0.0;

            void updateCoefficients(double fs)
            {
                double db = 3.999843853973347;
                double f0 = 1681.974450955533;
                double Q  = 0.7071752369554193;
                double K  = std::tan(M_PI * f0 / fs);
                double Vh = std::pow(10.0, db / 20.0);
                double V0 = Vh - 1.0;
                double den = 1.0 + K / Q + K * K;
                hs_b0 = (1.0 + K * V0 + K * K * Vh) / den;
                hs_b1 = 2.0 * (K * K * Vh - 1.0) / den;
                hs_b2 = (1.0 - K * V0 + K * K * Vh) / den;
                hs_a1 = 2.0 * (K * K - 1.0) / den;
                hs_a2 = (1.0 - K / Q + K * K) / den;

                double f0_hp = 38.13547087602444;
                double Q_hp  = 0.5003270373253927;
                double K_hp  = std::tan(M_PI * f0_hp / fs);
                double den_hp = 1.0 + K_hp / Q_hp + K_hp * K_hp;
                hp_b0 = 1.0 / den_hp;
                hp_b1 = -2.0 / den_hp;
                hp_b2 = 1.0 / den_hp;
                hp_a1 = 2.0 * (K_hp * K_hp - 1.0) / den_hp;
                hp_a2 = (1.0 - K_hp / Q_hp + K_hp * K_hp) / den_hp;
            }

            inline double process(double in)
            {
                double hs_out = hs_b0 * in + hs_z1;
                hs_z1 = hs_b1 * in - hs_a1 * hs_out + hs_z2;
                hs_z2 = hs_b2 * in - hs_a2 * hs_out;

                double hp_out = hp_b0 * hs_out + hp_z1;
                hp_z1 = hp_b1 * hs_out - hp_a1 * hp_out + hp_z2;
                hp_z2 = hp_b2 * hs_out - hp_a2 * hp_out;

                return hp_out;
            }
        };

        KWeightState kFilters[8];
        int currentSampleRate = 48000;

        double blockSumSq[8] = {0};
        uint32_t blockSampleCount = 0;
        uint32_t blockTargetSamples = 4800;

        static constexpr size_t RING_SIZE = 300;
        struct BlockPower {
            double power = 0.0;
            bool valid = false;
        };
        BlockPower blockRing[RING_SIZE];
        size_t ringHead = 0;
        size_t totalBlocksCount = 0;

        // Bounded history for integrated loudness / LRA gating.
        // std::deque gives O(1) front eviction (the old vector erase-from-front
        // was an O(N) memmove of up to ~108k doubles on the audio thread).
        static constexpr size_t MAX_ACCUMULATED_BLOCKS = 18000; // 30 min @ 100 ms blocks
        std::deque<double> accumulatedBlocks;
        double absGateSum = 0.0;   // running sum of blocks passing the absolute gate
        size_t absGateCount = 0;   // running count of blocks passing the absolute gate
        uint32_t blocksSinceAnalysis = 0;

        std::atomic<float> momentaryLUFS{-100.0f};
        std::atomic<float> shortTermLUFS{-100.0f};
        std::atomic<float> integratedLUFS{-100.0f};
        std::atomic<float> loudnessRangeLRA{0.0f};

        std::atomic<bool> normalizerEnabled{false};
        std::atomic<float> normalizerTargetLUFS{-14.0f};

        void reset(int sampleRate)
        {
            currentSampleRate = (sampleRate > 0) ? sampleRate : 48000;
            blockTargetSamples = (uint32_t)(0.1 * (double)currentSampleRate);
            for (int c = 0; c < 8; ++c)
            {
                kFilters[c].updateCoefficients((double)currentSampleRate);
                blockSumSq[c] = 0.0;
            }
            blockSampleCount = 0;
            ringHead = 0;
            totalBlocksCount = 0;
            for (size_t i = 0; i < RING_SIZE; ++i) blockRing[i] = {0.0, false};
            accumulatedBlocks.clear();
            absGateSum = 0.0;
            absGateCount = 0;
            blocksSinceAnalysis = 0;

            momentaryLUFS.store(-100.0f, std::memory_order_relaxed);
            shortTermLUFS.store(-100.0f, std::memory_order_relaxed);
            integratedLUFS.store(-100.0f, std::memory_order_relaxed);
            loudnessRangeLRA.store(0.0f, std::memory_order_relaxed);
        }

        void process(const float *interleaved, ma_uint32 frames, int channels)
        {
            if (channels < 1) return;
            const int ch = std::min(channels, 8);
            static const double channelWeights[8] = {1.0, 1.0, 1.0, 0.0, 1.41, 1.41, 1.0, 1.0};

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                for (int c = 0; c < ch; ++c)
                {
                    double inSample = (double)interleaved[i * (size_t)channels + c];
                    double kFiltered = kFilters[c].process(inSample);
                    blockSumSq[c] += kFiltered * kFiltered;
                }
                blockSampleCount++;

                if (blockSampleCount >= blockTargetSamples)
                {
                    double blockPower = 0.0;
                    for (int c = 0; c < ch; ++c)
                    {
                        double meanSq = blockSumSq[c] / (double)blockSampleCount;
                        blockPower += channelWeights[c] * meanSq;
                        blockSumSq[c] = 0.0;
                    }
                    blockSampleCount = 0;

                    blockRing[ringHead] = {blockPower, true};
                    ringHead = (ringHead + 1) % RING_SIZE;
                    totalBlocksCount++;

                    double momSum = 0.0;
                    int momCount = 0;
                    for (int b = 0; b < 4; ++b)
                    {
                        size_t idx = (ringHead + RING_SIZE - 1 - (size_t)b) % RING_SIZE;
                        if (blockRing[idx].valid) { momSum += blockRing[idx].power; momCount++; }
                    }
                    if (momCount > 0)
                    {
                        double meanPwr = momSum / (double)momCount;
                        float mLufs = (meanPwr > 1e-10) ? (float)(-0.691 + 10.0 * std::log10(meanPwr)) : -100.0f;
                        momentaryLUFS.store(mLufs, std::memory_order_relaxed);
                    }

                    double stSum = 0.0;
                    int stCount = 0;
                    for (int b = 0; b < 30; ++b)
                    {
                        size_t idx = (ringHead + RING_SIZE - 1 - (size_t)b) % RING_SIZE;
                        if (blockRing[idx].valid) { stSum += blockRing[idx].power; stCount++; }
                    }
                    if (stCount > 0)
                    {
                        double meanPwr = stSum / (double)stCount;
                        float stLufs = (meanPwr > 1e-10) ? (float)(-0.691 + 10.0 * std::log10(meanPwr)) : -100.0f;
                        shortTermLUFS.store(stLufs, std::memory_order_relaxed);
                    }

                    // Accumulate gated-block history with O(1) bookkeeping.
                    if (blockPower > 1e-10)
                    {
                        constexpr double absThresholdPwr = 1.17762e-7; // -70 LUFS
                        accumulatedBlocks.push_back(blockPower);
                        if (blockPower >= absThresholdPwr)
                        {
                            absGateSum += blockPower;
                            ++absGateCount;
                        }
                        if (accumulatedBlocks.size() > MAX_ACCUMULATED_BLOCKS)
                        {
                            const double oldest = accumulatedBlocks.front();
                            accumulatedBlocks.pop_front(); // O(1) vs O(N) vector erase
                            if (oldest >= absThresholdPwr && absGateCount > 0)
                            {
                                absGateSum -= oldest;
                                --absGateCount;
                            }
                        }
                    }

                    // Integrated loudness / LRA are perceptually slow metrics.
                    // Recomputing them on EVERY 100 ms block rescanned the whole
                    // history twice and sorted up to ~108k doubles inside the audio
                    // callback (multi-ms spikes). Throttle to once per second.
                    ++blocksSinceAnalysis;
                    const bool runGatedAnalysis =
                        blocksSinceAnalysis >= 10 && !accumulatedBlocks.empty();

                    if (runGatedAnalysis)
                    {
                        blocksSinceAnalysis = 0;
                        {
                        constexpr double absThresholdPwr = 1.17762e-7;
                        double ungatedMeanPwr = 0.0;
                        bool pass2Skip = false;
                        if (absGateCount > 0)
                        {
                            ungatedMeanPwr = absGateSum / (double)absGateCount;
                        }
                        else
                        {
                            double pass1Sum = 0.0;
                            size_t pass1Count = 0;
                            for (double pwr : accumulatedBlocks)
                            {
                                if (pwr >= absThresholdPwr) { pass1Sum += pwr; pass1Count++; }
                            }
                            if (pass1Count == 0)
                            {
                                ungatedMeanPwr = 0.0;
                                pass2Skip = true;
                            }
                            else
                            {
                                ungatedMeanPwr = pass1Sum / (double)pass1Count;
                            }
                        }

                        const double relThresholdLUFS = -0.691 + 10.0 * std::log10(ungatedMeanPwr > 1e-12 ? ungatedMeanPwr : 1e-12) - 10.0;
                        const double relThresholdPwr = std::pow(10.0, (relThresholdLUFS + 0.691) / 10.0);

                        double pass2Sum = 0.0;
                        size_t pass2Count = 0;
                        std::vector<double> pass2Powers;
                        if (!pass2Skip)
                        {
                            for (double pwr : accumulatedBlocks)
                            {
                                if (pwr >= relThresholdPwr)
                                {
                                    pass2Sum += pwr;
                                    pass2Count++;
                                    pass2Powers.push_back(pwr);
                                }
                            }
                        }

                        if (pass2Count > 0)
                        {
                            double finalMeanPwr = pass2Sum / (double)pass2Count;
                            float intLufs = (float)(-0.691 + 10.0 * std::log10(finalMeanPwr));
                            integratedLUFS.store(intLufs, std::memory_order_relaxed);

                            // Compute Loudness Range (LRA) between 10th percentile and 95th percentile
                            if (pass2Powers.size() >= 20)
                            {
                                std::sort(pass2Powers.begin(), pass2Powers.end());
                                size_t idx10 = (size_t)(0.10 * (double)pass2Powers.size());
                                size_t idx95 = (size_t)(0.95 * (double)pass2Powers.size());
                                if (idx95 >= pass2Powers.size()) idx95 = pass2Powers.size() - 1;

                                double lufs10 = -0.691 + 10.0 * std::log10(pass2Powers[idx10]);
                                double lufs95 = -0.691 + 10.0 * std::log10(pass2Powers[idx95]);
                                float lra = (float)(lufs95 - lufs10);
                                if (lra < 0.0f) lra = 0.0f;
                                loudnessRangeLRA.store(lra, std::memory_order_relaxed);
                            }
                        }
                        }
                    }
                }
            }
        }

        float getNormalizerGainLinear()
        {
            if (!normalizerEnabled.load(std::memory_order_relaxed)) return 1.0f;
            float currentIntegrated = integratedLUFS.load(std::memory_order_relaxed);
            if (currentIntegrated < -70.0f) return 1.0f;

            float targetGainDB = normalizerTargetLUFS.load(std::memory_order_relaxed) - currentIntegrated;
            targetGainDB = clampf(targetGainDB, -12.0f, 6.0f);
            return std::pow(10.0f, targetGainDB / 20.0f);
        }
    };

    struct AutomatedParamFloat
    {
        std::atomic<float> target{1.0f};
        float current = 1.0f;
        float step = 0.0f;

        void setTarget(float val)
        {
            target.store(val, std::memory_order_relaxed);
        }

        float getTarget() const
        {
            return target.load(std::memory_order_relaxed);
        }

        void prepareBlock(ma_uint32 frames, float smoothingMs, int sampleRate)
        {
            float tgt = target.load(std::memory_order_relaxed);
            if (smoothingMs <= 0.0f || frames == 0 || sampleRate <= 0)
            {
                current = tgt;
                step = 0.0f;
                return;
            }

            step = (tgt - current) / (float)frames;
        }

        inline float next()
        {
            current += step;
            // Clamp to the target: linear stepping otherwise overshoots/undershoots
            // and micro-oscillates around the setpoint forever.
            const float tgt = target.load(std::memory_order_relaxed);
            if ((step > 0.0f && current > tgt) || (step < 0.0f && current < tgt))
            {
                current = tgt;
                step = 0.0f;
            }
            return current;
        }
    };

    struct CrossfeedState
    {
        float a0_lo = 0.0f;
        float b1_lo = 0.0f;
        float a0_hi = 0.0f;
        float a1_hi = 0.0f;
        float b1_hi = 0.0f;
        float gain = 1.0f;

        struct FilterState
        {
            float lo[2] = {0.0f, 0.0f};
            float hi[2] = {0.0f, 0.0f};
            float asis[2] = {0.0f, 0.0f};
        } lfs;

        // Ambiophonics R.A.C.E. (Preset 4)
        static constexpr size_t RACE_MAX_DELAY = 128;
        float raceRingBufferL[RACE_MAX_DELAY] = {};
        float raceRingBufferR[RACE_MAX_DELAY] = {};
        size_t raceWriteIdx = 0;
        size_t raceDelaySamples = 8; // ~166us at 48kHz
        float raceDelayMs = 0.166f;  // ~166us
        float raceAlpha = 0.55f;
        float raceLpfHz = 2500.0f;
        float raceLpfA0 = 0.0f;
        float raceLpfB1 = 0.0f;
        float raceLpfOutL = 0.0f;
        float raceLpfOutR = 0.0f;

        int currentPreset = 1;
        int cachedSampleRate = 44100;

        double getLatencySamples(int sampleRate) const
        {
            if (currentPreset == 4)
            {
                int sr = (sampleRate > 0) ? sampleRate : (cachedSampleRate > 0 ? cachedSampleRate : 44100);
                return (double)(raceDelayMs * 0.001f) * (double)sr;
            }
            return 0.0;
        }

        void updateRaceParams(int sampleRate, float delayMs, float alpha, float lpfHz)
        {
            if (sampleRate <= 0)
                sampleRate = cachedSampleRate > 0 ? cachedSampleRate : 44100;
            cachedSampleRate = sampleRate;
            raceDelayMs = clampf(delayMs, 0.02f, 2.0f);
            raceAlpha = clampf(alpha, 0.0f, 1.0f);
            raceLpfHz = clampf(lpfHz, 200.0f, 16000.0f);

            constexpr double pi = 3.14159265358979323846;
            size_t d = (size_t)((double)(raceDelayMs / 1000.0f) * (double)sampleRate);
            raceDelaySamples = (d < 1) ? 1 : ((d >= RACE_MAX_DELAY) ? (RACE_MAX_DELAY - 1) : d);

            double x_race = std::exp(-2.0 * pi * (double)raceLpfHz / (double)sampleRate);
            raceLpfB1 = (float)x_race;
            raceLpfA0 = (float)(1.0 - x_race);
        }

        void reset(int sampleRate, int preset)
        {
            if (sampleRate <= 0)
                sampleRate = 44100;
            cachedSampleRate = sampleRate;
            currentPreset = preset;

            if (preset == 4) // Ambiophonics R.A.C.E.
            {
                updateRaceParams(sampleRate, raceDelayMs, raceAlpha, raceLpfHz);
                std::memset(raceRingBufferL, 0, sizeof(raceRingBufferL));
                std::memset(raceRingBufferR, 0, sizeof(raceRingBufferR));
                raceWriteIdx = 0;
                raceLpfOutL = 0.0f;
                raceLpfOutR = 0.0f;
                return;
            }

            uint32_t fcut = 700;
            uint32_t feed = 45;

            if (preset == 1) // BS2B Default (Jan Meier - 700Hz, 4.5dB)
            {
                fcut = 700;
                feed = 45;
            }
            else if (preset == 2) // BS2B Chu Moy (700Hz, 6.0dB)
            {
                fcut = 700;
                feed = 60;
            }
            else if (preset == 3) // BS2B Strong (650Hz, 9.5dB)
            {
                fcut = 650;
                feed = 95;
            }
            else
            {
                fcut = 700;
                feed = 45;
            }

            const double level = (double)feed / 10.0;
            const double gb_lo = level * -5.0 / 6.0 - 3.0;
            const double gb_hi = level / 6.0 - 3.0;

            const double g_lo = std::pow(10.0, gb_lo / 20.0);
            const double g_hi = 1.0 - std::pow(10.0, gb_hi / 20.0);
            const double fc_hi = (double)fcut * std::pow(2.0, (gb_lo - 20.0 * std::log10(g_hi)) / 12.0);

            constexpr double pi = 3.14159265358979323846;
            double x = std::exp(-2.0 * pi * (double)fcut / (double)sampleRate);
            b1_lo = (float)x;
            a0_lo = (float)(g_lo * (1.0 - x));

            x = std::exp(-2.0 * pi * fc_hi / (double)sampleRate);
            b1_hi = (float)x;
            a0_hi = (float)(1.0 - g_hi * (1.0 - x));
            a1_hi = (float)(-x);

            gain = (float)(1.0 / (1.0 - g_hi + g_lo));
            std::memset(&lfs, 0, sizeof(lfs));
        }

        inline float apply_lo_filter(float in, float out_1) const
        {
            return a0_lo * in + b1_lo * out_1;
        }

        inline float apply_hi_filter(float in, float in_1, float out_1) const
        {
            return a0_hi * in + a1_hi * in_1 + b1_hi * out_1;
        }

        void process(float *interleaved, ma_uint32 frames, int channels)
        {
            if (channels < 2)
                return;

            if (currentPreset == 4) // Ambiophonics R.A.C.E.
            {
                for (ma_uint32 i = 0; i < frames; ++i)
                {
                    size_t base = (size_t)i * (size_t)channels;
                    float sL = interleaved[base];
                    float sR = interleaved[base + 1];

                    size_t readIdx = (raceWriteIdx + RACE_MAX_DELAY - raceDelaySamples) % RACE_MAX_DELAY;
                    float delayedOutR = raceRingBufferR[readIdx];
                    float delayedOutL = raceRingBufferL[readIdx];

                    raceLpfOutR = raceLpfA0 * delayedOutR + raceLpfB1 * raceLpfOutR;
                    raceLpfOutL = raceLpfA0 * delayedOutL + raceLpfB1 * raceLpfOutL;

                    float outL = sL - raceAlpha * raceLpfOutR;
                    float outR = sR - raceAlpha * raceLpfOutL;

                    outL = std::tanh(outL);
                    outR = std::tanh(outR);

                    raceRingBufferL[raceWriteIdx] = outL;
                    raceRingBufferR[raceWriteIdx] = outR;
                    raceWriteIdx = (raceWriteIdx + 1) % RACE_MAX_DELAY;

                    interleaved[base]     = outL;
                    interleaved[base + 1] = outR;
                }
                return;
            }

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                size_t base = (size_t)i * (size_t)channels;
                float sL = interleaved[base];
                float sR = interleaved[base + 1];

                lfs.lo[0] = apply_lo_filter(sL, lfs.lo[0]);
                lfs.lo[1] = apply_lo_filter(sR, lfs.lo[1]);

                lfs.hi[0] = apply_hi_filter(sL, lfs.asis[0], lfs.hi[0]);
                lfs.hi[1] = apply_hi_filter(sR, lfs.asis[1], lfs.hi[1]);
                lfs.asis[0] = sL;
                lfs.asis[1] = sR;

                interleaved[base]     = (lfs.hi[0] + lfs.lo[1]) * gain;
                interleaved[base + 1] = (lfs.hi[1] + lfs.lo[0]) * gain;
            }
        }
    };

    struct StereoWidenState
    {
        std::vector<float> delayBuffer;
        size_t writeIdx = 0;
        float width = 1.0f;
        float delayMs = 15.0f;
        int cachedSampleRate = 44100;

        double getLatencySamples(int sampleRate) const
        {
            if (delayBuffer.empty()) return 0.0;
            int sr = (sampleRate > 0) ? sampleRate : (cachedSampleRate > 0 ? cachedSampleRate : 44100);
            return (double)(delayMs * 0.001f) * (double)sr;
        }

        // Crossovers for Left and Right channels to split Bass from Mids/Highs
        struct WidenCrossover
        {
            float ic1eq = 0.0f, ic2eq = 0.0f;
            float a1 = 0.0f, a2 = 0.0f, a3 = 0.0f, k = 0.0f;
            void set(float cutoff, float sampleRate)
            {
                float g = std::tan(3.14159265358979323846f * cutoff / sampleRate);
                k = 1.0f / 0.7071f; // Q = 0.7071 (Butterworth)
                a1 = 1.0f / (1.0f + g * (g + k));
                a2 = g * a1;
                a3 = g * a2;
            }
            void process(float input, float &lp, float &hp)
            {
                float v3 = input - ic2eq;
                float v1 = a1 * ic1eq + a2 * v3;
                float v2 = ic2eq + a2 * ic1eq + a3 * v3;
                ic1eq = 2.0f * v1 - ic1eq;
                ic2eq = 2.0f * v2 - ic2eq;
                lp = v2;
                hp = input - k * v1 - v2;
            }
        };

        WidenCrossover crossL;
        WidenCrossover crossR;

        void reset(int sampleRate)
        {
            cachedSampleRate = sampleRate;
            size_t delaySamples = (size_t)((delayMs / 1000.0f) * sampleRate);
            if (delaySamples == 0)
                delaySamples = 1;
            delayBuffer.assign(delaySamples, 0.0f);
            writeIdx = 0;

            crossL.set(300.0f, (float)sampleRate); // 300Hz Crossover
            crossR.set(300.0f, (float)sampleRate);
        }

        void updateParams(int sampleRate, float w, float dMs)
        {
            width = w;
            if (delayMs != dMs || cachedSampleRate != sampleRate)
            {
                delayMs = dMs;
                reset(sampleRate);
            }
        }

        void process(float *interleaved, ma_uint32 frames, int channels)
        {
            if (channels < 2)
                return; // Stereo only
            if (delayBuffer.empty())
                return;

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                size_t base = (size_t)i * channels;

                float originalL = interleaved[base];
                float originalR = interleaved[base + 1];

                // 1. Split into Bass (low) and Mid/High (high) bands
                float lowL, highL, lowR, highR;
                crossL.process(originalL, lowL, highL);
                crossR.process(originalR, lowR, highR);

                // 2. Haas Effect (Delay the right channel slightly) ONLY on the High band
                float delayedHighR = delayBuffer[writeIdx];
                delayBuffer[writeIdx] = highR;

                writeIdx++;
                if (writeIdx >= delayBuffer.size())
                    writeIdx = 0;

                // 3. Mid/Side Processing strictly on the High band
                float midHigh = (highL + delayedHighR) * 0.5f;
                float sideHigh = (highL - delayedHighR) * 0.5f;

                sideHigh *= width; // Widen the highs

                // Recombine widened highs
                float processHighL = midHigh + sideHigh;
                float processHighR = midHigh - sideHigh;

                // 4. Mono-center the bass
                float monoBass = (lowL + lowR) * 0.5f;

                // Mix the mono-centered bass back with the ultra-wide highs
                float outL = monoBass + processHighL;
                float outR = monoBass + processHighR;

                // 5. Soft clip to prevent 0dBFS clipping (crackling) when width is
                // extreme. Knee-limited so normal-level material passes untouched
                // instead of being tanh-compressed.
                if (outL > 0.95f)
                    outL = 0.95f + 0.05f * std::tanh((outL - 0.95f) / 0.05f);
                else if (outL < -0.95f)
                    outL = -0.95f + 0.05f * std::tanh((outL + 0.95f) / 0.05f);
                if (outR > 0.95f)
                    outR = 0.95f + 0.05f * std::tanh((outR - 0.95f) / 0.05f);
                else if (outR < -0.95f)
                    outR = -0.95f + 0.05f * std::tanh((outR + 0.95f) / 0.05f);

                interleaved[base] = outL;
                interleaved[base + 1] = outR;
            }
        }
    };

    // -------------------------------------------------------------
    // JamesDSP Warped Polyphase Filter Bank (5 Subband Decomposition)
    // -------------------------------------------------------------
    struct WarpedPFB
    {
        unsigned int decimationCounter[5] = {1, 1, 1, 1, 1};
        unsigned int Sk[5] = {1, 1, 1, 1, 1};
        float subbandData[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};

        // Allpass warp delay chain states for 5 subbands
        float dL[5][2] = {{0}};
        float dR[5][2] = {{0}};
        float warpingFactor = 0.65f;
    };

    static inline void initWarpedPFB(WarpedPFB *pfb, float sampleRate, int bands, int channels)
    {
        for (int i = 0; i < 5; i++)
        {
            pfb->decimationCounter[i] = 1;
            pfb->Sk[i] = 1;
            pfb->subbandData[i] = 0.0f;
            for (int j = 0; j < 2; j++)
            {
                pfb->dL[i][j] = 0.0f;
                pfb->dR[i][j] = 0.0f;
            }
        }
        if (sampleRate >= 88200.0f)
            pfb->warpingFactor = 0.82f;
        else if (sampleRate >= 44100.0f)
            pfb->warpingFactor = 0.65f;
        else
            pfb->warpingFactor = 0.50f;
    }

    static inline void assignPtrWarpedPFB(WarpedPFB *pfb, int bands, int channels)
    {
        for (int i = 0; i < 5; i++)
        {
            pfb->decimationCounter[i] = 1;
            pfb->Sk[i] = 1;
            pfb->subbandData[i] = 0.0f;
        }
    }

    static inline void analysisWarpedPFBStereo(WarpedPFB *subband0, WarpedPFB *subband1, float *inL, float *inR)
    {
        float xL = *inL;
        float xR = *inR;
        const float lambda = subband0->warpingFactor;

        // Channel 0 (Left)
        float wL0 = lambda * (xL - subband0->dL[0][0]) + subband0->dL[0][1];
        subband0->dL[0][1] = xL; subband0->dL[0][0] = wL0;
        float b0L = (xL + wL0) * 0.5f;
        float h0L = (xL - wL0) * 0.5f;

        float wL1 = lambda * (h0L - subband0->dL[1][0]) + subband0->dL[1][1];
        subband0->dL[1][1] = h0L; subband0->dL[1][0] = wL1;
        float b1L = (h0L + wL1) * 0.5f;
        float h1L = (h0L - wL1) * 0.5f;

        float wL2 = lambda * (h1L - subband0->dL[2][0]) + subband0->dL[2][1];
        subband0->dL[2][1] = h1L; subband0->dL[2][0] = wL2;
        float b2L = (h1L + wL2) * 0.5f;

        float wL3 = lambda * (b0L - subband0->dL[3][0]) + subband0->dL[3][1];
        subband0->dL[3][1] = b0L; subband0->dL[3][0] = wL3;
        float b3L = (b0L + wL3) * 0.5f;
        float h3L = (b0L - wL3) * 0.5f;

        subband0->subbandData[0] = h3L;
        subband0->subbandData[1] = b3L;
        subband0->subbandData[2] = b2L;
        subband0->subbandData[3] = b1L;
        subband0->subbandData[4] = (h1L - wL2) * 0.5f;

        // Channel 1 (Right)
        float wR0 = lambda * (xR - subband1->dL[0][0]) + subband1->dL[0][1];
        subband1->dL[0][1] = xR; subband1->dL[0][0] = wR0;
        float b0R = (xR + wR0) * 0.5f;
        float h0R = (xR - wR0) * 0.5f;

        float wR1 = lambda * (h0R - subband1->dL[1][0]) + subband1->dL[1][1];
        subband1->dL[1][1] = h0R; subband1->dL[1][0] = wR1;
        float b1R = (h0R + wR1) * 0.5f;
        float h1R = (h0R - wR1) * 0.5f;

        float wR2 = lambda * (h1R - subband1->dL[2][0]) + subband1->dL[2][1];
        subband1->dL[2][1] = h1R; subband1->dL[2][0] = wR2;
        float b2R = (h1R + wR2) * 0.5f;

        float wR3 = lambda * (b0R - subband1->dL[3][0]) + subband1->dL[3][1];
        subband1->dL[3][1] = b0R; subband1->dL[3][0] = wR3;
        float b3R = (b0R + wR3) * 0.5f;
        float h3R = (b0R - wR3) * 0.5f;

        subband1->subbandData[0] = h3R;
        subband1->subbandData[1] = b3R;
        subband1->subbandData[2] = b2R;
        subband1->subbandData[3] = b1R;
        subband1->subbandData[4] = (h1R - wR2) * 0.5f;
    }

    static inline void synthesisWarpedPFBStereo(WarpedPFB *subband0, WarpedPFB *subband1, float *outL, float *outR)
    {
        *outL = subband0->subbandData[0] + subband0->subbandData[1] + subband0->subbandData[2] + subband0->subbandData[3] + subband0->subbandData[4];
        *outR = subband1->subbandData[0] + subband1->subbandData[1] + subband1->subbandData[2] + subband1->subbandData[3] + subband1->subbandData[4];
    }

    // -------------------------------------------------------------
    // JamesDSP Stereo Enhancement Structure
    // -------------------------------------------------------------
    struct StereoEnhancementState
    {
        float mix = 0.5f;
        float minusMix = 0.5f;
        float gain = 1.0f;
        float emaAlpha[5] = {0};
        float sumStates[5] = {0};
        float diffStates[5] = {0};

        WarpedPFB subband0;
        WarpedPFB subband1;
        int cachedSampleRate = 44100;
        bool initialized = false;

        double getLatencySamples(int sampleRate) const
        {
            if (!initialized) return 0.0;
            int sr = (sampleRate > 0) ? sampleRate : (cachedSampleRate > 0 ? cachedSampleRate : 44100);
            return 0.0012 * (double)sr;
        }

        void refresh(int sampleRate)
        {
            if (sampleRate <= 0) sampleRate = 44100;
            cachedSampleRate = sampleRate;
            initWarpedPFB(&subband0, (float)sampleRate, 5, 2);
            assignPtrWarpedPFB(&subband1, 5, 2);
            // The right-channel bank must analyze with the SAME warping factor;
            // leaving it stale made L/R bands diverge at >= 88.2 kHz.
            subband1.warpingFactor = subband0.warpingFactor;

            float ms = 1.2f; // 1.2 ms attack/release constant
            for (unsigned int i = 0; i < 5; i++)
            {
                emaAlpha[i] = 1.0f - std::pow(10.0f, (std::log10(0.5f) / (ms / 1000.0f) / ((float)sampleRate / (float)subband0.Sk[i])));
                sumStates[i] = 0.0f;
                diffStates[i] = 0.0f;
            }
            setParam(mix);
            initialized = true;
        }

        void setParam(float m)
        {
            mix = clampf(m, 0.0f, 1.0f);
            minusMix = 1.0f - mix;
            if (mix > 0.5f)
                gain = 3.0f - mix * 2.0f;
            else
                gain = mix * 2.0f + 1.0f;
        }

        void process(float *interleaved, ma_uint32 frames, int channels)
        {
            if (channels < 2 || !initialized) return;

            unsigned int *samplingPeriod = subband0.decimationCounter;
            unsigned int *Sk = subband0.Sk;
            float *bandLeft = subband0.subbandData;
            float *bandRight = subband1.subbandData;

            for (ma_uint32 i = 0; i < frames; i++)
            {
                size_t base = (size_t)i * (size_t)channels;
                float inL = interleaved[base];
                float inR = interleaved[base + 1];
                float y1, y2;

                analysisWarpedPFBStereo(&subband0, &subband1, &inL, &inR);

                for (int j = 0; j < 5; j++)
                {
                    if (samplingPeriod[j] == Sk[j])
                    {
                        float sum = bandLeft[j] + bandRight[j];
                        float diff = bandLeft[j] - bandRight[j];
                        float sumSq = sum * sum;
                        float diffSq = diff * diff;

                        sumStates[j] = sumStates[j] * (1.0f - emaAlpha[j]) + sumSq * emaAlpha[j];
                        diffStates[j] = diffStates[j] * (1.0f - emaAlpha[j]) + diffSq * emaAlpha[j];

                        float centre = 0.0f;
                        if (sumSq > 1e-12f && sumStates[j] > 1e-12f)
                        {
                            float ratio = std::sqrt(clampf(diffStates[j] / sumStates[j], 0.0f, 1.0f));
                            centre = (0.5f - ratio * 0.5f) * sum;
                        }

                        bandLeft[j] = (bandLeft[j] - centre) * mix + centre * minusMix;
                        bandRight[j] = (bandRight[j] - centre) * mix + centre * minusMix;
                    }
                }

                synthesisWarpedPFBStereo(&subband0, &subband1, &y1, &y2);
                interleaved[base] = y1 * gain;
                interleaved[base + 1] = y2 * gain;
            }
        }
    };

    // ============================================================
    // CrystalizerState
    // Audiophile-grade transient edge reconstruction algorithm.
    //
    // Stage 1 — Transient Edge Reconstruction
    //   Recovers detail that lossy codecs (MP3/AAC) discard by extracting
    //   the inter-sample differences (signal derivative) and re-injecting them.
    //   This improves attack precision, presence, and perceived resolution.
    //
    // Stage 2 — High-Shelf "Air" Enhancement (optional)
    //   A gentle 2nd-order biquad high-shelf applied above ~8 kHz adds the
    //   "open sky" quality missing from compressed audio.
    //
    // Stage 3 — Soft-Clip Guard
    //   tanh saturation to prevent digital overs when intensity is high.
    // ============================================================
    struct CrystalizerState
    {
        float intensity = 0.5f;       // [0.0, 1.0] reconstruction strength
        bool highShelfEnabled = true; // enable Stage 2 air shelf
        float highShelfGainDb = 2.0f; // [0.0, 6.0] shelf boost in dB
        int cachedSampleRate = 0;
        sauti::dsp::PolyphaseOversampler2x oversampler;

        // Per-channel previous sample for derivative calculation (up to 8 ch)
        float prevSample[8] = {0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f};

        // 2nd-order high-shelf biquad coefficients (computed once on init/param change)
        // Using the Audio EQ Cookbook high-shelf formula
        struct HighShelfBiquad
        {
            double b0 = 1.0, b1 = 0.0, b2 = 0.0;
            double a1 = 0.0, a2 = 0.0;
            // Per-channel delay registers (up to 8 ch)
            double x1[8] = {}, x2[8] = {}, y1[8] = {}, y2[8] = {};

            void compute(double gainDb, double freqHz, double sampleRate)
            {
                const double A = std::pow(10.0, gainDb / 40.0);
                const double w0 = 2.0 * 3.14159265358979323846 * freqHz / sampleRate;
                const double cw = std::cos(w0);
                const double sw = std::sin(w0);
                // slope = 1 (standard Butterworth-matched)
                const double alpha = sw / 2.0 * std::sqrt((A + 1.0 / A) * (1.0 / 1.0 - 1.0) + 2.0);
                const double a0inv = 1.0 / ((A + 1.0) - (A - 1.0) * cw + 2.0 * std::sqrt(A) * alpha);

                b0 = A * ((A + 1.0) + (A - 1.0) * cw + 2.0 * std::sqrt(A) * alpha) * a0inv;
                b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw) * a0inv;
                b2 = A * ((A + 1.0) + (A - 1.0) * cw - 2.0 * std::sqrt(A) * alpha) * a0inv;
                const double a1c = 2.0 * ((A - 1.0) - (A + 1.0) * cw) * a0inv;
                const double a2c = ((A + 1.0) - (A - 1.0) * cw - 2.0 * std::sqrt(A) * alpha) * a0inv;
                a1 = a1c;
                a2 = a2c;
                // clear delay registers
                std::fill(x1, x1 + 8, 0.0);
                std::fill(x2, x2 + 8, 0.0);
                std::fill(y1, y1 + 8, 0.0);
                std::fill(y2, y2 + 8, 0.0);
            }

            float process(float sample, int ch)
            {
                double x0 = (double)sample;
                double y0 = b0 * x0 + b1 * x1[ch] + b2 * x2[ch] - a1 * y1[ch] - a2 * y2[ch];
                x2[ch] = x1[ch];
                x1[ch] = x0;
                y2[ch] = y1[ch];
                y1[ch] = y0;
                return (float)y0;
            }
        } shelf;

        void init(int sampleRate)
        {
            cachedSampleRate = sampleRate;
            std::fill(prevSample, prevSample + 8, 0.f);
            shelf.compute((double)highShelfGainDb, 8000.0, (double)sampleRate);
            oversampler.init(sampleRate, 4096);
        }

        void updateParams(int sampleRate, float newIntensity, bool newShelfEnabled, float newShelfGainDb)
        {
            intensity = clampf(newIntensity, 0.0f, 1.0f);
            highShelfEnabled = newShelfEnabled;
            const float clampedGain = clampf(newShelfGainDb, 0.0f, 6.0f);

            if (cachedSampleRate != sampleRate || clampedGain != highShelfGainDb)
            {
                highShelfGainDb = clampedGain;
                cachedSampleRate = sampleRate;
                shelf.compute((double)highShelfGainDb, 8000.0, (double)sampleRate);
                oversampler.init(sampleRate, 4096);
            }
        }

        void resetIfRateChanged(int sampleRate)
        {
            if (cachedSampleRate != sampleRate)
                init(sampleRate);
        }

        void process(float *interleaved, ma_uint32 frames, int channels)
        {
            if (intensity <= 0.0f || !interleaved || frames == 0)
                return;

            const int ch = std::min(channels, 8);

            for (ma_uint32 i = 0; i < frames; ++i)
            {
                for (int c = 0; c < ch; ++c)
                {
                    const size_t idx = (size_t)i * (size_t)channels + (size_t)c;
                    float x = interleaved[idx];

                    // Stage 1 — Transient edge reconstruction
                    // diff captures the derivative (high-frequency / transient energy)
                    const float diff = x - prevSample[c];
                    prevSample[c] = x;
                    x = x + diff * intensity;

                    // Stage 2 — High-shelf "air" enhancement (optional)
                    if (highShelfEnabled && intensity > 0.0f)
                    {
                        // Blend the shelf in proportion to intensity for smooth feel
                        const float shelfOut = shelf.process(x, c);
                        const float shelfBlend = intensity * 0.6f; // max 60% blend at full intensity
                        x = x * (1.0f - shelfBlend) + shelfOut * shelfBlend;
                    }

                    interleaved[idx] = x;
                }
            }

            // Stage 3 — 2x Oversampled Soft-Clip Guard (prevents overs without harmonic aliasing)
            if (channels == 2)
            {
                bool needsClip = false;
                for (ma_uint32 i = 0; i < frames * 2; ++i)
                {
                    if (std::abs(interleaved[i]) > 0.95f)
                    {
                        needsClip = true;
                        break;
                    }
                }

                if (needsClip)
                {
                    float *os = oversampler.upsample(interleaved, frames);
                    if (os)
                    {
                        const uint32_t osSamples = frames * 4;
                        for (uint32_t j = 0; j < osSamples; ++j)
                        {
                            float v = os[j];
                            if (v > 0.95f)
                                os[j] = 0.95f + 0.05f * std::tanh((v - 0.95f) / 0.05f);
                            else if (v < -0.95f)
                                os[j] = -0.95f + 0.05f * std::tanh((v + 0.95f) / 0.05f);
                        }
                        oversampler.downsample(os, interleaved, frames);
                    }
                }
            }
            else
            {
                for (ma_uint32 i = 0; i < frames * channels; ++i)
                {
                    float x = interleaved[i];
                    if (x > 0.95f)
                        interleaved[i] = 0.95f + 0.05f * std::tanh((x - 0.95f) / 0.05f);
                    else if (x < -0.95f)
                        interleaved[i] = -0.95f + 0.05f * std::tanh((x + 0.95f) / 0.05f);
                }
            }
        }
    };

    struct DitherProcessorState
    {
        float history[16][8] = {}; // Up to 16 channels, 8 taps history
        // One PRNG stream per channel: a single shared stream produced mono-
        // correlated dither across channels (visible on up-mixes).
        uint32_t prngState[16] = {
            0x12345678, 0x23456789, 0x3456789A, 0x456789AB,
            0x56789ABC, 0x6789ABCD, 0x789ABCDE, 0x89ABCDEF,
            0x9ABCDEF0, 0xABCDEF01, 0xBCDEF012, 0xCDEF0123,
            0xDEF01234, 0xEF012345, 0xF0123456, 0x01234567
        };

        void reset()
        {
            std::memset(history, 0, sizeof(history));
        }

        inline float getRpdfDither(float scale, int ch)
        {
            uint32_t s = prngState[ch & 15];
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            prngState[ch & 15] = s;
            const float r = (float)(s & 0xFFFFFF) * (1.0f / 16777216.0f) - 0.5f;
            return r * scale;
        }

        inline float getTpdfDither(float scale, int ch)
        {
            uint32_t s = prngState[ch & 15];
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            prngState[ch & 15] = s;
            const float r1 = (float)(s & 0xFFFFFF) * (1.0f / 16777216.0f);

            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            prngState[ch & 15] = s;
            const float r2 = (float)(s & 0xFFFFFF) * (1.0f / 16777216.0f);

            return (r1 - r2) * scale;
        }

        void process(int ditherMode, AEAudioFormat outFmt, float *inOutSamples, size_t totalSamples, int channels)
        {
            if (ditherMode <= 0 || !inOutSamples || totalSamples == 0)
                return;

            const int activeChannels = (channels > 0) ? channels : 2;
            const int ch = std::min(std::max(1, activeChannels), 16);
            const size_t frames = totalSamples / (size_t)activeChannels;

            float lsbScale = 1.0f / 32768.0f; // 16-bit target (default)
            if (outFmt == AE_FORMAT_S24)
                lsbScale = 1.0f / 8388608.0f;
            else if (outFmt == AE_FORMAT_S32)
                lsbScale = 1.0f / 2147483648.0f;
            else if (outFmt == AE_FORMAT_U8)
                lsbScale = 1.0f / 128.0f;

            // Mode 1: Rectangle (RPDF)
            if (ditherMode == 1)
            {
                const float ditherAmp = lsbScale; // 1.0 LSB p-p
                for (size_t i = 0; i < frames; ++i)
                {
                    size_t base = i * (size_t)activeChannels;
                    for (int c = 0; c < ch; ++c)
                    {
                        float x = inOutSamples[base + c];
                        float d = getRpdfDither(ditherAmp, c);
                        float q = std::round((x + d) / lsbScale) * lsbScale;
                        // Dither can push a near-full-scale sample past ±1.0;
                        // clamp so the downstream converter doesn't wrap/clip.
                        if (q > 1.0f) q = 1.0f;
                        else if (q < -1.0f) q = -1.0f;
                        inOutSamples[base + c] = q;
                    }
                }
                return;
            }

            // Mode 2: Triangle (TPDF)
            if (ditherMode == 2)
            {
                const float ditherAmp = lsbScale; // 2.0 LSB p-p
                for (size_t i = 0; i < frames; ++i)
                {
                    size_t base = i * (size_t)activeChannels;
                    for (int c = 0; c < ch; ++c)
                    {
                        float x = inOutSamples[base + c];
                        float d = getTpdfDither(ditherAmp, c);
                        float q = std::round((x + d) / lsbScale) * lsbScale;
                        if (q > 1.0f) q = 1.0f;
                        else if (q < -1.0f) q = -1.0f;
                        inOutSamples[base + c] = q;
                    }
                }
                return;
            }

            // Modes 3-8: Psychoacoustic Noise Shaping
            static const float coefLipshitz[5] = {2.033f, -2.165f, 1.959f, -1.137f, 0.321f};
            static const float coefFWeighted[5] = {2.412f, -2.970f, 2.453f, -1.332f, 0.366f};
            static const float coefModEWeighted[5] = {1.836f, -1.574f, 1.212f, -0.638f, 0.174f};
            static const float coefShibata[5] = {2.270f, -2.420f, 1.960f, -1.090f, 0.280f};
            static const float coefLowShibata[5] = {1.450f, -1.020f, 0.580f, -0.210f, 0.040f};
            static const float coefHighShibata[5] = {2.750f, -3.310f, 2.780f, -1.480f, 0.410f};

            const float *a = coefShibata;
            switch (ditherMode)
            {
            case 3: a = coefLipshitz; break;
            case 4: a = coefFWeighted; break;
            case 5: a = coefModEWeighted; break;
            case 6: a = coefShibata; break;
            case 7: a = coefLowShibata; break;
            case 8: a = coefHighShibata; break;
            default: a = coefShibata; break;
            }

            const float ditherAmp = lsbScale; // 2.0 LSB p-p TPDF dither

            for (size_t i = 0; i < frames; ++i)
            {
                size_t base = i * (size_t)activeChannels;
                for (int c = 0; c < ch; ++c)
                {
                    size_t idx = base + (size_t)c;
                    float x = inOutSamples[idx];

                    float feedback = a[0] * history[c][0] + a[1] * history[c][1] +
                                     a[2] * history[c][2] + a[3] * history[c][3] +
                                     a[4] * history[c][4];

                    float dither = getTpdfDither(ditherAmp, c);
                    float xShaped = x + feedback + dither;

                    float quantized = std::round(xShaped / lsbScale) * lsbScale;
                    if (quantized > 1.0f) quantized = 1.0f;
                    else if (quantized < -1.0f) quantized = -1.0f;
                    float err = xShaped - quantized;

                    // Anti-windup: when the clamp engages, the raw error is
                    // huge and feeding it back makes the shaper overshoot to
                    // the opposite rail (audible low-frequency buzzing on
                    // full-scale material). Drop the error instead.
                    if (quantized >= 1.0f || quantized <= -1.0f)
                        err = 0.0f;

                    history[c][4] = history[c][3];
                    history[c][3] = history[c][2];
                    history[c][2] = history[c][1];
                    history[c][1] = history[c][0];
                    history[c][0] = err;

                    inOutSamples[idx] = quantized;
                }
            }
        }
    };

    template <typename T>
    class SPSCBuffer
    {
    private:
        std::vector<T> m_buffer;
        size_t m_capacityMask = 0;
        alignas(64) std::atomic<size_t> m_writeIndex{0};
        alignas(64) std::atomic<size_t> m_readIndex{0};

    public:
        void init(size_t capacitySamples)
        {
            size_t cap = 1;
            while (cap < capacitySamples) cap <<= 1;
            m_buffer.assign(cap, T(0));
            m_capacityMask = cap - 1;
            m_writeIndex.store(0, std::memory_order_relaxed);
            m_readIndex.store(0, std::memory_order_relaxed);
        }

        size_t write(const T *data, size_t count)
        {
            if (m_buffer.empty() || count == 0) return 0;
            const size_t w = m_writeIndex.load(std::memory_order_relaxed);
            const size_t r = m_readIndex.load(std::memory_order_acquire);
            // Saturating arithmetic: during a concurrent reset() the indices can
            // be observed transiently inconsistent; clamp instead of wrapping
            // around to a bogus huge "available" value.
            const size_t used = (w >= r) ? (w - r) : 0;
            const size_t available = (m_capacityMask + 1) - std::min(used, m_capacityMask + 1);
            const size_t toWrite = std::min(count, available);
            if (toWrite == 0) return 0;

            const size_t mask = m_capacityMask;
            const size_t firstChunk = std::min(toWrite, (mask + 1) - (w & mask));
            std::memcpy(&m_buffer[w & mask], data, firstChunk * sizeof(T));
            if (toWrite > firstChunk)
            {
                std::memcpy(&m_buffer[0], data + firstChunk, (toWrite - firstChunk) * sizeof(T));
            }

            m_writeIndex.store(w + toWrite, std::memory_order_release);
            return toWrite;
        }

        size_t read(T *data, size_t count)
        {
            if (m_buffer.empty() || count == 0) return 0;
            const size_t r = m_readIndex.load(std::memory_order_relaxed);
            const size_t w = m_writeIndex.load(std::memory_order_acquire);
            // Saturating: see write().
            const size_t available = (w >= r) ? (w - r) : 0;
            const size_t toRead = std::min(count, available);
            if (toRead == 0) return 0;

            const size_t mask = m_capacityMask;
            const size_t firstChunk = std::min(toRead, (mask + 1) - (r & mask));
            std::memcpy(data, &m_buffer[r & mask], firstChunk * sizeof(T));
            if (toRead > firstChunk)
            {
                std::memcpy(data + firstChunk, &m_buffer[0], (toRead - firstChunk) * sizeof(T));
            }

            m_readIndex.store(r + toRead, std::memory_order_release);
            return toRead;
        }

        size_t available_read() const
        {
            if (m_buffer.empty()) return 0;
            const size_t w = m_writeIndex.load(std::memory_order_relaxed);
            const size_t r = m_readIndex.load(std::memory_order_relaxed);
            return (w >= r) ? (w - r) : 0;
        }

        size_t available_write() const
        {
            if (m_buffer.empty()) return 0;
            const size_t w = m_writeIndex.load(std::memory_order_relaxed);
            const size_t r = m_readIndex.load(std::memory_order_relaxed);
            const size_t used = (w >= r) ? (w - r) : 0;
            return (m_capacityMask + 1) - std::min(used, m_capacityMask + 1);
        }

        void reset()
        {
            m_writeIndex.store(0, std::memory_order_relaxed);
            m_readIndex.store(0, std::memory_order_relaxed);
        }
    };

    struct RetiredObject
    {
        ma_decoder *decoder = nullptr;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
        NetworkStreamState *stream = nullptr;
#endif
    };

    class GarbageQueue
    {
    private:
        std::mutex m_mtx;
        std::vector<RetiredObject> m_queue;

    public:
        void push(ma_decoder *dec
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
            , NetworkStreamState *st = nullptr
#endif
        )
        {
            if (!dec
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                && !st
#endif
            ) return;

            std::lock_guard<std::mutex> lk(m_mtx);
            m_queue.push_back({dec
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                , st
#endif
            });
        }

        void drain()
        {
            std::vector<RetiredObject> toDrain;
            {
                std::lock_guard<std::mutex> lk(m_mtx);
                if (m_queue.empty()) return;
                toDrain.swap(m_queue);
            }

            for (auto &item : toDrain)
            {
                if (item.decoder)
                {
                    ma_decoder_uninit(item.decoder);
                    delete item.decoder;
                }
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                if (item.stream)
                {
                    destroy_network_stream(item.stream);
                }
#endif
            }
        }
    };

} // namespace

struct AudioRatePlan
{
    uint32_t sourceRate = 48000;
    uint32_t engineRate = 48000;
    uint32_t deviceRate = 48000;

    bool decoderSRC = false;
    bool deviceSRC = false;
};

static AudioRatePlan calculateRatePlan(
    uint32_t sourceRate,
    uint32_t deviceRate,
    uint32_t userOutputRate,
    bool autoSampleRateMatch,
    bool exclusiveMode)
{
    AudioRatePlan plan{};
    plan.sourceRate = (sourceRate > 0) ? sourceRate : 48000;
    plan.deviceRate = (deviceRate > 0) ? deviceRate : 48000;

    if (autoSampleRateMatch)
    {
        // Auto sample rate match sets hardware device rate to source rate.
        // The engine DSP operates at the negotiated device rate.
        plan.engineRate = plan.deviceRate;
    }
    else if (userOutputRate > 0)
    {
        // Explicit user override for application processing rate
        plan.engineRate = userOutputRate;
    }
    else
    {
        // Standard shared mode: engine DSP operates at actual hardware device rate
        plan.engineRate = plan.deviceRate;
    }

    plan.decoderSRC = (plan.sourceRate != plan.engineRate);
    plan.deviceSRC = (plan.engineRate != plan.deviceRate);

    return plan;
}

struct AudioEngineHandle;

struct AudioEngineHandle
{
    ma_device device{};
    mutable std::mutex deviceMutex;
    std::atomic<bool> exclusiveModeEnabled{false};
    std::atomic<bool> use64BitProcessing{false};
    std::atomic<bool> autoSampleRateMatchEnabled{false};
    std::atomic<bool> rateTransitionInProgress{false};
    std::atomic<int> userPeriodFrames{0};
    std::atomic<int> userPeriodCount{0};
    // When worker_loop detects a native rate change, it sets this to the new
    // sample rate. The Dart control thread polls via ae_consume_pending_rate_change()
    // and triggers restart_and_apply_config from a safe context.
    std::atomic<int> pendingAutoSampleRateMatchRate{0};

    std::atomic<int> configuredBackend{0 /* AE_BACKEND_AUTO */};
    std::atomic<int> activeBackend{0 /* AE_BACKEND_AUTO */};
    ma_context customContext{};
    bool customContextInit = false;
    void *pAudioTrackSink = nullptr;

    ma_decoder *currentDecoder = nullptr;
    ma_decoder *nextDecoder = nullptr;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
    NetworkStreamState *currentStream = nullptr;
    NetworkStreamState *nextStream = nullptr;
#endif
    bool hasCurrent = false;
    bool hasNext = false;
    int nextIndex = -1;

    ma_uint64 currentLengthFrames = 0;
    ma_uint64 nextLengthFrames = 0;

    // Explicit Separated Sample Rate Architecture
    int sourceSampleRate = 0;     // Native rate of active track (e.g. 48000 Hz)
    int engineSampleRate = 48000; // Internal mixer & DSP processing rate (e.g. 48000 Hz)
    int deviceSampleRate = 48000; // Negotiated hardware DAC rate (e.g. 48000 Hz)
    int sampleRate = 48000;       // Master alias for engineSampleRate
    AudioRatePlan ratePlan{};

    ma_resampler deviceResampler{};
    mutable std::mutex deviceResamplerMutex;
    bool deviceResamplerInit = false;
    int deviceResamplerInRate = 0;
    int deviceResamplerOutRate = 0;
    int deviceResamplerCh = 0;
    std::vector<float> engineProcessBuffer;

    int channels = 2;

    std::vector<std::string> playlist;
    int currentIndex = -1;
    std::vector<int> playOrder;
    int orderCursor = -1;
    bool shuffleEnabled = false;
    int loopMode = AE_LOOP_ALL;
    std::mt19937 rng{std::random_device{}()};

    std::mutex playlistMutex;
    std::mutex decoderMutex;

    SPSCBuffer<float> pcmRingBuffer;
    GarbageQueue garbageQueue;
    std::atomic<uint64_t> preloadGeneration{0};

    std::mutex decodeProducerMutex;
    std::condition_variable decodeProducerCv;
    std::atomic<bool> decodeProducerExit{false};
    std::atomic<bool> ringBufferFlushing{false};
    std::thread decodeProducerThread;

    std::mutex workerMutex;
    std::condition_variable workerCv;
    bool workerExit = false;
    bool preloadRequested = false;
    int requestedIndex = -1;

    std::thread worker;

    std::atomic<bool> isPlaying{false};
    // Deferred auto-play: set by jump/next/prev, consumed by worker_loop
    // after the decoder is loaded. Prevents isPlaying=true before audio
    // is actually ready (fixes slider-ahead-of-audio bug).
    std::atomic<bool> pendingAutoPlay{false};
    std::atomic<bool> crossfadeEnabled{false};
    std::atomic<int> crossfadeDurationMs{250};

    // Crossfade State
    std::atomic<bool> isCrossfading{false};
    std::atomic<bool> loudnessCrossfadeEnabled{true};
    std::atomic<float> currentTrackReplayGain{1.0f};
    std::atomic<float> fadingOutReplayGain{1.0f};
    std::atomic<float> nextTrackReplayGain{1.0f};
    std::atomic<ma_uint64> crossfadeFramesRemaining{0};
    std::atomic<ma_uint64> crossfadeFramesTotal{0};
    ma_decoder* fadingOutDecoder = nullptr;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
    NetworkStreamState* fadingOutStream = nullptr;
#endif
    // Decoded old-track audio, produced by decode_producer_loop and consumed by
    // the realtime callback. This keeps codec decoding (and possibly blocking
    // network reads) OFF the audio thread during crossfades.
    SPSCBuffer<float> crossfadeRingBuffer;
    std::atomic<bool> crossfadeSourceEof{false};
    // Graceful abort: when a user skip interrupts an ACTIVE crossfade, the
    // outgoing track ramps to silence over a short window instead of cutting.
    // Lifetime rules are unchanged - the producer thread still retires
    // fadingOutDecoder once isCrossfading clears. Publish level/total BEFORE
    // the active flag so the realtime side never reads partial state.
    std::atomic<bool> crossfadeAbortActive{false};
    std::atomic<float> crossfadeAbortStartLevel{0.0f};
    std::atomic<ma_uint64> crossfadeAbortFramesTotal{0};
    std::atomic<ma_uint64> crossfadeAbortFramesDone{0};
    // Stall watchdog: if the fading-out source delivers nothing for ~250 ms
    // (network stall / dead connection), latch it dead so the realtime side
    // stops reading a sputtering ring and completes the fade as a clean
    // fade-in instead of stuttering.
    std::atomic<bool> crossfadeSourceDead{false};
    std::atomic<ma_uint32> crossfadeStarveFrames{0};

    std::atomic<bool> pendingSeekValid{false};
    std::atomic<ma_uint64> pendingSeekFrame{0};
    std::atomic<int> pendingSeekIndex{-1};

    // A-B Repeat
    std::atomic<bool> abRepeatEnabled{false};
    std::atomic<double> abStartSeconds{0.0};
    std::atomic<double> abEndSeconds{0.0};

    // Speed (Rate), Pitch & Pitch Correction (Scaletempo)
    std::atomic<float> rateMultiplier{1.0f};
    std::atomic<float> pitchMultiplier{1.0f};
    std::atomic<bool> pitchCorrectionEnabled{true};
    ma_resampler pitchResampler{};
    bool pitchResamplerInit = false;
    int pitchResamplerRate = 0;
    int pitchResamplerChannels = 0;
    float pitchResamplerCurrentPitch = 1.0f;
    std::vector<float> pitchInputBuffer;
    size_t pitchInputUnconsumed = 0;
    sauti::dsp::ScaleTempoDSP tempoProcessor;
    std::vector<float> tempoInputChunk;

    // Fading & Scheduling
    std::atomic<bool> customFadeArmed{false};
    std::atomic<float> customFadeVolumeBeg{1.0f};
    std::atomic<float> customFadeVolumeEnd{1.0f};
    std::atomic<ma_uint64> customFadeFramesTotal{0};
    std::atomic<ma_uint64> customFadeFramesRemaining{0};

    std::atomic<ma_uint64> scheduledStartTime{-1ULL};
    std::atomic<ma_uint64> scheduledStopTime{-1ULL};
    std::atomic<ma_uint64> engineAbsoluteTime{0};
    std::atomic<ma_uint64> playedPcmFrames{0};
    std::atomic<ma_uint64> seekBasePcmFrame{0};

    // End Callback
    AE_EndCallback endCallback = nullptr;
    void *pEndCallbackUserData = nullptr;

    std::mutex fxMutex;
    bool eqEnabled = false;
    std::atomic<float> gain{1.0f};
    std::atomic<float> replayGainLinear{1.0f}; // Replay Gain multiplier (linear); 1.0 = no change
    std::atomic<float> pan{0.0f};
    EqState eq;

    // Audio Limiter & Clipping Detection
    bool limiterEnabled = false;
    LimiterState limiter;

    // Dynamic Range Compressor
    bool compressorEnabled = false;
    CompressorState compressor;
    std::atomic<bool> clippingDetectionEnabled{false};
    std::atomic<uint64_t> clippedSamplesCount{0};
    // Realtime callback starvation counter (previously hardcoded to 0).
    std::atomic<uint64_t> underrunCount{0};

    // Release 1 Quality Foundation Subsystems.
    // Metering is opt-in: both meters are heavy (true-peak polyphase interpolation,
    // BS.1770 K-weighting + gated analysis) and previously ran unconditionally on
    // the realtime thread even when nothing read their output.
    std::atomic<bool> truePeakMeterEnabled{false};
    TruePeakMeterState truePeakMeter;

    std::atomic<bool> lookaheadLimiterEnabled{false};
    LookAheadLimiterState lookaheadLimiter;

    std::atomic<bool> loudnessMeterEnabled{false};
    BS1770LoudnessMeter loudnessMeter;

    AutomatedParamFloat paramGain;
    AutomatedParamFloat paramPan;
    // Loudness Normalizer gain automation (BS.1770 integrated LUFS -> target).
    // Ramped per-sample so slow loudness corrections never zipper or click.
    AutomatedParamFloat paramNormalizerGain;
    // Smoothed user master gain (prevents zipper noise on volume changes)
    AutomatedParamFloat paramUserGain;
    std::atomic<float> parameterSmoothingMs{15.0f};

    // Stereo Widen Effect
    bool stereoWidenEnabled = false;
    StereoWidenState stereoWiden;

    // JamesDSP Stereo Enhancement Effect
    bool stereoEnhancementEnabled = false;
    StereoEnhancementState stereoEnhancement;

    // Crossfeed (Headphone Virtualization)
    bool crossfeedEnabled = false;
    int crossfeedPreset = 1;
    CrossfeedState crossfeed;       // Legacy path (preset-4 RACE; kept for RACE API)
    CrossfeedNode crossfeedNode;    // New modular crossfeed DSP node

    // Crystalizer (audiophile transient reconstruction + air enhancement)
    bool crystalizerEnabled = false;
    CrystalizerState crystalizer;

    // Reverb (Freeverb-style FDN)
    bool reverbEnabled = false;
    ReverbNode reverbNode;

    // Advanced Audio Features
    AEAudioFormat outputFormat = AE_FORMAT_F32;
    int outputSampleRate = 0;     // Active hardware DAC output rate (0 = native)
    int userOutputSampleRate = 0; // User-selected preferred output rate (0 = native)
    int outputChannels = 2;       // default stereo

    bool multibandEqEnabled = false;
    int eqBandCount = 0;
    std::mutex eqMutex; // Protect EQ config changes

    int resampleAlgorithm = 8; // Default to AE_RESAMPLE_ALGORITHM_SOXR_VHQ_MINIMUM_PHASE (mode 8)
    std::atomic<int> ditherMode{0}; // AE_DITHER_MODE_NONE
    std::atomic<bool> phaseInvertLeft{false};
    std::atomic<bool> phaseInvertRight{false};
    std::atomic<bool> lrSwapEnabled{false};
    std::atomic<float> channelGainLeft{1.0f};
    std::atomic<float> channelGainRight{1.0f};
    DitherProcessorState ditherProcessor;

    std::vector<float> eqFrequencies;
    std::vector<float> eqGains;
    std::vector<float> eqQ;
    // Each band has one ma_peak2 filter which handles all channels (interleaved)
    std::vector<ma_peak2> eqFilters;

    struct FxBand
    {
        int type = AE_EQ_BAND_PEAK;
        bool enabled = true;
        float frequencyHz = 1000.0f;
        float q = 1.0f;
        float gainDb = 0.0f;
        float slope = 1.0f;

        ma_peak2 peak{};
        ma_bpf2 bandpass{};
        ma_notch2 notch{};
        ma_loshelf2 lowshelf{};
        ma_hishelf2 highshelf{};
        ma_lpf2 lowpass{};
        ma_hpf2 highpass{};
    };

    bool multibandFxEnabled = false;
    std::vector<FxBand> multibandFxBands;

    // Native Clean-Room Audio DSP Suite
    sauti::dsp::AudioClarityDSP clarityDsp;
    sauti::dsp::DialogEnhancerDSP dialogEnhancerDsp;
    sauti::dsp::HarmonicBassDSP harmonicBassDsp;
    sauti::dsp::DynamicSystemDSP dynamicSystemDsp;
    sauti::dsp::AnalogWarmthDSP analogWarmthDsp;
    sauti::dsp::DeEsserDSP deEsserDsp;
    sauti::dsp::DownwardExpanderDSP downwardExpanderDsp;
    sauti::dsp::FFTConvolverDSP fftConvolverDsp;
    sauti::dsp::MasterLimiterDSP masterLimiterDsp;
    sauti::dsp::SpatialSurroundDSP surroundDsp;
    sauti::dsp::SubsonicFilter subsonicFilter;
    std::mutex dspMutex;

    std::atomic<bool> analyzerEnabled{false};
    int analyzerFrameSize = 512;
    std::vector<float> analyzerAccumulator;
    int analyzerAccumulatorCount = 0;
    std::vector<float> analyzerLatest;
    std::mutex analyzerMutex;
    std::atomic<uint64_t> analyzerDroppedFrames{0};

    void update_eq_filters()
    {
        if (eqBandCount <= 0)
        {
            eqFilters.clear();
            return;
        }
        eqFilters.resize(eqBandCount);
        int sr = (outputSampleRate > 0) ? outputSampleRate : ((sampleRate > 0) ? sampleRate : 48000);
        int ch = outputChannels > 0 ? outputChannels : 2;

        for (int i = 0; i < eqBandCount; ++i)
        {
            ma_peak2_config config = ma_peak2_config_init(
                ma_format_f32,
                (ma_uint32)ch,
                (ma_uint32)sr,
                eqGains[i],
                eqQ[i],
                eqFrequencies[i]);
            ma_peak2_init(&config, nullptr, &eqFilters[i]);
        }
    }

    void process_multiband_eq(float *frames, ma_uint32 frameCount, int channels)
    {
        for (auto &filter : eqFilters)
        {
            ma_peak2_process_pcm_frames(&filter, frames, frames, (ma_uint64)frameCount);
        }
    }

    void update_multiband_fx_filters()
    {
        const int sr = (outputSampleRate > 0) ? outputSampleRate : ((sampleRate > 0) ? sampleRate : 48000);
        const int ch = (outputChannels > 0) ? outputChannels : ((channels > 0) ? channels : 2);
        const ma_uint32 sampleRateU32 = (ma_uint32)sr;
        const ma_uint32 channelsU32 = (ma_uint32)ch;

        for (auto &band : multibandFxBands)
        {
            const float frequencyHz = clampf(band.frequencyHz, 20.0f, (float)sampleRateU32 * 0.45f);
            const float q = clampf(band.q, 0.1f, 18.0f);
            const float gainDb = clampf(band.gainDb, -24.0f, 24.0f);
            const float slope = clampf(band.slope, 0.1f, 2.0f);

            band.frequencyHz = frequencyHz;
            band.q = q;
            band.gainDb = gainDb;
            band.slope = slope;

            switch (band.type)
            {
            case AE_EQ_BAND_BANDPASS:
            {
                ma_bpf2_config config = ma_bpf2_config_init(
                    ma_format_f32,
                    channelsU32,
                    sampleRateU32,
                    frequencyHz,
                    q);
                (void)ma_bpf2_init(&config, nullptr, &band.bandpass);
                break;
            }
            case AE_EQ_BAND_NOTCH:
            {
                ma_notch2_config config = ma_notch2_config_init(
                    ma_format_f32,
                    channelsU32,
                    sampleRateU32,
                    q,
                    frequencyHz);
                (void)ma_notch2_init(&config, nullptr, &band.notch);
                break;
            }
            case AE_EQ_BAND_LOWSHELF:
            {
                ma_loshelf2_config config = ma_loshelf2_config_init(
                    ma_format_f32,
                    channelsU32,
                    sampleRateU32,
                    gainDb,
                    slope,
                    frequencyHz);
                (void)ma_loshelf2_init(&config, nullptr, &band.lowshelf);
                break;
            }
            case AE_EQ_BAND_HIGHSHELF:
            {
                ma_hishelf2_config config = ma_hishelf2_config_init(
                    ma_format_f32,
                    channelsU32,
                    sampleRateU32,
                    gainDb,
                    slope,
                    frequencyHz);
                (void)ma_hishelf2_init(&config, nullptr, &band.highshelf);
                break;
            }
            case AE_EQ_BAND_LOWPASS:
            {
                ma_lpf2_config config = ma_lpf2_config_init(
                    ma_format_f32,
                    channelsU32,
                    sampleRateU32,
                    frequencyHz,
                    q);
                (void)ma_lpf2_init(&config, nullptr, &band.lowpass);
                break;
            }
            case AE_EQ_BAND_HIGHPASS:
            {
                ma_hpf2_config config = ma_hpf2_config_init(
                    ma_format_f32,
                    channelsU32,
                    sampleRateU32,
                    frequencyHz,
                    q);
                (void)ma_hpf2_init(&config, nullptr, &band.highpass);
                break;
            }
            case AE_EQ_BAND_PEAK:
            default:
            {
                ma_peak2_config config = ma_peak2_config_init(
                    ma_format_f32,
                    channelsU32,
                    sampleRateU32,
                    gainDb,
                    q,
                    frequencyHz);
                (void)ma_peak2_init(&config, nullptr, &band.peak);
                break;
            }
            }
        }
    }

    void process_multiband_fx(float *frames, ma_uint32 frameCount)
    {
        for (auto &band : multibandFxBands)
        {
            if (!band.enabled)
                continue;

            switch (band.type)
            {
            case AE_EQ_BAND_BANDPASS:
                (void)ma_bpf2_process_pcm_frames(&band.bandpass, frames, frames, (ma_uint64)frameCount);
                break;
            case AE_EQ_BAND_NOTCH:
                (void)ma_notch2_process_pcm_frames(&band.notch, frames, frames, (ma_uint64)frameCount);
                break;
            case AE_EQ_BAND_LOWSHELF:
                (void)ma_loshelf2_process_pcm_frames(&band.lowshelf, frames, frames, (ma_uint64)frameCount);
                break;
            case AE_EQ_BAND_HIGHSHELF:
                (void)ma_hishelf2_process_pcm_frames(&band.highshelf, frames, frames, (ma_uint64)frameCount);
                break;
            case AE_EQ_BAND_LOWPASS:
                (void)ma_lpf2_process_pcm_frames(&band.lowpass, frames, frames, (ma_uint64)frameCount);
                break;
            case AE_EQ_BAND_HIGHPASS:
                (void)ma_hpf2_process_pcm_frames(&band.highpass, frames, frames, (ma_uint64)frameCount);
                break;
            case AE_EQ_BAND_PEAK:
            default:
                (void)ma_peak2_process_pcm_frames(&band.peak, frames, frames, (ma_uint64)frameCount);
                break;
            }
        }
    }

    void capture_analyzer_frames(const float *frames, ma_uint32 frameCount, int channels)
    {
        if (!analyzerEnabled.load(std::memory_order_relaxed))
            return;
        if (analyzerFrameSize <= 0 || frameCount == 0 || channels <= 0)
            return;
        if ((int)analyzerAccumulator.size() != analyzerFrameSize)
            return;

        const int ch = std::max(1, channels);
        for (ma_uint32 i = 0; i < frameCount; ++i)
        {
            float mono = 0.0f;
            const size_t base = (size_t)i * (size_t)ch;
            for (int c = 0; c < ch; ++c)
            {
                mono += frames[base + (size_t)c];
            }
            mono /= (float)ch;

            if (analyzerAccumulatorCount < analyzerFrameSize)
            {
                analyzerAccumulator[(size_t)analyzerAccumulatorCount++] = mono;
            }

            if (analyzerAccumulatorCount >= analyzerFrameSize)
            {
                if (analyzerMutex.try_lock())
                {
                    analyzerLatest = analyzerAccumulator;
                    analyzerMutex.unlock();
                }
                else
                {
                    analyzerDroppedFrames.fetch_add(1, std::memory_order_relaxed);
                }
                analyzerAccumulatorCount = 0;
            }
        }
    }

    // Temporary buffer for format conversion/resampling if needed
    std::vector<float> conversionBuffer;

    // Pre-allocated scratch buffers for audio thread to avoid real-time heap allocations
    std::vector<float> crossfadeMixBuffer;

    std::mutex errorMutex;
    std::string lastError;

    // Push stream state
    PushStreamContext pushStreamForCurrent; // Single slot for now, for simplicity
    bool isPushStreamMode = false;
    // Set by ae_stop() to unblock ae_push_stream_chunk() when the consumer
    // stalls and the ring buffer stays full (prevents an unkillable wait).
    std::atomic<bool> pushStreamAbort{false};
};

extern "C"
{
    static void restart_and_apply_config(AudioEngineHandle *e);
}

static void apply_buffer_policy(AudioEngineHandle *e, ma_device_config &cfg)
{
    if (!e)
        return;
    const int userFrames = e->userPeriodFrames.load(std::memory_order_relaxed);
    const int userPeriods = e->userPeriodCount.load(std::memory_order_relaxed);

    if (userFrames > 0)
    {
        cfg.periodSizeInFrames = (ma_uint32)userFrames;
        cfg.periodSizeInMilliseconds = 0;
    }
    if (userPeriods > 0)
    {
        cfg.periods = (ma_uint32)userPeriods;
    }
}

static void arm_transition_fade_in(AudioEngineHandle *e)
{
    if (e == nullptr)
        return;

    const bool enabled = e->crossfadeEnabled.load(std::memory_order_relaxed);
    if (!enabled)
    {
        e->crossfadeFramesTotal.store(0, std::memory_order_relaxed);
        e->crossfadeFramesRemaining.store(0, std::memory_order_relaxed);
        return;
    }

    const int durationMs = clampi(e->crossfadeDurationMs.load(std::memory_order_relaxed), 0, 10000);
    if (durationMs <= 0)
    {
        e->crossfadeFramesTotal.store(0, std::memory_order_relaxed);
        e->crossfadeFramesRemaining.store(0, std::memory_order_relaxed);
        return;
    }

    const int sr = (e->sampleRate > 0) ? e->sampleRate : 48000;
    const ma_uint64 fadeFrames = (ma_uint64)((double)sr * ((double)durationMs / 1000.0));
    if (fadeFrames == 0)
    {
        e->crossfadeFramesTotal.store(0, std::memory_order_relaxed);
        e->crossfadeFramesRemaining.store(0, std::memory_order_relaxed);
        return;
    }

    e->crossfadeFramesTotal.store(fadeFrames, std::memory_order_relaxed);
    e->crossfadeFramesRemaining.store(fadeFrames, std::memory_order_relaxed);
}

static void reinit_advanced_fx_filters(AudioEngineHandle *e)
{
    if (e == nullptr)
        return;

    const ma_uint32 sampleRate = (ma_uint32)((e->sampleRate > 0) ? e->sampleRate : 48000);

    e->stereoEnhancement.refresh((int)sampleRate);
    e->crystalizer.init((int)sampleRate);

    const float srF = (float)sampleRate;
    e->clarityDsp.setSampleRate(srF);
    e->dialogEnhancerDsp.setSampleRate(srF);
    e->harmonicBassDsp.setSampleRate(srF);
    e->dynamicSystemDsp.setSampleRate(srF);
    e->analogWarmthDsp.setSampleRate(srF);
    e->deEsserDsp.setSampleRate(srF);
    e->downwardExpanderDsp.setSampleRate(srF);
    e->fftConvolverDsp.setSampleRate(srF);
    e->masterLimiterDsp.setSampleRate(srF);
    e->surroundDsp.setSampleRate(srF);
    e->subsonicFilter.setSampleRate(srF);
}

static void applyRatePlan(AudioEngineHandle *e, const AudioRatePlan &plan)
{
    if (e == nullptr)
        return;

    const int oldSource = e->sourceSampleRate;
    const int oldEngine = e->engineSampleRate;

    e->sourceSampleRate = (int)plan.sourceRate;
    e->engineSampleRate = (int)plan.engineRate;
    e->deviceSampleRate = (int)plan.deviceRate;
    e->sampleRate       = (int)plan.engineRate;
    e->ratePlan         = plan;

    const int sr = e->engineSampleRate;
    const int ch = (e->channels > 0) ? e->channels : 2;

    // Synchronize device resampler lifecycle on control thread (Requirements 8 & 9)
    {
        std::lock_guard<std::mutex> rLock(e->deviceResamplerMutex);
        if (plan.deviceSRC)
        {
            if (!e->deviceResamplerInit || e->deviceResamplerInRate != (int)plan.engineRate || e->deviceResamplerOutRate != (int)plan.deviceRate || e->deviceResamplerCh != ch)
            {
                if (e->deviceResamplerInit)
                {
                    ma_resampler_uninit(&e->deviceResampler, nullptr);
                    e->deviceResamplerInit = false;
                }
                ma_resampler_config rcfg = ma_resampler_config_init(
                    ma_format_f32,
                    (ma_uint32)ch,
                    (ma_uint32)plan.engineRate,
                    (ma_uint32)plan.deviceRate,
                    ma_resample_algorithm_linear
                );
                if (e->resampleAlgorithm > 0)
                {
                    rcfg.algorithm = ma_resample_algorithm_custom;
                    rcfg.pBackendVTable = get_resampler_vtable_for_algorithm(e->resampleAlgorithm);
                    rcfg.pBackendUserData = &e->resampleAlgorithm;
                }
                if (ma_resampler_init(&rcfg, nullptr, &e->deviceResampler) == MA_SUCCESS)
                {
                    e->deviceResamplerInit = true;
                    e->deviceResamplerInRate = (int)plan.engineRate;
                    e->deviceResamplerOutRate = (int)plan.deviceRate;
                    e->deviceResamplerCh = ch;
                }
            }
        }
        else
        {
            if (e->deviceResamplerInit)
            {
                ma_resampler_uninit(&e->deviceResampler, nullptr);
                e->deviceResamplerInit = false;
                e->deviceResamplerInRate = 0;
                e->deviceResamplerOutRate = 0;
                e->deviceResamplerCh = 0;
            }
        }
    }

    {
        std::lock_guard<std::mutex> eqLock(e->eqMutex);
        e->update_eq_filters();
        e->update_multiband_fx_filters();
    }

    {
        std::lock_guard<std::mutex> fx(e->fxMutex);
        reinit_advanced_fx_filters(e);
        e->eq.updateCoefficients(sr);
        e->stereoWiden.reset(sr);
        e->stereoEnhancement.refresh(sr);
        e->crossfeedNode.setSampleRate((double)sr);
        e->crossfeed.reset(sr, e->crossfeedPreset);
        e->crystalizer.init(sr);
        e->reverbNode.setSampleRate((double)sr);
    }

    {
        std::lock_guard<std::mutex> lock(e->dspMutex);
        const float srF = (float)sr;
        e->clarityDsp.setSampleRate(srF);
        e->dialogEnhancerDsp.setSampleRate(srF);
        e->harmonicBassDsp.setSampleRate(srF);
        e->dynamicSystemDsp.setSampleRate(srF);
        e->analogWarmthDsp.setSampleRate(srF);
        e->deEsserDsp.setSampleRate(srF);
        e->downwardExpanderDsp.setSampleRate(srF);
        e->fftConvolverDsp.setSampleRate(srF);
        e->masterLimiterDsp.setSampleRate(srF);
        e->surroundDsp.setSampleRate(srF);
        e->subsonicFilter.setSampleRate(srF);
    }

    ma_uint32 decOutRate = (e->currentDecoder != nullptr) ? e->currentDecoder->outputSampleRate : (ma_uint32)plan.engineRate;

    engine_log("AUTO-SR TRANSITION\n  old source = %d Hz\n  new source = %u Hz\n  requested device = %d Hz\n  actual device = %u Hz\n  old engine = %d Hz\n  new engine = %u Hz\n  decoder output = %u Hz\n  decoder SRC = %s\n  device SRC = %s\n  mode = %s",
               oldSource, plan.sourceRate,
               e->outputSampleRate, plan.deviceRate,
               oldEngine, plan.engineRate,
               decOutRate,
               plan.decoderSRC ? "ON" : "OFF",
               plan.deviceSRC ? "ON" : "OFF",
               e->exclusiveModeEnabled.load(std::memory_order_relaxed) ? "EXCLUSIVE" : "SHARED");
}

static void setEngineSampleRate(AudioEngineHandle *e, uint32_t newRate)
{
    if (e == nullptr || newRate == 0)
        return;
    AudioRatePlan plan = calculateRatePlan(
        (uint32_t)e->sourceSampleRate,
        (uint32_t)e->deviceSampleRate,
        newRate,
        e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed),
        e->exclusiveModeEnabled.load(std::memory_order_relaxed)
    );
    applyRatePlan(e, plan);
}

static void set_last_error(AudioEngineHandle *e, const std::string &message)
{
    if (e == nullptr)
        return;
    std::lock_guard<std::mutex> lk(e->errorMutex);
    e->lastError = message;
    engine_log("ERROR: %s", message.c_str());
}

static void clear_last_error(AudioEngineHandle *e)
{
    if (e == nullptr)
        return;
    std::lock_guard<std::mutex> lk(e->errorMutex);
    e->lastError.clear();
}

static void uninit_decoder_ptr(ma_decoder *&pDecoder)
{
    if (pDecoder != nullptr)
    {
        ma_decoder_uninit(pDecoder);
        delete pDecoder;
        pDecoder = nullptr;
    }
}

static void uninit_decoder_slot(
    AudioEngineHandle *e,
    ma_decoder *&pDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
    ,
    NetworkStreamState *&pStream
#endif
)
{
    if (e != nullptr)
    {
        e->garbageQueue.push(pDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
            , pStream
#endif
        );
        pDecoder = nullptr;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
        pStream = nullptr;
#endif
    }
    else
    {
        uninit_decoder_ptr(pDecoder);
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
        destroy_network_stream(pStream);
        pStream = nullptr;
#endif
    }
}

static void uninit_fading_out_slot_locked(AudioEngineHandle *e)
{
    if (e != nullptr && e->fadingOutDecoder != nullptr)
    {
        uninit_decoder_slot(
            e,
            e->fadingOutDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
            ,
            e->fadingOutStream
#endif
        );
        e->fadingOutDecoder = nullptr;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
        e->fadingOutStream = nullptr;
#endif
        // Never leave a stale abort ramp armed across fades
        e->crossfadeAbortActive.store(false, std::memory_order_release);
        e->crossfadeAbortFramesTotal.store(0, std::memory_order_relaxed);
        e->crossfadeAbortFramesDone.store(0, std::memory_order_relaxed);
        e->crossfadeSourceDead.store(false, std::memory_order_release);
        e->crossfadeStarveFrames.store(0, std::memory_order_relaxed);
        e->isCrossfading.store(false, std::memory_order_release);
    }
}

// Arms a short (~120 ms) graceful fade-out of an ACTIVE crossfade so a user
// skip doesn't hard-cut the outgoing track mid-fade. No-op when idle or
// already aborting. The outgoing decoder stays alive until the realtime
// mixer finishes the ramp; normal producer retirement then frees it.
static void request_crossfade_abort(AudioEngineHandle *e)
{
    if (e == nullptr ||
        e->fadingOutDecoder == nullptr ||
        !e->isCrossfading.load(std::memory_order_acquire))
    {
        return;
    }
    if (e->crossfadeAbortActive.load(std::memory_order_acquire))
    {
        return;
    }

    const ma_uint64 total = e->crossfadeFramesTotal.load(std::memory_order_relaxed);
    const ma_uint64 remaining = e->crossfadeFramesRemaining.load(std::memory_order_relaxed);
    double progress = 0.0;
    if (total > 0 && remaining <= total)
    {
        progress = (double)(total - remaining) / (double)total;
    }

    constexpr float halfPi = 1.57079632679f;
    // Perceived level of the outgoing track right now (matches mixer curve)
    const float startLevel = std::cos((float)progress * halfPi);

    const int sr = (e->sampleRate > 0) ? e->sampleRate : 48000;
    e->crossfadeAbortStartLevel.store(startLevel, std::memory_order_relaxed);
    e->crossfadeAbortFramesDone.store(0, std::memory_order_relaxed);
    e->crossfadeAbortFramesTotal.store((ma_uint64)((double)sr * 0.120), std::memory_order_release);
    e->crossfadeAbortActive.store(true, std::memory_order_release);
}



static bool load_decoder_for_path(
    AudioEngineHandle *e,
    const std::string &path,
    ma_decoder **outDecoder,
    ma_uint64 *outLength
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
    ,
    NetworkStreamState **outStream
#endif
    ,
    bool isPreload = false
)
{
    if (e == nullptr || outDecoder == nullptr || outLength == nullptr)
    {
        return false;
    }

    ma_uint32 outCh = (e->channels > 0) ? (ma_uint32)e->channels : 2;
    ma_uint32 targetRate = (e->engineSampleRate > 0)
                           ? (ma_uint32)e->engineSampleRate
                           : ((e->sampleRate > 0) ? (ma_uint32)e->sampleRate : 48000);
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, outCh, targetRate);
    if (e->resampleAlgorithm > 0)
    {
        cfg.resampling.algorithm = ma_resample_algorithm_custom;
        cfg.resampling.pBackendVTable = get_resampler_vtable_for_algorithm(e->resampleAlgorithm);
        cfg.resampling.pBackendUserData = &e->resampleAlgorithm;
    }
#if defined(SAUTIFLOW_ENABLE_FFMPEG) && SAUTIFLOW_ENABLE_FFMPEG
    static ma_decoding_backend_vtable *pCustomDecoders[] = {
        &g_ma_decoding_backend_vtable_mp4_aac,
        &g_ma_decoding_backend_vtable_ffmpeg
    };
    cfg.pCustomBackendUserData = nullptr;
    cfg.ppCustomBackendVTables = pCustomDecoders;
    cfg.customBackendCount = 2;
#else
    static ma_decoding_backend_vtable *pCustomDecoders[] = {
        &g_ma_decoding_backend_vtable_mp4_aac
    };
    cfg.pCustomBackendUserData = nullptr;
    cfg.ppCustomBackendVTables = pCustomDecoders;
    cfg.customBackendCount = 1;
#endif
    // Build a 200-point seek table for local files so seeking on 1-hour+ mixtapes is instant (<1ms).
    // Keep 0 for network URLs to prevent socket scanning overhead over HTTP.
    cfg.seekPointCount = is_network_url(path) ? 0 : 200;

    ma_decoder *tmp = new ma_decoder{};
    engine_log("decoder_init: %s (isPreload=%s, isNetwork=%s)",
               path.c_str(), isPreload ? "true" : "false", is_network_url(path) ? "true" : "false");

#if defined(_WIN32) || defined(_WIN64)
    std::wstring wpath = utf8_to_wstring(path);
    ma_result r = is_network_url(path)
                      ? ma_decoder_init_file(path.c_str(), &cfg, tmp)
                      : ma_decoder_init_file_w(wpath.c_str(), &cfg, tmp);
#else
    ma_result r = ma_decoder_init_file(path.c_str(), &cfg, tmp);
#endif
    if (r != MA_SUCCESS)
    {
        set_last_error(e, std::string("Failed to decode source: ") + path);
        engine_log("decoder_init failed (ma_result=%d) for: %s", (int)r, path.c_str());
        delete tmp;
        return false;
    }

    ma_uint64 len = 0;
    (void)ma_decoder_get_length_in_pcm_frames(tmp, &len);

    *outDecoder = tmp;
    *outLength = len;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
    if (outStream != nullptr)
        *outStream = nullptr;
#endif

    ma_format nativeFmt = ma_format_unknown;
    ma_uint32 nativeCh = 0;
    ma_uint32 nativeRate = 0;
    (void)ma_decoder_get_data_format(tmp, &nativeFmt, &nativeCh, &nativeRate, nullptr, 0);

    uint32_t srcRate = (nativeRate > 0) ? nativeRate : (uint32_t)tmp->outputSampleRate;
    engine_log("decoder_init_file success: %s | Native Rate=%u Hz | Assigned Target Rate=%u Hz (isPreload=%s)",
               path.c_str(), srcRate, targetRate, isPreload ? "true" : "false");
    clear_last_error(e);
    return true;
}

static void rebuild_play_order_locked(AudioEngineHandle *e)
{
    e->playOrder.resize(e->playlist.size());
    std::iota(e->playOrder.begin(), e->playOrder.end(), 0);

    if (e->shuffleEnabled && e->playOrder.size() > 1)
    {
        std::shuffle(e->playOrder.begin(), e->playOrder.end(), e->rng);
    }

    if (e->currentIndex >= 0 && !e->playOrder.empty())
    {
        auto it = std::find(e->playOrder.begin(), e->playOrder.end(), e->currentIndex);
        e->orderCursor = (it == e->playOrder.end()) ? 0 : (int)std::distance(e->playOrder.begin(), it);
    }
    else
    {
        e->orderCursor = e->playOrder.empty() ? -1 : 0;
    }
}

static int next_index_locked(AudioEngineHandle *e)
{
    if (e->playlist.empty())
        return -1;
    if (e->loopMode == AE_LOOP_ONE && e->currentIndex >= 0)
        return e->currentIndex;

    if (e->playOrder.empty())
    {
        rebuild_play_order_locked(e);
    }
    if (e->playOrder.empty())
        return -1;

    if (e->orderCursor < 0)
    {
        e->orderCursor = 0;
        return e->playOrder[0];
    }

    int nextPos = e->orderCursor + 1;
    if (nextPos >= (int)e->playOrder.size())
    {
        if (e->loopMode == AE_LOOP_OFF)
        {
            return -1;
        }
        nextPos = 0;
    }

    return e->playOrder[nextPos];
}

static int prev_index_locked(AudioEngineHandle *e)
{
    if (e->playlist.empty())
        return -1;
    if (e->loopMode == AE_LOOP_ONE && e->currentIndex >= 0)
        return e->currentIndex;

    if (e->playOrder.empty())
    {
        rebuild_play_order_locked(e);
    }
    if (e->playOrder.empty())
        return -1;

    if (e->orderCursor < 0)
    {
        e->orderCursor = 0;
        return e->playOrder[0];
    }

    int prevPos = e->orderCursor - 1;
    if (prevPos < 0)
    {
        if (e->loopMode == AE_LOOP_OFF)
        {
            return -1;
        }
        prevPos = (int)e->playOrder.size() - 1;
    }
    return e->playOrder[prevPos];
}

static void set_order_cursor_for_index_locked(AudioEngineHandle *e, int index)
{
    if (e->playOrder.empty())
    {
        rebuild_play_order_locked(e);
    }
    auto it = std::find(e->playOrder.begin(), e->playOrder.end(), index);
    e->orderCursor = (it == e->playOrder.end()) ? -1 : (int)std::distance(e->playOrder.begin(), it);
}

static void request_preload(AudioEngineHandle *e)
{
    std::lock_guard<std::mutex> lk(e->workerMutex);
    e->preloadRequested = true;
    e->workerCv.notify_one();
}

static void request_jump(AudioEngineHandle *e, int idx)
{
    std::lock_guard<std::mutex> lk(e->workerMutex);
    e->preloadGeneration.fetch_add(1, std::memory_order_relaxed);
    e->requestedIndex = idx;
    e->workerCv.notify_one();
}

static void worker_loop(AudioEngineHandle *e)
{
    while (true)
    {
        try
        {
            int jumpIndex = -1;
        bool doPreload = false;

        {
            std::unique_lock<std::mutex> lk(e->workerMutex);
            e->workerCv.wait(lk, [&]()
                             { return e->workerExit || (!e->rateTransitionInProgress.load(std::memory_order_acquire) && (e->requestedIndex >= 0 || e->preloadRequested)); });

            if (e->workerExit)
            {
                return;
            }

            if (e->rateTransitionInProgress.load(std::memory_order_acquire))
            {
                continue;
            }

            jumpIndex = e->requestedIndex;
            doPreload = e->preloadRequested;
            e->requestedIndex = -1;
            e->preloadRequested = false;
        }

        if (jumpIndex >= 0)
        {
            std::string path;
            int playlistCount = 0;
            {
                std::lock_guard<std::mutex> pl(e->playlistMutex);
                playlistCount = (int)e->playlist.size();
                if (jumpIndex < 0 || jumpIndex >= playlistCount)
                {
                    continue;
                }
                path = e->playlist[(size_t)jumpIndex];
            }

            ma_decoder *newCurrent = nullptr;
            ma_uint64 newCurrentLen = 0;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
            NetworkStreamState *newCurrentStream = nullptr;
#endif
            engine_log("worker jump request -> index=%d", jumpIndex);
            if (!load_decoder_for_path(
                    e,
                    path,
                    &newCurrent,
                    &newCurrentLen
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    ,
                    &newCurrentStream
#endif
                    ))
            {
                engine_log("worker jump failed to load index=%d", jumpIndex);
                continue;
            }

            int computedNextIndex = -1;

            {
                std::lock_guard<std::mutex> pl(e->playlistMutex);
                e->currentIndex = jumpIndex;
                set_order_cursor_for_index_locked(e, jumpIndex);
                computedNextIndex = next_index_locked(e);
            }

            // Auto Sample-Rate Match must be applied BEFORE acquiring decoderMutex:
            // restart_and_apply_config() locks decoderMutex internally, so calling it
            // while holding the non-recursive mutex would self-deadlock. This mirrors
            // the proven order used by execute_jump_direct().
            if (e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed) && newCurrent != nullptr)
            {
                const int nativeRate = (int)newCurrent->outputSampleRate;
                if (nativeRate > 0 && nativeRate != e->outputSampleRate)
                {
                    engine_log("Auto Sample-Rate Match: Track native rate is %d Hz (current DAC rate: %d Hz). Triggering full rate plan re-configuration...", nativeRate, e->outputSampleRate);
                    uninit_decoder_slot(
                        e,
                        newCurrent
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        , newCurrentStream
#endif
                    );
                    newCurrent = nullptr;
                    newCurrentLen = 0;
                    e->outputSampleRate = nativeRate;
                    restart_and_apply_config(e);
                    (void)load_decoder_for_path(
                        e,
                        path,
                        &newCurrent,
                        &newCurrentLen
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        , &newCurrentStream
#endif
                    );
                }
            }

            {
                std::lock_guard<std::mutex> d(e->decoderMutex);
                if (e->hasCurrent)
                {
                    uninit_decoder_slot(
                        e,
                        e->currentDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        ,
                        e->currentStream
#endif
                    );
                    e->hasCurrent = false;
                }
                if (e->hasNext)
                {
                    uninit_decoder_slot(
                        e,
                        e->nextDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        ,
                        e->nextStream
#endif
                    );
                    e->hasNext = false;
                }
                // Skip during an active crossfade: ramp the outgoing track out
                // gracefully instead of hard-cutting it. The producer thread
                // retires the outgoing decoder once the ramp completes.
                request_crossfade_abort(e);

                if (newCurrent != nullptr)
                {
                    ma_format nativeFmt = ma_format_unknown;
                    ma_uint32 nativeCh = 0;
                    ma_uint32 nativeRate = 0;
                    (void)ma_decoder_get_data_format(newCurrent, &nativeFmt, &nativeCh, &nativeRate, nullptr, 0);
                    uint32_t srcRate = (nativeRate > 0) ? nativeRate : (uint32_t)newCurrent->outputSampleRate;
                    AudioRatePlan plan = calculateRatePlan(
                        srcRate,
                        (uint32_t)e->deviceSampleRate,
                        (uint32_t)e->userOutputSampleRate,
                        e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed),
                        e->exclusiveModeEnabled.load(std::memory_order_relaxed)
                    );
                    applyRatePlan(e, plan);
                }

                e->currentDecoder = newCurrent;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                e->currentStream = newCurrentStream;
#endif
                e->currentLengthFrames = newCurrentLen;
                e->currentIndex = jumpIndex;
                e->hasCurrent = true;
                arm_transition_fade_in(e);

                ma_uint64 startFrame = 0;
                if (e->pendingSeekValid.load(std::memory_order_acquire) &&
                    e->pendingSeekIndex.load(std::memory_order_acquire) == jumpIndex)
                {
                    startFrame = e->pendingSeekFrame.load(std::memory_order_acquire);
                    const ma_result seekRc = ma_decoder_seek_to_pcm_frame(e->currentDecoder, startFrame);
                    if (seekRc != MA_SUCCESS)
                    {
                        engine_log("worker pending seek failed (ma_result=%d) index=%d", (int)seekRc, jumpIndex);
                        set_last_error(e, "Seek failed after jump.");
                    }
                    e->pendingSeekValid.store(false, std::memory_order_release);
                    e->pendingSeekIndex.store(-1, std::memory_order_release);
                }
                e->seekBasePcmFrame.store(startFrame, std::memory_order_release);
                e->playedPcmFrames.store(0, std::memory_order_release);

#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                e->nextStream = nullptr;
#endif
                e->nextDecoder = nullptr;
                e->nextIndex = -1;
                e->nextLengthFrames = 0;
                e->hasNext = false;
            }

            // Deferred auto-play: mark isPlaying=true NOW that the decoder is loaded.
            if (e->pendingAutoPlay.exchange(false, std::memory_order_acq_rel) ||
                e->isPlaying.load(std::memory_order_relaxed))
            {
                e->isPlaying.store(true, std::memory_order_relaxed);
                e->pcmRingBuffer.reset();
                e->decodeProducerCv.notify_one();
            }

            request_preload(e);
            engine_log("worker jump complete -> current=%d next=%d", jumpIndex, computedNextIndex);
        }

        if (doPreload)
        {
            uint64_t startGen = e->preloadGeneration.load(std::memory_order_relaxed);
            int localCurrentIndex = -1;
            {
                std::lock_guard<std::mutex> d(e->decoderMutex);
                localCurrentIndex = e->currentIndex;
                if (!e->hasCurrent || e->hasNext)
                {
                    continue;
                }
            }

            std::string nextPath;
            int nextIdx = -1;
            {
                std::lock_guard<std::mutex> pl(e->playlistMutex);
                if (e->playlist.size() <= 1 || localCurrentIndex < 0)
                {
                    continue;
                }
                set_order_cursor_for_index_locked(e, localCurrentIndex);
                nextIdx = next_index_locked(e);
                if (nextIdx < 0 || nextIdx == localCurrentIndex)
                {
                    continue;
                }
                nextPath = e->playlist[(size_t)nextIdx];
            }

            ma_decoder *decoded = nullptr;
            ma_uint64 len = 0;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
            NetworkStreamState *decodedStream = nullptr;
#endif
            if (!load_decoder_for_path(
                    e,
                    nextPath,
                    &decoded,
                    &len
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    ,
                    &decodedStream
#endif
                    ,
                    true // isPreload = true
                    ))
            {
                engine_log("worker preload failed -> nextIndex=%d", nextIdx);
                continue;
            }

            if (e->preloadGeneration.load(std::memory_order_relaxed) != startGen)
            {
                engine_log("worker preload discarded (stale generation) -> nextIndex=%d", nextIdx);
                uninit_decoder_slot(
                    e,
                    decoded
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    ,
                    decodedStream
#endif
                );
                continue;
            }

            {
                std::lock_guard<std::mutex> d(e->decoderMutex);
                if (e->preloadGeneration.load(std::memory_order_relaxed) == startGen &&
                    !e->hasNext && e->currentIndex == localCurrentIndex)
                {
                    e->nextDecoder = decoded;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    e->nextStream = decodedStream;
#endif
                    e->nextLengthFrames = len;
                    e->nextIndex = nextIdx;
                    e->hasNext = true;
                    engine_log("worker preload complete -> nextIndex=%d", nextIdx);
                }
                else
                {
                    engine_log("worker preload discarded -> nextIndex=%d", nextIdx);
                    uninit_decoder_slot(
                        e,
                        decoded
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        ,
                        decodedStream
#endif
                    );
                }
            }
        }
        }
        catch (...)
        {
            engine_log("worker_loop exception caught cleanly");
        }
    }
}

// Defers the end-of-track callback until decoderMutex is released.
// Invoking it while the producer thread holds decoderMutex lets the Dart
// handler re-enter any ae_* API that locks the same non-recursive mutex and
// self-deadlock. Declared as a loop-body local so every exit path (including
// `continue`) fires the callback after the lock guard has been destroyed.
struct DeferredEndCallback
{
    AudioEngineHandle *engine;
    AE_EndCallback callback = nullptr;
    void *userData = nullptr;

    explicit DeferredEndCallback(AudioEngineHandle *e) : engine(e) {}

    void arm()
    {
        if (engine != nullptr)
        {
            callback = engine->endCallback;
            userData = engine->pEndCallbackUserData;
        }
    }

    ~DeferredEndCallback()
    {
        if (callback != nullptr)
        {
            callback(userData, engine);
        }
    }
};

// Defined later in this file (inside the extern "C" section); used by the
// early crossfade trigger to align the fade start with what listeners hear.
extern "C" {
static double calculate_total_pipeline_latency_samples(AudioEngineHandle *e);
}

// Keeps the crossfade source ring topped up with pre-decoded old-track audio
// and retires the outgoing decoder once a fade finishes (or is aborted).
// Producer-thread only; must be invoked on EVERY loop iteration BEFORE any
// early-exit 'continue' (e.g. the pcmRingBuffer-full gate) so the realtime
// mixer never starves mid-fade.
static void service_crossfade_state(AudioEngineHandle *e, std::vector<float> &tempChunk)
{
    if (e == nullptr || tempChunk.empty())
        return;

    // Retire the old decoder once the fade is done. Decoder lifetime belongs
    // to threads that may hold decoderMutex - never to the realtime callback.
    if (!e->isCrossfading.load(std::memory_order_acquire) && e->fadingOutDecoder != nullptr)
    {
        std::lock_guard<std::mutex> d(e->decoderMutex);
        if (!e->isCrossfading.load(std::memory_order_acquire) && e->fadingOutDecoder != nullptr)
        {
            uninit_fading_out_slot_locked(e);
            e->crossfadeRingBuffer.reset();
            e->crossfadeSourceEof.store(false, std::memory_order_release);
        }
        return;
    }

    if (!e->isCrossfading.load(std::memory_order_acquire) ||
        e->crossfadeSourceEof.load(std::memory_order_relaxed) ||
        e->crossfadeSourceDead.load(std::memory_order_acquire))
    {
        return;
    }

    const size_t ch = (e->channels > 0) ? (size_t)e->channels : 2;
    std::lock_guard<std::mutex> d(e->decoderMutex);
    ma_decoder *fadeOut = e->fadingOutDecoder;
    if (fadeOut != nullptr)
    {
        const size_t wantFrames = 1024;
        const size_t availSamples = e->crossfadeRingBuffer.available_write();
        size_t fillFrames = std::min(wantFrames, availSamples / ch);
        if (fillFrames > 0)
        {
            ma_uint64 framesRead = 0;
            const ma_result rr = ma_decoder_read_pcm_frames(fadeOut, tempChunk.data(), (ma_uint64)fillFrames, &framesRead);
            if (framesRead > 0)
            {
                e->crossfadeRingBuffer.write(tempChunk.data(), (size_t)framesRead * ch);
            }
            if (rr == MA_AT_END || framesRead == 0)
            {
                e->crossfadeSourceEof.store(true, std::memory_order_release);
            }
        }
    }
    else
    {
        e->crossfadeSourceEof.store(true, std::memory_order_release);
    }
}

static void decode_producer_loop(AudioEngineHandle *e)
{
    sauti::dsp::ScopedDenormalsDisable denormalsScope;
    std::vector<float> tempChunk;
    tempChunk.resize(4096 * 2);

    while (!e->decodeProducerExit.load(std::memory_order_relaxed))
    {
        e->garbageQueue.drain();
        DeferredEndCallback deferredEnd(e);
        try
        {
            if (!e->isPlaying.load(std::memory_order_relaxed) ||
                e->ringBufferFlushing.load(std::memory_order_relaxed) ||
                e->rateTransitionInProgress.load(std::memory_order_acquire))
        {
            std::unique_lock<std::mutex> lk(e->decodeProducerMutex);
            e->decodeProducerCv.wait_for(lk, std::chrono::milliseconds(10));
            continue;
        }

        // Top up / retire the crossfade source BEFORE any of the early-exit
        // gates below: while the main ring is full the old path starved the
        // outgoing track, causing audible stutter during crossfades.
        service_crossfade_state(e, tempChunk);

        const size_t ch = (e->channels > 0) ? (size_t)e->channels : 2;
        const size_t targetChunkFrames = 1024;
        const size_t targetChunkSamples = targetChunkFrames * ch;

        if (e->pcmRingBuffer.available_write() < targetChunkSamples)
        {
            std::unique_lock<std::mutex> lk(e->decodeProducerMutex);
            e->decodeProducerCv.wait_for(lk, std::chrono::milliseconds(5));
            continue;
        }

        ma_uint32 produced = 0;
        {
            std::unique_lock<std::mutex> d(e->decoderMutex);

            // Lazy-init push stream decoder if needed
            if (e->isPushStreamMode && e->currentDecoder == nullptr && e->pushStreamForCurrent.initialized)
            {
                if (ma_rb_available_read(&e->pushStreamForCurrent.rb) >= 4096 || e->pushStreamForCurrent.isDone)
                {
                    ma_uint32 outCh = (e->channels > 0) ? (ma_uint32)e->channels : 2;
                    ma_decoder_config config = ma_decoder_config_init(ma_format_f32, outCh, (ma_uint32)e->sampleRate);
                    if (e->resampleAlgorithm > 0)
                    {
                        config.resampling.algorithm = ma_resample_algorithm_custom;
                        config.resampling.pBackendVTable = get_resampler_vtable_for_algorithm(e->resampleAlgorithm);
                        config.resampling.pBackendUserData = &e->resampleAlgorithm;
                    }
                    config.seekPointCount = 100;

                    auto *newDecoder = new ma_decoder{};
                    ma_result result = ma_decoder_init(push_stream_on_read, nullptr, &e->pushStreamForCurrent, &config, newDecoder);
                    if (result == MA_SUCCESS)
                    {
                        e->currentDecoder = newDecoder;
                        e->hasCurrent = true;
                    }
                    else
                    {
                        delete newDecoder;
                        d.unlock();
                        std::unique_lock<std::mutex> lk(e->decodeProducerMutex);
                        e->decodeProducerCv.wait_for(lk, std::chrono::milliseconds(10));
                        continue;
                    }
                }
                else
                {
                    d.unlock();
                    std::unique_lock<std::mutex> lk(e->decodeProducerMutex);
                    e->decodeProducerCv.wait_for(lk, std::chrono::milliseconds(10));
                    continue;
                }
            }

            if (!e->hasCurrent || e->currentDecoder == nullptr ||
                e->ringBufferFlushing.load(std::memory_order_relaxed) ||
                e->rateTransitionInProgress.load(std::memory_order_acquire))
            {
                d.unlock();
                std::unique_lock<std::mutex> lk(e->decodeProducerMutex);
                e->decodeProducerCv.wait_for(lk, std::chrono::milliseconds(10));
                continue;
            }

            // Early Crossfade Trigger
            if (e->crossfadeEnabled.load(std::memory_order_relaxed) && e->hasNext && !e->isCrossfading.load(std::memory_order_acquire))
            {
                ma_uint64 length = e->currentLengthFrames;
                if (length == 0 && e->currentDecoder != nullptr)
                {
                    ma_uint64 len = 0;
                    if (ma_decoder_get_length_in_pcm_frames(e->currentDecoder, &len) == MA_SUCCESS && len > 0)
                    {
                        e->currentLengthFrames = length = len;
                    }
                }
                if (length > 0)
                {
                    // Trigger on the AUDIBLE playback position, not the decode
                    // cursor: the decoder runs ahead of what listeners hear by
                    // whatever is pre-buffered in pcmRingBuffer (up to ~4 s).
                    // Using the decode cursor made the fade expire long before
                    // the old track audibly ended, so the next track appeared to
                    // start instantly with no fade-in.
                    const ma_uint64 baseFrame = e->seekBasePcmFrame.load(std::memory_order_relaxed);
                    const ma_uint64 played = e->playedPcmFrames.load(std::memory_order_relaxed);
                    const double latencySamples = calculate_total_pipeline_latency_samples(e);
                    const double effectivePosF = (double)(baseFrame + played);
                    const double audiblePosF = (effectivePosF > latencySamples) ? (effectivePosF - latencySamples) : 0.0;

                    if (audiblePosF <= (double)length)
                    {
                        const int durationMs = clampi(e->crossfadeDurationMs.load(std::memory_order_relaxed), 0, 10000);
                        const int sr = (e->sampleRate > 0) ? e->sampleRate : 48000;
                        const ma_uint64 fadeFrames = (ma_uint64)((double)sr * ((double)durationMs / 1000.0));
                        const ma_uint64 remain = length - (ma_uint64)audiblePosF;

                        if (fadeFrames > 0 && remain <= fadeFrames)
                        {
                            // Transfer the already-decoded old-track tail from
                            // the main ring into the crossfade source ring
                            // instead of rewinding the decoder: continuity is
                            // preserved sample-exactly for ANY source, including
                            // HTTP streams without range support and push/live
                            // streams that cannot seek. The decoder cursor sits
                            // exactly at the end of this buffered audio, so the
                            // producer's subsequent reads continue seamlessly.
                            e->crossfadeRingBuffer.reset();
                            e->ringBufferFlushing.store(true, std::memory_order_release);
                            {
                                size_t guard = 0;
                                while (guard++ < 256)
                                {
                                    const size_t want = tempChunk.size() / ch;
                                    const size_t room = e->crossfadeRingBuffer.available_write() / ch;
                                    if (room == 0)
                                        break;
                                    const size_t gotSamples = e->pcmRingBuffer.read(
                                        tempChunk.data(), std::min(want, room) * ch);
                                    if (gotSamples == 0)
                                        break;
                                    e->crossfadeRingBuffer.write(tempChunk.data(), gotSamples);
                                }
                                // Pending resampler input still belongs to the OLD
                                // stream; discard it so the new track decodes cleanly.
                                if (e->pitchResamplerInit)
                                {
                                    ma_resampler_reset(&e->pitchResampler);
                                    e->pitchInputUnconsumed = 0;
                                }
                                e->tempoProcessor.reset();
                                e->pcmRingBuffer.reset();
                            }
                            e->ringBufferFlushing.store(false, std::memory_order_release);

                            // Reset watchdog state for this fade
                            e->crossfadeSourceDead.store(false, std::memory_order_release);
                            e->crossfadeStarveFrames.store(0, std::memory_order_relaxed);

                            // Publish isCrossfading LAST (release) so the realtime
                            // reader can never observe stale audio or counters
                            // from a previous fade.
                            e->crossfadeSourceEof.store(false, std::memory_order_relaxed);
                            const ma_uint64 fadeLen = (remain > 0) ? remain : fadeFrames;
                            e->isCrossfading.store(true, std::memory_order_release);
                            e->crossfadeFramesTotal.store(fadeLen, std::memory_order_relaxed);
                            e->crossfadeFramesRemaining.store(fadeLen, std::memory_order_relaxed);

                            e->fadingOutReplayGain.store(e->currentTrackReplayGain.load(std::memory_order_relaxed), std::memory_order_relaxed);
                            e->currentTrackReplayGain.store(e->nextTrackReplayGain.load(std::memory_order_relaxed), std::memory_order_relaxed);

                            e->fadingOutDecoder = e->currentDecoder;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                            e->fadingOutStream = e->currentStream;
#endif

                            e->currentDecoder = e->nextDecoder;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                            e->currentStream = e->nextStream;
#endif
                            e->currentLengthFrames = e->nextLengthFrames;
                            e->currentIndex = e->nextIndex;
                            e->seekBasePcmFrame.store(0, std::memory_order_release);
                            e->playedPcmFrames.store(0, std::memory_order_release);

                            if (e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed) && e->currentDecoder != nullptr)
                            {
                                const int nativeRate = (int)e->currentDecoder->outputSampleRate;
                                if (nativeRate > 0 && nativeRate != e->outputSampleRate)
                                {
                                    engine_log("Auto Sample-Rate Match: Early crossfade track native rate is %d Hz (current hardware rate: %d Hz). Requesting deferred DAC switch...", nativeRate, e->outputSampleRate);
                                    e->pendingAutoSampleRateMatchRate.store(nativeRate, std::memory_order_release);
                                }
                            }

                            e->hasNext = false;
                            e->nextDecoder = nullptr;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                            e->nextStream = nullptr;
#endif
                            e->nextIndex = -1;
                            e->nextLengthFrames = 0;

                            if (e->endCallback != nullptr)
                            {
                                deferredEnd.arm();
                            }

                            request_preload(e);
                        }
                    }
                }
            }

            ma_uint64 framesRead = 0;
            const float rate = e->rateMultiplier.load(std::memory_order_relaxed);
            const float pitch = e->pitchMultiplier.load(std::memory_order_relaxed);
            const bool pitchCorrection = e->pitchCorrectionEnabled.load(std::memory_order_relaxed);
            ma_result r = MA_SUCCESS;

            float effectiveResampleRatio = 1.0f;
            float effectiveTempoScale = 1.0f;

            if (pitchCorrection)
            {
                // Scaletempo enabled: pitch shifted independently, speed stretched without pitch change
                effectiveResampleRatio = std::clamp(pitch, 0.05f, 10.0f);
                effectiveTempoScale = std::clamp(rate / effectiveResampleRatio, 0.05f, 10.0f);
            }
            else
            {
                // Scaletempo disabled: tape/vinyl mode (pitch & speed coupled)
                effectiveResampleRatio = std::clamp(rate * pitch, 0.05f, 10.0f);
                effectiveTempoScale = 1.0f;
            }

            const bool needResampler = (std::abs(effectiveResampleRatio - 1.0f) >= 0.001f);
            const bool needTempoScale = (std::abs(effectiveTempoScale - 1.0f) >= 0.001f);
            const int sr = (e->sampleRate > 0) ? e->sampleRate : 48000;

            if (needTempoScale)
            {
                if (!e->tempoProcessor.isInitialized() || e->tempoProcessor.getSampleRate() != sr || e->tempoProcessor.getChannels() != (int)ch)
                {
                    e->tempoProcessor.init(sr, (int)ch);
                }
                e->tempoProcessor.setScale(effectiveTempoScale);
            }

            if (tempChunk.size() < targetChunkFrames * ch * 2)
            {
                tempChunk.resize(targetChunkFrames * ch * 2);
            }

            if (needTempoScale && e->tempoProcessor.availableOutputFrames() >= targetChunkFrames)
            {
                framesRead = e->tempoProcessor.readOutput(tempChunk.data(), targetChunkFrames);
            }
            else
            {
                if (needResampler)
                {
                    if (!e->pitchResamplerInit || e->pitchResamplerRate != sr || e->pitchResamplerChannels != (int)ch)
                    {
                        if (e->pitchResamplerInit)
                        {
                            ma_resampler_uninit(&e->pitchResampler, nullptr);
                            e->pitchResamplerInit = false;
                        }
                        ma_resampler_config rcfg = ma_resampler_config_init(
                            ma_format_f32,
                            (ma_uint32)ch,
                            (ma_uint32)sr,
                            (ma_uint32)sr,
                            ma_resample_algorithm_linear);
                        if (ma_resampler_init(&rcfg, nullptr, &e->pitchResampler) == MA_SUCCESS)
                        {
                            e->pitchResamplerInit = true;
                            e->pitchResamplerRate = sr;
                            e->pitchResamplerChannels = (int)ch;
                            e->pitchResamplerCurrentPitch = 1.0f;
                        }
                        e->pitchInputBuffer.clear();
                        e->pitchInputUnconsumed = 0;
                    }

                    if (e->pitchResamplerInit)
                    {
                        if (std::abs(effectiveResampleRatio - e->pitchResamplerCurrentPitch) > 0.0001f)
                        {
                            ma_resampler_set_rate_ratio(&e->pitchResampler, effectiveResampleRatio);
                            e->pitchResamplerCurrentPitch = effectiveResampleRatio;
                        }

                        const ma_uint64 outNeeded = (ma_uint64)targetChunkFrames;
                        ma_uint64 inNeeded = 0;
                        ma_resampler_get_required_input_frame_count(&e->pitchResampler, outNeeded, &inNeeded);
                        if (inNeeded == 0) inNeeded = outNeeded;

                        size_t framesToRead = 0;
                        if ((size_t)inNeeded > e->pitchInputUnconsumed)
                        {
                            framesToRead = (size_t)inNeeded - e->pitchInputUnconsumed;
                        }

                        size_t requiredCapacityFrames = e->pitchInputUnconsumed + framesToRead;
                        size_t requiredCapacitySamples = requiredCapacityFrames * ch;
                        if (e->pitchInputBuffer.size() < requiredCapacitySamples)
                        {
                            e->pitchInputBuffer.resize(requiredCapacitySamples);
                        }

                        ma_uint64 inRead = 0;
                        if (framesToRead > 0)
                        {
                            r = ma_decoder_read_pcm_frames(
                                e->currentDecoder,
                                e->pitchInputBuffer.data() + (e->pitchInputUnconsumed * ch),
                                (ma_uint64)framesToRead,
                                &inRead);
                        }

                        ma_uint64 totalInFrames = e->pitchInputUnconsumed + inRead;
                        ma_uint64 outProcessed = outNeeded;
                        ma_uint64 inProcessed = totalInFrames;

                        float *destPtr = tempChunk.data();
                        if (needTempoScale)
                        {
                            if (e->tempoInputChunk.size() < outNeeded * ch)
                            {
                                e->tempoInputChunk.resize(outNeeded * ch);
                            }
                            destPtr = e->tempoInputChunk.data();
                        }

                        ma_resampler_process_pcm_frames(
                            &e->pitchResampler,
                            e->pitchInputBuffer.data(),
                            &inProcessed,
                            destPtr,
                            &outProcessed);

                        size_t unconsumedLeft = (totalInFrames > inProcessed) ? (size_t)(totalInFrames - inProcessed) : 0;
                        if (unconsumedLeft > 0 && inProcessed > 0)
                        {
                            std::memmove(
                                e->pitchInputBuffer.data(),
                                e->pitchInputBuffer.data() + (inProcessed * ch),
                                unconsumedLeft * ch * sizeof(float));
                        }
                        e->pitchInputUnconsumed = unconsumedLeft;

                        if (needTempoScale)
                        {
                            e->tempoProcessor.writeInput(e->tempoInputChunk.data(), outProcessed);
                            framesRead = e->tempoProcessor.readOutput(tempChunk.data(), targetChunkFrames);
                        }
                        else
                        {
                            framesRead = outProcessed;
                        }
                    }
                    else
                    {
                        r = ma_decoder_read_pcm_frames(
                            e->currentDecoder,
                            tempChunk.data(),
                            (ma_uint64)targetChunkFrames,
                            &framesRead);
                    }
                }
                else
                {
                    // No resampler needed
                    if (e->pitchResamplerInit && e->pitchResamplerCurrentPitch != 1.0f)
                    {
                        ma_resampler_reset(&e->pitchResampler);
                        e->pitchInputUnconsumed = 0;
                        e->pitchResamplerCurrentPitch = 1.0f;
                    }

                    if (needTempoScale)
                    {
                        if (e->tempoInputChunk.size() < targetChunkFrames * ch)
                        {
                            e->tempoInputChunk.resize(targetChunkFrames * ch);
                        }
                        ma_uint64 inRead = 0;
                        r = ma_decoder_read_pcm_frames(
                            e->currentDecoder,
                            e->tempoInputChunk.data(),
                            (ma_uint64)targetChunkFrames,
                            &inRead);
                        if (inRead > 0)
                        {
                            e->tempoProcessor.writeInput(e->tempoInputChunk.data(), inRead);
                        }
                        framesRead = e->tempoProcessor.readOutput(tempChunk.data(), targetChunkFrames);
                        if (framesRead == 0 && r == MA_AT_END && e->tempoProcessor.availableOutputFrames() > 0)
                        {
                            framesRead = e->tempoProcessor.readOutput(tempChunk.data(), targetChunkFrames);
                        }
                    }
                    else
                    {
                        if (e->tempoProcessor.availableOutputFrames() > 0)
                        {
                            framesRead = e->tempoProcessor.readOutput(tempChunk.data(), targetChunkFrames);
                        }
                        else
                        {
                            r = ma_decoder_read_pcm_frames(
                                e->currentDecoder,
                                tempChunk.data(),
                                (ma_uint64)targetChunkFrames,
                                &framesRead);
                        }
                    }
                }
            }

            produced = (ma_uint32)framesRead;
            e->engineAbsoluteTime.fetch_add(produced, std::memory_order_relaxed);

            // A-B Repeat automatic loop check
            if (e->abRepeatEnabled.load(std::memory_order_relaxed) && e->hasCurrent && e->currentDecoder != nullptr)
            {
                const double startSec = e->abStartSeconds.load(std::memory_order_relaxed);
                const double endSec = e->abEndSeconds.load(std::memory_order_relaxed);
                if (endSec > startSec)
                {
                    ma_uint64 cursor = 0;
                    if (ma_decoder_get_cursor_in_pcm_frames(e->currentDecoder, &cursor) == MA_SUCCESS)
                    {
                        int decSampleRate = (int)e->currentDecoder->outputSampleRate;
                        if (decSampleRate <= 0) decSampleRate = (e->sampleRate > 0) ? e->sampleRate : 48000;
                        const double currentSec = (double)cursor / (double)decSampleRate;
                        if (currentSec >= endSec)
                        {
                            const ma_uint64 targetFrameDec = (ma_uint64)(startSec * (double)decSampleRate);
                            const int engineSr = (e->sampleRate > 0) ? e->sampleRate : 48000;
                            const ma_uint64 targetFrameEngine = (ma_uint64)(startSec * (double)engineSr);

                            e->ringBufferFlushing.store(true, std::memory_order_release);
                            if (ma_decoder_seek_to_pcm_frame(e->currentDecoder, targetFrameDec) == MA_SUCCESS)
                            {
                                e->pcmRingBuffer.reset();
                                e->seekBasePcmFrame.store(targetFrameEngine, std::memory_order_release);
                                e->playedPcmFrames.store(0, std::memory_order_release);
                                if (e->pitchResamplerInit)
                                {
                                    ma_resampler_reset(&e->pitchResampler);
                                    e->pitchInputUnconsumed = 0;
                                }
                                e->tempoProcessor.reset();
                            }
                            e->ringBufferFlushing.store(false, std::memory_order_release);
                        }
                    }
                }
            }

            bool isRealEof = (r == MA_AT_END && framesRead == 0 && e->tempoProcessor.availableOutputFrames() == 0);
            if (!isRealEof && framesRead == 0 && e->currentDecoder != nullptr)
            {
                sautiflow::StreamTelemetry tel = sautiflow::get_stream_telemetry_from_decoder(e->currentDecoder);
                if (tel.state == sautiflow::StreamState::Ended)
                {
                    isRealEof = true;
                }
            }

            if (!isRealEof && framesRead == 0)
            {
                // Network stream buffering or transient underrun: wait briefly and retry without stopping playback
                std::unique_lock<std::mutex> lk(e->decodeProducerMutex);
                e->decodeProducerCv.wait_for(lk, std::chrono::milliseconds(10));
                continue;
            }

            if (isRealEof)
            {
                if (e->endCallback != nullptr)
                {
                    deferredEnd.arm();
                }

                if (e->hasNext)
                {
                    uninit_decoder_slot(
                        e,
                        e->currentDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        , e->currentStream
#endif
                    );
                    e->currentTrackReplayGain.store(e->nextTrackReplayGain.load(std::memory_order_relaxed), std::memory_order_relaxed);
                    e->currentDecoder = e->nextDecoder;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    e->currentStream = e->nextStream;
#endif
                    e->currentLengthFrames = e->nextLengthFrames;
                    e->currentIndex = e->nextIndex;
                    e->hasCurrent = true;
                    e->seekBasePcmFrame.store(0, std::memory_order_release);
                    e->playedPcmFrames.store(0, std::memory_order_release);
                    e->abRepeatEnabled.store(false, std::memory_order_release);

                    if (e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed) && e->currentDecoder != nullptr)
                    {
                        const int nativeRate = (int)e->currentDecoder->outputSampleRate;
                        if (nativeRate > 0 && nativeRate != e->outputSampleRate)
                        {
                            e->pendingAutoSampleRateMatchRate.store(nativeRate, std::memory_order_release);
                        }
                    }

                    e->hasNext = false;
                    e->nextDecoder = nullptr;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    e->nextStream = nullptr;
#endif
                    e->nextIndex = -1;
                    e->nextLengthFrames = 0;
                    arm_transition_fade_in(e);
                    request_preload(e);
                    continue;
                }

                if (e->loopMode == AE_LOOP_ONE && e->hasCurrent)
                {
                    (void)ma_decoder_seek_to_pcm_frame(e->currentDecoder, 0);
                    e->seekBasePcmFrame.store(0, std::memory_order_release);
                    e->playedPcmFrames.store(0, std::memory_order_release);
                    continue;
                }

                // If next track is not preloaded (e.g. for network streams), check if next track exists in playlist
                int autoNextIndex = -1;
                {
                    std::lock_guard<std::mutex> pl(e->playlistMutex);
                    if (e->currentIndex >= 0 && e->currentIndex < (int)e->playlist.size())
                    {
                        set_order_cursor_for_index_locked(e, e->currentIndex);
                        autoNextIndex = next_index_locked(e);
                    }
                }

                if (autoNextIndex >= 0 && autoNextIndex != e->currentIndex)
                {
                    uninit_decoder_slot(
                        e,
                        e->currentDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        , e->currentStream
#endif
                    );
                    e->currentDecoder = nullptr;
                    e->hasCurrent = false;
                    e->pendingAutoPlay.store(true, std::memory_order_relaxed);
                    request_jump(e, autoNextIndex);
                    continue;
                }

                // End of playlist
                e->isPlaying.store(false, std::memory_order_relaxed);
                continue;
            }
        }

        if (produced > 0)
        {
            e->pcmRingBuffer.write(tempChunk.data(), (size_t)produced * ch);
        }
        }
        catch (...)
        {
            engine_log("decode_producer_loop exception caught cleanly");
        }
    }
}

static void data_callback(ma_device *pDevice, void *pOutput, const void *, ma_uint32 frameCount)
{
    if (pDevice == nullptr || pOutput == nullptr || frameCount == 0)
        return;
    AudioEngineHandle *e = reinterpret_cast<AudioEngineHandle *>(pDevice->pUserData);
    if (e == nullptr)
        return;

    if (e->rateTransitionInProgress.load(std::memory_order_acquire))
    {
        const size_t outBytes = (size_t)frameCount * ma_get_bytes_per_frame(pDevice->playback.format, pDevice->playback.channels);
        std::memset(pOutput, 0, outBytes);
        return;
    }



    try
    {
        sauti::dsp::ScopedDenormalsDisable denormalsScope;
        float *processBuffer = nullptr;
    ma_uint32 totalSamples = frameCount * (ma_uint32)e->channels;

    if (e->outputFormat == AE_FORMAT_F32)
    {
        processBuffer = reinterpret_cast<float *>(pOutput);
    }
    else
    {
        size_t avail = e->conversionBuffer.size();
        if (avail < totalSamples)
        {
            totalSamples = (ma_uint32)avail;
        }
        processBuffer = e->conversionBuffer.data();
    }

    // Zero out buffer (silence)
    std::memset(processBuffer, 0, totalSamples * sizeof(float));

    if (!e->isPlaying.load(std::memory_order_relaxed))
    {
        const size_t outBytes = (size_t)frameCount * ma_get_bytes_per_frame(pDevice->playback.format, pDevice->playback.channels);
        std::memset(pOutput, 0, outBytes);
        return;
    }

    const ma_uint64 absTime = e->engineAbsoluteTime.load(std::memory_order_relaxed);
    const ma_uint64 startTime = e->scheduledStartTime.load(std::memory_order_relaxed);
    if (startTime != -1ULL && absTime < startTime)
    {
        const size_t outBytes = (size_t)frameCount * ma_get_bytes_per_frame(pDevice->playback.format, pDevice->playback.channels);
        std::memset(pOutput, 0, outBytes);
        e->engineAbsoluteTime.fetch_add(frameCount, std::memory_order_relaxed);
        return;
    }

    ma_uint32 produced = 0;
    const bool needsDeviceSRC = (e->engineSampleRate > 0 && e->deviceSampleRate > 0 && e->engineSampleRate != e->deviceSampleRate);

    if (!e->ringBufferFlushing.load(std::memory_order_relaxed))
    {
        if (!needsDeviceSRC)
        {
            size_t samplesNeeded = (size_t)frameCount * (size_t)e->channels;
            size_t samplesRead = e->pcmRingBuffer.read(processBuffer, samplesNeeded);
            produced = (ma_uint32)(samplesRead / (size_t)e->channels);

            if (samplesRead < samplesNeeded)
            {
                std::memset(processBuffer + samplesRead, 0, (samplesNeeded - samplesRead) * sizeof(float));
            }
        }
        else
        {
            // Explicit Engine-to-Device SRC Stage: Calculate input frames at engineSampleRate needed for frameCount frames at deviceSampleRate
            ma_uint64 inNeeded = (ma_uint64)std::ceil((double)frameCount * (double)e->engineSampleRate / (double)e->deviceSampleRate);
            size_t engineSamplesNeeded = (size_t)inNeeded * (size_t)e->channels;
            if (e->engineProcessBuffer.size() < engineSamplesNeeded)
            {
                engineSamplesNeeded = e->engineProcessBuffer.size();
            }

            size_t samplesRead = e->pcmRingBuffer.read(e->engineProcessBuffer.data(), engineSamplesNeeded);
            produced = (ma_uint32)(samplesRead / (size_t)e->channels);

            if (samplesRead < engineSamplesNeeded)
            {
                std::memset(e->engineProcessBuffer.data() + samplesRead, 0, (engineSamplesNeeded - samplesRead) * sizeof(float));
            }

            processBuffer = e->engineProcessBuffer.data();
        }

        std::unique_lock<std::mutex> lk(e->decodeProducerMutex);
        e->decodeProducerCv.notify_one();
    }

    if (produced > 0)
    {
        const float curRate = e->rateMultiplier.load(std::memory_order_relaxed);
        const ma_uint64 sourceAdvance = (std::abs(curRate - 1.0f) < 0.001f)
                                        ? (ma_uint64)produced
                                        : (ma_uint64)std::round((double)produced * (double)curRate);
        e->playedPcmFrames.fetch_add(sourceAdvance, std::memory_order_relaxed);
        // Telemetry: count realtime starvation honestly.
        if (produced < frameCount)
        {
            e->underrunCount.fetch_add(frameCount - produced, std::memory_order_relaxed);
        }
        ma_uint64 fadeRemaining = e->crossfadeFramesRemaining.load(std::memory_order_relaxed);
        const ma_uint64 fadeTotal = e->crossfadeFramesTotal.load(std::memory_order_relaxed);
        
        // MIXING FADEOUT DECODER (if active).
        // The old track is decoded by decode_producer_loop into
        // crossfadeRingBuffer; here we only consume pre-decoded samples.
        // The realtime thread must never run codec decode or touch decoders:
        // both cause glitches exactly when crossfading network streams.
        if (e->isCrossfading.load(std::memory_order_acquire)) {
            if (e->fadingOutDecoder != nullptr) {
                // Stall watchdog: once the source is latched dead (network
                // stall / dropped connection), stop reading the sputtering
                // ring entirely - the fade completes as a clean fade-in.
                const bool sourceDead = e->crossfadeSourceDead.load(std::memory_order_acquire);

                // Read pre-decoded old-track audio from the SPSC ring (lock-free)
                size_t neededMixSamples = (size_t)produced * (size_t)e->channels;
                if (e->crossfadeMixBuffer.size() < neededMixSamples)
                {
                    neededMixSamples = e->crossfadeMixBuffer.size();
                }
                size_t gotSamples = 0;
                if (!sourceDead)
                {
                    gotSamples = e->crossfadeRingBuffer.read(e->crossfadeMixBuffer.data(), neededMixSamples);
                }
                const ma_uint64 oldFramesRead = gotSamples / (size_t)e->channels;
                std::fill(e->crossfadeMixBuffer.begin() + gotSamples,
                          e->crossfadeMixBuffer.begin() + neededMixSamples, 0.0f);
                float *mixBuf = e->crossfadeMixBuffer.data();

                // Starvation accounting: silence gaps on the outgoing track are
                // masked while tOut is low, but intermittent chunks early in the
                // fade stutter audibly. Latch after ~250 ms of nothing.
                if (!sourceDead && gotSamples == 0 &&
                    !e->crossfadeSourceEof.load(std::memory_order_acquire))
                {
                    const ma_uint32 starved =
                        e->crossfadeStarveFrames.fetch_add(produced, std::memory_order_relaxed) + produced;
                    const int srForWatchdog = (e->sampleRate > 0) ? e->sampleRate : 48000;
                    if (starved > (ma_uint32)(srForWatchdog / 4))
                    {
                        e->crossfadeSourceDead.store(true, std::memory_order_release);
                        engine_log("Crossfade: outgoing source stalled; completing fade as fade-in.");
                    }
                }
                else if (gotSamples > 0)
                {
                    e->crossfadeStarveFrames.store(0, std::memory_order_relaxed);
                }

                const bool loudnessAware = e->loudnessCrossfadeEnabled.load(std::memory_order_relaxed);
                const float outGain = loudnessAware ? e->fadingOutReplayGain.load(std::memory_order_relaxed) : 1.0f;
                const float inGain  = loudnessAware ? e->currentTrackReplayGain.load(std::memory_order_relaxed) : 1.0f;

                // Graceful-abort ramp (user skipped mid-fade): the outgoing
                // track follows a linear envelope from its current perceived
                // level to zero instead of the cosine curve.
                const bool aborting = e->crossfadeAbortActive.load(std::memory_order_acquire);
                const float abortStartLevel = aborting ? e->crossfadeAbortStartLevel.load(std::memory_order_relaxed) : 0.0f;
                const ma_uint64 abortFramesTotal = aborting ? e->crossfadeAbortFramesTotal.load(std::memory_order_relaxed) : 0;
                ma_uint64 abortFramesDone = aborting ? e->crossfadeAbortFramesDone.load(std::memory_order_relaxed) : 0;

                const ma_uint64 processed = (fadeTotal > fadeRemaining) ? (fadeTotal - fadeRemaining) : 0;
                constexpr float halfPi = 1.57079632679f;
                for (ma_uint32 i = 0; i < produced && fadeRemaining > 0; ++i)
                {
                    const float t = clampf((float)(processed + (ma_uint64)i) / (float)fadeTotal, 0.0f, 1.0f);
                    const float tIn = std::sin(t * halfPi);

                    float outEnv;
                    if (aborting && abortFramesTotal > 0)
                    {
                        outEnv = abortStartLevel * (1.0f - (float)abortFramesDone / (float)abortFramesTotal);
                        outEnv = clampf(outEnv, 0.0f, 1.0f);
                        abortFramesDone += 1;
                    }
                    else
                    {
                        outEnv = std::cos(t * halfPi);
                    }

                    const size_t base = (size_t)i * (size_t)e->channels;
                    for (int c = 0; c < e->channels; ++c)
                    {
                        // If the ring supplied frames from the old track, add them with loudness gain alignment
                        float outSample = (i < oldFramesRead) ? (mixBuf[base + (size_t)c] * outGain) : 0.0f;
                        float inSample  = processBuffer[base + (size_t)c] * inGain;
                        processBuffer[base + (size_t)c] = (inSample * tIn) + (outSample * outEnv);
                    }
                    fadeRemaining -= 1;
                }
                e->crossfadeFramesRemaining.store(fadeRemaining, std::memory_order_release);

                bool endCrossfade = false;
                if (aborting)
                {
                    e->crossfadeAbortFramesDone.store((abortFramesDone < abortFramesTotal) ? abortFramesDone : abortFramesTotal, std::memory_order_release);
                    // A zero-length ramp can't make progress in the sample loop
                    // (e.g. fade counters were re-armed to 0); end immediately
                    // rather than leaving a stale abort flag behind.
                    if (abortFramesTotal == 0 || abortFramesDone >= abortFramesTotal)
                    {
                        e->crossfadeAbortActive.store(false, std::memory_order_release);
                        e->crossfadeAbortFramesTotal.store(0, std::memory_order_relaxed);
                        endCrossfade = true;
                    }
                }
                else if (fadeRemaining == 0 ||
                         (gotSamples == 0 && e->crossfadeSourceEof.load(std::memory_order_acquire)))
                {
                    endCrossfade = true;
                }

                if (endCrossfade)
                {
                    // Crossfade complete. Decoder teardown is handled by the
                    // producer thread (it owns decoder lifetime); the realtime
                    // side only drops out of the mixing path.
                    e->isCrossfading.store(false, std::memory_order_release);
                }
            }
        } 
        else if (fadeRemaining > 0 && fadeTotal > 0)
        {
            // Simple gapless fade-in (e.g. from seek or if crossfading is disabled/unsupported for this track)
            const ma_uint64 processed = (fadeTotal > fadeRemaining) ? (fadeTotal - fadeRemaining) : 0;
            constexpr float halfPi = 1.57079632679f;
            for (ma_uint32 i = 0; i < produced && fadeRemaining > 0; ++i)
            {
                const float t = clampf((float)(processed + (ma_uint64)i) / (float)fadeTotal, 0.0f, 1.0f);
                const float tIn = std::sin(t * halfPi);
                const size_t base = (size_t)i * (size_t)e->channels;
                for (int c = 0; c < e->channels; ++c)
                {
                    processBuffer[base + (size_t)c] *= tIn;
                }
                fadeRemaining -= 1;
            }
            e->crossfadeFramesRemaining.store(fadeRemaining, std::memory_order_relaxed);
        }

        std::lock_guard<std::mutex> fx(e->fxMutex);

        // Master Volume & Gain Stage (user gain × replay gain × loudness-normalizer gain)
        // Computed in 64-bit float (double precision) so that low-volume listening
        // preserves dynamic range before the downstream TPDF/noise-shaped dither stage.
        {
            const bool use64 = e->use64BitProcessing.load(std::memory_order_relaxed) ||
                               e->exclusiveModeEnabled.load(std::memory_order_relaxed) ||
                               (e->outputFormat == AE_FORMAT_S16 || e->outputFormat == AE_FORMAT_S24);
            const bool crossfadeMixing = e->isCrossfading.load(std::memory_order_relaxed) &&
                                         e->loudnessCrossfadeEnabled.load(std::memory_order_relaxed);
            const float rg = crossfadeMixing ? 1.0f : e->replayGainLinear.load(std::memory_order_relaxed);

            // User master gain rides AutomatedParamFloat so UI volume
            // changes ramp smoothly instead of stepping block-wise.
            e->paramUserGain.setTarget(e->gain.load(std::memory_order_relaxed));

            // Loudness Normalizer: rides output gain toward the user target
            // (BS.1770 integrated LUFS). Bypassed during loudness-aware
            // crossfade mixing, where per-track ReplayGains already align
            // loudness; AutomatedParamFloat re-ramps it smoothly afterwards.
            float normTarget = 1.0f;
            if (!crossfadeMixing &&
                e->loudnessMeter.normalizerEnabled.load(std::memory_order_relaxed))
            {
                normTarget = e->loudnessMeter.getNormalizerGainLinear();
            }
            e->paramNormalizerGain.setTarget(normTarget);
            // next() is consumed per sample below, so ramp over the full
            // sample count to keep the smoothing-time semantics correct.
            const size_t totalSamples = (size_t)produced * (size_t)e->channels;
            e->paramUserGain.prepareBlock((ma_uint32)totalSamples,
                                          e->parameterSmoothingMs.load(std::memory_order_relaxed),
                                          e->sampleRate);
            e->paramNormalizerGain.prepareBlock((ma_uint32)totalSamples,
                                                e->parameterSmoothingMs.load(std::memory_order_relaxed),
                                                e->sampleRate);

            const bool normActive = std::fabs(e->paramNormalizerGain.current - 1.0f) > 1e-4f ||
                                    std::fabs(normTarget - 1.0f) > 1e-4f;
            const float userGainTarget = e->paramUserGain.getTarget();
            const bool userGainActive = std::fabs(e->paramUserGain.current - userGainTarget) > 1e-6f ||
                                        std::fabs(userGainTarget - 1.0f) > 1e-6f;

            if (normActive)
            {
                if (use64)
                {
                    for (size_t i = 0; i < totalSamples; ++i)
                        processBuffer[i] = (float)((double)processBuffer[i] *
                                                   (double)e->paramUserGain.next() *
                                                   (double)rg *
                                                   (double)e->paramNormalizerGain.next());
                }
                else
                {
                    for (size_t i = 0; i < totalSamples; ++i)
                        processBuffer[i] *= e->paramUserGain.next() * rg * e->paramNormalizerGain.next();
                }
            }
            else if (userGainActive)
            {
                if (use64)
                {
                    for (size_t i = 0; i < totalSamples; ++i)
                        processBuffer[i] = (float)((double)processBuffer[i] *
                                                   (double)e->paramUserGain.next() *
                                                   (double)rg);
                }
                else
                {
                    for (size_t i = 0; i < totalSamples; ++i)
                        processBuffer[i] *= e->paramUserGain.next() * rg;
                }
            }
            else if (rg != 1.0f)
            {
                if (use64)
                {
                    const double rg64 = (double)rg;
                    for (size_t i = 0; i < totalSamples; ++i)
                        processBuffer[i] = (float)((double)processBuffer[i] * rg64);
                }
                else
                {
                    for (size_t i = 0; i < totalSamples; ++i)
                        processBuffer[i] *= rg;
                }
            }
        }

        // Per-Channel Gain (L/R independent trim)
        {
            const float lg = e->channelGainLeft.load(std::memory_order_relaxed);
            const float rg = e->channelGainRight.load(std::memory_order_relaxed);
            if (e->channels >= 2 && (lg != 1.0f || rg != 1.0f))
            {
                for (ma_uint32 i = 0; i < produced; ++i)
                {
                    processBuffer[i * (size_t)e->channels + 0] = (float)((double)processBuffer[i * (size_t)e->channels + 0] * (double)lg);
                    processBuffer[i * (size_t)e->channels + 1] = (float)((double)processBuffer[i * (size_t)e->channels + 1] * (double)rg);
                }
            }
        }

        const bool bypassAppDsp = e->exclusiveModeEnabled.load(std::memory_order_relaxed) &&
                                 !e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed);

        if (!bypassAppDsp)
        {
            const bool use64 = e->use64BitProcessing.load(std::memory_order_relaxed);

            // Custom Fading (Wait Fade)
            if (e->customFadeArmed.load(std::memory_order_acquire))
            {
                ma_uint64 fadeRemaining = e->customFadeFramesRemaining.load(std::memory_order_relaxed);
                ma_uint64 fadeTotal = e->customFadeFramesTotal.load(std::memory_order_relaxed);
                if (fadeRemaining > 0 && fadeTotal > 0)
                {
                    const float volBeg = e->customFadeVolumeBeg.load(std::memory_order_relaxed);
                    const float volEnd = e->customFadeVolumeEnd.load(std::memory_order_relaxed);

                    ma_uint64 processed = (fadeTotal > fadeRemaining) ? (fadeTotal - fadeRemaining) : 0;
                    for (ma_uint32 i = 0; i < produced && fadeRemaining > 0; ++i)
                    {
                        const size_t base = (size_t)i * (size_t)e->channels;
                        if (use64)
                        {
                            const double t64 = clampd((double)(processed + (ma_uint64)i) / (double)fadeTotal, 0.0, 1.0);
                            const double currentVol64 = (double)volBeg + ((double)volEnd - (double)volBeg) * t64;
                            for (int c = 0; c < e->channels; ++c)
                            {
                                processBuffer[base + (size_t)c] = (float)((double)processBuffer[base + (size_t)c] * currentVol64);
                            }
                        }
                        else
                        {
                            const float t = clampf((float)(processed + (ma_uint64)i) / (float)fadeTotal, 0.0f, 1.0f);
                            const float currentVol = volBeg + (volEnd - volBeg) * t;
                            for (int c = 0; c < e->channels; ++c)
                            {
                                processBuffer[base + (size_t)c] *= currentVol;
                            }
                        }
                        fadeRemaining -= 1;
                    }
                    e->customFadeFramesRemaining.store(fadeRemaining, std::memory_order_relaxed);
                    if (fadeRemaining == 0)
                    {
                        e->customFadeArmed.store(false, std::memory_order_release);
                    }
                }
            }

            // Pan (Assume Stereo or more)
            const float panVal = e->pan.load(std::memory_order_relaxed);
            if (e->channels >= 2 && panVal != 0.0f)
            {
                if (use64)
                {
                    const double p = (double)panVal;
                    const double l = clampd(1.0 - std::max(0.0, p), 0.0, 1.0);
                    const double r = clampd(1.0 + std::min(0.0, p), 0.0, 1.0);
                    for (ma_uint32 i = 0; i < produced; ++i)
                    {
                        processBuffer[i * e->channels]     = (float)((double)processBuffer[i * e->channels] * l);
                        processBuffer[i * e->channels + 1] = (float)((double)processBuffer[i * e->channels + 1] * r);
                    }
                }
                else
                {
                    const float p = panVal;
                    const float l = clampf(1.0f - std::max(0.0f, p), 0.0f, 1.0f);
                    const float r = clampf(1.0f + std::min(0.0f, p), 0.0f, 1.0f);
                    for (ma_uint32 i = 0; i < produced; ++i)
                    {
                        processBuffer[i * e->channels]     *= l;
                        processBuffer[i * e->channels + 1] *= r;
                    }
                }
            }

            // Subsonic DC / Infrasonic Rumble Clean-Room Filter (18 Hz Butterworth HPF)
            e->subsonicFilter.process(processBuffer, produced, e->channels);

            if (e->crossfeedEnabled)
            {
                e->crossfeedNode.process(processBuffer, produced, e->channels);
            }

            // Stereo Widen
            if (e->stereoWidenEnabled)
            {
                e->stereoWiden.process(processBuffer, produced, e->channels);
            }

            // JamesDSP Stereo Enhancement
            if (e->stereoEnhancementEnabled)
            {
                e->stereoEnhancement.process(processBuffer, produced, e->channels);
            }

            // Crystalizer (transient edge reconstruction + air shelf)
            if (e->crystalizerEnabled)
            {
                e->crystalizer.process(processBuffer, produced, e->channels);
            }

            // Reverb (Freeverb-style FDN)
            if (e->reverbEnabled)
            {
                e->reverbNode.process(processBuffer, produced, e->channels);
            }

            // Multiband EQ and mixed multiband FX
            std::lock_guard<std::mutex> eqLock(e->eqMutex);
            if (e->multibandEqEnabled)
            {
                e->process_multiband_eq(processBuffer, produced, e->channels);
            }
            if (e->multibandFxEnabled)
            {
                e->process_multiband_fx(processBuffer, produced);
            }

            // 3-band EQ
            if (e->eqEnabled)
                e->eq.process(processBuffer, produced, e->channels);

            // Native Clean-Room Audio DSP Suite.
            // The ae_dsp_set_* setters mutate these objects under dspMutex on the
            // control thread; the realtime side must synchronize with them or read
            // torn coefficients/state. Use try_lock so the audio thread never
            // blocks on a contended setter - it simply bypasses for one block.
            if (e->channels >= 2)
            {
                std::unique_lock<std::mutex> dspLock(e->dspMutex, std::try_to_lock);
                if (dspLock.owns_lock())
                {
                    e->downwardExpanderDsp.process(processBuffer, produced);
                    e->harmonicBassDsp.process(processBuffer, produced);
                    e->dynamicSystemDsp.process(processBuffer, produced);
                    e->analogWarmthDsp.process(processBuffer, produced);
                    e->dialogEnhancerDsp.process(processBuffer, produced);
                    e->clarityDsp.process(processBuffer, produced);
                    e->deEsserDsp.process(processBuffer, produced);
                    if (e->channels == 2)
                    {
                        e->surroundDsp.process(processBuffer, produced);
                    }
                    e->fftConvolverDsp.process(processBuffer, produced);
                    e->masterLimiterDsp.process(processBuffer, produced);
                }
            }

            // Dynamic Range Compressor (runs before the limiters so they catch overshoot)
            if (e->compressorEnabled)
            {
                e->compressor.process(processBuffer, produced, e->channels, e->engineSampleRate);
            }

            // Limiter & Clipping Detection (run at the end of the chain before format conversion)
            if (e->lookaheadLimiterEnabled.load(std::memory_order_relaxed))
            {
                e->lookaheadLimiter.process(processBuffer, produced, e->channels, e->engineSampleRate);
            }
            else if (e->limiterEnabled)
            {
                e->limiter.process(processBuffer, produced, e->channels);
            }
        } // End of !bypassAppDsp block

        // Read-only Metering Subsystems (Post-DSP / Pre-Output)
        // The BS.1770 meter also feeds the Loudness Normalizer, so it must run
        // whenever the normalizer is enabled even if the meter UI toggle is off.
        if (e->loudnessMeterEnabled.load(std::memory_order_relaxed) ||
            e->loudnessMeter.normalizerEnabled.load(std::memory_order_relaxed))
        {
            e->loudnessMeter.process(processBuffer, produced, e->channels);
        }
        if (e->truePeakMeterEnabled.load(std::memory_order_relaxed))
        {
            e->truePeakMeter.process(processBuffer, produced, e->channels);
        }

        e->capture_analyzer_frames(processBuffer, produced, e->channels);

        if (e->clippingDetectionEnabled.load(std::memory_order_relaxed))
        {
            uint64_t clippedCountLocal = 0;
            const size_t numSamplesCheck = produced * e->channels;
            for (size_t i = 0; i < numSamplesCheck; ++i)
            {
                if (processBuffer[i] > 1.0f || processBuffer[i] < -1.0f)
                {
                    clippedCountLocal++;
                }
            }
            if (clippedCountLocal > 0)
            {
                e->clippedSamplesCount.fetch_add(clippedCountLocal, std::memory_order_relaxed);
            }
        }
    }

    // Phase Inversion (Polarity Flip) + L/R Swap - applied to output frames
    {
        const bool invL  = e->phaseInvertLeft.load(std::memory_order_relaxed);
        const bool invR  = e->phaseInvertRight.load(std::memory_order_relaxed);
        const bool doSwap = e->lrSwapEnabled.load(std::memory_order_relaxed);
        const int ch = (e->channels > 0) ? e->channels : 2;
        if (invL || invR)
        {
            for (ma_uint32 i = 0; i < produced; ++i)
            {
                if (invL)
                    processBuffer[i * (size_t)ch + 0] = -processBuffer[i * (size_t)ch + 0];
                if (ch > 1 && invR)
                    processBuffer[i * (size_t)ch + 1] = -processBuffer[i * (size_t)ch + 1];
            }
        }
        // L/R Swap: exchange left and right channels (applied after polarity so they compose correctly)
        if (doSwap && ch >= 2)
        {
            for (ma_uint32 i = 0; i < produced; ++i)
            {
                float tmp = processBuffer[i * (size_t)ch + 0];
                processBuffer[i * (size_t)ch + 0] = processBuffer[i * (size_t)ch + 1];
                processBuffer[i * (size_t)ch + 1] = tmp;
            }
        }
    }

    // Explicit Engine-to-Device Output Resampling Stage (if engineSampleRate != deviceSampleRate)
    float *finalDstBuffer = (e->outputFormat == AE_FORMAT_F32) ? reinterpret_cast<float *>(pOutput) : e->conversionBuffer.data();

    if (needsDeviceSRC)
    {
        std::lock_guard<std::mutex> rLock(e->deviceResamplerMutex);
        if (e->deviceResamplerInit)
        {
            ma_uint64 inFrames = (ma_uint64)produced;
            ma_uint64 outFrames = (ma_uint64)frameCount;
            ma_resampler_process_pcm_frames(&e->deviceResampler, processBuffer, &inFrames, finalDstBuffer, &outFrames);
        }
        else
        {
            std::memcpy(finalDstBuffer, processBuffer, std::min<size_t>((size_t)produced, (size_t)frameCount) * (size_t)e->channels * sizeof(float));
        }
    }
    else
    {
        finalDstBuffer = processBuffer;
    }

    // Dithering & Format Conversion
    AEAudioFormat activeIntFormat = e->outputFormat;
    if (activeIntFormat == AE_FORMAT_F32)
    {
        if (pDevice->playback.format == ma_format_s16)
            activeIntFormat = AE_FORMAT_S16;
        else if (pDevice->playback.format == ma_format_s24)
            activeIntFormat = AE_FORMAT_S24;
        else if (pDevice->playback.format == ma_format_s32)
            activeIntFormat = AE_FORMAT_S32;
        else if (pDevice->playback.format == ma_format_u8)
            activeIntFormat = AE_FORMAT_U8;
    }

    const int ditherVal = e->ditherMode.load(std::memory_order_relaxed);
    int effectiveDither = ditherVal;

    // In integer exclusive modes (int16/int24), if volume is attenuated / non-unity,
    // ensure TPDF dither is active so low-volume listening doesn't quantize badly.
    if (effectiveDither == 0 && activeIntFormat != AE_FORMAT_F32)
    {
        const bool isIntExclusive = e->exclusiveModeEnabled.load(std::memory_order_relaxed) ||
                                    (activeIntFormat == AE_FORMAT_S16 || activeIntFormat == AE_FORMAT_S24);
        // Any gain stage that scales samples before quantization can cause
        // correlated truncation distortion at low levels: user master gain,
        // replay gain, loudness normalizer, L/R channel trim, and pan.
        // (Fades/crossfades are transient envelopes, not steady-state
        // attenuation, so they are excluded.)
        const bool isVolumeAttenuated = std::fabs(e->paramUserGain.current - 1.0f) > 1e-4f ||
                                       std::fabs(e->gain.load(std::memory_order_relaxed) - 1.0f) > 1e-4f ||
                                       (e->replayGainLinear.load(std::memory_order_relaxed) != 1.0f) ||
                                       std::fabs(e->paramNormalizerGain.current - 1.0f) > 1e-4f ||
                                       (e->loudnessMeter.normalizerEnabled.load(std::memory_order_relaxed) &&
                                        std::fabs(e->loudnessMeter.getNormalizerGainLinear() - 1.0f) > 1e-4f) ||
                                       std::fabs(e->channelGainLeft.load(std::memory_order_relaxed) - 1.0f) > 1e-4f ||
                                       std::fabs(e->channelGainRight.load(std::memory_order_relaxed) - 1.0f) > 1e-4f ||
                                       (e->pan.load(std::memory_order_relaxed) != 0.0f);
        if (isIntExclusive && isVolumeAttenuated)
        {
            effectiveDither = 2; // Mode 2: Triangle (TPDF 2.0 LSB p-p)
        }
    }

    if (effectiveDither > 0 && activeIntFormat != AE_FORMAT_F32)
    {
        e->ditherProcessor.process(effectiveDither, activeIntFormat, finalDstBuffer, totalSamples, e->channels);
    }

    if (pDevice->playback.format == ma_format_s16)
    {
        ma_pcm_f32_to_s16(pOutput, finalDstBuffer, totalSamples, ma_dither_mode_none);
    }
    else if (pDevice->playback.format == ma_format_u8)
    {
        ma_pcm_f32_to_u8(pOutput, finalDstBuffer, totalSamples, ma_dither_mode_none);
    }
    else if (pDevice->playback.format == ma_format_s24)
    {
        ma_pcm_f32_to_s24(pOutput, finalDstBuffer, totalSamples, ma_dither_mode_none);
    }
    else if (pDevice->playback.format == ma_format_s32)
    {
        ma_pcm_f32_to_s32(pOutput, finalDstBuffer, totalSamples, ma_dither_mode_none);
    }
    else if (pDevice->playback.format == ma_format_f32)
    {
        std::memcpy(pOutput, finalDstBuffer, totalSamples * sizeof(float));
    }
    // else F32 -> already in pOutput via finalDstBuffer!
    }
    catch (...)
    {
        // Silence the device buffer using its real negotiated format size.
        // Assuming F32 here overruns the buffer by 2-4x when the device runs
        // S16/U8/S24 formats (heap corruption).
        std::memset(pOutput, 0, (size_t)frameCount * ma_get_bytes_per_frame(pDevice->playback.format, pDevice->playback.channels));
    }
}

#if defined(__ANDROID__)
    #include <jni.h>
    #include <sys/system_properties.h>
    #include <sys/resource.h>
    #include <unistd.h>
    #include <cctype>

    static JavaVM* g_androidJavaVM = nullptr;

    extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved)
    {
        (void)reserved;
        g_androidJavaVM = vm;
        return JNI_VERSION_1_6;
    }

    AE_API void ae_register_android_jvm(void *vm)
    {
        if (vm) g_androidJavaVM = (JavaVM*)vm;
    }

    static void detect_universal_hardware_dsp(AEHardwareInfo* info)
    {
        if (!info) return;

        char platform[PROP_VALUE_MAX] = {0};
        char soc_model[PROP_VALUE_MAX] = {0};
        char soc_mfr[PROP_VALUE_MAX] = {0};
        char hardware[PROP_VALUE_MAX] = {0};
        char board[PROP_VALUE_MAX] = {0};

        __system_property_get("ro.board.platform", platform);
        __system_property_get("ro.soc.model", soc_model);
        __system_property_get("ro.soc.manufacturer", soc_mfr);
        __system_property_get("ro.hardware", hardware);
        __system_property_get("ro.product.board", board);

        std::string p = platform;
        std::string s = soc_model;
        std::string m = soc_mfr;
        std::string h = hardware;
        std::string b = board;

        auto to_lower = [](std::string str) {
            for (char &c : str) c = (char)std::tolower((unsigned char)c);
            return str;
        };
        p = to_lower(p);
        s = to_lower(s);
        m = to_lower(m);
        h = to_lower(h);
        b = to_lower(b);

        auto matches = [&](const std::string& pat) {
            return p.find(pat) != std::string::npos || 
                   s.find(pat) != std::string::npos || 
                   h.find(pat) != std::string::npos ||
                   b.find(pat) != std::string::npos;
        };

        // 1. Qualcomm Snapdragon Detection
        if (matches("sun") || matches("sm8750")) {
            std::strncpy(info->soc_name, "Snapdragon 8 Elite", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon v79 aDSP (QDSP6)", sizeof(info->dsp_hardware) - 1);
        } else if (matches("pineapple") || matches("sm8650")) {
            std::strncpy(info->soc_name, "Snapdragon 8 Gen 3", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon v75 aDSP (QDSP6)", sizeof(info->dsp_hardware) - 1);
        } else if (matches("kalama") || matches("sm8550")) {
            std::strncpy(info->soc_name, "Snapdragon 8 Gen 2", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon v73 aDSP (QDSP6)", sizeof(info->dsp_hardware) - 1);
        } else if (matches("taro") || matches("sm8450") || matches("cape") || matches("sm8475")) {
            std::strncpy(info->soc_name, "Snapdragon 8/8+ Gen 1", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon v69 aDSP (QDSP6)", sizeof(info->dsp_hardware) - 1);
        } else if (matches("lahaina") || matches("sm8350") || matches("shima")) {
            std::strncpy(info->soc_name, "Snapdragon 888", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon v68 aDSP (QDSP6)", sizeof(info->dsp_hardware) - 1);
        } else if (matches("kona") || matches("sm8250")) {
            std::strncpy(info->soc_name, "Snapdragon 865 / 870", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon v66 aDSP (QDSP6)", sizeof(info->dsp_hardware) - 1);
        } else if (matches("msmnile") || matches("sm8150")) {
            std::strncpy(info->soc_name, "Snapdragon 855", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon 690 DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("sdm845")) {
            std::strncpy(info->soc_name, "Snapdragon 845", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon 685 DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("sm7475") || matches("marble")) {
            std::strncpy(info->soc_name, "Snapdragon 7+ Gen 2", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon v69 aDSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("sm7325") || matches("yupik")) {
            std::strncpy(info->soc_name, "Snapdragon 778G", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon v68 aDSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("qcom") || matches("snapdragon") || p.rfind("sm", 0) == 0 || p.rfind("msm", 0) == 0 || m.find("qualcomm") != std::string::npos) {
            std::strncpy(info->soc_name, "Qualcomm Snapdragon", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Qualcomm Hexagon aDSP (QDSP6)", sizeof(info->dsp_hardware) - 1);
        }
        // 2. MediaTek Detection
        else if (matches("mt6991")) {
            std::strncpy(info->soc_name, "MediaTek Dimensity 9400", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "MediaTek Cadence Tensilica HiFi 5 DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("mt6989")) {
            std::strncpy(info->soc_name, "MediaTek Dimensity 9300", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "MediaTek Cadence Tensilica HiFi 5 DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("mt6985") || matches("mt6983")) {
            std::strncpy(info->soc_name, "MediaTek Dimensity 9200/9000", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "MediaTek Cadence Tensilica HiFi 5 DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("mt6895") || matches("mt6896") || matches("mt6897")) {
            std::strncpy(info->soc_name, "MediaTek Dimensity 8000 Series", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "MediaTek Cadence Tensilica HiFi 5 DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("mt6893") || matches("mt6891") || matches("mt6877") || matches("mt6879")) {
            std::strncpy(info->soc_name, "MediaTek Dimensity 1200 / 1080 / 7050", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "MediaTek Cadence Tensilica HiFi 4 DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("mt6853") || matches("mt6833") || matches("mt6789")) {
            std::strncpy(info->soc_name, "MediaTek Dimensity / Helio G99", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "MediaTek Tensilica HiFi 4 DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("mtk") || matches("mediatek") || p.rfind("mt6", 0) == 0 || m.find("mediatek") != std::string::npos) {
            std::strncpy(info->soc_name, "MediaTek Dimensity / Helio", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "MediaTek Tensilica HiFi DSP", sizeof(info->dsp_hardware) - 1);
        }
        // 3. Samsung Exynos Detection
        else if (matches("s5e9945") || matches("exynos2400")) {
            std::strncpy(info->soc_name, "Samsung Exynos 2400", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Exynos Multi-Core Audio DSP & Cirrus Logic DAC", sizeof(info->dsp_hardware) - 1);
        } else if (matches("s5e9925") || matches("exynos2200")) {
            std::strncpy(info->soc_name, "Samsung Exynos 2200", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Exynos Dual Audio DSP & Cirrus Logic DAC", sizeof(info->dsp_hardware) - 1);
        } else if (matches("exynos2100") || matches("exynos990")) {
            std::strncpy(info->soc_name, "Samsung Exynos 2100 / 990", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Exynos Audio Subsystem & Shannon DAC", sizeof(info->dsp_hardware) - 1);
        } else if (matches("exynos1380") || matches("exynos1480") || matches("s5e8845")) {
            std::strncpy(info->soc_name, "Samsung Exynos 1380/1480", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Exynos Audio Subsystem", sizeof(info->dsp_hardware) - 1);
        } else if (matches("exynos") || p.rfind("universal", 0) == 0 || m.find("samsung") != std::string::npos) {
            std::strncpy(info->soc_name, "Samsung Exynos", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Samsung Exynos Audio DSP", sizeof(info->dsp_hardware) - 1);
        }
        // 4. Google Tensor Detection
        else if (matches("zuma_pro") || matches("tensor_g4")) {
            std::strncpy(info->soc_name, "Google Tensor G4", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Google Tensor Gen 4 Audio Subsystem", sizeof(info->dsp_hardware) - 1);
        } else if (matches("zuma") || matches("tensor_g3")) {
            std::strncpy(info->soc_name, "Google Tensor G3", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Google Tensor Gen 3 Audio Subsystem", sizeof(info->dsp_hardware) - 1);
        } else if (matches("blueport") || matches("cloudripper") || matches("gs201")) {
            std::strncpy(info->soc_name, "Google Tensor G2", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Google Tensor Gen 2 Audio Subsystem", sizeof(info->dsp_hardware) - 1);
        } else if (matches("whitechapel") || matches("gs101")) {
            std::strncpy(info->soc_name, "Google Tensor G1", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Google Tensor Audio Subsystem", sizeof(info->dsp_hardware) - 1);
        }
        // 5. Unisoc / Spreadtrum Detection
        else if (matches("ums9230") || matches("t606") || matches("t612") || matches("t616")) {
            std::strncpy(info->soc_name, "Unisoc Tiger T606/T616", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Unisoc Multi-Core Audio Engine", sizeof(info->dsp_hardware) - 1);
        } else if (matches("ums512") || matches("t618") || matches("t610")) {
            std::strncpy(info->soc_name, "Unisoc Tiger T618", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Unisoc Audio Processing Engine", sizeof(info->dsp_hardware) - 1);
        } else if (matches("t700") || matches("t820") || matches("uis7862")) {
            std::strncpy(info->soc_name, "Unisoc Tiger T820/T700", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Unisoc Hi-Fi Audio DSP", sizeof(info->dsp_hardware) - 1);
        } else if (matches("sprd") || matches("unisoc") || matches("sc98")) {
            std::strncpy(info->soc_name, "Unisoc / Spreadtrum", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Unisoc Audio Engine", sizeof(info->dsp_hardware) - 1);
        }
        // 6. HiSilicon Kirin Detection
        else if (matches("kirin9000") || matches("hi36a0")) {
            std::strncpy(info->soc_name, "HiSilicon Kirin 9000", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "HiSilicon HiFi 4 DSP Subsystem", sizeof(info->dsp_hardware) - 1);
        } else if (matches("kirin990") || matches("hi3690")) {
            std::strncpy(info->soc_name, "HiSilicon Kirin 990", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "HiSilicon HiFi 3 DSP Subsystem", sizeof(info->dsp_hardware) - 1);
        } else if (matches("kirin") || matches("hi36")) {
            std::strncpy(info->soc_name, "HiSilicon Kirin", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "HiSilicon Kirin HiFi DSP", sizeof(info->dsp_hardware) - 1);
        }
        else {
            std::strncpy(info->soc_name, "ARM Mobile Platform", sizeof(info->soc_name) - 1);
            std::strncpy(info->dsp_hardware, "Android AudioFlinger Audio HAL", sizeof(info->dsp_hardware) - 1);
        }
    }

    struct AndroidAudioTrackSink
    {
        AudioEngineHandle* engine = nullptr;
        jobject audioTrackObj = nullptr;
        jobject directBufferObj = nullptr;
        void* directBufferAddress = nullptr;
        size_t directBufferSize = 0;

        jmethodID writeMethod = nullptr;
        jmethodID playMethod = nullptr;
        jmethodID pauseMethod = nullptr;
        jmethodID stopMethod = nullptr;
        jmethodID releaseMethod = nullptr;
        jmethodID flushMethod = nullptr;
        jmethodID rewindMethod = nullptr;

        std::thread workerThread;
        std::atomic<bool> isRunning{false};

        int sampleRate = 48000;
        int channels = 2;
        int encoding = 4; // ENCODING_PCM_FLOAT (4), ENCODING_PCM_24BIT_PACKED (21), ENCODING_PCM_16BIT (2), ENCODING_PCM_32BIT (22)
        size_t framesPerBuffer = 1024;
        bool isDirectHiRes = false;

        std::vector<float> renderBuffer;

        static void convert_f32_to_s24_packed(uint8_t* dst, const float* src, size_t count)
        {
            for (size_t i = 0; i < count; ++i)
            {
                float s = src[i];
                if (s > 1.0f) s = 1.0f;
                else if (s < -1.0f) s = -1.0f;
                int32_t val = static_cast<int32_t>(s * 8388607.0f);
                dst[i * 3 + 0] = static_cast<uint8_t>(val & 0xFF);
                dst[i * 3 + 1] = static_cast<uint8_t>((val >> 8) & 0xFF);
                dst[i * 3 + 2] = static_cast<uint8_t>((val >> 16) & 0xFF);
            }
        }

        static void convert_f32_to_s16(int16_t* dst, const float* src, size_t count)
        {
            for (size_t i = 0; i < count; ++i)
            {
                float s = src[i];
                if (s > 1.0f) s = 1.0f;
                else if (s < -1.0f) s = -1.0f;
                dst[i] = static_cast<int16_t>(s * 32767.0f);
            }
        }

        static void convert_f32_to_s32(int32_t* dst, const float* src, size_t count)
        {
            for (size_t i = 0; i < count; ++i)
            {
                float s = src[i];
                if (s > 1.0f) s = 1.0f;
                else if (s < -1.0f) s = -1.0f;
                dst[i] = static_cast<int32_t>(s * 2147483647.0);
            }
        }

        bool init(AudioEngineHandle* e, int targetSampleRate, int targetChannels, bool wantDirect)
        {
            if (g_androidJavaVM == nullptr || e == nullptr)
                return false;

            stop();
            release();

            this->engine = e;
            this->sampleRate = targetSampleRate > 0 ? targetSampleRate : 48000;
            this->channels = targetChannels > 0 ? targetChannels : 2;
            this->isDirectHiRes = wantDirect;

            JNIEnv* env = nullptr;
            bool needsDetach = false;
            jint res = g_androidJavaVM->GetEnv((void**)&env, JNI_VERSION_1_6);
            if (res == JNI_EDETACHED)
            {
                if (g_androidJavaVM->AttachCurrentThread(&env, nullptr) != JNI_OK)
                    return false;
                needsDetach = true;
            }
            else if (res != JNI_OK || env == nullptr)
            {
                return false;
            }

            bool ok = false;
            do
            {
                jclass trackClass = env->FindClass("android/media/AudioTrack");
                if (!trackClass) { env->ExceptionClear(); break; }

                jclass attrBuilderClass = env->FindClass("android/media/AudioAttributes$Builder");
                jclass fmtBuilderClass = env->FindClass("android/media/AudioFormat$Builder");
                jclass trackBuilderClass = env->FindClass("android/media/AudioTrack$Builder");
                jclass bufferClass = env->FindClass("java/nio/Buffer");
                if (!attrBuilderClass || !fmtBuilderClass || !trackBuilderClass)
                {
                    env->ExceptionClear();
                    break;
                }

                if (bufferClass)
                {
                    rewindMethod = env->GetMethodID(bufferClass, "rewind", "()Ljava/nio/Buffer;");
                    env->DeleteLocalRef(bufferClass);
                }

                // Methods for AudioAttributes$Builder
                jmethodID attrInit = env->GetMethodID(attrBuilderClass, "<init>", "()V");
                jmethodID attrSetUsage = env->GetMethodID(attrBuilderClass, "setUsage", "(I)Landroid/media/AudioAttributes$Builder;");
                jmethodID attrSetContentType = env->GetMethodID(attrBuilderClass, "setContentType", "(I)Landroid/media/AudioAttributes$Builder;");
                jmethodID attrBuild = env->GetMethodID(attrBuilderClass, "build", "()Landroid/media/AudioAttributes;");

                // Methods for AudioFormat$Builder
                jmethodID fmtInit = env->GetMethodID(fmtBuilderClass, "<init>", "()V");
                jmethodID fmtSetEncoding = env->GetMethodID(fmtBuilderClass, "setEncoding", "(I)Landroid/media/AudioFormat$Builder;");
                jmethodID fmtSetSampleRate = env->GetMethodID(fmtBuilderClass, "setSampleRate", "(I)Landroid/media/AudioFormat$Builder;");
                jmethodID fmtSetChannelMask = env->GetMethodID(fmtBuilderClass, "setChannelMask", "(I)Landroid/media/AudioFormat$Builder;");
                jmethodID fmtBuild = env->GetMethodID(fmtBuilderClass, "build", "()Landroid/media/AudioFormat;");

                // Methods for AudioTrack$Builder
                jmethodID trackInit = env->GetMethodID(trackBuilderClass, "<init>", "()V");
                jmethodID trackSetAttr = env->GetMethodID(trackBuilderClass, "setAudioAttributes", "(Landroid/media/AudioAttributes;)Landroid/media/AudioTrack$Builder;");
                jmethodID trackSetFmt = env->GetMethodID(trackBuilderClass, "setAudioFormat", "(Landroid/media/AudioFormat;)Landroid/media/AudioTrack$Builder;");
                jmethodID trackSetBufSize = env->GetMethodID(trackBuilderClass, "setBufferSizeInBytes", "(I)Landroid/media/AudioTrack$Builder;");
                jmethodID trackSetTransferMode = env->GetMethodID(trackBuilderClass, "setTransferMode", "(I)Landroid/media/AudioTrack$Builder;");
                jmethodID trackBuild = env->GetMethodID(trackBuilderClass, "build", "()Landroid/media/AudioTrack;");

                if (!attrInit || !attrBuild || !fmtInit || !fmtBuild || !trackInit || !trackBuild)
                {
                    env->ExceptionClear();
                    break;
                }

                int channelMask = (channels == 1) ? 4 /* CHANNEL_OUT_MONO */ : 12 /* CHANNEL_OUT_STEREO */;

                // Build AudioAttributes for high fidelity media playback
                // NOTE: Do not set 0x1 (FLAG_AUDIBILITY_ENFORCED) - that is for camera shutter sounds
                // and prevents Android AudioPolicy from opening DirectOutputThread!
                jobject attrBuilder = env->NewObject(attrBuilderClass, attrInit);
                if (attrSetUsage) env->CallObjectMethod(attrBuilder, attrSetUsage, 1 /* USAGE_MEDIA */);
                if (attrSetContentType) env->CallObjectMethod(attrBuilder, attrSetContentType, 2 /* CONTENT_TYPE_MUSIC */);
                jobject attrObj = env->CallObjectMethod(attrBuilder, attrBuild);

                // Candidate encodings:
                // Hardware DSPs (Qualcomm Hexagon, MediaTek HiFi, Exynos) require integer PCM on direct_pcm HAL profiles.
                // 21 = ENCODING_PCM_24BIT_PACKED, 22 = ENCODING_PCM_32BIT, 4 = ENCODING_PCM_FLOAT, 2 = ENCODING_PCM_16BIT
                std::vector<int> candidates;
                if (wantDirect)
                {
                    candidates = {21 /* 24-bit packed */, 22 /* 32-bit int */, 4 /* float */, 2 /* 16-bit */};
                }
                else
                {
                    candidates = {4 /* float */, 2 /* 16-bit */};
                }

                jmethodID isDirectMethod = nullptr;
                if (wantDirect)
                {
                    isDirectMethod = env->GetStaticMethodID(trackClass, "isDirectPlaybackSupported", "(Landroid/media/AudioFormat;Landroid/media/AudioAttributes;)Z");
                    if (env->ExceptionCheck())
                    {
                        env->ExceptionClear();
                        isDirectMethod = nullptr;
                    }
                }

                int chosenEncoding = candidates[0];
                if (wantDirect && isDirectMethod)
                {
                    for (int cand : candidates)
                    {
                        jobject tFmtBuilder = env->NewObject(fmtBuilderClass, fmtInit);
                        if (fmtSetEncoding) env->CallObjectMethod(tFmtBuilder, fmtSetEncoding, cand);
                        if (fmtSetSampleRate) env->CallObjectMethod(tFmtBuilder, fmtSetSampleRate, sampleRate);
                        if (fmtSetChannelMask) env->CallObjectMethod(tFmtBuilder, fmtSetChannelMask, channelMask);
                        jobject tFmtObj = env->CallObjectMethod(tFmtBuilder, fmtBuild);
                        env->DeleteLocalRef(tFmtBuilder);

                        jboolean sup = env->CallStaticBooleanMethod(trackClass, isDirectMethod, tFmtObj, attrObj);
                        if (env->ExceptionCheck()) { env->ExceptionClear(); sup = JNI_FALSE; }
                        env->DeleteLocalRef(tFmtObj);

                        if (sup == JNI_TRUE)
                        {
                            chosenEncoding = cand;
                            break;
                        }
                    }
                }

                jmethodID getMinBuf = env->GetStaticMethodID(trackClass, "getMinBufferSize", "(III)I");
                jobject localTrack = nullptr;

                // Build loop trying candidate encodings starting from chosenEncoding
                std::vector<int> buildOrder;
                buildOrder.push_back(chosenEncoding);
                for (int c : candidates)
                {
                    if (c != chosenEncoding) buildOrder.push_back(c);
                }

                for (int encToTry : buildOrder)
                {
                    chosenEncoding = encToTry;
                    jobject fBuilder = env->NewObject(fmtBuilderClass, fmtInit);
                    if (fmtSetEncoding) env->CallObjectMethod(fBuilder, fmtSetEncoding, chosenEncoding);
                    if (fmtSetSampleRate) env->CallObjectMethod(fBuilder, fmtSetSampleRate, sampleRate);
                    if (fmtSetChannelMask) env->CallObjectMethod(fBuilder, fmtSetChannelMask, channelMask);
                    jobject fObj = env->CallObjectMethod(fBuilder, fmtBuild);
                    env->DeleteLocalRef(fBuilder);

                    int minBufSize = 8192;
                    if (getMinBuf)
                    {
                        int query = env->CallStaticIntMethod(trackClass, getMinBuf, sampleRate, channelMask, chosenEncoding);
                        if (env->ExceptionCheck()) { env->ExceptionClear(); query = -1; }
                        if (query > 0) minBufSize = query;
                    }

                    int targetBufSize = minBufSize * 2;
                    if (wantDirect && targetBufSize < 32768) targetBufSize = 32768;
                    else if (targetBufSize < 8192) targetBufSize = 8192;

                    jobject tBuilder = env->NewObject(trackBuilderClass, trackInit);
                    if (trackSetAttr) env->CallObjectMethod(tBuilder, trackSetAttr, attrObj);
                    if (trackSetFmt) env->CallObjectMethod(tBuilder, trackSetFmt, fObj);
                    if (trackSetBufSize) env->CallObjectMethod(tBuilder, trackSetBufSize, targetBufSize);
                    if (trackSetTransferMode) env->CallObjectMethod(tBuilder, trackSetTransferMode, 1 /* MODE_STREAM */);

                    localTrack = env->CallObjectMethod(tBuilder, trackBuild);
                    env->DeleteLocalRef(tBuilder);
                    env->DeleteLocalRef(fObj);

                    if (env->ExceptionCheck())
                    {
                        env->ExceptionClear();
                        localTrack = nullptr;
                    }

                    if (localTrack != nullptr)
                    {
                        break;
                    }
                }

                env->DeleteLocalRef(attrObj);

                if (!localTrack)
                {
                    engine_log("Failed to build AudioTrack via Builder for any encoding candidate");
                    break;
                }

                audioTrackObj = env->NewGlobalRef(localTrack);

                // Ensure initial track volume is set to 1.0f (full volume)
                jmethodID setVolMethod = env->GetMethodID(trackClass, "setVolume", "(F)I");
                if (setVolMethod)
                {
                    env->CallIntMethod(localTrack, setVolMethod, 1.0f);
                    if (env->ExceptionCheck()) env->ExceptionClear();
                }
                env->DeleteLocalRef(localTrack);

                playMethod = env->GetMethodID(trackClass, "play", "()V");
                pauseMethod = env->GetMethodID(trackClass, "pause", "()V");
                stopMethod = env->GetMethodID(trackClass, "stop", "()V");
                releaseMethod = env->GetMethodID(trackClass, "release", "()V");
                flushMethod = env->GetMethodID(trackClass, "flush", "()V");
                writeMethod = env->GetMethodID(trackClass, "write", "(Ljava/nio/ByteBuffer;II)I");

                encoding = chosenEncoding;
                framesPerBuffer = (sampleRate <= 48000) ? 1024 : 2048;
                size_t bytesPerSample = 4;
                if (encoding == 21) bytesPerSample = 3;
                else if (encoding == 2) bytesPerSample = 2;
                else if (encoding == 22) bytesPerSample = 4;
                else bytesPerSample = 4;

                directBufferSize = framesPerBuffer * (size_t)channels * bytesPerSample;

                directBufferAddress = std::malloc(directBufferSize);
                if (!directBufferAddress) break;

                jobject localBB = env->NewDirectByteBuffer(directBufferAddress, (jlong)directBufferSize);
                if (!localBB || env->ExceptionCheck())
                {
                    env->ExceptionClear();
                    break;
                }
                directBufferObj = env->NewGlobalRef(localBB);
                env->DeleteLocalRef(localBB);

                renderBuffer.resize(framesPerBuffer * (size_t)channels);
                ok = true;
            } while (false);

            if (needsDetach)
            {
                g_androidJavaVM->DetachCurrentThread();
            }

            return ok;
        }

        void start()
        {
            if (audioTrackObj == nullptr || isRunning.load(std::memory_order_relaxed))
                return;

            isRunning.store(true, std::memory_order_release);
            workerThread = std::thread(&AndroidAudioTrackSink::threadLoop, this);
        }

        void stop()
        {
            if (!isRunning.load(std::memory_order_relaxed))
                return;

            isRunning.store(false, std::memory_order_release);
            if (workerThread.joinable())
            {
                workerThread.join();
            }
        }

        void release()
        {
            stop();
            if (g_androidJavaVM == nullptr) return;

            JNIEnv* env = nullptr;
            bool needsDetach = false;
            jint res = g_androidJavaVM->GetEnv((void**)&env, JNI_VERSION_1_6);
            if (res == JNI_EDETACHED)
            {
                if (g_androidJavaVM->AttachCurrentThread(&env, nullptr) == JNI_OK)
                    needsDetach = true;
            }

            if (env != nullptr)
            {
                if (audioTrackObj != nullptr)
                {
                    if (releaseMethod) env->CallVoidMethod(audioTrackObj, releaseMethod);
                    env->DeleteGlobalRef(audioTrackObj);
                    audioTrackObj = nullptr;
                }
                if (directBufferObj != nullptr)
                {
                    env->DeleteGlobalRef(directBufferObj);
                    directBufferObj = nullptr;
                }
                if (env->ExceptionCheck()) env->ExceptionClear();
            }

            if (directBufferAddress != nullptr)
            {
                std::free(directBufferAddress);
                directBufferAddress = nullptr;
            }
            directBufferSize = 0;

            if (needsDetach)
            {
                g_androidJavaVM->DetachCurrentThread();
            }
        }

        void threadLoop()
        {
            if (g_androidJavaVM == nullptr || audioTrackObj == nullptr || engine == nullptr)
                return;

            JNIEnv* env = nullptr;
            if (g_androidJavaVM->AttachCurrentThread(&env, nullptr) != JNI_OK || env == nullptr)
                return;

            setpriority(PRIO_PROCESS, 0, -16);

            const size_t totalSamples = framesPerBuffer * (size_t)channels;
            const size_t bytesToWrite = directBufferSize;
            bool playCalled = false;

            while (isRunning.load(std::memory_order_relaxed))
            {
                std::memset(renderBuffer.data(), 0, totalSamples * sizeof(float));
                data_callback(&engine->device, renderBuffer.data(), nullptr, (ma_uint32)framesPerBuffer);

                if (encoding == 21)
                {
                    convert_f32_to_s24_packed(reinterpret_cast<uint8_t*>(directBufferAddress), renderBuffer.data(), totalSamples);
                }
                else if (encoding == 2)
                {
                    convert_f32_to_s16(reinterpret_cast<int16_t*>(directBufferAddress), renderBuffer.data(), totalSamples);
                }
                else if (encoding == 22)
                {
                    convert_f32_to_s32(reinterpret_cast<int32_t*>(directBufferAddress), renderBuffer.data(), totalSamples);
                }
                else
                {
                    std::memcpy(directBufferAddress, renderBuffer.data(), totalSamples * sizeof(float));
                }

                // CRITICAL FIX: Reset the java.nio.ByteBuffer position to 0 before every write!
                // AudioTrack.write() in Android advances the buffer position by the written byte count.
                // Without rewinding, subsequent writes have remaining() == 0, causing AudioTrack.write()
                // to return ERROR_BAD_VALUE (-2) continuously and permanently muting playback.
                if (rewindMethod && directBufferObj)
                {
                    env->CallObjectMethod(directBufferObj, rewindMethod);
                    if (env->ExceptionCheck()) env->ExceptionClear();
                }

                if (writeMethod && directBufferObj)
                {
                    int written = env->CallIntMethod(audioTrackObj, writeMethod, directBufferObj, (jint)bytesToWrite, 0 /* WRITE_BLOCKING */);
                    if (env->ExceptionCheck())
                    {
                        env->ExceptionClear();
                        std::this_thread::sleep_for(std::chrono::milliseconds(5));
                    }
                    else if (written < 0)
                    {
                        std::this_thread::sleep_for(std::chrono::milliseconds(5));
                    }
                    else if (!playCalled && playMethod)
                    {
                        // Start playback once the initial pre-roll buffer is written
                        env->CallVoidMethod(audioTrackObj, playMethod);
                        if (env->ExceptionCheck()) env->ExceptionClear();
                        playCalled = true;
                    }
                }
                else
                {
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                }
            }

            if (stopMethod && audioTrackObj)
            {
                env->CallVoidMethod(audioTrackObj, stopMethod);
                if (env->ExceptionCheck()) env->ExceptionClear();
            }

            g_androidJavaVM->DetachCurrentThread();
        }
    };
#else
    AE_API void ae_register_android_jvm(void *vm)
    {
        (void)vm;
    }
#endif

extern "C"
{
    AE_API AudioEngineHandle *ae_create_engine(int sample_rate, int channels)

    {
        if (sample_rate <= 0)
            sample_rate = 48000;
        if (channels <= 0)
            channels = 2;

#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
        static std::once_flag gCurlInitOnce;
        std::call_once(gCurlInitOnce, []()
                       {
            const auto rc = curl_global_init(CURL_GLOBAL_DEFAULT);
            if (rc != CURLE_OK)
            {
                engine_log("curl_global_init failed: %d", (int)rc);
            } });
#endif

        AudioEngineHandle *e = new AudioEngineHandle();
        e->sampleRate = sample_rate;
        e->channels = channels;

        e->eq.updateCoefficients(sample_rate);
        reinit_advanced_fx_filters(e);
        e->crystalizer.init(sample_rate);

        e->analyzerFrameSize = 512;
        e->analyzerAccumulator.assign((size_t)e->analyzerFrameSize, 0.0f);
        e->analyzerLatest.assign((size_t)e->analyzerFrameSize, 0.0f);
        e->analyzerAccumulatorCount = 0;

        // Pre-allocate real-time scratch buffers to eliminate heap allocations inside data_callback
        const size_t preallocSamples = 262144; // 256K floats (~1MB)
        e->conversionBuffer.resize(preallocSamples);
        e->crossfadeMixBuffer.resize(preallocSamples);
        e->engineProcessBuffer.resize(preallocSamples);

        // Initialize advanced settings
        e->outputSampleRate = sample_rate;
        e->outputChannels = channels;
        // Default format is F32
        e->outputFormat = AE_FORMAT_F32;

        ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
        cfg.playback.format = ma_format_f32;
        cfg.playback.channels = (ma_uint32)channels;
        cfg.sampleRate = (ma_uint32)sample_rate;
        cfg.dataCallback = data_callback;
        cfg.pUserData = e;
        apply_buffer_policy(e, cfg);

        // The OS hardware device handle uses standard miniaudio direct/linear fallback,
        // while all internal track decoding & rate conversion use the high-precision
        // SoXR VHQ Minimum Phase / Sinc engine (e->pitchResampler & e->deviceResampler).
        cfg.resampling.algorithm = ma_resample_algorithm_linear;

        if (ma_device_init(nullptr, &cfg, &e->device) != MA_SUCCESS)
        {
            set_last_error(e, "Failed to initialize playback device.");
            delete e;
            return nullptr;
        }

        // Sync actual device-negotiated values back into the engine struct.
        // ma_device_init may adjust channels/rate to what the hardware supports.
        {
            const int actualRate = (int)e->device.sampleRate;
            const int actualCh   = (int)e->device.playback.channels;
            if (actualCh > 0)
            {
                e->channels = actualCh;
                if (e->outputChannels <= 0) e->outputChannels = actualCh;
            }

            uint32_t devRate = (actualRate > 0) ? (uint32_t)actualRate : (uint32_t)sample_rate;
            uint32_t srcRate = (e->sourceSampleRate > 0) ? (uint32_t)e->sourceSampleRate : devRate;
            AudioRatePlan plan = calculateRatePlan(
                srcRate,
                devRate,
                (uint32_t)e->userOutputSampleRate,
                e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed),
                e->exclusiveModeEnabled.load(std::memory_order_relaxed)
            );
            applyRatePlan(e, plan);
        }

        if (ma_device_start(&e->device) != MA_SUCCESS)
        {
            set_last_error(e, "Failed to start playback device.");
            ma_device_uninit(&e->device);
            delete e;
            return nullptr;
        }

        engine_log("engine created (sampleRate=%d channels=%d)", e->sampleRate, e->channels);
        e->pcmRingBuffer.init(192000);
        e->crossfadeRingBuffer.init(192000);
        e->decodeProducerExit.store(false, std::memory_order_release);
        e->decodeProducerThread = std::thread(decode_producer_loop, e);
        e->worker = std::thread(worker_loop, e);
        return e;
    }

    AE_API void ae_destroy_engine(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return;

        engine_log("destroy_engine begin");

        {
            std::lock_guard<std::mutex> lk(e->decodeProducerMutex);
            e->decodeProducerExit.store(true, std::memory_order_release);
            e->decodeProducerCv.notify_all();
        }

        if (e->decodeProducerThread.joinable())
        {
            e->decodeProducerThread.join();
        }

        {
            std::lock_guard<std::mutex> lk(e->workerMutex);
            e->workerExit = true;
            e->workerCv.notify_one();
        }

        if (e->worker.joinable())
        {
            e->worker.join();
        }

        {
            std::lock_guard<std::mutex> d(e->decoderMutex);
            if (e->hasCurrent && e->currentDecoder)
            {
                uninit_decoder_slot(
                    e,
                    e->currentDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    ,
                    e->currentStream
#endif
                );
                e->currentDecoder = nullptr;
                e->hasCurrent = false;
            }
            if (e->hasNext && e->nextDecoder)
            {
                uninit_decoder_slot(
                    e,
                    e->nextDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    ,
                    e->nextStream
#endif
                );
                e->nextDecoder = nullptr;
                e->hasNext = false;
            }
            uninit_fading_out_slot_locked(e);

            if (e->pitchResamplerInit)
            {
                ma_resampler_uninit(&e->pitchResampler, nullptr);
                e->pitchResamplerInit = false;
            }
            e->tempoProcessor.reset();

            // Cleanup Push Stream if allocated
            if (e->pushStreamForCurrent.initialized)
            {
                ma_rb_uninit(&e->pushStreamForCurrent.rb);
                if (e->pushStreamForCurrent.rbBuffer)
                {
                    std::free(e->pushStreamForCurrent.rbBuffer);
                    e->pushStreamForCurrent.rbBuffer = nullptr;
                }
                e->pushStreamForCurrent.initialized = false;
            }

            e->garbageQueue.drain();
        }

        {
            std::lock_guard<std::mutex> devLock(e->deviceMutex);
#if defined(__ANDROID__)
            if (e->pAudioTrackSink != nullptr)
            {
                auto *sink = reinterpret_cast<AndroidAudioTrackSink *>(e->pAudioTrackSink);
                sink->stop();
                sink->release();
                delete sink;
                e->pAudioTrackSink = nullptr;
            }
#endif
            ma_device_uninit(&e->device);
            if (e->customContextInit)
            {
                ma_context_uninit(&e->customContext);
                e->customContextInit = false;
            }
        }

        e->garbageQueue.drain();
        engine_log("destroy_engine end");
        delete e;
    }

    AE_API bool ae_set_playlist(AudioEngineHandle *e, const char **paths, int count)
    {
        if (e == nullptr || paths == nullptr || count <= 0)
        {
            set_last_error(e, "Invalid playlist input.");
            return false;
        }

        std::vector<std::string> incoming;
        incoming.reserve((size_t)count);
        for (int i = 0; i < count; ++i)
        {
            if (paths[i] != nullptr && paths[i][0] != '\0')
            {
                incoming.emplace_back(paths[i]);
            }
        }

        if (incoming.empty())
        {
            set_last_error(e, "Playlist is empty after filtering invalid paths.");
            return false;
        }

        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            e->playlist = std::move(incoming);
            e->currentIndex = 0;
            rebuild_play_order_locked(e);
        }

        {
            std::lock_guard<std::mutex> d(e->decoderMutex);
            if (e->hasCurrent)
            {
                uninit_decoder_slot(
                    e,
                    e->currentDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    ,
                    e->currentStream
#endif
                );
                e->hasCurrent = false;
            }
            if (e->hasNext)
            {
                uninit_decoder_slot(
                    e,
                    e->nextDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    ,
                    e->nextStream
#endif
                );
                e->hasNext = false;
            }
            uninit_fading_out_slot_locked(e);
            e->nextIndex = -1;
            e->currentLengthFrames = 0;
            e->nextLengthFrames = 0;
        }

        engine_log("set_playlist: count=%d", count);
        // Do not auto-jump here. The caller may immediately request a specific
        // initial index/position; auto-jumping can cause duplicate decoder
        // initialization races.
        clear_last_error(e);
        return true;
    }

    AE_API bool ae_add_to_playlist(AudioEngineHandle *e, const char *path)
    {
        if (e == nullptr || path == nullptr || path[0] == '\0')
        {
            set_last_error(e, "Invalid path for add_to_playlist.");
            return false;
        }

        std::lock_guard<std::mutex> pl(e->playlistMutex);
        e->playlist.emplace_back(path);
        rebuild_play_order_locked(e);
        if (e->currentIndex < 0)
        {
            e->currentIndex = 0;
            request_jump(e, 0);
        }
        else
        {
            std::lock_guard<std::mutex> d(e->decoderMutex);
            if (e->hasCurrent && !e->hasNext)
            {
                request_preload(e);
            }
        }
        clear_last_error(e);
        return true;
    }

    AE_API bool ae_insert_to_playlist(AudioEngineHandle *e, int index, const char *path)
    {
        if (e == nullptr || path == nullptr || path[0] == '\0')
        {
            set_last_error(e, "Invalid path for insert_to_playlist.");
            return false;
        }

        std::lock_guard<std::mutex> pl(e->playlistMutex);
        if (index < 0)
            index = 0;
        if (index > (int)e->playlist.size())
            index = (int)e->playlist.size();

        e->playlist.insert(e->playlist.begin() + index, std::string(path));
        if (e->currentIndex >= index)
        {
            e->currentIndex += 1;
        }
        if (e->currentIndex < 0)
            e->currentIndex = 0;
        rebuild_play_order_locked(e);

        if (e->currentIndex >= 0)
        {
            std::lock_guard<std::mutex> d(e->decoderMutex);
            if (e->hasCurrent && !e->hasNext)
            {
                request_preload(e);
            }
        }

        clear_last_error(e);
        return true;
    }

    AE_API bool ae_remove_from_playlist(AudioEngineHandle *e, int index)
    {
        if (e == nullptr)
        {
            set_last_error(e, "Engine is null in remove_from_playlist.");
            return false;
        }

        bool removedCurrent = false;
        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            if (index < 0 || index >= (int)e->playlist.size())
            {
                set_last_error(e, "remove_from_playlist index out of range.");
                return false;
            }

            removedCurrent = (e->currentIndex == index);
            e->playlist.erase(e->playlist.begin() + index);

            if (e->playlist.empty())
            {
                e->currentIndex = -1;
                e->orderCursor = -1;
            }
            else
            {
                if (e->currentIndex > index)
                    e->currentIndex -= 1;
                if (e->currentIndex >= (int)e->playlist.size())
                    e->currentIndex = (int)e->playlist.size() - 1;
                rebuild_play_order_locked(e);
            }
        }

        if (removedCurrent)
        {
            if (e->currentIndex >= 0)
            {
                request_jump(e, e->currentIndex);
            }
            else
            {
                ae_stop(e);
            }
        }
        else
        {
            request_preload(e);
        }
        clear_last_error(e);
        return true;
    }

    AE_API bool ae_move_playlist_item(AudioEngineHandle *e, int from_index, int to_index)
    {
        if (e == nullptr)
        {
            set_last_error(e, "Engine is null in move_playlist_item.");
            return false;
        }

        std::lock_guard<std::mutex> pl(e->playlistMutex);
        const int n = (int)e->playlist.size();
        if (from_index < 0 || from_index >= n || to_index < 0 || to_index >= n)
        {
            set_last_error(e, "move_playlist_item index out of range.");
            return false;
        }
        if (from_index == to_index)
            return true;

        std::string moved = e->playlist[(size_t)from_index];
        e->playlist.erase(e->playlist.begin() + from_index);
        e->playlist.insert(e->playlist.begin() + to_index, moved);

        if (e->currentIndex == from_index)
        {
            e->currentIndex = to_index;
        }
        else if (from_index < e->currentIndex && to_index >= e->currentIndex)
        {
            e->currentIndex -= 1;
        }
        else if (from_index > e->currentIndex && to_index <= e->currentIndex)
        {
            e->currentIndex += 1;
        }

        rebuild_play_order_locked(e);
        clear_last_error(e);
        return true;
    }

    AE_API void ae_clear_playlist(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return;

        engine_log("clear_playlist requested");

        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            e->playlist.clear();
            e->currentIndex = -1;
            e->playOrder.clear();
            e->orderCursor = -1;
            e->preloadGeneration.fetch_add(1, std::memory_order_relaxed);
        }

        std::lock_guard<std::mutex> d(e->decoderMutex);
        if (e->hasCurrent)
        {
            uninit_decoder_slot(
                e,
                e->currentDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                ,
                e->currentStream
#endif
            );
            e->hasCurrent = false;
        }
        if (e->hasNext)
        {
            uninit_decoder_slot(
                e,
                e->nextDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                ,
                e->nextStream
#endif
            );
            e->hasNext = false;
        }
        uninit_fading_out_slot_locked(e);
        e->isPlaying.store(false, std::memory_order_relaxed);
        engine_log("clear_playlist completed");
    }

    AE_API bool ae_play(AudioEngineHandle *e)
    {
        if (e == nullptr)
        {
            set_last_error(e, "Engine is null in play.");
            return false;
        }

        bool hasCurrent = false;
        bool isPushMode = false;
        bool pushInitialized = false;
        {
            std::lock_guard<std::mutex> d(e->decoderMutex);
            // A finished, fully drained push-stream session must not trap the
            // engine in push mode forever: fall back to normal playlist
            // playback so subsequent ae_play() calls load tracks again.
            if (e->isPushStreamMode && e->pushStreamForCurrent.isDone &&
                (!e->pushStreamForCurrent.initialized ||
                 ma_rb_available_read(&e->pushStreamForCurrent.rb) == 0))
            {
                e->isPushStreamMode = false;
                e->pushStreamAbort.store(false, std::memory_order_relaxed);
            }
            hasCurrent = e->hasCurrent;
            isPushMode = e->isPushStreamMode;
            pushInitialized = e->pushStreamForCurrent.initialized;
        }

        if (!hasCurrent)
        {
            if (isPushMode && pushInitialized)
            {
                // Push-stream mode may not have an initialized decoder yet.
                // The audio callback will lazy-init it once enough bytes arrive.
                e->isPlaying.store(true, std::memory_order_relaxed);
                engine_log("play requested in push-stream mode (decoder pending)");
                clear_last_error(e);
                return true;
            }

            int idx = 0;
            {
                std::lock_guard<std::mutex> pl(e->playlistMutex);
                if (e->playlist.empty())
                {
                    set_last_error(e, "Cannot play: playlist is empty.");
                    return false;
                }
                idx = (e->currentIndex >= 0) ? e->currentIndex : 0;
            }
            e->pendingAutoPlay.store(true, std::memory_order_relaxed);
            request_jump(e, idx);
        }

        {
            std::lock_guard<std::mutex> devLock(e->deviceMutex);
#if defined(__ANDROID__)
            if (e->pAudioTrackSink != nullptr && e->activeBackend.load(std::memory_order_relaxed) >= AE_BACKEND_AUDIOTRACK)
            {
                reinterpret_cast<AndroidAudioTrackSink *>(e->pAudioTrackSink)->start();
            }
            else
#endif
            {
                if (ma_device_get_state(&e->device) != ma_device_state_started)
                {
                    if (ma_device_start(&e->device) != MA_SUCCESS)
                    {
                        engine_log("Failed to start device in ae_play");
                    }
                }
            }
        }

        e->isPlaying.store(true, std::memory_order_relaxed);
        e->pendingAutoPlay.store(true, std::memory_order_relaxed);
        e->decodeProducerCv.notify_one();
        engine_log("play requested (currentIndex=%d)", e->currentIndex);
        clear_last_error(e);
        return true;
    }

    AE_API bool ae_pause(AudioEngineHandle *e)
    {
        if (e == nullptr)
        {
            set_last_error(e, "Engine is null in seek.");
            return false;
        }
        e->isPlaying.store(false, std::memory_order_relaxed);
        e->pendingAutoPlay.store(false, std::memory_order_relaxed);
        return true;
    }

    AE_API bool ae_stop(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return false;
        e->isPlaying.store(false, std::memory_order_relaxed);
        e->pendingAutoPlay.store(false, std::memory_order_relaxed);
        // Unblock any ae_push_stream_chunk() caller spinning on a full ring
        // buffer (previously the Dart isolate could block indefinitely).
        e->pushStreamAbort.store(true, std::memory_order_release);

        std::lock_guard<std::mutex> d(e->decoderMutex);
        if (e->hasCurrent)
        {
            (void)ma_decoder_seek_to_pcm_frame(e->currentDecoder, 0);
        }
        if (e->pitchResamplerInit)
        {
            ma_resampler_reset(&e->pitchResampler);
            e->pitchInputUnconsumed = 0;
        }
        e->tempoProcessor.reset();
#if defined(__ANDROID__)
        if (e->pAudioTrackSink != nullptr && e->activeBackend.load(std::memory_order_relaxed) >= AE_BACKEND_AUDIOTRACK)
        {
            reinterpret_cast<AndroidAudioTrackSink *>(e->pAudioTrackSink)->stop();
        }
#endif
        return true;
    }

    AE_API bool ae_seek(AudioEngineHandle *e, double percent_0_to_1)
    {
        if (e == nullptr)
            return false;

        const double p = clampd(percent_0_to_1, 0.0, 1.0);

        e->ringBufferFlushing.store(true, std::memory_order_release);
        std::lock_guard<std::mutex> d(e->decoderMutex);
        if (e->hasCurrent && e->currentLengthFrames == 0 && e->currentDecoder != nullptr)
        {
            ma_uint64 len = 0;
            if (ma_decoder_get_length_in_pcm_frames(e->currentDecoder, &len) == MA_SUCCESS && len > 0)
            {
                e->currentLengthFrames = len;
            }
        }

        if (!e->hasCurrent || e->currentLengthFrames == 0)
        {
            set_last_error(e, "Seek failed: no active track or unseekable live stream.");
            e->ringBufferFlushing.store(false, std::memory_order_release);
            return false;
        }

        ma_uint64 target = (ma_uint64)((double)e->currentLengthFrames * p);
        const bool ok = ma_decoder_seek_to_pcm_frame(e->currentDecoder, target) == MA_SUCCESS;
        if (!ok)
            set_last_error(e, "Seek failed in decoder.");
        else
        {
            e->pcmRingBuffer.reset();
            e->seekBasePcmFrame.store(target, std::memory_order_release);
            e->playedPcmFrames.store(0, std::memory_order_release);
            if (e->pitchResamplerInit)
            {
                ma_resampler_reset(&e->pitchResampler);
                e->pitchInputUnconsumed = 0;
            }
            e->tempoProcessor.reset();
            clear_last_error(e);
        }
        e->ringBufferFlushing.store(false, std::memory_order_release);
        e->decodeProducerCv.notify_one();
        return ok;
    }

    static bool execute_jump_direct(AudioEngineHandle *e, int jumpIndex)
    {
        if (e == nullptr || jumpIndex < 0) return false;
        e->preloadGeneration.fetch_add(1, std::memory_order_relaxed);

        std::string path;
        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            if (jumpIndex >= (int)e->playlist.size()) return false;
            path = e->playlist[(size_t)jumpIndex];
        }

        ma_decoder *newCurrent = nullptr;
        ma_uint64 newCurrentLen = 0;
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
        NetworkStreamState *newCurrentStream = nullptr;
#endif

        if (!load_decoder_for_path(e, path, &newCurrent, &newCurrentLen
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
            , &newCurrentStream
#endif
        ))
        {
            return false;
        }

        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            e->currentIndex = jumpIndex;
            set_order_cursor_for_index_locked(e, jumpIndex);
        }
        e->abRepeatEnabled.store(false, std::memory_order_release);

        if (e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed) && newCurrent != nullptr)
        {
            const int nativeRate = (int)newCurrent->outputSampleRate;
            if (nativeRate > 0 && nativeRate != e->outputSampleRate)
            {
                engine_log("Auto Sample-Rate Match (execute_jump_direct): Track native rate is %d Hz (current DAC rate: %d Hz). Triggering full rate plan re-configuration...", nativeRate, e->outputSampleRate);
                uninit_decoder_slot(
                    e,
                    newCurrent
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    , newCurrentStream
#endif
                );
                newCurrent = nullptr;
                e->outputSampleRate = nativeRate;
                restart_and_apply_config(e);
                (void)load_decoder_for_path(
                    e,
                    path,
                    &newCurrent,
                    &newCurrentLen
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    , &newCurrentStream
#endif
                );
            }
        }

        if (newCurrent != nullptr)
        {
            ma_format nativeFmt = ma_format_unknown;
            ma_uint32 nativeCh = 0;
            ma_uint32 nativeRate = 0;
            (void)ma_decoder_get_data_format(newCurrent, &nativeFmt, &nativeCh, &nativeRate, nullptr, 0);
            uint32_t srcRate = (nativeRate > 0) ? nativeRate : (uint32_t)newCurrent->outputSampleRate;
            AudioRatePlan plan = calculateRatePlan(
                srcRate,
                (uint32_t)e->deviceSampleRate,
                (uint32_t)e->userOutputSampleRate,
                e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed),
                e->exclusiveModeEnabled.load(std::memory_order_relaxed)
            );
            applyRatePlan(e, plan);
        }

        {
            std::lock_guard<std::mutex> d(e->decoderMutex);
            if (e->hasCurrent)
            {
                uninit_decoder_slot(
                    e,
                    e->currentDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    , e->currentStream
#endif
                );
                e->hasCurrent = false;
            }
            if (e->hasNext)
            {
                uninit_decoder_slot(
                    e,
                    e->nextDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    , e->nextStream
#endif
                );
                e->hasNext = false;
            }
            // Skip during an active crossfade: ramp the outgoing track out
            // gracefully instead of hard-cutting it. The producer thread
            // retires the outgoing decoder once the ramp completes.
            request_crossfade_abort(e);

            e->currentDecoder = newCurrent;
            if (newCurrent != nullptr && newCurrent->outputSampleRate > 0)
            {
                e->sourceSampleRate = (int)newCurrent->outputSampleRate;
            }
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
            e->currentStream = newCurrentStream;
#endif
            e->currentLengthFrames = newCurrentLen;
            e->currentIndex = jumpIndex;
            e->hasCurrent = (newCurrent != nullptr);
            arm_transition_fade_in(e);

            ma_uint64 startFrame = 0;
            if (e->pendingSeekValid.load(std::memory_order_acquire) &&
                e->pendingSeekIndex.load(std::memory_order_acquire) == jumpIndex)
            {
                startFrame = e->pendingSeekFrame.load(std::memory_order_acquire);
                if (e->currentDecoder != nullptr)
                {
                    (void)ma_decoder_seek_to_pcm_frame(e->currentDecoder, startFrame);
                }
                e->pendingSeekValid.store(false, std::memory_order_release);
                e->pendingSeekIndex.store(-1, std::memory_order_release);
            }
            e->seekBasePcmFrame.store(startFrame, std::memory_order_release);
            e->playedPcmFrames.store(0, std::memory_order_release);

            e->nextDecoder = nullptr;
            e->nextIndex = -1;
            e->nextLengthFrames = 0;
            e->hasNext = false;
        }

        if (e->pendingAutoPlay.exchange(false, std::memory_order_acq_rel) ||
            e->isPlaying.load(std::memory_order_relaxed))
        {
            e->isPlaying.store(true, std::memory_order_relaxed);
            e->pcmRingBuffer.reset();
            e->decodeProducerCv.notify_one();

            std::lock_guard<std::mutex> devLock(e->deviceMutex);
            if (ma_device_get_state(&e->device) != ma_device_state_started)
            {
                ma_device_start(&e->device);
            }
        }

        request_preload(e);
        return true;
    }

    AE_API bool ae_next(AudioEngineHandle *e)
    {
        if (e == nullptr)
        {
            set_last_error(e, "Engine is null in next.");
            return false;
        }

        int idx = -1;
        std::string path;
        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            idx = next_index_locked(e);
            if (idx >= 0 && idx < (int)e->playlist.size())
            {
                path = e->playlist[(size_t)idx];
            }
        }

        if (idx < 0)
        {
            set_last_error(e, "No next track (loop mode may be off).");
            return false;
        }

        e->pendingAutoPlay.store(true, std::memory_order_relaxed);

        if (!is_network_url(path))
        {
            execute_jump_direct(e, idx);
        }
        else
        {
            request_jump(e, idx);
        }

        {
            std::lock_guard<std::mutex> devLock(e->deviceMutex);
            if (ma_device_get_state(&e->device) != ma_device_state_started)
            {
                if (ma_device_start(&e->device) != MA_SUCCESS)
                {
                    engine_log("Failed to start device in ae_next");
                }
            }
        }

        clear_last_error(e);
        return true;
    }

    AE_API bool ae_prev(AudioEngineHandle *e)
    {
        if (e == nullptr)
        {
            set_last_error(e, "Engine is null in prev.");
            return false;
        }

        int idx = -1;
        std::string path;
        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            idx = prev_index_locked(e);
            if (idx >= 0 && idx < (int)e->playlist.size())
            {
                path = e->playlist[(size_t)idx];
            }
        }

        if (idx < 0)
        {
            set_last_error(e, "No previous track (loop mode may be off).");
            return false;
        }

        e->pendingAutoPlay.store(true, std::memory_order_relaxed);

        if (!is_network_url(path))
        {
            execute_jump_direct(e, idx);
        }
        else
        {
            request_jump(e, idx);
        }

        {
            std::lock_guard<std::mutex> devLock(e->deviceMutex);
            if (ma_device_get_state(&e->device) != ma_device_state_started)
            {
                if (ma_device_start(&e->device) != MA_SUCCESS)
                {
                    engine_log("Failed to start device in ae_prev");
                }
            }
        }

        clear_last_error(e);
        return true;
    }

    AE_API bool ae_jump_to(AudioEngineHandle *e, int index)
    {
        if (e == nullptr || index < 0)
        {
            set_last_error(e, "Invalid jump_to index.");
            return false;
        }

        std::string path;
        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            if (index >= (int)e->playlist.size())
            {
                set_last_error(e, "jump_to index out of range.");
                return false;
            }
            path = e->playlist[(size_t)index];
        }

        e->pendingSeekValid.store(false, std::memory_order_release);
        e->pendingSeekIndex.store(-1, std::memory_order_release);
        e->pendingAutoPlay.store(true, std::memory_order_relaxed);

        if (!is_network_url(path))
        {
            execute_jump_direct(e, index);
        }
        else
        {
            request_jump(e, index);
        }

        {
            std::lock_guard<std::mutex> devLock(e->deviceMutex);
            if (ma_device_get_state(&e->device) != ma_device_state_started)
            {
                if (ma_device_start(&e->device) != MA_SUCCESS)
                {
                    engine_log("Failed to start device in ae_jump_to");
                }
            }
        }

        engine_log("jump_to requested: index=%d", index);
        clear_last_error(e);
        return true;
    }

    AE_API bool ae_jump_to_with_position(AudioEngineHandle *e, int index, double position_seconds)
    {
        if (e == nullptr || index < 0)
        {
            set_last_error(e, "Invalid jump_to_with_position input.");
            return false;
        }

        std::string path;
        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            if (index >= (int)e->playlist.size())
            {
                set_last_error(e, "jump_to_with_position index out of range.");
                return false;
            }
            path = e->playlist[(size_t)index];
        }

        const double pos = std::max(0.0, position_seconds);
        const ma_uint64 frame = (ma_uint64)(pos * (double)e->sampleRate);

        e->pendingSeekFrame.store(frame, std::memory_order_release);
        e->pendingSeekIndex.store(index, std::memory_order_release);
        e->pendingSeekValid.store(true, std::memory_order_release);
        e->pendingAutoPlay.store(true, std::memory_order_relaxed);

        if (!is_network_url(path))
        {
            execute_jump_direct(e, index);
        }
        else
        {
            request_jump(e, index);
        }

        {
            std::lock_guard<std::mutex> devLock(e->deviceMutex);
            if (ma_device_get_state(&e->device) != ma_device_state_started)
            {
                if (ma_device_start(&e->device) != MA_SUCCESS)
                {
                    engine_log("Failed to start device in ae_jump_to_with_position");
                }
            }
        }

        engine_log("jump_to_with_position requested: index=%d frame=%llu", index, (unsigned long long)frame);
        clear_last_error(e);
        return true;
    }

    AE_API int ae_is_network_streaming_supported(void)
    {
#if (defined(SAUTIFLOW_ENABLE_FFMPEG) && SAUTIFLOW_ENABLE_FFMPEG) || (defined(AE_ENABLE_CURL) && AE_ENABLE_CURL)
        return 1;
#else
        return 0;
#endif
    }

    AE_API int ae_get_stream_telemetry(AudioEngineHandle *e,
                                       int *out_state,
                                       int *out_error_code,
                                       double *out_buffered_duration_sec,
                                       double *out_total_duration_sec,
                                       double *out_buffer_percent,
                                       int64_t *out_bitrate,
                                       char *out_codec_name, int codec_name_len,
                                       char *out_icy_title, int icy_title_len,
                                       char *out_icy_artist, int icy_artist_len)
    {
        sautiflow::StreamTelemetry tel;
        if (e != nullptr && e->currentDecoder != nullptr) {
            tel = sautiflow::get_stream_telemetry_from_decoder(e->currentDecoder);
        } else {
            tel = sautiflow::get_active_stream_telemetry();
        }

        if (out_state) *out_state = (int)tel.state;
        if (out_error_code) *out_error_code = (int)tel.errorCode;
        if (out_buffered_duration_sec) *out_buffered_duration_sec = tel.bufferedDurationSec;
        if (out_total_duration_sec) *out_total_duration_sec = tel.totalDurationSec;
        if (out_buffer_percent) *out_buffer_percent = tel.bufferPercent;
        if (out_bitrate) *out_bitrate = tel.bitrate;
        if (out_codec_name && codec_name_len > 0) {
            std::strncpy(out_codec_name, tel.codecName, codec_name_len - 1);
            out_codec_name[codec_name_len - 1] = '\0';
        }
        if (out_icy_title && icy_title_len > 0) {
            std::strncpy(out_icy_title, tel.icyTitle, icy_title_len - 1);
            out_icy_title[icy_title_len - 1] = '\0';
        }
        if (out_icy_artist && icy_artist_len > 0) {
            std::strncpy(out_icy_artist, tel.icyArtist, icy_artist_len - 1);
            out_icy_artist[icy_artist_len - 1] = '\0';
        }
        return 1;
    }

    AE_API int ae_is_stream_live(AudioEngineHandle *e)
    {
        sautiflow::StreamTelemetry tel;
        if (e != nullptr && e->currentDecoder != nullptr) {
            tel = sautiflow::get_stream_telemetry_from_decoder(e->currentDecoder);
        } else {
            tel = sautiflow::get_active_stream_telemetry();
        }
        return tel.isLiveStream ? 1 : 0;
    }

    AE_API void ae_set_loop_mode(AudioEngineHandle *e, int loop_mode)
    {
        if (e == nullptr)
        {
            return;
        }

        std::lock_guard<std::mutex> pl(e->playlistMutex);
        if (loop_mode < AE_LOOP_OFF)
            loop_mode = AE_LOOP_OFF;
        if (loop_mode > AE_LOOP_ONE)
            loop_mode = AE_LOOP_ONE;
        e->loopMode = loop_mode;
    }

    AE_API void ae_set_shuffle_enabled(AudioEngineHandle *e, int enabled)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> pl(e->playlistMutex);
        e->shuffleEnabled = (enabled != 0);
        rebuild_play_order_locked(e);
    }

    AE_API void ae_reshuffle(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> pl(e->playlistMutex);
        rebuild_play_order_locked(e);
    }

    AE_API void ae_set_ab_repeat(AudioEngineHandle *e, int enabled, double start_seconds, double end_seconds)
    {
        if (e == nullptr)
            return;
        if (start_seconds < 0.0)
            start_seconds = 0.0;
        if (end_seconds < start_seconds)
            end_seconds = start_seconds;

        e->abStartSeconds.store(start_seconds, std::memory_order_release);
        e->abEndSeconds.store(end_seconds, std::memory_order_release);
        e->abRepeatEnabled.store(enabled != 0, std::memory_order_release);
    }

    AE_API void ae_get_ab_repeat(AudioEngineHandle *e, int *out_enabled, double *out_start_seconds, double *out_end_seconds)
    {
        if (e == nullptr)
        {
            if (out_enabled) *out_enabled = 0;
            if (out_start_seconds) *out_start_seconds = 0.0;
            if (out_end_seconds) *out_end_seconds = 0.0;
            return;
        }

        if (out_enabled) *out_enabled = e->abRepeatEnabled.load(std::memory_order_relaxed) ? 1 : 0;
        if (out_start_seconds) *out_start_seconds = e->abStartSeconds.load(std::memory_order_relaxed);
        if (out_end_seconds) *out_end_seconds = e->abEndSeconds.load(std::memory_order_relaxed);
    }

    AE_API void ae_set_crossfade_enabled(AudioEngineHandle *e, int enabled)
    {
        if (e == nullptr)
            return;
        e->crossfadeEnabled.store(enabled != 0, std::memory_order_relaxed);
        if (enabled == 0)
        {
            e->crossfadeFramesTotal.store(0, std::memory_order_relaxed);
            if (e->currentDecoder != nullptr)
            {
                e->crossfadeFramesRemaining.store(0, std::memory_order_relaxed);
            }
        }
    }

    AE_API int ae_get_crossfade_enabled(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0;
        return e->crossfadeEnabled.load(std::memory_order_relaxed) ? 1 : 0;
    }

    AE_API void ae_set_crossfade_duration_ms(AudioEngineHandle *e, int duration_ms)
    {
        if (e == nullptr)
            return;
        e->crossfadeDurationMs.store(clampi(duration_ms, 0, 10000), std::memory_order_relaxed);
    }

    AE_API int ae_get_crossfade_duration_ms(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0;
        return clampi(e->crossfadeDurationMs.load(std::memory_order_relaxed), 0, 10000);
    }

    AE_API void ae_set_loudness_crossfade_enabled(AudioEngineHandle *e, int enabled)
    {
        if (e == nullptr)
            return;
        e->loudnessCrossfadeEnabled.store(enabled != 0, std::memory_order_relaxed);
    }

    AE_API int ae_get_loudness_crossfade_enabled(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0;
        return e->loudnessCrossfadeEnabled.load(std::memory_order_relaxed) ? 1 : 0;
    }

    AE_API void ae_set_next_replay_gain(AudioEngineHandle *e, float gain_db)
    {
        if (e == nullptr)
            return;
        const float linear = (gain_db == 0.0f) ? 1.0f : std::pow(10.0f, gain_db / 20.0f);
        e->nextTrackReplayGain.store(linear, std::memory_order_relaxed);
    }

    AE_API float ae_get_device_latency_ms(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0.0f;
        if (e->device.sampleRate == 0)
            return 0.0f;
            
        uint32_t frames = e->device.playback.internalPeriodSizeInFrames * e->device.playback.internalPeriods;
        return (float)frames / (float)e->device.sampleRate * 1000.0f;
    }

    static double calculate_total_pipeline_latency_samples(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0.0;

        double totalLatency = 0.0;
        const int sr = (e->sampleRate > 0) ? e->sampleRate : 48000;

        std::lock_guard<std::mutex> fx(e->fxMutex);

        if (e->lookaheadLimiterEnabled.load(std::memory_order_relaxed))
        {
            totalLatency += (double)e->lookaheadLimiter.getLatencySamples(sr);
        }
        // The simple limiter has no delay line - it contributes no latency.
        if (e->stereoWidenEnabled)
        {
            totalLatency += e->stereoWiden.getLatencySamples(sr);
        }
        if (e->stereoEnhancementEnabled)
        {
            totalLatency += e->stereoEnhancement.getLatencySamples(sr);
        }
        if (e->crossfeedEnabled)
        {
            totalLatency += e->crossfeedNode.getLatencySamples();
        }
        if (e->reverbEnabled)
        {
            totalLatency += e->reverbNode.getLatencySamples();
        }
        // Clean-room DSP suite: report real pipeline latencies so position
        // reporting / PDC stays aligned when these nodes are active.
        {
            std::unique_lock<std::mutex> dspLock(e->dspMutex, std::try_to_lock);
            if (dspLock.owns_lock())
            {
                if (e->fftConvolverDsp.isEnabled() && e->fftConvolverDsp.hasImpulseResponse())
                {
                    // Partitioned overlap-add convolver delays output by BLOCK_SIZE.
                    totalLatency += (double)sauti::dsp::FFTConvolverDSP::BLOCK_SIZE;
                }
                if (e->masterLimiterDsp.isEnabled())
                {
                    // Look-ahead limiter delays the signal by its lookahead window
                    // (~1.5 ms at the engine sample rate).
                    totalLatency += 0.0015 * (double)sr;
                }
            }
        }
        if (e->deviceResamplerInit)
        {
            totalLatency += (double)ma_resampler_get_input_latency(&e->deviceResampler);
        }

        return totalLatency;
    }

    AE_API double ae_get_engine_latency_samples(AudioEngineHandle *e)
    {
        return calculate_total_pipeline_latency_samples(e);
    }

    AE_API double ae_get_engine_latency_ms(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0.0;
        const int sr = (e->sampleRate > 0) ? e->sampleRate : 48000;
        double samples = ae_get_engine_latency_samples(e);
        return (samples / (double)sr) * 1000.0;
    }

    AE_API PlayerStatus ae_get_status(AudioEngineHandle *e)
    {
        PlayerStatus s{};
        if (e == nullptr)
            return s;

        bool isPlaying = e->isPlaying.load(std::memory_order_relaxed);
        bool hasCurrent = false;

        {
            std::lock_guard<std::mutex> pl(e->playlistMutex);
            s.playlist_count = (int)e->playlist.size();
            s.current_index = e->currentIndex;
            s.shuffle_enabled = e->shuffleEnabled ? 1 : 0;
            s.loop_mode = e->loopMode;
        }

        {
            std::lock_guard<std::mutex> d(e->decoderMutex);
            hasCurrent = e->hasCurrent;
            if (e->hasCurrent)
            {
                ma_uint64 len = e->currentLengthFrames;
                if (len == 0 && e->currentDecoder != nullptr)
                {
                    if (ma_decoder_get_length_in_pcm_frames(e->currentDecoder, &len) == MA_SUCCESS && len > 0)
                    {
                        e->currentLengthFrames = len;
                    }
                }
                ma_uint64 baseFrame = e->seekBasePcmFrame.load(std::memory_order_relaxed);
                ma_uint64 played = e->playedPcmFrames.load(std::memory_order_relaxed);
                ma_uint64 currentFrame = baseFrame + played;
                if (currentFrame > len && len > 0)
                    currentFrame = len;

                const int sr = (e->sampleRate > 0) ? e->sampleRate : 48000;
                const double latencySamples = calculate_total_pipeline_latency_samples(e);
                const double effectiveFrame = ((double)currentFrame > latencySamples) ? ((double)currentFrame - latencySamples) : 0.0;
                s.position_seconds = effectiveFrame / (double)sr;
                s.duration_seconds = (double)len / (double)sr;
            }
        }

        s.is_playing = (isPlaying && (hasCurrent || e->isPushStreamMode)) ? 1 : 0;

        return s;
    }

    AE_API AEPipelineState ae_get_pipeline_state(AudioEngineHandle *e)
    {
        AEPipelineState ps{};
        if (e == nullptr)
            return ps;

        ps.input_format = (int)AE_FORMAT_F32;
        ps.input_sample_rate = (e->sourceSampleRate > 0) ? e->sourceSampleRate : e->sampleRate;
        ps.input_channels = e->channels;

        ps.processing_format = (int)AE_FORMAT_F32;
        ps.processing_sample_rate = e->sampleRate;
        ps.processing_channels = e->channels;

        ps.output_format = (int)e->outputFormat;
        ps.output_sample_rate = (e->outputSampleRate > 0) ? e->outputSampleRate : e->sampleRate;
        ps.output_channels = (e->outputChannels > 0) ? e->outputChannels : e->channels;

        std::lock_guard<std::mutex> fx(e->fxMutex);
        ps.eq_enabled = e->eqEnabled ? 1 : 0;
        ps.reverb_enabled = 0;
        ps.limiter_enabled = e->limiterEnabled ? 1 : 0;
        ps.stereo_widen_enabled = e->stereoWidenEnabled ? 1 : 0;
        ps.stereo_enhancement_enabled = e->stereoEnhancementEnabled ? 1 : 0;
        ps.spatialization_enabled = 0;
        ps.delay_enabled = 0;
        ps.gain = e->gain;
        ps.pan = e->pan;
        ps.pitch = e->pitchMultiplier.load(std::memory_order_relaxed);
        ps.rate = e->rateMultiplier.load(std::memory_order_relaxed);
        ps.pitch_correction_enabled = e->pitchCorrectionEnabled.load(std::memory_order_relaxed) ? 1 : 0;
        return ps;
    }

    AE_API const char *ae_get_last_error(AudioEngineHandle *e)
    {
        static thread_local std::string tlsLastError;
        if (e == nullptr)
            return "";

        std::lock_guard<std::mutex> lk(e->errorMutex);
        tlsLastError = e->lastError;
        return tlsLastError.c_str();
    }

    AE_API void ae_clear_last_error(AudioEngineHandle *e)
    {
        clear_last_error(e);
    }

    AE_API void ae_set_reverb_enabled(AudioEngineHandle *e, int enabled)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->reverbEnabled = (enabled != 0);
        e->reverbNode.setEnabled(enabled != 0);
    }

    AE_API void ae_set_reverb_params(AudioEngineHandle *e, float mix, float feedback, float delay_ms)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        // Legacy 3-param API mapped onto the FDN node:
        //   feedback -> room size (decay), delay_ms -> pre-delay.
        e->reverbNode.setMix(mix);
        e->reverbNode.setRoomSize(feedback);
        e->reverbNode.setPreDelayMs(delay_ms * 0.25f);
    }

    AE_API void ae_set_reverb_params_ex(AudioEngineHandle *e, float mix, float room_size, float damping, float pre_delay_ms, float width)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->reverbNode.setMix(mix);
        e->reverbNode.setRoomSize(room_size);
        e->reverbNode.setDamping(damping);
        e->reverbNode.setPreDelayMs(pre_delay_ms);
        e->reverbNode.setWidth(width);
    }

    AE_API void ae_set_reverb_gains(AudioEngineHandle *e, float wet, float dry)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->reverbNode.setWet(wet);
        e->reverbNode.setDry(dry);
    }

    AE_API void ae_get_reverb_gains(AudioEngineHandle *e, float *out_wet, float *out_dry)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        if (out_wet) *out_wet = e->reverbNode.getWet();
        if (out_dry) *out_dry = e->reverbNode.getDry();
    }

    AE_API void ae_get_reverb_params_ex(AudioEngineHandle *e, int *out_enabled, float *out_mix, float *out_room_size, float *out_damping, float *out_pre_delay_ms, float *out_width)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        if (out_enabled) *out_enabled = e->reverbEnabled ? 1 : 0;
        if (out_mix) *out_mix = e->reverbNode.getWet();
        if (out_room_size) *out_room_size = e->reverbNode.getRoomSize();
        if (out_damping) *out_damping = e->reverbNode.getDamping();
        if (out_pre_delay_ms) *out_pre_delay_ms = e->reverbNode.getPreDelayMs();
        if (out_width) *out_width = e->reverbNode.getWidth();
    }

    AE_API void ae_set_eq_enabled(AudioEngineHandle *e, int enabled)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->eqEnabled = (enabled != 0);
    }

    AE_API void ae_set_eq_gains(AudioEngineHandle *e, float low_gain, float mid_gain, float high_gain)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->eq.lowGain = clampf(low_gain, 0.0f, 4.0f);
        e->eq.midGain = clampf(mid_gain, 0.0f, 4.0f);
        e->eq.highGain = clampf(high_gain, 0.0f, 4.0f);
    }

    AE_API void ae_set_gain(AudioEngineHandle *e, float gain)
    {
        if (e == nullptr)
            return;
        const float g = clampf(gain, 0.0f, 8.0f);
        e->gain.store(g, std::memory_order_relaxed);
        // While stopped, snap the smoothed gain so playback doesn't briefly
        // ramp in from the previous level (e.g. un-muting before play).
        if (!e->isPlaying.load(std::memory_order_acquire))
        {
            std::lock_guard<std::mutex> fx(e->fxMutex);
            e->paramUserGain.setTarget(g);
            e->paramUserGain.current = g;
            e->paramUserGain.step = 0.0f;
        }
    }

    // Applies a ReplayGain offset (in dB) on top of the main gain.
    // gain_db == 0 means no adjustment. Positive boosts, negative attenuates.
    AE_API void ae_set_replay_gain(AudioEngineHandle *e, float gain_db)
    {
        if (e == nullptr)
            return;
        const float linear = (gain_db == 0.0f) ? 1.0f : std::pow(10.0f, gain_db / 20.0f);
        e->replayGainLinear.store(linear, std::memory_order_relaxed);
        e->currentTrackReplayGain.store(linear, std::memory_order_relaxed);
    }

    AE_API void ae_set_pan(AudioEngineHandle *e, float pan_minus1_to_plus1)
    {
        if (e == nullptr)
            return;
        e->pan.store(clampf(pan_minus1_to_plus1, -1.0f, 1.0f), std::memory_order_relaxed);
    }

    AE_API void ae_set_rate(AudioEngineHandle *e, float rate)
    {
        if (e == nullptr)
            return;
        const float clamped = std::clamp(rate, 0.01f, 100.0f);
        const float oldRate = e->rateMultiplier.load(std::memory_order_relaxed);
        if (std::abs(clamped - oldRate) > 0.0005f)
        {
            e->rateMultiplier.store(clamped, std::memory_order_relaxed);
            e->decodeProducerCv.notify_all();
        }
    }

    AE_API float ae_get_rate(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 1.0f;
        return e->rateMultiplier.load(std::memory_order_relaxed);
    }

    AE_API void ae_set_pitch(AudioEngineHandle *e, float pitch)
    {
        if (e == nullptr)
            return;
        const float clamped = std::clamp(pitch, 0.05f, 10.0f);
        const float oldPitch = e->pitchMultiplier.load(std::memory_order_relaxed);
        if (std::abs(clamped - oldPitch) > 0.0005f)
        {
            e->pitchMultiplier.store(clamped, std::memory_order_relaxed);
            e->decodeProducerCv.notify_all();
        }
    }

    AE_API float ae_get_pitch(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 1.0f;
        return e->pitchMultiplier.load(std::memory_order_relaxed);
    }

    AE_API void ae_set_pitch_correction(AudioEngineHandle *e, int enabled)
    {
        if (e == nullptr)
            return;
        e->pitchCorrectionEnabled.store(enabled != 0, std::memory_order_relaxed);
        e->decodeProducerCv.notify_all();
    }

    AE_API int ae_get_pitch_correction(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 1;
        return e->pitchCorrectionEnabled.load(std::memory_order_relaxed) ? 1 : 0;
    }

    AE_API void ae_set_lowpass_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_lowpass_cutoff(AudioEngineHandle *e, float hz)
    {
        (void)e; (void)hz;
    }

    AE_API void ae_set_highpass_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_highpass_cutoff(AudioEngineHandle *e, float hz)
    {
        (void)e; (void)hz;
    }

    AE_API void ae_set_delay_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_delay_params(AudioEngineHandle *e, float mix, float feedback, float delay_ms)
    {
        (void)e; (void)mix; (void)feedback; (void)delay_ms;
    }

    AE_API void ae_set_bandpass_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_bandpass_params(AudioEngineHandle *e, float cutoff_hz, float q)
    {
        (void)e; (void)cutoff_hz; (void)q;
    }

    AE_API void ae_set_peak_eq_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_peak_eq_params(AudioEngineHandle *e, float gain_db, float q, float frequency_hz)
    {
        (void)e; (void)gain_db; (void)q; (void)frequency_hz;
    }

    AE_API void ae_set_notch_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_notch_params(AudioEngineHandle *e, float q, float frequency_hz)
    {
        (void)e; (void)q; (void)frequency_hz;
    }

    AE_API void ae_set_lowshelf_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_lowshelf_params(AudioEngineHandle *e, float gain_db, float slope, float frequency_hz)
    {
        (void)e; (void)gain_db; (void)slope; (void)frequency_hz;
    }

    AE_API void ae_set_highshelf_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_highshelf_params(AudioEngineHandle *e, float gain_db, float slope, float frequency_hz)
    {
        (void)e; (void)gain_db; (void)slope; (void)frequency_hz;
    }

    AE_API void ae_set_custom_lpf1_params(AudioEngineHandle *e, int enabled, double cutoff_hz)
    {
        (void)e; (void)enabled; (void)cutoff_hz;
    }

    AE_API void ae_set_custom_hpf1_params(AudioEngineHandle *e, int enabled, double cutoff_hz)
    {
        (void)e; (void)enabled; (void)cutoff_hz;
    }

    AE_API void ae_set_custom_biquad_params(AudioEngineHandle *e, int enabled, double b0, double b1, double b2, double a0, double a1, double a2)
    {
        (void)e; (void)enabled; (void)b0; (void)b1; (void)b2; (void)a0; (void)a1; (void)a2;
    }

    // --- Crystalizer ---

    AE_API void ae_set_crystalizer_enabled(AudioEngineHandle *e, int enabled)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->crystalizerEnabled = (enabled != 0);
    }

    AE_API void ae_set_crystalizer_params(AudioEngineHandle *e, float intensity, int high_shelf_enabled, float high_shelf_gain_db)
    {
        if (e == nullptr)
            return;
        const int sr = (e->outputSampleRate > 0) ? e->outputSampleRate : ((e->sampleRate > 0) ? e->sampleRate : 48000);
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->crystalizer.updateParams(sr, intensity, high_shelf_enabled != 0, high_shelf_gain_db);
    }

    AE_API float ae_get_crystalizer_intensity(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0.0f;
        return e->crystalizer.intensity;
    }

    AE_API void ae_set_stereo_widen(AudioEngineHandle *e, int enabled, float width, float delay_ms)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->stereoWidenEnabled = (enabled != 0);
        e->stereoWiden.updateParams(e->sampleRate, width, delay_ms);
    }

    AE_API void ae_set_stereo_enhancement_enabled(AudioEngineHandle *e, int enabled)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->stereoEnhancementEnabled = (enabled != 0);
    }

    AE_API int ae_get_stereo_enhancement_enabled(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        return e->stereoEnhancementEnabled ? 1 : 0;
    }

    AE_API void ae_set_stereo_enhancement_mix(AudioEngineHandle *e, float mix)
    {
        if (e == nullptr)
            return;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        e->stereoEnhancement.setParam(mix);
    }

    AE_API float ae_get_stereo_enhancement_mix(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0.5f;
        std::lock_guard<std::mutex> fx(e->fxMutex);
        return e->stereoEnhancement.mix;
    }

    AE_API void ae_set_crossfeed_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> lock(engine->fxMutex);
        engine->crossfeedEnabled = (enabled != 0);
        if (engine->crossfeedEnabled)
        {
            if (engine->crossfeedPreset == 4)
            {
                engine->crossfeedNode.setAlgorithm(CrossfeedAlgorithm::RACE);
                engine->crossfeedNode.setSampleRate((double)engine->sampleRate);
            }
            else
            {
                CrossfeedAlgorithm algo = CrossfeedAlgorithm::BS2B;
                if (engine->crossfeedPreset == 0)
                    algo = CrossfeedAlgorithm::Off;
                engine->crossfeedNode.setAlgorithm(algo);
                engine->crossfeedNode.setSampleRate((double)engine->sampleRate);

                // Map preset to mix / cutoff defaults
                if (engine->crossfeedPreset == 1) { engine->crossfeedNode.setMix(0.5f); engine->crossfeedNode.setCutoffHz(700.0f); }
                else if (engine->crossfeedPreset == 2) { engine->crossfeedNode.setMix(0.65f); engine->crossfeedNode.setCutoffHz(700.0f); }
                else if (engine->crossfeedPreset == 3) { engine->crossfeedNode.setMix(0.85f); engine->crossfeedNode.setCutoffHz(650.0f); }
            }
        }
        else
        {
            engine->crossfeedNode.setAlgorithm(CrossfeedAlgorithm::Off);
        }
    }

    AE_API void ae_set_crossfeed_preset(AudioEngineHandle *engine, int preset)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> lock(engine->fxMutex);
        engine->crossfeedPreset = preset;

        if (preset == 4)
        {
            engine->crossfeedNode.setAlgorithm(CrossfeedAlgorithm::RACE);
            engine->crossfeedNode.setSampleRate((double)engine->sampleRate);
        }
        else
        {
            CrossfeedAlgorithm algo = CrossfeedAlgorithm::BS2B;
            if (preset == 0)
                algo = CrossfeedAlgorithm::Off;
            engine->crossfeedNode.setAlgorithm(algo);
            engine->crossfeedNode.setSampleRate((double)engine->sampleRate);
            if (preset == 1) { engine->crossfeedNode.setMix(0.5f); engine->crossfeedNode.setCutoffHz(700.0f); }
            else if (preset == 2) { engine->crossfeedNode.setMix(0.65f); engine->crossfeedNode.setCutoffHz(700.0f); }
            else if (preset == 3) { engine->crossfeedNode.setMix(0.85f); engine->crossfeedNode.setCutoffHz(650.0f); }
        }
    }

    AE_API void ae_set_crossfeed_algorithm(AudioEngineHandle *engine, int algorithm)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> lock(engine->fxMutex);
        CrossfeedAlgorithm algo = static_cast<CrossfeedAlgorithm>(algorithm);
        engine->crossfeedNode.setAlgorithm(algo);
        engine->crossfeedNode.setSampleRate((double)engine->sampleRate);
        // Enable/disable the crossfeed path
        if (algo == CrossfeedAlgorithm::Off)
        {
            engine->crossfeedEnabled = false;
        }
        else
        {
            engine->crossfeedEnabled = true;
        }
    }

    AE_API void ae_set_crossfeed_params(AudioEngineHandle *engine, float mix, float delay_ms, float cutoff_hz, int output_compensation)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> lock(engine->fxMutex);
        engine->crossfeedNode.setMix(mix);
        engine->crossfeedNode.setDelayMs(delay_ms);
        engine->crossfeedNode.setCutoffHz(cutoff_hz);
        engine->crossfeedNode.setOutputCompensation(output_compensation != 0);
    }

    AE_API void ae_get_crossfeed_params(AudioEngineHandle *engine, int *out_algorithm, float *out_mix, float *out_delay_ms, float *out_cutoff_hz, int *out_output_compensation)
    {
        if (!engine)
        {
            if (out_algorithm) *out_algorithm = 0;
            if (out_mix) *out_mix = 0.5f;
            if (out_delay_ms) *out_delay_ms = 0.4f;
            if (out_cutoff_hz) *out_cutoff_hz = 700.0f;
            if (out_output_compensation) *out_output_compensation = 1;
            return;
        }
        std::lock_guard<std::mutex> lock(engine->fxMutex);
        if (out_algorithm) *out_algorithm = static_cast<int>(engine->crossfeedNode.getAlgorithm());
        if (out_mix) *out_mix = engine->crossfeedNode.getMix();
        if (out_delay_ms) *out_delay_ms = engine->crossfeedNode.getDelayMs();
        if (out_cutoff_hz) *out_cutoff_hz = engine->crossfeedNode.getCutoffHz();
        if (out_output_compensation) *out_output_compensation = engine->crossfeedNode.getOutputCompensation() ? 1 : 0;
    }

    AE_API void ae_set_race_params(AudioEngineHandle *engine, float delay_ms, float alpha, float lpf_hz)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> lock(engine->fxMutex);
        engine->crossfeedNode.setRaceParams(delay_ms, alpha, lpf_hz);
        engine->crossfeed.updateRaceParams(engine->sampleRate, delay_ms, alpha, lpf_hz);
    }

    AE_API void ae_set_dynamic_bass_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->harmonicBassDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_set_dynamic_bass_params(AudioEngineHandle *engine, int preset, float gain)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->harmonicBassDsp.setProfile(sauti::dsp::BassEnhanceProfile::DynamicMultiPole);
        engine->harmonicBassDsp.setPreset(preset);
        engine->harmonicBassDsp.setGainDb(gain);
    }

    static void device_notification_callback(const ma_device_notification *pNotification)
    {
        if (pNotification == nullptr || pNotification->pDevice == nullptr)
            return;
        AudioEngineHandle *e = reinterpret_cast<AudioEngineHandle *>(pNotification->pDevice->pUserData);
        if (e == nullptr)
            return;

        if (pNotification->type == ma_device_notification_type_stopped ||
            pNotification->type == ma_device_notification_type_rerouted)
        {
            engine_log("Audio device notification event %d received. Device route or state changed.", (int)pNotification->type);
        }
    }



    // Helper to restart device with new config
    static void restart_and_apply_config(AudioEngineHandle *e)
    {
        if (!e)
            return;
        try
        {
            e->rateTransitionInProgress.store(true, std::memory_order_release);
            std::lock_guard<std::mutex> devLock(e->deviceMutex);
            bool wasPlaying = e->isPlaying.load();

            engine_log("AUTO DISABLE BEGIN\n  old:\n    auto=%s\n    outputRate=%d\n    engineRate=%d\n    deviceRate=%d\n    sourceRate=%d\n    currentIndex=%d\n    hasCurrent=%s\n    isPlaying=%s\n    isCrossfading=%s",
                       e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed) ? "true" : "false",
                       e->outputSampleRate,
                       e->engineSampleRate,
                       e->deviceSampleRate,
                       e->sourceSampleRate,
                       e->currentIndex,
                       e->hasCurrent ? "true" : "false",
                       wasPlaying ? "true" : "false",
                       e->isCrossfading.load(std::memory_order_relaxed) ? "true" : "false");

            engine_log("DEVICE STOP BEGIN");
#if defined(__ANDROID__)
            if (e->pAudioTrackSink != nullptr)
            {
                auto *sink = reinterpret_cast<AndroidAudioTrackSink *>(e->pAudioTrackSink);
                sink->stop();
                sink->release();
            }
#endif
            if (ma_device_get_state(&e->device) == ma_device_state_started)
            {
                ma_device_stop(&e->device);
            }
            engine_log("DEVICE STOP END");

            engine_log("DEVICE UNINIT BEGIN");
            ma_device_uninit(&e->device);
            if (e->customContextInit)
            {
                ma_context_uninit(&e->customContext);
                e->customContextInit = false;
            }
            engine_log("DEVICE UNINIT END");

            // Cleanly finalize any active crossfade before destroying decoder slots
            {
                std::lock_guard<std::mutex> d(e->decoderMutex);
                if (e->isCrossfading.load(std::memory_order_acquire) || e->fadingOutDecoder != nullptr)
                {
                    engine_log("restart_and_apply_config: Terminating active crossfade before rate transition");
                    uninit_fading_out_slot_locked(e);
                    e->crossfadeFramesRemaining.store(0, std::memory_order_release);
                    e->crossfadeFramesTotal.store(0, std::memory_order_release);
                    e->isCrossfading.store(false, std::memory_order_release);
                }
            }

            int oldRate = e->sampleRate > 0 ? e->sampleRate : 48000;
            int targetOutputRate = e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed)
                                   ? e->outputSampleRate
                                   : e->userOutputSampleRate;
            int newRate = targetOutputRate > 0 ? targetOutputRate : 0;
            int newCh = e->outputChannels > 0 ? e->outputChannels : 2;

            bool wantExclusive = e->exclusiveModeEnabled.load(std::memory_order_relaxed) ||
                                 e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed);
#if defined(_WIN32)
            if (e->configuredBackend.load(std::memory_order_relaxed) == AE_BACKEND_DIRECT_HIRES)
            {
                wantExclusive = true;
            }
#endif

            // Exclusive mode requires an explicit sample rate (never 0)
            if (wantExclusive && newRate == 0)
            {
                newRate = (e->sourceSampleRate > 0) ? e->sourceSampleRate : ((e->sampleRate > 0) ? e->sampleRate : 48000);
            }

            const int srForFilterInit = (newRate > 0) ? newRate : ((e->sampleRate > 0) ? e->sampleRate : 48000);
            e->sampleRate = srForFilterInit;
            e->channels = newCh;

            e->update_eq_filters();
            e->update_multiband_fx_filters();
            {
                std::lock_guard<std::mutex> fx(e->fxMutex);
                reinit_advanced_fx_filters(e);
            }

            ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
            switch (e->outputFormat)
            {
            case AE_FORMAT_S16:
                cfg.playback.format = ma_format_s16;
                break;
            case AE_FORMAT_U8:
                cfg.playback.format = ma_format_u8;
                break;
            case AE_FORMAT_S24:
                cfg.playback.format = ma_format_s32; // WASAPI 24-bit PCM container
                break;
            case AE_FORMAT_S32:
                cfg.playback.format = ma_format_s32;
                break;
            default:
                cfg.playback.format = ma_format_f32;
                break;
            }
            cfg.playback.channels = (ma_uint32)newCh;
            cfg.sampleRate = (ma_uint32)newRate; // 0 = native device sample rate for shared mode.
            cfg.dataCallback = data_callback;
            cfg.notificationCallback = device_notification_callback;
            cfg.pUserData = e;

            // The hardware device uses standard linear fallback, while Sautiflow's
            // internal engine resamplers use SoXR VHQ Minimum Phase (e->resampleAlgorithm).
            cfg.resampling.algorithm = ma_resample_algorithm_linear;

            if (e->resampleAlgorithm == 1 /* Sinc Best Quality */ || e->resampleAlgorithm == 2 /* Sinc Medium Quality */)
            {
                cfg.periodSizeInMilliseconds = 50;
                cfg.periods = 3;
            }

            engine_log("DEVICE INIT REQUESTED:\n  requestedRate=%u\n  shareMode=%s\n  exclusive=%s",
                       cfg.sampleRate,
                       wantExclusive ? "exclusive" : "shared",
                       wantExclusive ? "true" : "false");

            bool initOk = false;
            int targetBackend = e->configuredBackend.load(std::memory_order_relaxed);

#if defined(__ANDROID__)
            if (targetBackend == AE_BACKEND_AUDIOTRACK || targetBackend == AE_BACKEND_DIRECT_HIRES)
            {
                if (e->pAudioTrackSink == nullptr)
                {
                    e->pAudioTrackSink = new AndroidAudioTrackSink();
                }
                auto *sink = reinterpret_cast<AndroidAudioTrackSink *>(e->pAudioTrackSink);
                bool wantDirect = (targetBackend == AE_BACKEND_DIRECT_HIRES);
                int targetRate = (wantDirect && e->sourceSampleRate > 0) ? e->sourceSampleRate : srForFilterInit;

                // AudioTrack sink internally consumes float PCM from data_callback and converts to S24 packed if required
                e->device.playback.format = ma_format_f32;
                e->device.playback.channels = (ma_uint32)newCh;
                e->device.sampleRate = (ma_uint32)targetRate;
                e->device.pUserData = e;

                if (sink->init(e, targetRate, newCh, wantDirect))
                {
                    initOk = true;
                    e->activeBackend.store(targetBackend, std::memory_order_release);
                    engine_log("AudioTrack sink initialized successfully (direct=%s, rate=%d)", wantDirect ? "true" : "false", targetRate);
                }
                else
                {
                    engine_log("AudioTrack sink init failed; falling back to default miniaudio device...");
                }
            }
#endif

            if (!initOk)
            {
                ma_context *pContextToUse = nullptr;
#if defined(__ANDROID__)
                if (targetBackend == AE_BACKEND_AAUDIO || targetBackend == AE_BACKEND_OPENSL)
                {
                    ma_backend backends[1];
                    backends[0] = (targetBackend == AE_BACKEND_AAUDIO) ? ma_backend_aaudio : ma_backend_opensl;
                    if (ma_context_init(backends, 1, nullptr, &e->customContext) == MA_SUCCESS)
                    {
                        e->customContextInit = true;
                        pContextToUse = &e->customContext;
                    }
                }
#endif
                if (wantExclusive)
                {
                    cfg.playback.shareMode = ma_share_mode_exclusive;
                    cfg.performanceProfile = ma_performance_profile_low_latency;
                    cfg.periodSizeInMilliseconds = 25;
                    cfg.periods = 4;
                    cfg.wasapi.noAutoConvertSRC = 1;
                    cfg.wasapi.noDefaultQualitySRC = 1;
                    cfg.alsa.noMMap = 0;
                    cfg.noPreSilencedOutputBuffer = 0;

                    apply_buffer_policy(e, cfg);

                    if (ma_device_init(pContextToUse, &cfg, &e->device) == MA_SUCCESS)
                    {
                        initOk = true;
                        engine_log("Exclusive/Low-Latency Mode initialized successfully at %u Hz.", cfg.sampleRate);
                    }
                    else
                    {
                        engine_log("Hardware declined Exclusive Mode config at %u Hz. Falling back to Shared Mode...", cfg.sampleRate);
                    }
                }

                if (!initOk)
                {
                    cfg.playback.shareMode = ma_share_mode_shared;
                    cfg.performanceProfile = ma_performance_profile_conservative;
                    cfg.sampleRate = 0;
                    cfg.wasapi.noAutoConvertSRC = 0;
                    cfg.wasapi.noDefaultQualitySRC = 0;
                    cfg.noPreSilencedOutputBuffer = 0;

                    apply_buffer_policy(e, cfg);

                    if (ma_device_init(pContextToUse, &cfg, &e->device) == MA_SUCCESS)
                    {
                        initOk = true;
                        engine_log("Shared Mode initialized successfully at DAC rate %u Hz.", e->device.sampleRate);
                    }
                    else
                    {
                        engine_log("Hardware declined standard Shared Mode config. Attempting failsafe baseline config...");
                        ma_device_config safeCfg = ma_device_config_init(ma_device_type_playback);
                        safeCfg.playback.format = ma_format_f32;
                        safeCfg.playback.channels = 2;
                        safeCfg.sampleRate = 0;
                        safeCfg.dataCallback = data_callback;
                        safeCfg.notificationCallback = device_notification_callback;
                        safeCfg.pUserData = e;

                        if (ma_device_init(pContextToUse, &safeCfg, &e->device) == MA_SUCCESS)
                        {
                            initOk = true;
                            engine_log("Failsafe baseline Shared Mode initialized successfully at %u Hz.", e->device.sampleRate);
                        }
                    }
                }

                if (initOk)
                {
                    int reportedBackend = AE_BACKEND_AUTO;
                    if (e->device.pContext != nullptr)
                    {
                        if (e->device.pContext->backend == ma_backend_aaudio) reportedBackend = AE_BACKEND_AAUDIO;
                        else if (e->device.pContext->backend == ma_backend_opensl) reportedBackend = AE_BACKEND_OPENSL;
                    }
                    e->activeBackend.store(reportedBackend, std::memory_order_release);
                }
            }

            if (!initOk)
            {
                set_last_error(e, "Failed to re-initialize audio output device.");
                e->rateTransitionInProgress.store(false, std::memory_order_release);
                return;
            }

            engine_log("DEVICE INIT RESULT:\n  actualRate=%u", e->device.sampleRate);

            {
                const uint32_t actualRate = e->device.sampleRate;
                uint32_t srcRate = (e->sourceSampleRate > 0) ? (uint32_t)e->sourceSampleRate : actualRate;
                AudioRatePlan plan = calculateRatePlan(
                    srcRate,
                    actualRate,
                    (uint32_t)e->userOutputSampleRate,
                    e->autoSampleRateMatchEnabled.load(std::memory_order_relaxed),
                    e->exclusiveModeEnabled.load(std::memory_order_relaxed)
                );
                engine_log("APPLY RATE PLAN:\n  source=%u\n  engine=%u\n  device=%u\n  decoderSRC=%s\n  deviceSRC=%s",
                           plan.sourceRate, plan.engineRate, plan.deviceRate,
                           plan.decoderSRC ? "true" : "false", plan.deviceSRC ? "true" : "false");
                applyRatePlan(e, plan);
            }

            // Cleanly reset pitch resampler state and buffers for new sample rate
            {
                std::lock_guard<std::mutex> d(e->decoderMutex);
                if (e->pitchResamplerInit)
                {
                    ma_resampler_uninit(&e->pitchResampler, nullptr);
                    e->pitchResamplerInit = false;
                }
                e->pitchInputBuffer.clear();
                e->pitchInputUnconsumed = 0;
                e->tempoProcessor.reset();
            }

            // Scale absolute time counter to the new sample rate
            {
                const ma_uint64 oldAbsTime = e->engineAbsoluteTime.load(std::memory_order_relaxed);
                const double absSec = (oldRate > 0) ? ((double)oldAbsTime / (double)oldRate) : 0.0;
                e->engineAbsoluteTime.store((ma_uint64)(absSec * (double)e->sampleRate), std::memory_order_relaxed);
            }

            // Re-initialize active decoders to match new outCh so miniaudio downmixes properly
            ma_uint64 resumeFrame = 0;
            int resumeIndex = -1;
            bool hadDecoder = false;
            {
                std::lock_guard<std::mutex> d(e->decoderMutex);
                if (e->hasCurrent && e->currentDecoder)
                {
                    hadDecoder = true;
                    resumeIndex = e->currentIndex;
                    (void)ma_decoder_get_cursor_in_pcm_frames(e->currentDecoder, &resumeFrame);
                    engine_log("OLD DECODER DESTROY");
                    uninit_decoder_slot(
                        e,
                        e->currentDecoder
    #if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        ,
                        e->currentStream
    #endif
                    );
                    e->currentDecoder = nullptr;
                    e->hasCurrent = false;
                }
                if (e->hasNext && e->nextDecoder)
                {
                    uninit_decoder_slot(
                        e,
                        e->nextDecoder
    #if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        ,
                        e->nextStream
    #endif
                    );
                    e->nextDecoder = nullptr;
                    e->hasNext = false;
                }
                uninit_fading_out_slot_locked(e);
            }

            if (hadDecoder && resumeIndex >= 0)
            {
                std::string path;
                {
                    std::lock_guard<std::mutex> pl(e->playlistMutex);
                    if (resumeIndex < (int)e->playlist.size())
                    {
                        path = e->playlist[(size_t)resumeIndex];
                    }
                }
                if (!path.empty())
                {
                    ma_decoder *newDec = nullptr;
                    ma_uint64 newLen = 0;
    #if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    NetworkStreamState *newSt = nullptr;
                    if (load_decoder_for_path(e, path, &newDec, &newLen, &newSt))
    #else
                    if (load_decoder_for_path(e, path, &newDec, &newLen))
    #endif
                    {
                        engine_log("NEW DECODER CREATED:\n  outputRate=%u", newDec->outputSampleRate);
                        if (resumeFrame > 0 && oldRate > 0)
                        {
                            const double posSec = (double)resumeFrame / (double)oldRate;
                            const ma_uint64 decRate = (newDec->outputSampleRate > 0) ? (ma_uint64)newDec->outputSampleRate : (ma_uint64)e->sampleRate;
                            const ma_uint64 targetFrame = (ma_uint64)(posSec * (double)decRate);
                            (void)ma_decoder_seek_to_pcm_frame(newDec, targetFrame);
                            e->seekBasePcmFrame.store(targetFrame, std::memory_order_release);
                        }
                        else
                        {
                            e->seekBasePcmFrame.store(0, std::memory_order_release);
                        }
                        e->playedPcmFrames.store(0, std::memory_order_release);

                        std::lock_guard<std::mutex> d(e->decoderMutex);
                        e->currentDecoder = newDec;
                        e->currentLengthFrames = newLen;
                        e->currentIndex = resumeIndex;
                        e->hasCurrent = true;
    #if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                        e->currentStream = newSt;
    #endif
                    }
                }
            }

            // WIPE ALL OLD-RATE PCM SAMPLES FROM RING BUFFER TO ELIMINATE PITCH/TEMPO SHIFTS
            e->ringBufferFlushing.store(true, std::memory_order_release);
            e->pcmRingBuffer.reset();
            e->ringBufferFlushing.store(false, std::memory_order_release);
            engine_log("RING BUFFER RESET");
            e->decodeProducerCv.notify_one();



            if (wasPlaying)
            {
                engine_log("DEVICE START");
#if defined(__ANDROID__)
                if (e->pAudioTrackSink != nullptr && e->activeBackend.load(std::memory_order_relaxed) >= AE_BACKEND_AUDIOTRACK)
                {
                    reinterpret_cast<AndroidAudioTrackSink *>(e->pAudioTrackSink)->start();
                }
                else
#endif
                {
                    ma_device_start(&e->device);
                }
            }

            request_preload(e);
            e->rateTransitionInProgress.store(false, std::memory_order_release);
            engine_log("AUTO DISABLE END");
        }
        catch (...)
        {
            e->rateTransitionInProgress.store(false, std::memory_order_release);
            engine_log("restart_and_apply_config exception caught cleanly");
        }
    }

    // --- Spatialization (3D Audio) ---

    AE_API void ae_set_spatialization_enabled(AudioEngineHandle *e, int enabled)
    {
        (void)e; (void)enabled;
    }

    AE_API void ae_set_position(AudioEngineHandle *e, float x, float y, float z)
    {
        (void)e; (void)x; (void)y; (void)z;
    }

    AE_API void ae_set_direction(AudioEngineHandle *e, float x, float y, float z)
    {
        (void)e; (void)x; (void)y; (void)z;
    }

    AE_API void ae_set_velocity(AudioEngineHandle *e, float x, float y, float z)
    {
        (void)e; (void)x; (void)y; (void)z;
    }

    AE_API void ae_set_sound_cone(AudioEngineHandle *e, float inner_angle_rad, float outer_angle_rad, float outer_gain)
    {
        (void)e; (void)inner_angle_rad; (void)outer_angle_rad; (void)outer_gain;
    }

    AE_API void ae_set_attenuation_model(AudioEngineHandle *e, int model)
    {
        (void)e; (void)model;
    }

    AE_API void ae_set_rolloff(AudioEngineHandle *e, float rolloff)
    {
        (void)e; (void)rolloff;
    }

    AE_API void ae_set_min_gain(AudioEngineHandle *e, float min_gain)
    {
        (void)e; (void)min_gain;
    }

    AE_API void ae_set_max_gain(AudioEngineHandle *e, float max_gain)
    {
        (void)e; (void)max_gain;
    }

    AE_API void ae_set_min_distance(AudioEngineHandle *e, float min_distance)
    {
        (void)e; (void)min_distance;
    }

    AE_API void ae_set_max_distance(AudioEngineHandle *e, float max_distance)
    {
        (void)e; (void)max_distance;
    }

    AE_API void ae_set_doppler_factor(AudioEngineHandle *e, float doppler_factor)
    {
        (void)e; (void)doppler_factor;
    }

    // --- Listener 3D Spatialization Controls ---

    AE_API void ae_set_listener_position(AudioEngineHandle *e, float x, float y, float z)
    {
        (void)e; (void)x; (void)y; (void)z;
    }

    AE_API void ae_set_listener_direction(AudioEngineHandle *e, float x, float y, float z)
    {
        (void)e; (void)x; (void)y; (void)z;
    }

    AE_API void ae_set_listener_velocity(AudioEngineHandle *e, float x, float y, float z)
    {
        (void)e; (void)x; (void)y; (void)z;
    }

    AE_API void ae_set_listener_world_up(AudioEngineHandle *e, float x, float y, float z)
    {
        (void)e; (void)x; (void)y; (void)z;
    }

    AE_API void ae_set_listener_cone(AudioEngineHandle *e, float inner_angle_rad, float outer_angle_rad, float outer_gain)
    {
        (void)e; (void)inner_angle_rad; (void)outer_angle_rad; (void)outer_gain;
    }


    // --- Fading & Scheduling ---

    AE_API void ae_set_fade_in_milliseconds(AudioEngineHandle *e, float volume_beg, float volume_end, int time_ms)
    {
        if (e == nullptr || time_ms <= 0)
            return;
        const int sr = (e->sampleRate > 0) ? e->sampleRate : 48000;
        const ma_uint64 fadeFrames = (ma_uint64)((double)sr * ((double)time_ms / 1000.0));

        e->customFadeVolumeBeg.store(volume_beg, std::memory_order_relaxed);
        e->customFadeVolumeEnd.store(volume_end, std::memory_order_relaxed);
        e->customFadeFramesTotal.store(fadeFrames, std::memory_order_relaxed);
        e->customFadeFramesRemaining.store(fadeFrames, std::memory_order_relaxed);
        e->customFadeArmed.store(true, std::memory_order_release);
    }

    AE_API void ae_set_start_time_in_pcm_frames(AudioEngineHandle *e, uint64_t absolute_time)
    {
        if (e == nullptr)
            return;
        e->scheduledStartTime.store(absolute_time, std::memory_order_relaxed);
    }

    AE_API void ae_set_stop_time_in_pcm_frames(AudioEngineHandle *e, uint64_t absolute_time)
    {
        if (e == nullptr)
            return;
        e->scheduledStopTime.store(absolute_time, std::memory_order_relaxed);
    }

    AE_API uint64_t ae_get_engine_time_in_pcm_frames(AudioEngineHandle *e)
    {
        if (e == nullptr)
            return 0;
        return e->engineAbsoluteTime.load(std::memory_order_relaxed);
    }

    AE_API void ae_set_end_callback(AudioEngineHandle *e, AE_EndCallback callback, void *pUserData)
    {
        if (e == nullptr)
            return;
        // Swap both pointers atomically with respect to the producer thread,
        // which snapshots them under decoderMutex before invoking.
        std::lock_guard<std::mutex> d(e->decoderMutex);
        e->endCallback = callback;
        e->pEndCallbackUserData = pUserData;
    }

    // Advanced Audio Controls
    AE_API void ae_set_exclusive_mode(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        bool wantExclusive = (enabled != 0);
        if (engine->exclusiveModeEnabled.load(std::memory_order_relaxed) == wantExclusive)
            return;

        engine->exclusiveModeEnabled.store(wantExclusive, std::memory_order_relaxed);
        restart_and_apply_config(engine);
    }

    AE_API int ae_get_exclusive_mode(AudioEngineHandle *engine)
    {
        return engine ? (engine->exclusiveModeEnabled.load(std::memory_order_relaxed) ? 1 : 0) : 0;
    }

    AE_API int ae_is_backend_supported(AudioEngineHandle *engine, int backend)
    {
        if (!engine)
            return 0;
        if (backend == AE_BACKEND_AUTO)
            return 1;

#if defined(__ANDROID__)
        if (backend == AE_BACKEND_AAUDIO)
        {
            char sdkStr[PROP_VALUE_MAX] = {0};
            __system_property_get("ro.build.version.sdk", sdkStr);
            int sdk = std::atoi(sdkStr);
            return (sdk >= 26 || sdk == 0) ? 1 : 0;
        }
        if (backend == AE_BACKEND_OPENSL)
        {
            return 1;
        }
        if (backend == AE_BACKEND_AUDIOTRACK)
        {
            return (g_androidJavaVM != nullptr) ? 1 : 0;
        }
        if (backend == AE_BACKEND_DIRECT_HIRES)
        {
            return (g_androidJavaVM != nullptr) ? 1 : 0;
        }
        return 0;
#elif defined(_WIN32)
        if (backend == AE_BACKEND_DIRECT_HIRES)
            return 1;
        return 0;
#elif defined(__APPLE__)
        if (backend == AE_BACKEND_DIRECT_HIRES)
            return 1;
        return 0;
#elif defined(__linux__)
        if (backend == AE_BACKEND_DIRECT_HIRES)
            return 1;
        return 0;
#else
        return 0;
#endif
    }

    AE_API int ae_set_output_backend(AudioEngineHandle *engine, int backend)
    {
        if (!engine)
            return 0;
        if (backend < 0 || backend > AE_BACKEND_DIRECT_HIRES)
            return 0;

        if (!ae_is_backend_supported(engine, backend))
        {
            engine_log("Requested backend %d is not supported on this platform/device", backend);
            return 0;
        }

        if (engine->configuredBackend.load(std::memory_order_relaxed) == backend)
        {
            return 1;
        }

        engine_log("Setting output backend to: %d", backend);
        engine->configuredBackend.store(backend, std::memory_order_relaxed);
        restart_and_apply_config(engine);
        return 1;
    }

    AE_API int ae_get_output_backend(AudioEngineHandle *engine)
    {
        if (!engine)
            return AE_BACKEND_AUTO;
        return engine->activeBackend.load(std::memory_order_relaxed);
    }


    AE_API void ae_set_output_format(AudioEngineHandle *engine, int format)
    {
        if (!engine)
            return;
        if (engine->outputFormat == (AEAudioFormat)format)
            return;
        // No unlocked ma_device_stop() here: restart_and_apply_config() already
        // stops/uninits the device while holding deviceMutex. Stopping outside
        // the lock raced a concurrent control call into a double-uninit.
        engine->outputFormat = (AEAudioFormat)format;
        restart_and_apply_config(engine);
    }

    AE_API int ae_get_output_format(AudioEngineHandle *engine)
    {
        return engine ? (int)engine->outputFormat : 0;
    }

    AE_API void ae_set_output_sample_rate(AudioEngineHandle *engine, int sample_rate)
    {
        if (!engine || sample_rate < 0)
            return;
        if (!engine->autoSampleRateMatchEnabled.load(std::memory_order_relaxed))
        {
            engine->userOutputSampleRate = sample_rate;
        }
        if (engine->outputSampleRate == sample_rate)
            return;
            
        // Fix: Do not use restart_device_rate_only because it does not recreate the decoder.
        // We must recreate the decoder so its targetRate matches the new outputSampleRate,
        // otherwise miniaudio will feed data at the old rate into the new device buffer rate,
        // causing pitch/speed shifts.
        engine->outputSampleRate = sample_rate;
        restart_and_apply_config(engine);
    }

    AE_API int ae_get_output_sample_rate(AudioEngineHandle *engine)
    {
        if (!engine)
            return 0;
        if (engine->autoSampleRateMatchEnabled.load(std::memory_order_relaxed))
        {
            return engine->outputSampleRate;
        }
        // 0 = native/unset: report the ACTIVE hardware rate instead of the
        // unset sentinel, so callers never see a bogus 0 Hz on a fresh engine.
        if (engine->userOutputSampleRate != 0)
            return engine->userOutputSampleRate;
        if (engine->outputSampleRate != 0)
            return engine->outputSampleRate;
        return (int)engine->device.sampleRate;
    }

    AE_API void ae_set_output_channels(AudioEngineHandle *engine, int channels)
    {
        if (!engine || channels <= 0)
            return;
        if (engine->outputChannels == channels)
            return;
        // See ae_set_output_format(): no unlocked stop; restart handles it under deviceMutex.
        engine->outputChannels = channels;
        restart_and_apply_config(engine);
    }

    AE_API int ae_get_output_channels(AudioEngineHandle *engine)
    {
        return engine ? engine->outputChannels : 0;
    }

    AE_API void ae_set_output_buffer(AudioEngineHandle *engine, int period_frames, int period_count)
    {
        if (!engine)
            return;

        int clampedFrames = 0;
        if (period_frames > 0)
        {
            clampedFrames = clampi(period_frames, 16, 16384);
        }

        int clampedCount = 0;
        if (period_count > 0)
        {
            clampedCount = clampi(period_count, 2, 16);
        }

        if (engine->userPeriodFrames.load(std::memory_order_relaxed) == clampedFrames &&
            engine->userPeriodCount.load(std::memory_order_relaxed) == clampedCount)
        {
            return;
        }

        engine->userPeriodFrames.store(clampedFrames, std::memory_order_relaxed);
        engine->userPeriodCount.store(clampedCount, std::memory_order_relaxed);

        restart_and_apply_config(engine);
    }

    AE_API void ae_get_output_buffer(AudioEngineHandle *engine, int *out_period_frames, int *out_period_count)
    {
        if (!engine)
        {
            if (out_period_frames) *out_period_frames = 0;
            if (out_period_count) *out_period_count = 0;
            return;
        }
        if (out_period_frames)
        {
            *out_period_frames = engine->userPeriodFrames.load(std::memory_order_relaxed);
        }
        if (out_period_count)
        {
            *out_period_count = engine->userPeriodCount.load(std::memory_order_relaxed);
        }
    }

    AE_API void ae_set_engine_resample_algorithm(AudioEngineHandle *engine, int algorithm)
    {
        if (!engine)
            return;
        engine->resampleAlgorithm = algorithm;
        restart_and_apply_config(engine);
    }

    AE_API int ae_get_engine_resample_algorithm(AudioEngineHandle *engine)
    {
        return engine ? engine->resampleAlgorithm : 0;
    }

    AE_API void ae_set_engine_dither_mode(AudioEngineHandle *engine, int dither_mode)
    {
        if (!engine)
            return;
        int prevMode = engine->ditherMode.exchange(dither_mode, std::memory_order_relaxed);
        if (prevMode != dither_mode)
        {
            engine->ditherProcessor.reset();
        }
    }

    AE_API int ae_get_engine_dither_mode(AudioEngineHandle *engine)
    {
        return engine ? engine->ditherMode.load(std::memory_order_relaxed) : 0;
    }

    AE_API void ae_set_64bit_processing_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        engine->use64BitProcessing.store(enabled != 0, std::memory_order_relaxed);
    }

    AE_API int ae_get_64bit_processing_enabled(AudioEngineHandle *engine)
    {
        return engine ? (engine->use64BitProcessing.load(std::memory_order_relaxed) ? 1 : 0) : 0;
    }

    AE_API void ae_set_auto_sample_rate_match_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        const bool prev = engine->autoSampleRateMatchEnabled.load(std::memory_order_relaxed);
        const bool next = (enabled != 0);
        if (prev != next)
        {
            engine->autoSampleRateMatchEnabled.store(next, std::memory_order_relaxed);
            if (!next)
            {
                // Restore active output rate to user's configured rate (0 = native) when disabling Auto Sample-Rate Match
                engine->outputSampleRate = engine->userOutputSampleRate;
                restart_and_apply_config(engine);
            }
            else
            {
                restart_and_apply_config(engine);
            }
        }
    }

    AE_API int ae_get_auto_sample_rate_match_enabled(AudioEngineHandle *engine)
    {
        return engine ? (engine->autoSampleRateMatchEnabled.load(std::memory_order_relaxed) ? 1 : 0) : 0;
    }

    AE_API void ae_set_auto_bit_perfect_enabled(AudioEngineHandle *engine, int enabled)
    {
        ae_set_auto_sample_rate_match_enabled(engine, enabled);
    }

    AE_API int ae_get_auto_bit_perfect_enabled(AudioEngineHandle *engine)
    {
        return ae_get_auto_sample_rate_match_enabled(engine);
    }

    // Called from the Dart control thread (e.g. on status poll) to safely apply
    // a pending Auto Sample-Rate Match sample rate change detected by worker_loop.
    // Returns the new sample rate, or 0 if nothing is pending.
    // The caller is responsible for calling ae_set_output_sample_rate() which
    // triggers restart_and_apply_config() from the correct (control) thread context.
    AE_API int ae_consume_pending_rate_change(AudioEngineHandle *engine)
    {
        if (!engine)
            return 0;
        // Do not consume/apply hardware rate switch mid-crossfade (Requirement 7)
        if (engine->isCrossfading.load(std::memory_order_acquire))
        {
            return 0;
        }
        // Atomically read and clear the pending rate
        int pending = engine->pendingAutoSampleRateMatchRate.exchange(0, std::memory_order_acq_rel);
        if (pending > 0 && pending != engine->outputSampleRate)
        {
            engine_log("ae_consume_pending_rate_change: Applying deferred Auto Sample-Rate Match rate = %d Hz", pending);
            return pending;
        }
        return 0;
    }

    AE_API void ae_set_phase_inversion(AudioEngineHandle *engine, int invert_left, int invert_right)
    {
        if (!engine)
            return;
        engine->phaseInvertLeft.store(invert_left != 0, std::memory_order_relaxed);
        engine->phaseInvertRight.store(invert_right != 0, std::memory_order_relaxed);
        engine_log("Phase Inversion updated: Left=%d, Right=%d", invert_left != 0 ? 1 : 0, invert_right != 0 ? 1 : 0);
    }

    AE_API void ae_get_phase_inversion(AudioEngineHandle *engine, int *out_invert_left, int *out_invert_right)
    {
        if (!engine)
        {
            if (out_invert_left) *out_invert_left = 0;
            if (out_invert_right) *out_invert_right = 0;
            return;
        }
        if (out_invert_left)
            *out_invert_left = engine->phaseInvertLeft.load(std::memory_order_relaxed) ? 1 : 0;
        if (out_invert_right)
            *out_invert_right = engine->phaseInvertRight.load(std::memory_order_relaxed) ? 1 : 0;
    }

    // L/R Swap
    AE_API void ae_set_lr_swap(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        engine->lrSwapEnabled.store(enabled != 0, std::memory_order_relaxed);
        engine_log("L/R Swap: %s", enabled ? "ON" : "OFF");
    }

    AE_API int ae_get_lr_swap(AudioEngineHandle *engine)
    {
        if (!engine)
            return 0;
        return engine->lrSwapEnabled.load(std::memory_order_relaxed) ? 1 : 0;
    }

    // Per-Channel Gain (L/R independent trim)
    // gain_left, gain_right: linear multipliers, clamped to [0.0, 4.0] (1.0 = unity, ~+12 dB max)
    AE_API void ae_set_channel_gains(AudioEngineHandle *engine, float gain_left, float gain_right)
    {
        if (!engine)
            return;
        engine->channelGainLeft.store(clampf(gain_left, 0.0f, 4.0f), std::memory_order_relaxed);
        engine->channelGainRight.store(clampf(gain_right, 0.0f, 4.0f), std::memory_order_relaxed);
        engine_log("Channel Gains updated: L=%.3f R=%.3f", gain_left, gain_right);
    }

    AE_API void ae_get_channel_gains(AudioEngineHandle *engine, float *out_gain_left, float *out_gain_right)
    {
        if (!engine)
        {
            if (out_gain_left)  *out_gain_left  = 1.0f;
            if (out_gain_right) *out_gain_right = 1.0f;
            return;
        }
        if (out_gain_left)  *out_gain_left  = engine->channelGainLeft.load(std::memory_order_relaxed);
        if (out_gain_right) *out_gain_right = engine->channelGainRight.load(std::memory_order_relaxed);
    }

    // Audio Limiter & Clipping Detection
    AE_API void ae_set_limiter_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> fx(engine->fxMutex);
        engine->limiterEnabled = (enabled != 0);
    }

    AE_API void ae_set_limiter_params(AudioEngineHandle *engine, float threshold, float attack_ms, float release_ms)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> fx(engine->fxMutex);
        engine->limiter.updateParams(engine->sampleRate, threshold, attack_ms, release_ms);
    }

    // Dynamic Range Compressor
    AE_API void ae_set_compressor_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        engine->compressorEnabled = (enabled != 0);
    }

    // detector: 0 = peak, 1 = RMS. stereo_link: 1 = linked, 0 = dual mono.
    // auto_makeup: derive makeup from threshold/ratio (overrides makeup_gain_db).
    // mix: 0 = dry, 1 = fully compressed.
    AE_API void ae_set_compressor_params(AudioEngineHandle *engine, float threshold_db, float ratio,
                                         float knee_db, float attack_ms, float release_ms,
                                         float makeup_gain_db, int detector, int stereo_link,
                                         int auto_makeup, float mix)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> fx(engine->fxMutex);
        engine->compressor.updateParams(engine->sampleRate, engine->channels, threshold_db, ratio,
                                        knee_db, attack_ms, release_ms, makeup_gain_db,
                                        detector, stereo_link, auto_makeup, mix);
    }

    AE_API float ae_get_compressor_gain_reduction_db(AudioEngineHandle *engine)
    {
        return engine ? engine->compressor.currentGainReductionDB.load(std::memory_order_relaxed) : 0.0f;
    }

    AE_API void ae_set_clipping_detection_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        engine->clippingDetectionEnabled.store(enabled != 0, std::memory_order_relaxed);
    }

    AE_API uint64_t ae_get_clipped_samples_count(AudioEngineHandle *engine)
    {
        if (!engine)
            return 0;
        return engine->clippedSamplesCount.load(std::memory_order_relaxed);
    }

    AE_API void ae_reset_clipped_samples_count(AudioEngineHandle *engine)
    {
        if (!engine)
            return;
        engine->clippedSamplesCount.store(0, std::memory_order_relaxed);
    }

    AE_API void ae_init_multiband_eq(AudioEngineHandle *engine, int band_count, float *frequencies, float *q_factors)
    {
        if (!engine || band_count <= 0)
            return;

        std::lock_guard<std::mutex> lk(engine->eqMutex);
        engine->eqBandCount = band_count;
        engine->eqFrequencies.assign(frequencies, frequencies + band_count);
        engine->eqGains.assign(band_count, 0.0f); // 0dB initially

        if (q_factors)
        {
            engine->eqQ.assign(q_factors, q_factors + band_count);
        }
        else
        {
            engine->eqQ.assign(band_count, 1.0f); // Default Q=1.0
        }

        engine->update_eq_filters();
    }

    AE_API void ae_set_multiband_eq_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> lk(engine->eqMutex);
        engine->multibandEqEnabled = (enabled != 0);
    }

    AE_API void ae_set_multiband_eq_gain(AudioEngineHandle *engine, int band_index, float gain_db)
    {
        if (!engine || band_index < 0)
            return;

        std::lock_guard<std::mutex> lk(engine->eqMutex);
        if (band_index < engine->eqBandCount && band_index < (int)engine->eqFilters.size())
        {
            engine->eqGains[band_index] = gain_db;

            int sr = engine->outputSampleRate > 0 ? engine->outputSampleRate : 48000;
            int ch = engine->outputChannels > 0 ? engine->outputChannels : 2;

            ma_peak2_config config = ma_peak2_config_init(
                ma_format_f32,
                (ma_uint32)ch,
                (ma_uint32)sr,
                gain_db,
                engine->eqQ[band_index],
                engine->eqFrequencies[band_index]);

            // Re-init the filter for this band
            // This resets internal state (history), which might cause a click.
            // Ideally we'd update coeffs, but standard miniaudio usage often implies re-init for param changes
            // unless using lower-level coeff API.
            ma_peak2_init(&config, nullptr, &engine->eqFilters[band_index]);
        }
    }

    AE_API float ae_get_multiband_eq_gain(AudioEngineHandle *engine, int band_index)
    {
        if (!engine || band_index < 0 || band_index >= engine->eqBandCount)
            return 0.0f;
        std::lock_guard<std::mutex> lk(engine->eqMutex);
        return engine->eqGains[band_index];
    }

    AE_API void ae_set_multiband_fx_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> lk(engine->eqMutex);
        engine->multibandFxEnabled = (enabled != 0);
    }

    AE_API void ae_set_multiband_fx_bands(
        AudioEngineHandle *engine,
        int band_count,
        const int *types,
        const float *frequencies,
        const float *q_factors,
        const float *gains_db,
        const float *slopes,
        const int *enabled_flags)
    {
        if (!engine || band_count <= 0 || types == nullptr || frequencies == nullptr)
            return;

        std::lock_guard<std::mutex> lk(engine->eqMutex);
        engine->multibandFxBands.clear();
        engine->multibandFxBands.reserve((size_t)band_count);

        for (int i = 0; i < band_count; ++i)
        {
            AudioEngineHandle::FxBand band{};

            int type = types[i];
            if (type < AE_EQ_BAND_PEAK || type > AE_EQ_BAND_HIGHSHELF)
            {
                type = AE_EQ_BAND_PEAK;
            }

            band.type = type;
            band.enabled = (enabled_flags == nullptr) ? true : (enabled_flags[i] != 0);
            band.frequencyHz = frequencies[i];
            band.q = (q_factors == nullptr) ? 1.0f : q_factors[i];
            band.gainDb = (gains_db == nullptr) ? 0.0f : gains_db[i];
            band.slope = (slopes == nullptr) ? 1.0f : slopes[i];

            engine->multibandFxBands.push_back(band);
        }

        engine->update_multiband_fx_filters();
    }

    AE_API void ae_clear_multiband_fx(AudioEngineHandle *engine)
    {
        if (!engine)
            return;
        std::lock_guard<std::mutex> lk(engine->eqMutex);
        engine->multibandFxBands.clear();
        engine->multibandFxEnabled = false;
    }

    AE_API void ae_set_analyzer_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine)
            return;
        engine->analyzerEnabled.store(enabled != 0, std::memory_order_relaxed);
    }

    AE_API void ae_configure_analyzer(AudioEngineHandle *engine, int frame_size)
    {
        if (!engine)
            return;
        const int size = std::max(64, std::min(frame_size, 8192));

        std::lock_guard<std::mutex> fx(engine->fxMutex);
        std::lock_guard<std::mutex> lk(engine->analyzerMutex);
        engine->analyzerFrameSize = size;
        engine->analyzerAccumulator.assign((size_t)size, 0.0f);
        engine->analyzerLatest.assign((size_t)size, 0.0f);
        engine->analyzerAccumulatorCount = 0;
    }

    AE_API int ae_get_analyzer_frame_size(AudioEngineHandle *engine)
    {
        if (!engine)
            return 0;
        return engine->analyzerFrameSize;
    }

    AE_API int ae_poll_analyzer_frame(AudioEngineHandle *engine, float *out_samples, int max_samples)
    {
        if (!engine || out_samples == nullptr || max_samples <= 0)
            return 0;

        std::lock_guard<std::mutex> lk(engine->analyzerMutex);
        if (engine->analyzerLatest.empty())
            return 0;

        const int n = std::min((int)engine->analyzerLatest.size(), max_samples);
        std::memcpy(out_samples, engine->analyzerLatest.data(), (size_t)n * sizeof(float));
        return n;
    }

    AE_API uint64_t ae_get_analyzer_dropped_frames(AudioEngineHandle *engine)
    {
        if (!engine)
            return 0;
        return engine->analyzerDroppedFrames.load(std::memory_order_relaxed);
    }

    AE_API void ae_init_push_stream(AudioEngineHandle *engine)
    {
        if (!engine)
            return;

        // Force stop any current playback first
        if (engine->isPlaying)
        {
            ae_stop(engine);
        }

        // Unload current decoder if any
        {
            std::lock_guard<std::mutex> d(engine->decoderMutex);
            if (engine->currentDecoder)
            {
                uninit_decoder_slot(
                    engine,
                    engine->currentDecoder
#if defined(AE_ENABLE_CURL) && AE_ENABLE_CURL
                    ,
                    engine->currentStream
#endif
                );
                engine->currentDecoder = nullptr;
                engine->hasCurrent = false;
            }
        }

        std::lock_guard<std::mutex> lk(engine->pushStreamForCurrent.mtx);

        if (engine->pushStreamForCurrent.initialized)
        {
            // Already initialized, maybe reset?
            // For safety, uninit first
            ma_rb_uninit(&engine->pushStreamForCurrent.rb);
            if (engine->pushStreamForCurrent.rbBuffer)
            {
                std::free(engine->pushStreamForCurrent.rbBuffer);
                engine->pushStreamForCurrent.rbBuffer = nullptr;
            }
            engine->pushStreamForCurrent.initialized = false;
        }

        const size_t bufSize = 1024 * 1024 * 4; // 4MB buffer
        engine->pushStreamForCurrent.rbBuffer = std::malloc(bufSize);
        if (!engine->pushStreamForCurrent.rbBuffer)
            return;

        if (ma_rb_init(bufSize, engine->pushStreamForCurrent.rbBuffer, nullptr, &engine->pushStreamForCurrent.rb) == MA_SUCCESS)
        {
            engine->pushStreamForCurrent.initialized = true;
            engine->pushStreamForCurrent.isDone = false;
        }
        else
        {
            std::free(engine->pushStreamForCurrent.rbBuffer);
            engine->pushStreamForCurrent.rbBuffer = nullptr;
        }

        // We do NOT init the decoder here anymore.
        // We set the mode, and let data_callback (or a separate call) init the decoder
        // once data is available.
        // We can add a flag "needsDecoderInit" or just check if currentDecoder is null while isPushStreamMode is true.

        engine->pushStreamAbort.store(false, std::memory_order_release);
        engine->isPushStreamMode = true;

        // Ensure hasCurrent is false so data_callback waits
        {
            std::lock_guard<std::mutex> d(engine->decoderMutex);
            engine->currentDecoder = nullptr;
            engine->hasCurrent = false; // Will trigger decoder init attempts in data_callback
            engine->hasNext = false;
        }
    }

    AE_API void ae_push_stream_chunk(AudioEngineHandle *engine, const unsigned char *data, size_t size)
    {
        if (!engine || !data || size == 0 || !engine->pushStreamForCurrent.initialized)
            return;

        size_t written = 0;
        while (written < size)
        {
            if (engine->pushStreamAbort.load(std::memory_order_acquire))
            {
                engine_log("ae_push_stream_chunk aborted with %zu/%zu bytes written", written, size);
                return;
            }

            void *pWrite = nullptr;
            size_t toWrite = size - written;

            if (ma_rb_acquire_write(&engine->pushStreamForCurrent.rb, &toWrite, &pWrite) == MA_SUCCESS && toWrite > 0)
            {
                std::memcpy(pWrite, data + written, toWrite);
                ma_rb_commit_write(&engine->pushStreamForCurrent.rb, toWrite);
                written += toWrite;
                continue;
            }

            // Buffer full: wait briefly, but honor an abort request (ae_stop)
            // so the calling isolate can never block indefinitely.
            if (engine->pushStreamAbort.load(std::memory_order_acquire))
            {
                engine_log("ae_push_stream_chunk aborted with %zu/%zu bytes written", written, size);
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }

        std::lock_guard<std::mutex> lk(engine->decodeProducerMutex);
        engine->decodeProducerCv.notify_all();
    }

    AE_API void ae_end_push_stream(AudioEngineHandle *engine)
    {
        if (!engine || !engine->pushStreamForCurrent.initialized)
            return;
        engine->pushStreamForCurrent.isDone = true;

        std::lock_guard<std::mutex> lk(engine->decodeProducerMutex);
        engine->decodeProducerCv.notify_all();
    }

    AE_API int ae_get_push_stream_buffered_bytes(AudioEngineHandle *engine)
    {
        if (!engine || !engine->pushStreamForCurrent.initialized)
            return 0;
        return (int)ma_rb_available_read(&engine->pushStreamForCurrent.rb);
    }

    // ==========================================
    // Standalone Filters & Resampler (miniaudio direct bindings)
    // ==========================================

    static ma_format ae_format_to_ma(int format)
    {
        switch (format)
        {
        case AE_FORMAT_F32:
            return ma_format_f32;
        case AE_FORMAT_S16:
            return ma_format_s16;
        case AE_FORMAT_U8:
            return ma_format_u8;
        case AE_FORMAT_S24:
            return ma_format_s24;
        case AE_FORMAT_S32:
            return ma_format_s32;
        default:
            return ma_format_unknown;
        }
    }

    struct AELpf1
    {
        ma_lpf1 filter;
    };
    struct AELpf2
    {
        ma_lpf2 filter;
    };
    struct AELpf
    {
        ma_lpf filter;
    };
    struct AEHpf1
    {
        ma_hpf1 filter;
    };
    struct AEHpf2
    {
        ma_hpf2 filter;
    };
    struct AEHpf
    {
        ma_hpf filter;
    };
    struct AEBiquad
    {
        ma_biquad filter;
    };
    struct AEBpf2
    {
        ma_bpf2 filter;
    };
    struct AEBpf
    {
        ma_bpf filter;
    };
    struct AENotch2
    {
        ma_notch2 filter;
    };
    struct AEPeak2
    {
        ma_peak2 filter;
    };
    struct AELoshelf2
    {
        ma_loshelf2 filter;
    };
    struct AEHishelf2
    {
        ma_hishelf2 filter;
    };
    struct AEResampler
    {
        ma_resampler filter;
        int algorithmChoice = 1;
        // Dither support: when ditherMode > 0 and the caller's format is an
        // integer type, the underlying miniaudio resampler is configured as
        // f32 internally; process() converts int->f32, dithers/quantizes on
        // the target grid via DitherProcessorState, then converts back.
        int requestedFormat = AE_FORMAT_F32;
        int channels = 0;
        int ditherMode = 0;
        bool floatInternal = false;
        std::vector<float> inFloat;
        std::vector<float> outFloat;
        DitherProcessorState dither;
    };

    // LPF1
    AE_API AELpf1 *ae_lpf1_create(int format, int channels, int sample_rate, double cutoff_hz)
    {
        AELpf1 *obj = new AELpf1();
        ma_lpf1_config config = ma_lpf1_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz);
        if (ma_lpf1_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_lpf1_destroy(AELpf1 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_lpf1_reinit(AELpf1 *obj, int format, int channels, int sample_rate, double cutoff_hz)
    {
        if (obj)
        {
            ma_lpf1_config config = ma_lpf1_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz);
            ma_lpf1_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_lpf1_process(AELpf1 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_lpf1_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // LPF2
    AE_API AELpf2 *ae_lpf2_create(int format, int channels, int sample_rate, double cutoff_hz, double q)
    {
        AELpf2 *obj = new AELpf2();
        ma_lpf2_config config = ma_lpf2_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, q);
        if (ma_lpf2_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_lpf2_destroy(AELpf2 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_lpf2_reinit(AELpf2 *obj, int format, int channels, int sample_rate, double cutoff_hz, double q)
    {
        if (obj)
        {
            ma_lpf2_config config = ma_lpf2_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, q);
            ma_lpf2_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_lpf2_process(AELpf2 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_lpf2_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // LPF
    AE_API AELpf *ae_lpf_create(int format, int channels, int sample_rate, double cutoff_hz, int order)
    {
        AELpf *obj = new AELpf();
        ma_lpf_config config = ma_lpf_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, order);
        if (ma_lpf_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_lpf_destroy(AELpf *obj)
    {
        if (obj)
        {
            ma_lpf_uninit(&obj->filter, nullptr);
            delete obj;
        }
    }
    AE_API void ae_lpf_reinit(AELpf *obj, int format, int channels, int sample_rate, double cutoff_hz, int order)
    {
        if (obj)
        {
            ma_lpf_config config = ma_lpf_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, order);
            ma_lpf_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_lpf_process(AELpf *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_lpf_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // HPF1
    AE_API AEHpf1 *ae_hpf1_create(int format, int channels, int sample_rate, double cutoff_hz)
    {
        AEHpf1 *obj = new AEHpf1();
        ma_hpf1_config config = ma_hpf1_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz);
        if (ma_hpf1_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_hpf1_destroy(AEHpf1 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_hpf1_reinit(AEHpf1 *obj, int format, int channels, int sample_rate, double cutoff_hz)
    {
        if (obj)
        {
            ma_hpf1_config config = ma_hpf1_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz);
            ma_hpf1_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_hpf1_process(AEHpf1 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_hpf1_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // HPF2
    AE_API AEHpf2 *ae_hpf2_create(int format, int channels, int sample_rate, double cutoff_hz, double q)
    {
        AEHpf2 *obj = new AEHpf2();
        ma_hpf2_config config = ma_hpf2_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, q);
        if (ma_hpf2_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_hpf2_destroy(AEHpf2 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_hpf2_reinit(AEHpf2 *obj, int format, int channels, int sample_rate, double cutoff_hz, double q)
    {
        if (obj)
        {
            ma_hpf2_config config = ma_hpf2_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, q);
            ma_hpf2_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_hpf2_process(AEHpf2 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_hpf2_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // HPF
    AE_API AEHpf *ae_hpf_create(int format, int channels, int sample_rate, double cutoff_hz, int order)
    {
        AEHpf *obj = new AEHpf();
        ma_hpf_config config = ma_hpf_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, order);
        if (ma_hpf_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_hpf_destroy(AEHpf *obj)
    {
        if (obj)
        {
            ma_hpf_uninit(&obj->filter, nullptr);
            delete obj;
        }
    }
    AE_API void ae_hpf_reinit(AEHpf *obj, int format, int channels, int sample_rate, double cutoff_hz, int order)
    {
        if (obj)
        {
            ma_hpf_config config = ma_hpf_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, order);
            ma_hpf_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_hpf_process(AEHpf *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_hpf_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // BPF2
    AE_API AEBpf2 *ae_bpf2_create(int format, int channels, int sample_rate, double cutoff_hz, double q)
    {
        AEBpf2 *obj = new AEBpf2();
        ma_bpf2_config config = ma_bpf2_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, q);
        if (ma_bpf2_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_bpf2_destroy(AEBpf2 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_bpf2_reinit(AEBpf2 *obj, int format, int channels, int sample_rate, double cutoff_hz, double q)
    {
        if (obj)
        {
            ma_bpf2_config config = ma_bpf2_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, q);
            ma_bpf2_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_bpf2_process(AEBpf2 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_bpf2_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // BPF
    AE_API AEBpf *ae_bpf_create(int format, int channels, int sample_rate, double cutoff_hz, int order)
    {
        AEBpf *obj = new AEBpf();
        ma_bpf_config config = ma_bpf_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, order);
        if (ma_bpf_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_bpf_destroy(AEBpf *obj)
    {
        if (obj)
        {
            ma_bpf_uninit(&obj->filter, nullptr);
            delete obj;
        }
    }
    AE_API void ae_bpf_reinit(AEBpf *obj, int format, int channels, int sample_rate, double cutoff_hz, int order)
    {
        if (obj)
        {
            ma_bpf_config config = ma_bpf_config_init(ae_format_to_ma(format), channels, sample_rate, cutoff_hz, order);
            ma_bpf_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_bpf_process(AEBpf *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_bpf_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // Notch2
    AE_API AENotch2 *ae_notch2_create(int format, int channels, int sample_rate, double q, double cutoff_hz)
    {
        AENotch2 *obj = new AENotch2();
        ma_notch2_config config = ma_notch2_config_init(ae_format_to_ma(format), channels, sample_rate, q, cutoff_hz);
        if (ma_notch2_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_notch2_destroy(AENotch2 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_notch2_reinit(AENotch2 *obj, int format, int channels, int sample_rate, double q, double cutoff_hz)
    {
        if (obj)
        {
            ma_notch2_config config = ma_notch2_config_init(ae_format_to_ma(format), channels, sample_rate, q, cutoff_hz);
            ma_notch2_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_notch2_process(AENotch2 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_notch2_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // Peak2
    AE_API AEPeak2 *ae_peak2_create(int format, int channels, int sample_rate, double gain_db, double q, double cutoff_hz)
    {
        AEPeak2 *obj = new AEPeak2();
        ma_peak2_config config = ma_peak2_config_init(ae_format_to_ma(format), channels, sample_rate, gain_db, q, cutoff_hz);
        if (ma_peak2_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_peak2_destroy(AEPeak2 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_peak2_reinit(AEPeak2 *obj, int format, int channels, int sample_rate, double gain_db, double q, double cutoff_hz)
    {
        if (obj)
        {
            ma_peak2_config config = ma_peak2_config_init(ae_format_to_ma(format), channels, sample_rate, gain_db, q, cutoff_hz);
            ma_peak2_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_peak2_process(AEPeak2 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_peak2_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // LowShelf2
    AE_API AELoshelf2 *ae_loshelf2_create(int format, int channels, int sample_rate, double gain_db, double slope, double cutoff_hz)
    {
        AELoshelf2 *obj = new AELoshelf2();
        ma_loshelf2_config config = ma_loshelf2_config_init(ae_format_to_ma(format), channels, sample_rate, gain_db, slope, cutoff_hz);
        if (ma_loshelf2_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_loshelf2_destroy(AELoshelf2 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_loshelf2_reinit(AELoshelf2 *obj, int format, int channels, int sample_rate, double gain_db, double slope, double cutoff_hz)
    {
        if (obj)
        {
            ma_loshelf2_config config = ma_loshelf2_config_init(ae_format_to_ma(format), channels, sample_rate, gain_db, slope, cutoff_hz);
            ma_loshelf2_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_loshelf2_process(AELoshelf2 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_loshelf2_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // HighShelf2
    AE_API AEHishelf2 *ae_hishelf2_create(int format, int channels, int sample_rate, double gain_db, double slope, double cutoff_hz)
    {
        AEHishelf2 *obj = new AEHishelf2();
        ma_hishelf2_config config = ma_hishelf2_config_init(ae_format_to_ma(format), channels, sample_rate, gain_db, slope, cutoff_hz);
        if (ma_hishelf2_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_hishelf2_destroy(AEHishelf2 *obj)
    {
        if (obj)
            delete obj;
    }
    AE_API void ae_hishelf2_reinit(AEHishelf2 *obj, int format, int channels, int sample_rate, double gain_db, double slope, double cutoff_hz)
    {
        if (obj)
        {
            ma_hishelf2_config config = ma_hishelf2_config_init(ae_format_to_ma(format), channels, sample_rate, gain_db, slope, cutoff_hz);
            ma_hishelf2_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_hishelf2_process(AEHishelf2 *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_hishelf2_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // Biquad
    AE_API AEBiquad *ae_biquad_create(int format, int channels, double b0, double b1, double b2, double a0, double a1, double a2)
    {
        AEBiquad *obj = new AEBiquad();
        ma_biquad_config config = ma_biquad_config_init(ae_format_to_ma(format), channels, b0, b1, b2, a0, a1, a2);
        if (ma_biquad_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_biquad_destroy(AEBiquad *obj)
    {
        if (obj)
        {
            ma_biquad_uninit(&obj->filter, nullptr);
            delete obj;
        }
    }
    AE_API void ae_biquad_reinit(AEBiquad *obj, int format, int channels, double b0, double b1, double b2, double a0, double a1, double a2)
    {
        if (obj)
        {
            ma_biquad_config config = ma_biquad_config_init(ae_format_to_ma(format), channels, b0, b1, b2, a0, a1, a2);
            ma_biquad_reinit(&config, &obj->filter);
        }
    }
    AE_API int ae_biquad_process(AEBiquad *obj, void *out_frames, const void *in_frames, uint64_t frame_count)
    {
        if (!obj)
            return 0;
        return ma_biquad_process_pcm_frames(&obj->filter, out_frames, in_frames, frame_count) == MA_SUCCESS;
    }

    // Exact inverses of miniaudio's X->f32 scalers (which divide by 2^(N-1)).
    // ma_pcm_f32_to_X use an asymmetric "*((2^(N-1))-1) + truncate" fast path
    // that shifts a quantization-grid signal by ~1 LSB of DC error, breaking a
    // dithered int -> f32 -> int round trip. These convert with round-to-
    // nearest against the original grid and clamp to the type's range.
    static void f32ToIntExact(AEAudioFormat fmt, void *dst, const float *src, size_t count)
    {
        switch (fmt)
        {
        case AE_FORMAT_U8:
        {
            ma_uint8 *d = (ma_uint8 *)dst;
            for (size_t i = 0; i < count; ++i)
            {
                int r = (int)std::lrintf((src[i] + 1.0f) * 127.5f);
                if (r < 0) r = 0;
                else if (r > 255) r = 255;
                d[i] = (ma_uint8)r;
            }
        }
        break;
        case AE_FORMAT_S16:
        {
            ma_int16 *d = (ma_int16 *)dst;
            for (size_t i = 0; i < count; ++i)
            {
                int r = (int)std::lrintf(src[i] * 32768.0f);
                if (r < -32768) r = -32768;
                else if (r > 32767) r = 32767;
                d[i] = (ma_int16)r;
            }
        }
        break;
        case AE_FORMAT_S24:
        {
            ma_uint8 *d = (ma_uint8 *)dst;
            for (size_t i = 0; i < count; ++i)
            {
                long long r = (long long)std::llround((double)src[i] * 8388608.0);
                if (r < -8388608LL) r = -8388608LL;
                else if (r > 8388607LL) r = 8388607LL;
                const ma_int32 t = (ma_int32)r;
                d[(i * 3) + 0] = (ma_uint8)((t & 0x0000FF) >> 0);
                d[(i * 3) + 1] = (ma_uint8)((t & 0x00FF00) >> 8);
                d[(i * 3) + 2] = (ma_uint8)((t & 0xFF0000) >> 16);
            }
        }
        break;
        case AE_FORMAT_S32:
        {
            ma_int32 *d = (ma_int32 *)dst;
            for (size_t i = 0; i < count; ++i)
            {
                long long r = (long long)std::llround((double)src[i] * 2147483648.0);
                if (r < (-2147483647LL - 1)) r = -2147483648LL;
                else if (r > 2147483647LL) r = 2147483647LL;
                d[i] = (ma_int32)r;
            }
        }
        break;
        default:
            break;
        }
    }

    // Resampler
    AE_API AEResampler *ae_resampler_create(int format, int channels, int sample_rate_in, int sample_rate_out, int algorithm, int dither_mode)
    {
        AEResampler *obj = new AEResampler();
        obj->algorithmChoice = algorithm;
        obj->requestedFormat = format;
        obj->channels = channels;
        obj->ditherMode = dither_mode;

        ma_resample_algorithm algo = ma_resample_algorithm_linear;
        if (algorithm != AE_RESAMPLE_ALGORITHM_MINIAUDIO_LINEAR)
        {
            algo = ma_resample_algorithm_custom;
        }

        // Dithering requires a float processing domain so we can quantize on
        // the target integer grid with dither/noise shaping. For F32 callers
        // there is no quantization grid, so the mode stays a documented no-op.
        obj->floatInternal = (dither_mode > 0 && format != AE_FORMAT_F32);
        const int internalFormat = obj->floatInternal ? (int)AE_FORMAT_F32 : format;

        ma_resampler_config config = ma_resampler_config_init(ae_format_to_ma(internalFormat), channels, sample_rate_in, sample_rate_out, algo);
        if (algo == ma_resample_algorithm_custom)
        {
            config.pBackendVTable = get_resampler_vtable_for_algorithm(algorithm);
            config.pBackendUserData = &obj->algorithmChoice;
        }

        if (ma_resampler_init(&config, nullptr, &obj->filter) != MA_SUCCESS)
        {
            delete obj;
            return nullptr;
        }
        return obj;
    }
    AE_API void ae_resampler_destroy(AEResampler *obj)
    {
        if (obj)
        {
            ma_resampler_uninit(&obj->filter, nullptr);
            delete obj;
        }
    }
    AE_API int ae_resampler_process(AEResampler *obj, const void *in_frames, uint64_t *in_frame_count, void *out_frames, uint64_t *out_frame_count)
    {
        if (!obj)
            return 0;

        // Dithered path (integer formats only): resample in the float domain,
        // apply dither/noise-shaping on the target LSB grid, convert back.
        if (obj->floatInternal && obj->ditherMode > 0)
        {
            const ma_uint64 inCount = in_frame_count ? *in_frame_count : 0;
            const ma_uint64 outCap = out_frame_count ? *out_frame_count : 0;
            const int ch = std::max(1, obj->channels);

            if (inCount > 0)
            {
                obj->inFloat.resize((size_t)inCount * (size_t)ch);
                switch ((AEAudioFormat)obj->requestedFormat)
                {
                case AE_FORMAT_U8:  ma_pcm_u8_to_f32(obj->inFloat.data(), in_frames, inCount * (ma_uint64)ch, ma_dither_mode_none); break;
                case AE_FORMAT_S16: ma_pcm_s16_to_f32(obj->inFloat.data(), in_frames, inCount * (ma_uint64)ch, ma_dither_mode_none); break;
                case AE_FORMAT_S24: ma_pcm_s24_to_f32(obj->inFloat.data(), in_frames, inCount * (ma_uint64)ch, ma_dither_mode_none); break;
                case AE_FORMAT_S32: ma_pcm_s32_to_f32(obj->inFloat.data(), in_frames, inCount * (ma_uint64)ch, ma_dither_mode_none); break;
                default: return 0;
                }
            }

            obj->outFloat.resize((size_t)outCap * (size_t)ch);
            ma_uint64 inF = inCount;
            ma_uint64 outF = outCap;
            ma_result result = ma_resampler_process_pcm_frames(
                &obj->filter,
                inCount > 0 ? obj->inFloat.data() : nullptr, &inF,
                outCap > 0 ? obj->outFloat.data() : nullptr, &outF);

            if (outF > 0)
            {
                obj->dither.process(obj->ditherMode, (AEAudioFormat)obj->requestedFormat,
                                    obj->outFloat.data(), (size_t)outF * (size_t)ch, ch);
                f32ToIntExact((AEAudioFormat)obj->requestedFormat, out_frames,
                              obj->outFloat.data(), (size_t)outF * (size_t)ch);
            }

            if (in_frame_count)
                *in_frame_count = inF;
            if (out_frame_count)
                *out_frame_count = outF;
            return result == MA_SUCCESS;
        }

        ma_uint64 in_count = in_frame_count ? *in_frame_count : 0;
        ma_uint64 out_count = out_frame_count ? *out_frame_count : 0;
        ma_result result = ma_resampler_process_pcm_frames(&obj->filter, in_frames, &in_count, out_frames, &out_count);
        if (in_frame_count)
            *in_frame_count = in_count;
        if (out_frame_count)
            *out_frame_count = out_count;
        return result == MA_SUCCESS;
    }
    AE_API void ae_resampler_set_rate(AEResampler *obj, int sample_rate_in, int sample_rate_out)
    {
        if (obj)
            ma_resampler_set_rate(&obj->filter, sample_rate_in, sample_rate_out);
    }
    AE_API void ae_resampler_set_rate_ratio(AEResampler *obj, float ratio_in_out)
    {
        if (obj)
            ma_resampler_set_rate_ratio(&obj->filter, ratio_in_out);
    }
    AE_API uint64_t ae_resampler_get_required_input_frame_count(AEResampler *obj, uint64_t out_frame_count)
    {
        if (!obj)
            return 0;
        ma_uint64 in_count = 0;
        ma_resampler_get_required_input_frame_count(&obj->filter, out_frame_count, &in_count);
        return in_count;
    }
    AE_API uint64_t ae_resampler_get_expected_output_frame_count(AEResampler *obj, uint64_t in_frame_count)
    {
        if (!obj)
            return 0;
        ma_uint64 out_count = 0;
        ma_resampler_get_expected_output_frame_count(&obj->filter, in_frame_count, &out_count);
        return out_count;
    }
    AE_API uint64_t ae_resampler_get_input_latency(AEResampler *obj)
    {
        if (!obj)
            return 0;
        return ma_resampler_get_input_latency(&obj->filter);
    }
    AE_API uint64_t ae_resampler_get_output_latency(AEResampler *obj)
    {
        if (!obj)
            return 0;
        return ma_resampler_get_output_latency(&obj->filter);
    }

    // ==========================================
    // Native Clean-Room Audio DSP Suite Implementation
    // ==========================================

    // Audio Clarity Engine
    AE_API void ae_dsp_set_clarity_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->clarityDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_clarity_params(AudioEngineHandle *engine, int profile, float intensity)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->clarityDsp.setProfile(static_cast<sauti::dsp::AudioClarityProfile>(profile));
        engine->clarityDsp.setIntensity(intensity);
    }

    // Harmonic Bass Engine
    AE_API void ae_dsp_set_bass_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->harmonicBassDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_bass_params(AudioEngineHandle *engine, int profile, float cutoff_hz, float boost)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->harmonicBassDsp.setProfile(static_cast<sauti::dsp::BassEnhanceProfile>(profile));
        engine->harmonicBassDsp.setCutoffFrequency(cutoff_hz);
        engine->harmonicBassDsp.setBoost(boost);
    }

    // Dynamic Transducer System
    AE_API void ae_dsp_set_dynamic_system_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->dynamicSystemDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_dynamic_system_params(AudioEngineHandle *engine, int profile, float strength)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->dynamicSystemDsp.setProfile(static_cast<sauti::dsp::TransducerProfile>(profile));
        engine->dynamicSystemDsp.setStrength(strength);
    }

    AE_API void ae_dsp_set_dynamic_system_custom_params(AudioEngineHandle *engine, float x_low, float x_high, float y_low, float y_high, float side_gain_low, float side_gain_high, float bass_gain)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->dynamicSystemDsp.setXCoeffs(x_low, x_high);
        engine->dynamicSystemDsp.setYCoeffs(y_low, y_high);
        engine->dynamicSystemDsp.setSideGain(side_gain_low, side_gain_high);
        engine->dynamicSystemDsp.setBassGain(bass_gain);
    }

    // Analog Warmth (Tube & Tape Saturation)
    AE_API void ae_dsp_set_analog_warmth_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->analogWarmthDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_analog_warmth_params(AudioEngineHandle *engine, int profile, float drive)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->analogWarmthDsp.setProfile(static_cast<sauti::dsp::AnalogWarmthProfile>(profile));
        engine->analogWarmthDsp.setDrive(drive);
    }

    // Dialogue Booster / Enhancer
    AE_API void ae_dsp_set_dialog_enhancer_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->dialogEnhancerDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_dialog_enhancer_params(AudioEngineHandle *engine, int profile, float amount, float ducking, float clarity, float center_focus)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        if (profile < 0 || profile > 4) profile = 0;
        engine->dialogEnhancerDsp.setParams(static_cast<sauti::dsp::DialogEnhancerProfile>(profile), amount, ducking, clarity, center_focus);
    }

    AE_API float ae_dsp_get_dialog_enhancer_gain_reduction_db(AudioEngineHandle *engine)
    {
        if (!engine) return 0.0f;
        return engine->dialogEnhancerDsp.getGainReductionDb();
    }

    // Split-Band / Wideband De-Esser
    AE_API void ae_dsp_set_de_esser_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->deEsserDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_de_esser_preset(AudioEngineHandle *engine, int preset)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        if (preset < 0 || preset > 4) preset = 0;
        engine->deEsserDsp.setPreset(static_cast<sauti::dsp::DeEsserPreset>(preset));
    }

    AE_API void ae_dsp_set_de_esser_params(AudioEngineHandle *engine, int mode, float intensity)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        if (mode < 0 || mode > 1) mode = 0;
        engine->deEsserDsp.setMode(static_cast<sauti::dsp::DeEsserMode>(mode));
        engine->deEsserDsp.setIntensity(intensity);
    }

    AE_API void ae_dsp_set_de_esser_params_ex(AudioEngineHandle *engine, int mode, float frequency_hz, float threshold_db, float ratio, float max_reduction_db, float attack_ms, float release_ms)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        if (mode < 0 || mode > 1) mode = 0;
        engine->deEsserDsp.setMode(static_cast<sauti::dsp::DeEsserMode>(mode));
        engine->deEsserDsp.setFrequencyHz(frequency_hz);
        engine->deEsserDsp.setThresholdDb(threshold_db);
        engine->deEsserDsp.setRatio(ratio);
        engine->deEsserDsp.setMaxReductionDb(max_reduction_db);
        engine->deEsserDsp.setAttackMs(attack_ms);
        engine->deEsserDsp.setReleaseMs(release_ms);
    }

    AE_API float ae_dsp_get_de_esser_gain_reduction_db(AudioEngineHandle *engine)
    {
        if (!engine) return 0.0f;
        return engine->deEsserDsp.getGainReductionDb();
    }

    // Downward Expander & Noise Floor Reducer
    AE_API void ae_dsp_set_expander_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->downwardExpanderDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_expander_preset(AudioEngineHandle *engine, int preset)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        if (preset < 0 || preset > 4) preset = 0;
        engine->downwardExpanderDsp.setPreset(static_cast<sauti::dsp::ExpanderPreset>(preset));
    }

    AE_API void ae_dsp_set_expander_params(AudioEngineHandle *engine, float threshold_db, float ratio, float range_db, float attack_ms, float release_ms)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->downwardExpanderDsp.setThresholdDb(threshold_db);
        engine->downwardExpanderDsp.setRatio(ratio);
        engine->downwardExpanderDsp.setRangeDb(range_db);
        engine->downwardExpanderDsp.setAttackMs(attack_ms);
        engine->downwardExpanderDsp.setReleaseMs(release_ms);
    }

    AE_API void ae_dsp_set_expander_params_ex(AudioEngineHandle *engine, float threshold_db, float ratio, float range_db, float attack_ms, float release_ms, float knee_db, float sidechain_hpf_hz)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->downwardExpanderDsp.setThresholdDb(threshold_db);
        engine->downwardExpanderDsp.setRatio(ratio);
        engine->downwardExpanderDsp.setRangeDb(range_db);
        engine->downwardExpanderDsp.setAttackMs(attack_ms);
        engine->downwardExpanderDsp.setReleaseMs(release_ms);
        engine->downwardExpanderDsp.setKneeDb(knee_db);
        engine->downwardExpanderDsp.setSidechainHpfHz(sidechain_hpf_hz);
    }

    AE_API float ae_dsp_get_expander_gain_reduction_db(AudioEngineHandle *engine)
    {
        if (!engine) return 0.0f;
        return engine->downwardExpanderDsp.getCurrentGainReductionDb();
    }

    // Master DSP Reset
    AE_API void ae_dsp_reset(AudioEngineHandle *engine)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->clarityDsp.reset();
        engine->harmonicBassDsp.reset();
        engine->dynamicSystemDsp.reset();
        engine->analogWarmthDsp.reset();
        engine->dialogEnhancerDsp.reset();
        engine->deEsserDsp.reset();
        engine->downwardExpanderDsp.reset();
        engine->fftConvolverDsp.reset();
        engine->masterLimiterDsp.reset();
        engine->surroundDsp.reset();
        engine->subsonicFilter.reset();
    }

    // Spatial Surround Suite
    AE_API void ae_dsp_set_surround_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->surroundDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_surround_mode(AudioEngineHandle *engine, int mode)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        if (mode == 4) mode = 1; // Map legacy AE_SURROUND_MATRIX_5_1_HRTF (4) to Matrix (1)
        if (mode < 0 || mode > 3) mode = 0;
        engine->surroundDsp.setMode(static_cast<sauti::dsp::SurroundMode>(mode));
    }

    AE_API void ae_dsp_set_surround_params(AudioEngineHandle *engine,
                                           float p1,
                                           float p2,
                                           float p3,
                                           float p4)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        auto &dsp = engine->surroundDsp;
        switch (dsp.getMode()) {
            case sauti::dsp::SurroundMode::MatrixSurround:
                dsp.setCenterFocus(p1);
                dsp.setSurroundBoost(p2);
                dsp.setSurroundDelayMs(p3);
                if (p4 > 1.0f) dsp.setHeadRadiusCm(p4);
                break;
            case sauti::dsp::SurroundMode::BinauralVirtualizer:
                dsp.setBinauralBoost(p1);
                dsp.setBinauralMode(static_cast<int>(p2 + 0.1f));
                dsp.setBinauralRoomPreset(static_cast<int>(p3 + 0.1f));
                dsp.setBinauralRoomMix(p4);
                break;
            case sauti::dsp::SurroundMode::AcousticStage:
                dsp.setStageWidth(p1);
                dsp.setStageDepth(p2);
                dsp.setStageMode(static_cast<int>(p3 + 0.1f));
                dsp.setStageCancellation(p4);
                break;
            default:
                dsp.setCenterFocus(p1);
                dsp.setSurroundBoost(p2);
                break;
        }
    }

    AE_API void ae_dsp_get_surround_params(AudioEngineHandle *engine,
                                           int *out_enabled,
                                           int *out_mode,
                                           float *out_p1,
                                           float *out_p2,
                                           float *out_p3,
                                           float *out_p4)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        const auto &dsp = engine->surroundDsp;
        if (out_enabled) *out_enabled = dsp.isEnabled() ? 1 : 0;
        if (out_mode)    *out_mode = static_cast<int>(dsp.getMode());

        switch (dsp.getMode()) {
            case sauti::dsp::SurroundMode::BinauralVirtualizer:
                if (out_p1) *out_p1 = dsp.getBinauralBoost();
                if (out_p2) *out_p2 = static_cast<float>(dsp.getBinauralMode());
                if (out_p3) *out_p3 = static_cast<float>(dsp.getBinauralRoomPreset());
                if (out_p4) *out_p4 = dsp.getBinauralRoomMix();
                break;
            case sauti::dsp::SurroundMode::AcousticStage:
                if (out_p1) *out_p1 = dsp.getStageWidth();
                if (out_p2) *out_p2 = dsp.getStageDepth();
                if (out_p3) *out_p3 = static_cast<float>(dsp.getStageMode());
                if (out_p4) *out_p4 = dsp.getStageCancellation();
                break;
            case sauti::dsp::SurroundMode::MatrixSurround:
            default:
                if (out_p1) *out_p1 = dsp.getCenterFocus();
                if (out_p2) *out_p2 = dsp.getSurroundBoost();
                if (out_p3) *out_p3 = dsp.getSurroundDelayMs();
                if (out_p4) *out_p4 = dsp.getHeadRadiusCm();
                break;
        }
    }

    AE_API void ae_dsp_set_surround_matrix_params(AudioEngineHandle *engine,
                                                  float center_focus,
                                                  float surround_boost,
                                                  float surround_delay_ms,
                                                  float head_radius_cm)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        auto &dsp = engine->surroundDsp;
        dsp.setCenterFocus(center_focus);
        dsp.setSurroundBoost(surround_boost);
        dsp.setSurroundDelayMs(surround_delay_ms);
        dsp.setHeadRadiusCm(head_radius_cm);
    }

    AE_API void ae_dsp_set_surround_binaural_params(AudioEngineHandle *engine,
                                                    int mode,
                                                    float boost,
                                                    int room_preset,
                                                    float room_mix,
                                                    int speaker_angle,
                                                    float shadow_cutoff_hz)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        auto &dsp = engine->surroundDsp;
        dsp.setBinauralMode(mode);
        dsp.setBinauralBoost(boost);
        dsp.setBinauralRoomPreset(room_preset);
        dsp.setBinauralRoomMix(room_mix);
        dsp.setBinauralSpeakerAngle(speaker_angle);
        dsp.setBinauralShadowCutoff(shadow_cutoff_hz);
    }

    AE_API void ae_dsp_set_surround_stage_params(AudioEngineHandle *engine,
                                                 int profile,
                                                 int mode,
                                                 float width,
                                                 float depth,
                                                 float cancellation,
                                                 float air_presence,
                                                 float bass_anchor_hz)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        auto &dsp = engine->surroundDsp;
        dsp.setStageProfile(profile);
        dsp.setStageMode(mode);
        dsp.setStageWidth(width);
        dsp.setStageDepth(depth);
        dsp.setStageCancellation(cancellation);
        dsp.setStageAirPresence(air_presence);
        dsp.setStageBassAnchorHz(bass_anchor_hz);
    }

    AE_API void ae_dsp_set_surround_params_ex(AudioEngineHandle *engine,
                                              float field_width,
                                              float field_crossover_hz,
                                              float field_diffuser_mix,
                                              float bass_anchor,
                                              float haas_delay_ms,
                                              float haas_depth,
                                              float haas_damping_hz,
                                              int vhs_room_preset,
                                              float vhs_reflection_gain,
                                              float vhs_damping,
                                              float center_focus,
                                              float surround_boost,
                                              float surround_delay_ms,
                                              float head_radius_cm)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        auto &dsp = engine->surroundDsp;
        dsp.setCenterFocus(center_focus);
        dsp.setSurroundBoost(surround_boost);
        dsp.setSurroundDelayMs(surround_delay_ms);
        dsp.setHeadRadiusCm(head_radius_cm);

        // Map backwards-compatible legacy fields to new algorithms:
        dsp.setStageWidth(field_width);
        dsp.setBinauralRoomPreset(vhs_room_preset);
        dsp.setBinauralRoomMix(vhs_reflection_gain);
    }

    // FFT Impulse Response Convolver
    AE_API void ae_dsp_set_convolver_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->fftConvolverDsp.setEnabled(enabled != 0);
    }

    AE_API int ae_dsp_load_convolver_ir(AudioEngineHandle *engine, const float *samples, int frame_count, int channels)
    {
        if (!engine) return 0;
        return engine->fftConvolverDsp.loadImpulseResponse(samples, frame_count, channels) ? 1 : 0;
    }

    AE_API void ae_dsp_clear_convolver_ir(AudioEngineHandle *engine)
    {
        if (!engine) return;
        engine->fftConvolverDsp.clearImpulseResponse();
    }

    AE_API void ae_dsp_set_convolver_mix(AudioEngineHandle *engine, float wet, float dry)
    {
        if (!engine) return;
        engine->fftConvolverDsp.setWetLevel(wet);
        engine->fftConvolverDsp.setDryLevel(dry);
    }

    AE_API int ae_dsp_has_convolver_ir(AudioEngineHandle *engine)
    {
        if (!engine) return 0;
        return engine->fftConvolverDsp.hasImpulseResponse() ? 1 : 0;
    }

    AE_API int ae_dsp_get_convolver_kernel_length(AudioEngineHandle *engine)
    {
        if (!engine) return 0;
        return (int)engine->fftConvolverDsp.getKernelLength();
    }

    // Master Peak Limiter & Output Level
    AE_API void ae_dsp_set_master_limiter_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->masterLimiterDsp.setEnabled(enabled != 0);
    }

    AE_API void ae_dsp_set_master_limiter_params(AudioEngineHandle *engine, float ceiling_db, float output_gain_db, float release_ms)
    {
        if (!engine) return;
        std::lock_guard<std::mutex> lock(engine->dspMutex);
        engine->masterLimiterDsp.setCeilingDb(ceiling_db);
        engine->masterLimiterDsp.setOutputGainDb(output_gain_db);
        engine->masterLimiterDsp.setReleaseMs(release_ms);
    }

    AE_API float ae_dsp_get_limiter_gain_reduction_db(AudioEngineHandle *engine)
    {
        if (!engine) return 0.0f;
        return engine->masterLimiterDsp.getCurrentGainReductionDb();
    }

    AE_API AETrackInfo ae_inspect_file(const char *file_path)
    {
        AETrackInfo info;
        std::memset(&info, 0, sizeof(info));
        if (!file_path || file_path[0] == '\0')
        {
            return info;
        }

        // 1. Open file to read header & get file size
        FILE *f = nullptr;
#if defined(_WIN32) || defined(_WIN64)
        std::wstring wpath = utf8_to_wstring(file_path);
        f = _wfopen(wpath.c_str(), L"rb");
#else
        f = std::fopen(file_path, "rb");
#endif
        if (!f) return info;

        std::fseek(f, 0, SEEK_END);
        info.file_size_bytes = (int64_t)std::ftell(f);
        std::fseek(f, 0, SEEK_SET);

        size_t bufSize = (info.file_size_bytes > 1048576) ? 1048576 : (size_t)info.file_size_bytes;
        std::vector<unsigned char> bytes(bufSize);
        size_t readBytes = std::fread(bytes.data(), 1, bufSize, f);
        std::fclose(f);

        // 2. Format extension check
        std::string pathStr(file_path);
        size_t dotIdx = pathStr.rfind('.');
        if (dotIdx != std::string::npos && dotIdx + 1 < pathStr.size())
        {
            std::string ext = pathStr.substr(dotIdx + 1);
            for (auto &c : ext) c = (char)std::toupper((unsigned char)c);
            std::snprintf(info.format_name, sizeof(info.format_name), "%s", ext.c_str());
        }
        else
        {
            std::snprintf(info.format_name, sizeof(info.format_name), "AUDIO");
        }

        // 3. Binary header inspection for exact native parameters
        // A. FLAC header check
        int flacOffset = -1;
        for (size_t i = 0; i + 4 <= readBytes; i++)
        {
            if (bytes[i] == 'f' && bytes[i+1] == 'L' && bytes[i+2] == 'a' && bytes[i+3] == 'C')
            {
                flacOffset = (int)i;
                break;
            }
        }
        if (flacOffset != -1 && (size_t)flacOffset + 42 <= readBytes)
        {
            size_t pos = (size_t)flacOffset + 4; // Skip 'fLaC'
            while (pos + 4 <= readBytes)
            {
                unsigned char h0 = bytes[pos];
                bool isLast = (h0 & 0x80) != 0;
                int blockType = h0 & 0x7F;
                size_t len = ((size_t)bytes[pos+1] << 16) | ((size_t)bytes[pos+2] << 8) | bytes[pos+3];
                pos += 4;

                if (blockType == 0 && pos + 34 <= readBytes) // STREAMINFO block
                {
                    unsigned char b10 = bytes[pos + 10];
                    unsigned char b11 = bytes[pos + 11];
                    unsigned char b12 = bytes[pos + 12];
                    unsigned char b13 = bytes[pos + 13];

                    info.sample_rate = (int)((b10 << 12) | (b11 << 4) | ((b12 & 0xF0) >> 4));
                    info.channels = (int)(((b12 & 0x0E) >> 1) + 1);
                    info.bit_depth = (int)((((b12 & 0x01) << 4) | ((b13 & 0xF0) >> 4)) + 1);
                    info.is_float = 0;
                    std::snprintf(info.format_name, sizeof(info.format_name), "FLAC");
                    if (info.duration_secs <= 0.0 && info.sample_rate > 0)
                    {
                        uint64_t totalSamples = ((uint64_t)(b13 & 0x0F) << 32) |
                                                ((uint64_t)bytes[pos+14] << 24) |
                                                ((uint64_t)bytes[pos+15] << 16) |
                                                ((uint64_t)bytes[pos+16] << 8) |
                                                (uint64_t)bytes[pos+17];
                        if (totalSamples > 0)
                        {
                            info.duration_secs = (double)totalSamples / (double)info.sample_rate;
                        }
                    }
                    break;
                }
                if (isLast) break;
                pos += len;
            }
        }

        // B. WAV header check
        if (info.sample_rate == 0 && readBytes >= 12 && bytes[0] == 'R' && bytes[1] == 'I' && bytes[2] == 'F' && bytes[3] == 'F')
        {
            for (size_t i = 0; i + 24 <= readBytes; i++)
            {
                if (bytes[i] == 'f' && bytes[i+1] == 'm' && bytes[i+2] == 't' && bytes[i+3] == ' ')
                {
                    int audioFormat = bytes[i + 8] | (bytes[i + 9] << 8);
                    info.channels = bytes[i + 10] | (bytes[i + 11] << 8);
                    info.sample_rate = bytes[i + 12] | (bytes[i + 13] << 8) | (bytes[i + 14] << 16) | (bytes[i + 15] << 24);
                    info.bit_depth = bytes[i + 22] | (bytes[i + 23] << 8);
                    info.is_float = (audioFormat == 3) ? 1 : 0;
                    std::snprintf(info.format_name, sizeof(info.format_name), info.is_float ? "WAV (Float)" : "WAV");
                    break;
                }
            }
        }

        // C. M4A / MP4 / AAC / ALAC atom inspection
        if (info.sample_rate == 0 && readBytes >= 16)
        {
            // 1. Check for ALAC atom
            int alacOffset = -1;
            for (size_t i = 0; i + 4 <= readBytes; i++)
            {
                if (bytes[i] == 'a' && bytes[i+1] == 'l' && bytes[i+2] == 'a' && bytes[i+3] == 'c')
                {
                    alacOffset = (int)i;
                    break;
                }
            }
            if (alacOffset != -1 && (size_t)alacOffset + 36 <= readBytes)
            {
                int bitDepth = (int)bytes[alacOffset + 21];
                int ch = (int)bytes[alacOffset + 25];
                int sr = (bytes[alacOffset + 32] << 24) |
                         (bytes[alacOffset + 33] << 16) |
                         (bytes[alacOffset + 34] << 8) |
                         bytes[alacOffset + 35];
                if (bitDepth > 0) info.bit_depth = bitDepth;
                if (ch > 0) info.channels = ch;
                if (sr > 0 && sr < 384000) info.sample_rate = sr;
                std::snprintf(info.format_name, sizeof(info.format_name), "ALAC");
            }

            // 2. Check for MP4A (AAC) atom
            if (info.sample_rate == 0)
            {
                int mp4aOffset = -1;
                for (size_t i = 0; i + 4 <= readBytes; i++)
                {
                    if (bytes[i] == 'm' && bytes[i+1] == 'p' && bytes[i+2] == '4' && bytes[i+3] == 'a')
                    {
                        mp4aOffset = (int)i;
                        break;
                    }
                }
                if (mp4aOffset != -1 && (size_t)mp4aOffset + 30 <= readBytes)
                {
                    int ch = (bytes[mp4aOffset + 20] << 8) | bytes[mp4aOffset + 21];
                    int bd = (bytes[mp4aOffset + 22] << 8) | bytes[mp4aOffset + 23];
                    int sr = (bytes[mp4aOffset + 28] << 8) | bytes[mp4aOffset + 29];
                    if (ch > 0) info.channels = ch;
                    if (bd > 0) info.bit_depth = bd;
                    if (sr > 0 && sr < 384000) info.sample_rate = sr;
                    std::snprintf(info.format_name, sizeof(info.format_name), "AAC");
                }
            }

            // 3. Check for Opus in MP4 ('Opus' or 'dOps' atom)
            if (info.sample_rate == 0)
            {
                int opusOffset = -1;
                for (size_t i = 0; i + 4 <= readBytes; i++)
                {
                    if ((bytes[i] == 'O' && bytes[i+1] == 'p' && bytes[i+2] == 'u' && bytes[i+3] == 's') ||
                        (bytes[i] == 'd' && bytes[i+1] == 'O' && bytes[i+2] == 'p' && bytes[i+3] == 's'))
                    {
                        opusOffset = (int)i;
                        break;
                    }
                }
                if (opusOffset != -1)
                {
                    info.sample_rate = 48000;
                    info.channels = 2;
                    info.bit_depth = 16;
                    std::snprintf(info.format_name, sizeof(info.format_name), "OPUS");
                }
            }

            // 3. Fast duration extraction from mvhd atom if present in readBytes
            if (info.duration_secs <= 0.0)
            {
                for (size_t i = 0; i + 24 <= readBytes; i++)
                {
                    if (bytes[i] == 'm' && bytes[i+1] == 'v' && bytes[i+2] == 'h' && bytes[i+3] == 'd')
                    {
                        unsigned char ver = bytes[i + 4];
                        if (ver == 0 && i + 24 <= readBytes)
                        {
                            uint32_t timescale = ((uint32_t)bytes[i + 16] << 24) | ((uint32_t)bytes[i + 17] << 16) | ((uint32_t)bytes[i + 18] << 8) | bytes[i + 19];
                            uint32_t duration = ((uint32_t)bytes[i + 20] << 24) | ((uint32_t)bytes[i + 21] << 16) | ((uint32_t)bytes[i + 22] << 8) | bytes[i + 23];
                            if (timescale > 0 && duration > 0)
                            {
                                info.duration_secs = (double)duration / (double)timescale;
                                break;
                            }
                        }
                        else if (ver == 1 && i + 36 <= readBytes)
                        {
                            uint32_t timescale = ((uint32_t)bytes[i + 24] << 24) | ((uint32_t)bytes[i + 25] << 16) | ((uint32_t)bytes[i + 26] << 8) | bytes[i + 27];
                            uint64_t duration = ((uint64_t)bytes[i + 28] << 56) | ((uint64_t)bytes[i + 29] << 48) |
                                                ((uint64_t)bytes[i + 30] << 40) | ((uint64_t)bytes[i + 31] << 32) |
                                                ((uint64_t)bytes[i + 32] << 24) | ((uint64_t)bytes[i + 33] << 16) |
                                                ((uint64_t)bytes[i + 34] << 8) | bytes[i + 35];
                            if (timescale > 0 && duration > 0)
                            {
                                info.duration_secs = (double)duration / (double)timescale;
                                break;
                            }
                        }
                    }
                }
            }
        }

        // D. Fallback to miniaudio decoder if sample_rate not resolved by header parser
        if (info.sample_rate <= 0)
        {
            ma_decoder decoder;
            ma_decoder_config config = ma_decoder_config_init(ma_format_unknown, 0, 0);
            ma_result res = MA_ERROR;

#if defined(_WIN32) || defined(_WIN64)
            res = ma_decoder_init_file_w(wpath.c_str(), &config, &decoder);
#else
            res = ma_decoder_init_file(file_path, &config, &decoder);
#endif

            if (res == MA_SUCCESS)
            {
                if (info.sample_rate <= 0) info.sample_rate = (int)decoder.outputSampleRate;
                if (info.channels <= 0) info.channels = (int)decoder.outputChannels;
                if (info.bit_depth <= 0) info.bit_depth = 16;

                ma_uint64 frameCount = 0;
                if (info.duration_secs <= 0.0 && ma_decoder_get_length_in_pcm_frames(&decoder, &frameCount) == MA_SUCCESS && info.sample_rate > 0)
                {
                    info.duration_secs = (double)frameCount / (double)info.sample_rate;
                }
                ma_decoder_uninit(&decoder);
            }
        }

        // D. Calculate exact average bitrate in kbps
        if (info.duration_secs > 0 && info.file_size_bytes > 0)
        {
            info.bitrate_kbps = (int)(((info.file_size_bytes * 8.0) / info.duration_secs) / 1000.0);
        }

        return info;
    }

#if defined(__ANDROID__)
    static void query_android_hardware_info(AEHardwareInfo* info)
    {
        if (g_androidJavaVM == nullptr || info == nullptr)
            return;

        JNIEnv* env = nullptr;
        bool needsDetach = false;
        jint getEnvResult = g_androidJavaVM->GetEnv((void**)&env, JNI_VERSION_1_6);
        if (getEnvResult == JNI_EDETACHED)
        {
            if (g_androidJavaVM->AttachCurrentThread(&env, nullptr) == JNI_OK)
            {
                needsDetach = true;
            }
            else
            {
                return;
            }
        }
        else if (getEnvResult != JNI_OK || env == nullptr)
        {
            return;
        }

        do
        {
            jclass activityThreadClass = env->FindClass("android/app/ActivityThread");
            if (!activityThreadClass) { env->ExceptionClear(); break; }

            jmethodID currentActivityThreadMethod = env->GetStaticMethodID(activityThreadClass, "currentActivityThread", "()Landroid/app/ActivityThread;");
            if (!currentActivityThreadMethod) { env->ExceptionClear(); break; }

            jobject activityThread = env->CallStaticObjectMethod(activityThreadClass, currentActivityThreadMethod);
            if (!activityThread) break;

            jmethodID getApplicationMethod = env->GetMethodID(activityThreadClass, "getApplication", "()Landroid/app/Application;");
            if (!getApplicationMethod) { env->ExceptionClear(); break; }

            jobject context = env->CallObjectMethod(activityThread, getApplicationMethod);
            if (!context) break;

            jclass contextClass = env->FindClass("android/content/Context");
            if (!contextClass) { env->ExceptionClear(); break; }

            jfieldID audioServiceField = env->GetStaticFieldID(contextClass, "AUDIO_SERVICE", "Ljava/lang/String;");
            if (!audioServiceField) { env->ExceptionClear(); break; }

            jobject audioServiceName = env->GetStaticObjectField(contextClass, audioServiceField);
            if (!audioServiceName) break;

            jmethodID getSystemServiceMethod = env->GetMethodID(contextClass, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
            if (!getSystemServiceMethod) { env->ExceptionClear(); break; }

            jobject audioManager = env->CallObjectMethod(context, getSystemServiceMethod, audioServiceName);
            if (!audioManager) break;

            jclass audioManagerClass = env->FindClass("android/media/AudioManager");
            if (!audioManagerClass) { env->ExceptionClear(); break; }

            int defaultHalRate = 48000;
            jmethodID getPropertyMethod = env->GetMethodID(audioManagerClass, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;");
            if (getPropertyMethod)
            {
                jstring propKey = env->NewStringUTF("android.media.property.OUTPUT_SAMPLE_RATE");
                if (propKey)
                {
                    jstring rateStr = (jstring)env->CallObjectMethod(audioManager, getPropertyMethod, propKey);
                    if (rateStr)
                    {
                        const char* rateUtf = env->GetStringUTFChars(rateStr, nullptr);
                        if (rateUtf)
                        {
                            int parsedRate = std::atoi(rateUtf);
                            if (parsedRate > 0)
                            {
                                defaultHalRate = parsedRate;
                            }
                            env->ReleaseStringUTFChars(rateStr, rateUtf);
                        }
                        env->DeleteLocalRef(rateStr);
                    }
                    env->DeleteLocalRef(propKey);
                }

                jstring bufKey = env->NewStringUTF("android.media.property.OUTPUT_FRAMES_PER_BUFFER");
                if (bufKey)
                {
                    jstring bufStr = (jstring)env->CallObjectMethod(audioManager, getPropertyMethod, bufKey);
                    if (bufStr)
                    {
                        const char* bufUtf = env->GetStringUTFChars(bufStr, nullptr);
                        if (bufUtf)
                        {
                            int parsedFrames = std::atoi(bufUtf);
                            if (parsedFrames > 0)
                            {
                                info->period_size_frames = (uint32_t)parsedFrames;
                            }
                            env->ReleaseStringUTFChars(bufStr, bufUtf);
                        }
                        env->DeleteLocalRef(bufStr);
                    }
                    env->DeleteLocalRef(bufKey);
                }
            }

            jmethodID getDevicesMethod = env->GetMethodID(audioManagerClass, "getDevices", "(I)[Landroid/media/AudioDeviceInfo;");
            if (!getDevicesMethod) { env->ExceptionClear(); break; }

            jobjectArray deviceArray = (jobjectArray)env->CallObjectMethod(audioManager, getDevicesMethod, 2 /* GET_DEVICES_OUTPUTS */);
            if (!deviceArray) break;

            jsize deviceCount = env->GetArrayLength(deviceArray);
            if (deviceCount <= 0) break;

            jclass deviceInfoClass = env->FindClass("android/media/AudioDeviceInfo");
            if (!deviceInfoClass) { env->ExceptionClear(); break; }

            jmethodID getProductNameMethod = env->GetMethodID(deviceInfoClass, "getProductName", "()Ljava/lang/CharSequence;");
            jmethodID getTypeMethod = env->GetMethodID(deviceInfoClass, "getType", "()I");
            jmethodID getEncodingsMethod = env->GetMethodID(deviceInfoClass, "getEncodings", "()[I");
            jmethodID getSampleRatesMethod = env->GetMethodID(deviceInfoClass, "getSampleRates", "()[I");
            jclass charSeqClass = env->FindClass("java/lang/CharSequence");
            jmethodID toStringMethod = (charSeqClass && getProductNameMethod) ? env->GetMethodID(charSeqClass, "toString", "()Ljava/lang/String;") : nullptr;

            jobject selectedDevice = nullptr;
            int selectedPriority = -1;

            for (jsize i = 0; i < deviceCount; ++i)
            {
                jobject dev = env->GetObjectArrayElement(deviceArray, i);
                if (!dev) continue;

                int devType = getTypeMethod ? env->CallIntMethod(dev, getTypeMethod) : 0;
                int priority = 1;
                if (devType == 11 || devType == 22) priority = 4; // TYPE_USB_DEVICE / TYPE_USB_HEADSET
                else if (devType == 8 || devType == 26) priority = 3; // TYPE_BLUETOOTH_A2DP / TYPE_BLUETOOTH_LE
                else if (devType == 3 || devType == 4) priority = 2; // TYPE_WIRED_HEADSET / TYPE_WIRED_HEADPHONES

                if (priority > selectedPriority)
                {
                    selectedPriority = priority;
                    if (selectedDevice) env->DeleteLocalRef(selectedDevice);
                    selectedDevice = dev;
                }
                else
                {
                    env->DeleteLocalRef(dev);
                }
            }

            if (selectedDevice)
            {
                if (toStringMethod && getProductNameMethod)
                {
                    jobject nameSeq = env->CallObjectMethod(selectedDevice, getProductNameMethod);
                    if (nameSeq)
                    {
                        jstring nameStr = (jstring)env->CallObjectMethod(nameSeq, toStringMethod);
                        if (nameStr)
                        {
                            const char* utf = env->GetStringUTFChars(nameStr, nullptr);
                            if (utf && std::strlen(utf) > 0)
                            {
                                std::strncpy(info->device_name, utf, sizeof(info->device_name) - 1);
                                info->device_name[sizeof(info->device_name) - 1] = '\0';
                            }
                            if (utf) env->ReleaseStringUTFChars(nameStr, utf);
                            env->DeleteLocalRef(nameStr);
                        }
                        env->DeleteLocalRef(nameSeq);
                    }
                }

                if (getEncodingsMethod)
                {
                    jintArray encArray = (jintArray)env->CallObjectMethod(selectedDevice, getEncodingsMethod);
                    if (encArray)
                    {
                        jsize encLen = env->GetArrayLength(encArray);
                        jint* encs = env->GetIntArrayElements(encArray, nullptr);
                        if (encs)
                        {
                            int maxBitDepth = 16;
                            bool isFloat = false;
                            for (jsize e = 0; e < encLen; ++e)
                            {
                                jint fmtVal = encs[e];
                                if (fmtVal == 4) { // ENCODING_PCM_FLOAT
                                    isFloat = true;
                                    if (32 > maxBitDepth) maxBitDepth = 32;
                                } else if (fmtVal == 21) { // ENCODING_PCM_24BIT_PACKED
                                    if (24 > maxBitDepth) maxBitDepth = 24;
                                } else if (fmtVal == 22) { // ENCODING_PCM_32BIT
                                    if (32 > maxBitDepth) maxBitDepth = 32;
                                } else if (fmtVal == 2) { // ENCODING_PCM_16BIT
                                    if (16 > maxBitDepth) maxBitDepth = 16;
                                }
                            }
                            if (maxBitDepth > 0) info->bit_depth = maxBitDepth;
                            info->is_float = isFloat ? 1 : 0;
                            if (isFloat) info->output_format = AE_FORMAT_F32;
                            else if (maxBitDepth == 24) info->output_format = AE_FORMAT_S24;
                            else if (maxBitDepth == 32) info->output_format = AE_FORMAT_S32;
                            else if (maxBitDepth == 16) info->output_format = AE_FORMAT_S16;

                            env->ReleaseIntArrayElements(encArray, encs, JNI_ABORT);
                        }
                        env->DeleteLocalRef(encArray);
                    }
                }

                if (getSampleRatesMethod)
                {
                    jintArray ratesArray = (jintArray)env->CallObjectMethod(selectedDevice, getSampleRatesMethod);
                    if (ratesArray)
                    {
                        jsize rLen = env->GetArrayLength(ratesArray);
                        jint* rates = env->GetIntArrayElements(ratesArray, nullptr);
                        if (rates && rLen > 0)
                        {
                            int maxRate = 0;
                            for (jsize r = 0; r < rLen; ++r)
                            {
                                if (rates[r] > maxRate) maxRate = rates[r];
                            }
                            if (maxRate > 0 && (selectedPriority == 4 /* USB DAC */ || selectedPriority == 2 /* Wired */))
                            {
                                info->sample_rate = maxRate;
                            }
                            env->ReleaseIntArrayElements(ratesArray, rates, JNI_ABORT);
                        }
                        env->DeleteLocalRef(ratesArray);
                    }
                }

                env->DeleteLocalRef(selectedDevice);
            }

            if (selectedPriority == 4 /* USB DAC */)
            {
                if (info->sample_rate <= 0) info->sample_rate = defaultHalRate;
            }
            else if (selectedPriority == 3 /* Bluetooth */)
            {
                // If sample_rate was not pre-filled by the device negotiation, use default HAL rate
                if (info->sample_rate <= 0) info->sample_rate = defaultHalRate;
            }
            else
            {
                // Built-in speaker / 3.5mm jack
                if (info->sample_rate <= 0 || selectedPriority <= 1)
                {
                    info->sample_rate = defaultHalRate;
                }
            }

            if (info->sample_rate > 0 && info->period_size_frames > 0)
            {
                uint32_t periods = (info->period_count > 0) ? info->period_count : 2;
                double totalFrames = (double)info->period_size_frames * (double)periods;
                info->latency_ms = (totalFrames / (double)info->sample_rate) * 1000.0;
            }

            detect_universal_hardware_dsp(info);

            if (selectedPriority == 4)
            {
                std::strncat(info->dsp_hardware, " (External USB Audio Class DAC)", sizeof(info->dsp_hardware) - std::strlen(info->dsp_hardware) - 1);
            }
            else if (selectedPriority == 3)
            {
                std::strncat(info->dsp_hardware, " (Bluetooth Audio Output)", sizeof(info->dsp_hardware) - std::strlen(info->dsp_hardware) - 1);
            }

        } while (false);

        if (env->ExceptionCheck())
        {
            env->ExceptionClear();
        }

        if (needsDetach)
        {
            g_androidJavaVM->DetachCurrentThread();
        }
    }
#endif

    AE_API AEHardwareInfo ae_get_hardware_info(AudioEngineHandle *engine)
    {
        AEHardwareInfo info;
        std::memset(&info, 0, sizeof(AEHardwareInfo));

        if (!engine)
        {
            return info;
        }

        try
        {
            std::lock_guard<std::mutex> devLock(engine->deviceMutex);

            ma_device *pDevice = &engine->device;
            if (pDevice->pContext != nullptr && ma_device_get_state(pDevice) != ma_device_state_uninitialized)
            {
                const char *bname = ma_get_backend_name(pDevice->pContext->backend);
                if (bname)
                {
                    std::strncpy(info.backend_name, bname, sizeof(info.backend_name) - 1);
                }
            }
            else
            {
                std::strncpy(info.backend_name, "Unknown", sizeof(info.backend_name) - 1);
            }

            if (pDevice->playback.name[0] != '\0')
            {
                std::strncpy(info.device_name, pDevice->playback.name, sizeof(info.device_name) - 1);
            }
            else
            {
                std::strncpy(info.device_name, "Default Output Device", sizeof(info.device_name) - 1);
            }

#if defined(__ANDROID__)
            int activeBkForHw = engine->activeBackend.load(std::memory_order_relaxed);
            if (engine->pAudioTrackSink != nullptr && activeBkForHw >= AE_BACKEND_AUDIOTRACK)
            {
                auto* sink = reinterpret_cast<AndroidAudioTrackSink*>(engine->pAudioTrackSink);
                info.sample_rate = sink->sampleRate;
                info.channels = sink->channels;
                info.period_size_frames = (uint32_t)sink->framesPerBuffer;
                info.period_count = 2;
                info.is_exclusive_mode = (activeBkForHw == AE_BACKEND_DIRECT_HIRES) ? 1 : 0;

                if (sink->encoding == 21)
                {
                    info.output_format = AE_FORMAT_S24;
                    info.bit_depth = 24;
                    info.is_float = 0;
                }
                else if (sink->encoding == 2)
                {
                    info.output_format = AE_FORMAT_S16;
                    info.bit_depth = 16;
                    info.is_float = 0;
                }
                else if (sink->encoding == 22)
                {
                    info.output_format = AE_FORMAT_S32;
                    info.bit_depth = 32;
                    info.is_float = 0;
                }
                else
                {
                    info.output_format = AE_FORMAT_F32;
                    info.bit_depth = 32;
                    info.is_float = 1;
                }
            }
            else
#endif
            {
                ma_format hwFormat = pDevice->playback.internalFormat;
                info.sample_rate = (int)pDevice->playback.internalSampleRate;
                info.channels = (int)pDevice->playback.internalChannels;
                info.period_size_frames = (uint32_t)pDevice->playback.internalPeriodSizeInFrames;
                info.period_count = (uint32_t)pDevice->playback.internalPeriods;

                info.is_exclusive_mode = engine->exclusiveModeEnabled ? 1 : 0;

                switch (hwFormat)
                {
                case ma_format_u8:
                    info.output_format = AE_FORMAT_U8;
                    info.bit_depth = 8;
                    info.is_float = 0;
                    break;
                case ma_format_s16:
                    info.output_format = AE_FORMAT_S16;
                    info.bit_depth = 16;
                    info.is_float = 0;
                    break;
                case ma_format_s24:
                    info.output_format = AE_FORMAT_S24;
                    info.bit_depth = 24;
                    info.is_float = 0;
                    break;
                case ma_format_s32:
                    info.output_format = AE_FORMAT_S32;
                    info.bit_depth = 32;
                    info.is_float = 0;
                    break;
                case ma_format_f32:
                default:
                    info.output_format = AE_FORMAT_F32;
                    info.bit_depth = 32;
                    info.is_float = 1;
                    break;
                }
            }

            if (info.sample_rate > 0)
            {
                double totalFrames = (double)info.period_size_frames * (double)info.period_count;
                info.latency_ms = (totalFrames / (double)info.sample_rate) * 1000.0;
            }

            int activeBk = engine->activeBackend.load(std::memory_order_relaxed);
            if (activeBk == AE_BACKEND_DIRECT_HIRES)
            {
                std::strncpy(info.backend_name, "Direct Hi-Res", sizeof(info.backend_name) - 1);
                info.is_direct_pcm = 1;
            }
            else if (activeBk == AE_BACKEND_AUDIOTRACK)
            {
                std::strncpy(info.backend_name, "AudioTrack", sizeof(info.backend_name) - 1);
                info.is_direct_pcm = 0;
            }
            else if (activeBk == AE_BACKEND_AAUDIO)
            {
                std::strncpy(info.backend_name, "AAudio", sizeof(info.backend_name) - 1);
                info.is_direct_pcm = 0;
            }
            else if (activeBk == AE_BACKEND_OPENSL)
            {
                std::strncpy(info.backend_name, "OpenSL ES", sizeof(info.backend_name) - 1);
                info.is_direct_pcm = 0;
            }

#if !defined(__ANDROID__)
#if defined(_WIN32)
            std::strncpy(info.dsp_hardware, "Windows Audio Subsystem (WASAPI Core)", sizeof(info.dsp_hardware) - 1);
            std::strncpy(info.soc_name, "x86_64 Host Processor (SIMD AVX2/SSE)", sizeof(info.soc_name) - 1);
            info.is_direct_pcm = engine->exclusiveModeEnabled ? 1 : 0;
#elif defined(__APPLE__)
            std::strncpy(info.dsp_hardware, "Apple Core Audio Engine", sizeof(info.dsp_hardware) - 1);
            std::strncpy(info.soc_name, "Apple Silicon / Core Audio", sizeof(info.soc_name) - 1);
            info.is_direct_pcm = 1;
#elif defined(__linux__)
            std::strncpy(info.dsp_hardware, "ALSA Direct Kernel Sound", sizeof(info.dsp_hardware) - 1);
            std::strncpy(info.soc_name, "Linux Host Processor", sizeof(info.soc_name) - 1);
            info.is_direct_pcm = engine->exclusiveModeEnabled ? 1 : 0;
#else
            std::strncpy(info.dsp_hardware, "Host Native Audio", sizeof(info.dsp_hardware) - 1);
            std::strncpy(info.soc_name, "Host CPU", sizeof(info.soc_name) - 1);
            info.is_direct_pcm = 0;
#endif
#else
            query_android_hardware_info(&info);
            if (activeBk == AE_BACKEND_DIRECT_HIRES)
            {
                info.is_direct_pcm = 1;
            }
#endif
        }
        catch (...)
        {
            engine_log("ae_get_hardware_info exception caught cleanly");
        }

        return info;
    }

    AE_API void ae_set_loudness_meter_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (engine) engine->loudnessMeterEnabled.store(enabled != 0, std::memory_order_relaxed);
    }

    AE_API int ae_get_loudness_meter_enabled(AudioEngineHandle *engine)
    {
        return engine ? (engine->loudnessMeterEnabled.load(std::memory_order_relaxed) ? 1 : 0) : 0;
    }

    AE_API AELoudnessMetrics ae_get_loudness_metrics(AudioEngineHandle *engine)
    {
        AELoudnessMetrics m{-100.0f, -100.0f, -100.0f, 0.0f};
        if (engine)
        {
            m.momentary_lufs = engine->loudnessMeter.momentaryLUFS.load(std::memory_order_relaxed);
            m.short_term_lufs = engine->loudnessMeter.shortTermLUFS.load(std::memory_order_relaxed);
            m.integrated_lufs = engine->loudnessMeter.integratedLUFS.load(std::memory_order_relaxed);
            m.loudness_range_lra = engine->loudnessMeter.loudnessRangeLRA.load(std::memory_order_relaxed);
        }
        return m;
    }

    AE_API void ae_reset_loudness_meter(AudioEngineHandle *engine)
    {
        if (engine) engine->loudnessMeter.reset(engine->engineSampleRate);
    }

    AE_API void ae_set_loudness_normalizer_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (engine) engine->loudnessMeter.normalizerEnabled.store(enabled != 0, std::memory_order_relaxed);
    }

    AE_API int ae_get_loudness_normalizer_enabled(AudioEngineHandle *engine)
    {
        return engine ? (engine->loudnessMeter.normalizerEnabled.load(std::memory_order_relaxed) ? 1 : 0) : 0;
    }

    AE_API void ae_set_loudness_normalizer_target(AudioEngineHandle *engine, float target_lufs)
    {
        if (engine) engine->loudnessMeter.normalizerTargetLUFS.store(clampf(target_lufs, -30.0f, -6.0f), std::memory_order_relaxed);
    }

    AE_API float ae_get_loudness_normalizer_target(AudioEngineHandle *engine)
    {
        return engine ? engine->loudnessMeter.normalizerTargetLUFS.load(std::memory_order_relaxed) : -14.0f;
    }

    AE_API float ae_get_loudness_normalizer_gain_db(AudioEngineHandle *engine)
    {
        if (!engine) return 0.0f;
        const float g = engine->paramNormalizerGain.current;
        if (g <= 1e-6f) return -120.0f;
        return 20.0f * std::log10(g);
    }

    AE_API void ae_set_true_peak_meter_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (engine) engine->truePeakMeterEnabled.store(enabled != 0, std::memory_order_relaxed);
    }

    AE_API int ae_get_true_peak_meter_enabled(AudioEngineHandle *engine)
    {
        return engine ? (engine->truePeakMeterEnabled.load(std::memory_order_relaxed) ? 1 : 0) : 0;
    }

    AE_API AETruePeakMetrics ae_get_true_peak(AudioEngineHandle *engine)
    {
        AETruePeakMetrics tp{-100.0f, -100.0f, -100.0f};
        if (engine)
        {
            tp.left_dbtp  = engine->truePeakMeter.peakLeftDBTP.load(std::memory_order_relaxed);
            tp.right_dbtp = engine->truePeakMeter.peakRightDBTP.load(std::memory_order_relaxed);
            tp.max_dbtp   = engine->truePeakMeter.maxTruePeakDBTP.load(std::memory_order_relaxed);
        }
        return tp;
    }

    AE_API void ae_set_lookahead_limiter_enabled(AudioEngineHandle *engine, int enabled)
    {
        if (engine)
        {
            engine->lookaheadLimiterEnabled.store(enabled != 0, std::memory_order_relaxed);
            if (enabled != 0)
            {
                engine->lookaheadLimiter.updateParams(
                    engine->engineSampleRate,
                    engine->channels,
                    engine->lookaheadLimiter.ceilingDBTP,
                    engine->lookaheadLimiter.attackMs,
                    engine->lookaheadLimiter.releaseMs
                );
            }
        }
    }

    AE_API int ae_get_lookahead_limiter_enabled(AudioEngineHandle *engine)
    {
        return engine ? (engine->lookaheadLimiterEnabled.load(std::memory_order_relaxed) ? 1 : 0) : 0;
    }

    AE_API void ae_set_lookahead_limiter_params(AudioEngineHandle *engine, float ceiling_dbtp, float attack_ms, float release_ms)
    {
        if (engine)
        {
            engine->lookaheadLimiter.updateParams(
                engine->engineSampleRate,
                engine->channels,
                ceiling_dbtp,
                attack_ms,
                release_ms
            );
        }
    }

    AE_API void ae_get_lookahead_limiter_params(AudioEngineHandle *engine, float *out_ceiling_dbtp, float *out_attack_ms, float *out_release_ms)
    {
        if (engine)
        {
            if (out_ceiling_dbtp) *out_ceiling_dbtp = engine->lookaheadLimiter.ceilingDBTP;
            if (out_attack_ms) *out_attack_ms = engine->lookaheadLimiter.attackMs;
            if (out_release_ms) *out_release_ms = engine->lookaheadLimiter.releaseMs;
        }
    }

    AE_API float ae_get_lookahead_limiter_gain_reduction_db(AudioEngineHandle *engine)
    {
        return engine ? engine->lookaheadLimiter.currentGainReductionDB.load(std::memory_order_relaxed) : 0.0f;
    }

    AE_API void ae_set_parameter_smoothing_ms(AudioEngineHandle *engine, float smoothing_ms)
    {
        if (engine) engine->parameterSmoothingMs.store(clampf(smoothing_ms, 0.0f, 100.0f), std::memory_order_relaxed);
    }

    AE_API float ae_get_parameter_smoothing_ms(AudioEngineHandle *engine)
    {
        return engine ? engine->parameterSmoothingMs.load(std::memory_order_relaxed) : 15.0f;
    }

    AE_API AEResamplingPolicyInfo ae_get_resampling_policy_info(AudioEngineHandle *engine)
    {
        AEResamplingPolicyInfo info{};
        if (engine)
        {
            info.input_sample_rate  = engine->sourceSampleRate > 0 ? engine->sourceSampleRate : engine->engineSampleRate;
            info.engine_sample_rate = engine->engineSampleRate;
            info.device_sample_rate = engine->deviceSampleRate;
            info.is_bypassed = (info.engine_sample_rate == info.device_sample_rate) ? 1 : 0;
            info.mode = info.is_bypassed ? 0 : (engine->autoSampleRateMatchEnabled ? 1 : 3);
            info.resampler_latency_ms = engine->deviceResamplerInit ? (double)ma_resampler_get_input_latency(&engine->deviceResampler) / (double)engine->deviceSampleRate * 1000.0 : 0.0;
            info.filter_passband_ratio = 0.45 * (double)info.device_sample_rate;
            info.is_linear_phase = (engine->resampleAlgorithm == AE_RESAMPLE_ALGORITHM_SOXR_VHQ_LINEAR_PHASE || engine->resampleAlgorithm == AE_RESAMPLE_ALGORITHM_R8BRAIN_24_LINEAR_PHASE) ? 1 : 0;
        }
        return info;
    }

    AE_API AEQualityTelemetry ae_get_quality_telemetry(AudioEngineHandle *engine)
    {
        AEQualityTelemetry t{};
        if (engine)
        {
            AETruePeakMetrics tp = ae_get_true_peak(engine);
            AELoudnessMetrics lm = ae_get_loudness_metrics(engine);
            t.true_peak_dbtp = tp.max_dbtp;
            t.momentary_lufs = lm.momentary_lufs;
            t.short_term_lufs = lm.short_term_lufs;
            t.integrated_lufs = lm.integrated_lufs;
            t.loudness_range_lra = lm.loudness_range_lra;
            t.crest_factor_db = (tp.max_dbtp > -90.0f && lm.short_term_lufs > -90.0f) ? (tp.max_dbtp - lm.short_term_lufs) : 0.0f;
            t.limiter_gain_reduction_db = ae_get_lookahead_limiter_gain_reduction_db(engine);
            t.resampler_latency_ms = ae_get_resampling_policy_info(engine).resampler_latency_ms;
            t.total_engine_latency_ms = ae_get_engine_latency_ms(engine);
            t.clipped_samples_count = ae_get_clipped_samples_count(engine);
            // Real measured values: sample peak from the meter (not a fabricated
            // "truepeak - 0.5 dB") and the actual underrun counter.
            const float samplePeak = engine->truePeakMeter.samplePeakDBTP.load(std::memory_order_relaxed);
            t.sample_peak_db = samplePeak;
            t.underrun_count = engine->underrunCount.load(std::memory_order_relaxed);
        }
        return t;
    }

} // extern "C"
