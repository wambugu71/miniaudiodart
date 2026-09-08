#include "ffmpeg_stream_decoder.h"

#include <cstring>
#include <chrono>
#include <algorithm>
#include <iostream>
#include <mutex>

#ifdef __ANDROID__
#include <android/log.h>
#define SF_LOG(...) __android_log_print(ANDROID_LOG_INFO, "SautiFlowFFmpeg", __VA_ARGS__)
#define SF_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "SautiFlowFFmpeg", __VA_ARGS__)
#else
#define SF_LOG(...) do { std::printf(__VA_ARGS__); std::fflush(stdout); } while(0)
#define SF_LOGE(...) do { std::fprintf(stderr, __VA_ARGS__); std::fflush(stderr); } while(0)
#endif

#if defined(SAUTIFLOW_ENABLE_FFMPEG) && SAUTIFLOW_ENABLE_FFMPEG
#ifdef __cplusplus
extern "C" {
#endif
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <libavutil/dict.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/time.h>
#ifdef __cplusplus
}
#endif

#include "dsp/denormals.h"

namespace sautiflow {

static void configure_audiophile_swr_opts(SwrContext* swrCtx) {
    if (!swrCtx) return;
    // Attempt SoXR engine if compiled in libswresample, fallback gracefully
    av_opt_set_int(swrCtx, "resampler", 1 /* SWR_ENGINE_SOXR */, 0);
    // 32-tap high-precision sinc filter
    av_opt_set_int(swrCtx, "filter_size", 32, 0);
    av_opt_set_double(swrCtx, "cutoff", 0.99, 0);
    av_opt_set_int(swrCtx, "precision", 28, 0);
    // Minimum phase to eliminate pre-ringing on transients
    av_opt_set_int(swrCtx, "phase", 0, 0);
}

static bool init_swr_context(SwrContext* swrCtx) {
    if (!swrCtx) return false;

    // 1. Attempt SoXR audiophile engine with minimum-phase sinc filter
    configure_audiophile_swr_opts(swrCtx);
    int ret = swr_init(swrCtx);
    if (ret >= 0 && swr_is_initialized(swrCtx)) {
        SF_LOG("[ffmpeg] SwrContext initialized successfully with SoXR audiophile engine\n");
        return true;
    }

    // 2. Fallback to FFmpeg default swresample engine (guaranteed available across all platforms including Android)
    SF_LOG("[ffmpeg] SoXR engine unavailable in libswresample (ret=%d); falling back to default swresample engine\n", ret);
    av_opt_set_int(swrCtx, "resampler", 0 /* SWR_ENGINE_SWR */, 0);
    av_opt_set_int(swrCtx, "filter_size", 32, 0);
    av_opt_set_double(swrCtx, "cutoff", 0.99, 0);
    ret = swr_init(swrCtx);
    if (ret >= 0 && swr_is_initialized(swrCtx)) {
        SF_LOG("[ffmpeg] SwrContext initialized successfully with default swresample engine\n");
        return true;
    }

    SF_LOGE("[ffmpeg] Failed to initialize SwrContext with any engine (ret=%d)\n", ret);
    return false;
}


static std::atomic<FFmpegStreamSource*> g_activeStreamSource{nullptr};

static int ffmpeg_interrupt_callback(void* ctx) {
    auto* self = static_cast<FFmpegStreamSource*>(ctx);
    if (!self) return 0;
    return self->is_stop_requested() ? 1 : 0;
}

StreamTelemetry get_active_stream_telemetry() {
    FFmpegStreamSource* src = g_activeStreamSource.load(std::memory_order_acquire);
    if (src != nullptr) {
        return src->get_telemetry();
    }
    return StreamTelemetry();
}

bool FFmpegStreamSource::is_network_url(const char* path) {
    if (path == nullptr) return false;
    std::string s(path);
    auto to_lower = [](std::string in) {
        for (auto &c : in) c = (char)::tolower(c);
        return in;
    };
    std::string lower = to_lower(s);
    return (lower.rfind("http://", 0) == 0 ||
            lower.rfind("https://", 0) == 0 ||
            lower.rfind("rtmp://", 0) == 0 ||
            lower.rfind("rtsp://", 0) == 0 ||
            lower.rfind("mms://", 0) == 0 ||
            lower.find(".m3u8") != std::string::npos ||
            lower.find(".mpd") != std::string::npos);
}

static std::string av_err2str_cpp(int errnum) {
    char errbuf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(errnum, errbuf, sizeof(errbuf));
    return std::string(errbuf);
}

FFmpegStreamSource::FFmpegStreamSource() {
    static std::once_flag initFlag;
    std::call_once(initFlag, []() {
        avformat_network_init();
    });
}

FFmpegStreamSource::~FFmpegStreamSource() {
    close();
}

void FFmpegStreamSource::set_telemetry_callback(StreamTelemetryCallback cb) {
    std::lock_guard<std::mutex> lock(m_stateMutex);
    m_telemetryCb = std::move(cb);
}

void FFmpegStreamSource::notify_telemetry() {
    StreamTelemetry copy;
    StreamTelemetryCallback cb;
    {
        std::lock_guard<std::mutex> lock(m_stateMutex);
        copy = m_telemetry;
        cb = m_telemetryCb;
    }
    if (cb) {
        cb(copy);
    }
}

void FFmpegStreamSource::set_error(StreamErrorCode code, const std::string& msg) {
    {
        std::lock_guard<std::mutex> lock(m_stateMutex);
        m_telemetry.state = StreamState::Error;
        m_telemetry.errorCode = code;
        std::strncpy(m_telemetry.errorMessage, msg.c_str(), sizeof(m_telemetry.errorMessage) - 1);
    }
    notify_telemetry();
}

StreamTelemetry FFmpegStreamSource::get_telemetry() const {
    std::lock_guard<std::mutex> lock(m_stateMutex);
    return m_telemetry;
}

bool FFmpegStreamSource::open(const std::string& url, int targetSampleRate, int targetChannels, int prebufferMs) {
    close();

    m_url = url;
    m_targetSampleRate = (targetSampleRate > 0) ? targetSampleRate : 48000;
    m_targetChannels = (targetChannels > 0) ? targetChannels : 2;
    
    bool isNetwork = is_network_url(m_url.c_str());

    // Allocate 10-second circular PCM ring buffer
    const size_t ringBufferDurationSec = 10;
    m_rbCapacityFrames = m_targetSampleRate * ringBufferDurationSec;
    m_pcmRingBuffer.assign(m_rbCapacityFrames * m_targetChannels, 0.0f);
    m_rbReadPos.store(0, std::memory_order_relaxed);
    m_rbWritePos.store(0, std::memory_order_relaxed);
    m_rbAvailableFrames.store(0, std::memory_order_relaxed);

    if (isNetwork) {
        // Initial prebuffer threshold (e.g. 1.5 seconds)
        size_t prebufferFrames = (m_targetSampleRate * (prebufferMs > 0 ? prebufferMs : 1500)) / 1000;
        if (prebufferFrames == 0) prebufferFrames = m_targetSampleRate / 2; // minimum 500ms
        m_prebufferBytes = prebufferFrames;

        // Rebuffer threshold (e.g. 3.0 seconds for jitter recovery)
        size_t rebufferFrames = (m_targetSampleRate * (prebufferMs > 0 ? prebufferMs * 2 : 3000)) / 1000;
        if (rebufferFrames > m_rbCapacityFrames / 2) rebufferFrames = m_rbCapacityFrames / 2;
        m_rebufferBytes = rebufferFrames;

        m_isBuffering.store(true, std::memory_order_release);
    } else {
        // Local file - instant playback from disk with zero prebuffering delay
        m_prebufferBytes = 0;
        m_rebufferBytes = 0;
        m_isBuffering.store(false, std::memory_order_release);
    }

    m_stopRequested.store(false, std::memory_order_release);
    m_isPaused.store(false, std::memory_order_relaxed);
    m_isEnded.store(false, std::memory_order_relaxed);
    m_seekRequested.store(false, std::memory_order_relaxed);

    {
        std::lock_guard<std::mutex> lock(m_stateMutex);
        m_telemetry = StreamTelemetry();
        m_telemetry.state = isNetwork ? StreamState::Connecting : StreamState::Playing;
        m_telemetry.sampleRate = m_targetSampleRate;
        m_telemetry.channels = m_targetChannels;
    }
    notify_telemetry();

    m_isOpen.store(true, std::memory_order_release);
    g_activeStreamSource.store(this, std::memory_order_release);
    m_workerThread = std::thread(&FFmpegStreamSource::demux_and_decode_thread_func, this);
    return true;
}

void FFmpegStreamSource::close() {
    m_stopRequested.store(true, std::memory_order_release);
    m_cv.notify_all();

    if (m_workerThread.joinable()) {
        m_workerThread.join();
    }

    {
        std::lock_guard<std::mutex> lock(m_stateMutex);
        if (m_swrCtx) {
            swr_free(&m_swrCtx);
            m_swrCtx = nullptr;
        }
        if (m_codecCtx) {
            avcodec_free_context(&m_codecCtx);
            m_codecCtx = nullptr;
        }
        if (m_fmtCtx) {
            avformat_close_input(&m_fmtCtx);
            m_fmtCtx = nullptr;
        }
        m_audioStreamIndex = -1;
        m_telemetry.state = StreamState::Idle;
    }

    if (g_activeStreamSource.load(std::memory_order_acquire) == this) {
        g_activeStreamSource.store(nullptr, std::memory_order_release);
    }

    m_isOpen.store(false, std::memory_order_release);
    m_isBuffering.store(false, std::memory_order_release);
    m_isEnded.store(false, std::memory_order_release);
}

void FFmpegStreamSource::pause() {
    m_isPaused.store(true, std::memory_order_release);
}

void FFmpegStreamSource::resume() {
    m_isPaused.store(false, std::memory_order_release);
    m_cv.notify_all();
}

bool FFmpegStreamSource::seek(int64_t timestampMs) {
    if (!m_isOpen.load(std::memory_order_acquire) || m_telemetry.isLiveStream) {
        return false;
    }
    m_seekTargetMs.store(timestampMs, std::memory_order_release);
    m_seekRequested.store(true, std::memory_order_release);
    m_cv.notify_all();
    return true;
}

size_t FFmpegStreamSource::read_pcm(float* pOut, size_t frameCount) {
    if (!m_isOpen.load(std::memory_order_acquire) || pOut == nullptr || frameCount == 0) {
        return 0;
    }

    size_t available = m_rbAvailableFrames.load(std::memory_order_acquire);
    if (m_isBuffering.load(std::memory_order_relaxed)) {
        // Exit buffering once we have enough frames or reached stream end
        if (available >= m_rebufferBytes || m_isEnded.load(std::memory_order_relaxed)) {
            m_isBuffering.store(false, std::memory_order_release);
            {
                std::lock_guard<std::mutex> lock(m_stateMutex);
                m_telemetry.state = StreamState::Playing;
            }
            notify_telemetry();
        } else {
            // Fill with silence while buffering and return 0 frames to prevent timeline drift
            std::fill(pOut, pOut + frameCount * m_targetChannels, 0.0f);
            return 0;
        }
    }

    if (available == 0) {
        if (m_isEnded.load(std::memory_order_relaxed)) {
            {
                std::lock_guard<std::mutex> lock(m_stateMutex);
                m_telemetry.state = StreamState::Ended;
            }
            notify_telemetry();
            return 0;
        }
        // Jitter underrun: enter buffering mode
        m_isBuffering.store(true, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(m_stateMutex);
            m_telemetry.state = StreamState::Buffering;
        }
        notify_telemetry();
        std::fill(pOut, pOut + frameCount * m_targetChannels, 0.0f);
        return 0;
    }

    size_t toRead = std::min(frameCount, available);
    size_t readPos = m_rbReadPos.load(std::memory_order_relaxed);

    size_t firstPart = std::min(toRead, m_rbCapacityFrames - readPos);
    std::memcpy(pOut, &m_pcmRingBuffer[readPos * m_targetChannels], firstPart * m_targetChannels * sizeof(float));

    if (toRead > firstPart) {
        size_t secondPart = toRead - firstPart;
        std::memcpy(pOut + firstPart * m_targetChannels, &m_pcmRingBuffer[0], secondPart * m_targetChannels * sizeof(float));
    }

    m_rbReadPos.store((readPos + toRead) % m_rbCapacityFrames, std::memory_order_relaxed);
    m_rbAvailableFrames.fetch_sub(toRead, std::memory_order_release);

    if (toRead < frameCount) {
        std::fill(pOut + toRead * m_targetChannels, pOut + frameCount * m_targetChannels, 0.0f);
    }

    // Wake decoder thread if buffer has room
    m_cv.notify_one();
    return toRead;
}

void FFmpegStreamSource::update_icy_metadata() {
    if (!m_fmtCtx) return;

    AVDictionaryEntry* tag = nullptr;
    tag = av_dict_get(m_fmtCtx->metadata, "StreamTitle", nullptr, 0);
    if (!tag) {
        tag = av_dict_get(m_fmtCtx->metadata, "title", nullptr, 0);
    }

    if (tag && tag->value) {
        std::string rawTitle = tag->value;
        std::string artist, title;
        size_t dashPos = rawTitle.find(" - ");
        if (dashPos != std::string::npos) {
            artist = rawTitle.substr(0, dashPos);
            title = rawTitle.substr(dashPos + 3);
        } else {
            title = rawTitle;
        }

        std::lock_guard<std::mutex> lock(m_stateMutex);
        if (std::strcmp(m_telemetry.icyTitle, title.c_str()) != 0 ||
            std::strcmp(m_telemetry.icyArtist, artist.c_str()) != 0) {
            std::strncpy(m_telemetry.icyTitle, title.c_str(), sizeof(m_telemetry.icyTitle) - 1);
            std::strncpy(m_telemetry.icyArtist, artist.c_str(), sizeof(m_telemetry.icyArtist) - 1);
            notify_telemetry();
        }
    }
}

void FFmpegStreamSource::demux_and_decode_thread_func() {
    sauti::dsp::ScopedDenormalsDisable denormalsScope;
    bool isNetwork = is_network_url(m_url.c_str());
    AVDictionary* opts = nullptr;

    if (isNetwork) {
        av_dict_set(&opts, "user_agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MiniAudioDart/1.0 SautiFlow/1.0", 0);
        av_dict_set(&opts, "reconnect", "1", 0);
        av_dict_set(&opts, "reconnect_streamed", "1", 0);
        av_dict_set(&opts, "reconnect_delay_max", "5", 0);
        av_dict_set(&opts, "timeout", "10000000", 0);      // 10s socket timeout
        av_dict_set(&opts, "rw_timeout", "10000000", 0);   // 10s read/write timeout
        av_dict_set(&opts, "probesize", "32768", 0);       // 32 KB probe for fast startup
        av_dict_set(&opts, "max_analyze_duration", "500000", 0); // 500ms max analyze duration
        av_dict_set(&opts, "icy", "1", 0);                 // Enable Shoutcast/Icecast in-band metadata
        av_dict_set(&opts, "tls_verify", "0", 0);          // Disable TLS verify for Android where CA bundles are not in /etc/ssl
    }

    m_fmtCtx = avformat_alloc_context();
    if (!m_fmtCtx) {
        if (opts) av_dict_free(&opts);
        set_error(StreamErrorCode::OpenFailed, "Failed to allocate AVFormatContext");
        m_isBuffering.store(false, std::memory_order_release);
        m_isEnded.store(true, std::memory_order_release);
        m_cv.notify_all();
        return;
    }

    if (isNetwork) {
        // Register interrupt callback to abort hanging socket/network calls immediately on close
        m_fmtCtx->interrupt_callback.callback = ffmpeg_interrupt_callback;
        m_fmtCtx->interrupt_callback.opaque = this;
    }

    SF_LOG("[ffmpeg] Step 1/5: Opening format context for %s: %s\n",
           isNetwork ? "network URL" : "local file", m_url.c_str());

    int ret = avformat_open_input(&m_fmtCtx, m_url.c_str(), nullptr, opts ? &opts : nullptr);
    if (opts) av_dict_free(&opts);

    if (ret < 0) {
        SF_LOGE("[ffmpeg] Step 1/5 FAILED: avformat_open_input returned error %s for %s\n",
                av_err2str_cpp(ret).c_str(), m_url.c_str());
        if (!m_stopRequested.load(std::memory_order_acquire)) {
            set_error(StreamErrorCode::OpenFailed, "Failed to open " + std::string(isNetwork ? "stream URL: " : "audio file: ") + av_err2str_cpp(ret));
        }
        m_isBuffering.store(false, std::memory_order_release);
        m_isEnded.store(true, std::memory_order_release);
        m_cv.notify_all();
        return;
    }

    SF_LOG("[ffmpeg] Step 2/5: Probing stream information...\n");

    if (avformat_find_stream_info(m_fmtCtx, nullptr) < 0) {
        SF_LOGE("[ffmpeg] Step 2/5 FAILED: avformat_find_stream_info failed for %s\n", m_url.c_str());
        if (!m_stopRequested.load(std::memory_order_acquire)) {
            set_error(StreamErrorCode::StreamInfoNotFound, "Could not find stream info");
        }
        m_isBuffering.store(false, std::memory_order_release);
        m_isEnded.store(true, std::memory_order_release);
        m_cv.notify_all();
        return;
    }

    const AVCodec* decoder = nullptr;
    m_audioStreamIndex = av_find_best_stream(m_fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
    if (m_audioStreamIndex < 0 || !decoder) {
        SF_LOGE("[ffmpeg] Step 2/5 FAILED: No audio stream or decoder found in %s\n", m_url.c_str());
        if (!m_stopRequested.load(std::memory_order_acquire)) {
            set_error(StreamErrorCode::CodecNotFound, "No audio stream or decoder found");
        }
        m_isBuffering.store(false, std::memory_order_release);
        m_isEnded.store(true, std::memory_order_release);
        m_cv.notify_all();
        return;
    }

    AVStream* audioStream = m_fmtCtx->streams[m_audioStreamIndex];
    SF_LOG("[ffmpeg] Step 2/5 SUCCESS: Found audio stream (index=%d, codec=%s, rate=%d Hz, channels=%d)\n",
           m_audioStreamIndex, decoder->name, audioStream->codecpar->sample_rate, audioStream->codecpar->ch_layout.nb_channels);

    m_codecCtx = avcodec_alloc_context3(decoder);
    if (!m_codecCtx) {
        set_error(StreamErrorCode::CodecOpenFailed, "Failed to allocate codec context");
        m_isBuffering.store(false, std::memory_order_release);
        m_isEnded.store(true, std::memory_order_release);
        m_cv.notify_all();
        return;
    }

    if (avcodec_parameters_to_context(m_codecCtx, audioStream->codecpar) < 0) {
        set_error(StreamErrorCode::CodecOpenFailed, "Failed to copy codec parameters");
        m_isBuffering.store(false, std::memory_order_release);
        m_isEnded.store(true, std::memory_order_release);
        m_cv.notify_all();
        return;
    }

    if (avcodec_open2(m_codecCtx, decoder, nullptr) < 0) {
        SF_LOGE("[ffmpeg] Step 3/5 FAILED: avcodec_open2 failed for codec %s\n", decoder->name);
        set_error(StreamErrorCode::CodecOpenFailed, "Failed to open audio codec");
        m_isBuffering.store(false, std::memory_order_release);
        m_isEnded.store(true, std::memory_order_release);
        m_cv.notify_all();
        return;
    }

    SF_LOG("[ffmpeg] Step 3/5 SUCCESS: Codec %s initialized\n", decoder->name);

    // Initial Resampler setup if sample format is already known
    if (m_codecCtx->sample_rate > 0 && m_codecCtx->sample_fmt != AV_SAMPLE_FMT_NONE) {
        AVChannelLayout outLayout;
        av_channel_layout_default(&outLayout, m_targetChannels == 1 ? 1 : 2);

        ret = swr_alloc_set_opts2(
            &m_swrCtx,
            &outLayout,
            AV_SAMPLE_FMT_FLT, // 32-bit float interleaved
            m_targetSampleRate,
            &m_codecCtx->ch_layout,
            m_codecCtx->sample_fmt,
            m_codecCtx->sample_rate,
            0,
            nullptr
        );

        av_channel_layout_uninit(&outLayout);

        if (ret >= 0 && m_swrCtx) {
            if (init_swr_context(m_swrCtx)) {
                SF_LOG("[ffmpeg] Step 4/5 SUCCESS: Initial SwrContext configured (%d Hz -> %d Hz, %d ch)\n",
                       m_codecCtx->sample_rate, m_targetSampleRate, m_targetChannels);
            } else {
                SF_LOGE("[ffmpeg] Step 4/5 FAILED: Failed to initialize SwrContext\n");
            }
        }
    }

    // Populate initial telemetry
    {
        std::lock_guard<std::mutex> lock(m_stateMutex);
        m_telemetry.state = isNetwork ? StreamState::Buffering : StreamState::Playing;
        m_telemetry.bitrate = m_fmtCtx->bit_rate > 0 ? m_fmtCtx->bit_rate : audioStream->codecpar->bit_rate;
        m_telemetry.isLiveStream = (m_fmtCtx->duration <= 0 || m_fmtCtx->duration == AV_NOPTS_VALUE);
        m_telemetry.totalDurationSec = m_telemetry.isLiveStream ? 0.0 : (double)m_fmtCtx->duration / AV_TIME_BASE;
        m_telemetry.isSeekable = !m_telemetry.isLiveStream;
        std::strncpy(m_telemetry.codecName, decoder->name, sizeof(m_telemetry.codecName) - 1);
    }
    if (isNetwork) {
        update_icy_metadata();
    }
    notify_telemetry();

    SF_LOG("[ffmpeg] Step 5/5 SUCCESS: Playback pipeline active (duration=%.2fs, isLive=%d, isSeekable=%d)\n",
           m_telemetry.totalDurationSec, m_telemetry.isLiveStream ? 1 : 0, m_telemetry.isSeekable ? 1 : 0);

    AVPacket* packet = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();
    std::vector<float> resampleOutBuf;

    auto lastTelemetryUpdate = std::chrono::steady_clock::now();

    while (!m_stopRequested.load(std::memory_order_acquire)) {
        // Handle Seek Request
        if (m_seekRequested.load(std::memory_order_acquire)) {
            int64_t targetMs = m_seekTargetMs.load(std::memory_order_acquire);
            m_seekRequested.store(false, std::memory_order_release);

            if (m_fmtCtx != nullptr && m_audioStreamIndex >= 0) {
                AVStream* audioStream = m_fmtCtx->streams[m_audioStreamIndex];
                int64_t targetTs = av_rescale_q(targetMs, AVRational{1, 1000}, audioStream->time_base);
                
                int seekRes = avformat_seek_file(m_fmtCtx, m_audioStreamIndex, INT64_MIN, targetTs, targetTs, 0);
                if (seekRes < 0) {
                    // Fallback to av_seek_frame with AVSEEK_FLAG_BACKWARD
                    seekRes = av_seek_frame(m_fmtCtx, m_audioStreamIndex, targetTs, AVSEEK_FLAG_BACKWARD);
                }

                if (seekRes >= 0) {
                    avcodec_flush_buffers(m_codecCtx);
                    if (m_swrCtx) {
                        swr_init(m_swrCtx);
                    }
                    m_rbReadPos.store(0, std::memory_order_release);
                    m_rbWritePos.store(0, std::memory_order_release);
                    m_rbAvailableFrames.store(0, std::memory_order_release);
                    m_isBuffering.store(true, std::memory_order_release);
                    m_isEnded.store(false, std::memory_order_release);

                    {
                        std::lock_guard<std::mutex> lock(m_stateMutex);
                        m_telemetry.state = StreamState::Buffering;
                    }
                    notify_telemetry();
                }
            }
        }

        // Wait if paused
        if (m_isPaused.load(std::memory_order_acquire)) {
            std::unique_lock<std::mutex> lock(m_stateMutex);
            m_cv.wait_for(lock, std::chrono::milliseconds(50), [this]() {
                return !m_isPaused.load(std::memory_order_acquire) || m_stopRequested.load(std::memory_order_acquire);
            });
            continue;
        }

        // Check if ring buffer is near full (prevent overflow)
        size_t available = m_rbAvailableFrames.load(std::memory_order_relaxed);
        if (available >= m_rbCapacityFrames - (size_t)(m_targetSampleRate * 2)) {
            // Buffer has plenty of headroom (> 8 seconds)
            std::unique_lock<std::mutex> lock(m_stateMutex);
            m_cv.wait_for(lock, std::chrono::milliseconds(20), [this]() {
                return m_stopRequested.load(std::memory_order_acquire) || 
                       m_seekRequested.load(std::memory_order_acquire) ||
                       m_rbAvailableFrames.load(std::memory_order_relaxed) < m_rbCapacityFrames / 2;
            });
            continue;
        }

        // Periodic telemetry & ICY metadata check
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastTelemetryUpdate).count() >= 250) {
            lastTelemetryUpdate = now;
            update_icy_metadata();

            double bufferedSec = (double)available / m_targetSampleRate;
            double pct = std::min(100.0, (bufferedSec / ((double)m_prebufferBytes / m_targetSampleRate)) * 100.0);
            {
                std::lock_guard<std::mutex> lock(m_stateMutex);
                m_telemetry.bufferedDurationSec = bufferedSec;
                m_telemetry.bufferPercent = pct;
            }
            notify_telemetry();
        }

        ret = av_read_frame(m_fmtCtx, packet);
        if (ret < 0) {
            if (ret == AVERROR_EOF || (m_fmtCtx->pb && avio_feof(m_fmtCtx->pb))) {
                // Stream reached end
                m_isEnded.store(true, std::memory_order_release);
                m_isBuffering.store(false, std::memory_order_release);
                break;
            }
            if (m_stopRequested.load(std::memory_order_acquire)) {
                break;
            }
            // Transient error: wait and retry
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        if (packet->stream_index == m_audioStreamIndex) {
            if (avcodec_send_packet(m_codecCtx, packet) >= 0) {
                while (avcodec_receive_frame(m_codecCtx, frame) >= 0) {
                    // Dynamically ensure SwrContext matches actual decoded frame properties
                    if (!m_swrCtx) {
                        AVChannelLayout outLayout;
                        av_channel_layout_default(&outLayout, m_targetChannels == 1 ? 1 : 2);
                        swr_alloc_set_opts2(
                            &m_swrCtx,
                            &outLayout,
                            AV_SAMPLE_FMT_FLT,
                            m_targetSampleRate,
                            &frame->ch_layout,
                            (AVSampleFormat)frame->format,
                            frame->sample_rate,
                            0,
                            nullptr
                        );
                        av_channel_layout_uninit(&outLayout);
                        if (m_swrCtx) {
                            init_swr_context(m_swrCtx);
                        }
                    }

                    if (!m_swrCtx) continue;

                    // Resample decoded frame to float32 stereo
                    int outSamples = swr_get_out_samples(m_swrCtx, frame->nb_samples);
                    if (outSamples > 0) {
                        resampleOutBuf.resize(outSamples * m_targetChannels);
                        uint8_t* outData[32] = { nullptr };
                        outData[0] = reinterpret_cast<uint8_t*>(resampleOutBuf.data());

                        int converted = swr_convert(
                            m_swrCtx,
                            outData,
                            outSamples,
                            const_cast<const uint8_t**>(frame->data),
                            frame->nb_samples
                        );

                        if (converted > 0) {
                            // Wait for buffer space if full
                            std::unique_lock<std::mutex> cvLock(m_stateMutex);
                            m_cv.wait(cvLock, [this, converted]() {
                                return m_stopRequested.load(std::memory_order_acquire) ||
                                       m_seekRequested.load(std::memory_order_acquire) ||
                                       (m_rbCapacityFrames - m_rbAvailableFrames.load(std::memory_order_acquire)) >= static_cast<size_t>(converted);
                            });

                            if (m_stopRequested.load(std::memory_order_acquire) || m_seekRequested.load(std::memory_order_acquire)) {
                                break;
                            }

                            // Write to circular ring buffer
                            size_t writePos = m_rbWritePos.load(std::memory_order_relaxed);
                            size_t firstPart = std::min(static_cast<size_t>(converted), m_rbCapacityFrames - writePos);
                            std::memcpy(&m_pcmRingBuffer[writePos * m_targetChannels], resampleOutBuf.data(), firstPart * m_targetChannels * sizeof(float));

                            if (static_cast<size_t>(converted) > firstPart) {
                                size_t secondPart = static_cast<size_t>(converted) - firstPart;
                                std::memcpy(&m_pcmRingBuffer[0], resampleOutBuf.data() + firstPart * m_targetChannels, secondPart * m_targetChannels * sizeof(float));
                            }

                            m_rbWritePos.store((writePos + converted) % m_rbCapacityFrames, std::memory_order_relaxed);
                            m_rbAvailableFrames.fetch_add(converted, std::memory_order_release);
                        }
                    }
                }
            }
        }
        av_packet_unref(packet);
    }

    av_frame_free(&frame);
    av_packet_free(&packet);
}

} // namespace sautiflow

// ============================================================================
// MINIAUDIO DATA SOURCE & DECODING BACKEND ADAPTER
// ============================================================================

struct ma_ffmpeg_data_source {
    ma_data_source_base base;
    sautiflow::FFmpegStreamSource* stream;
    ma_format format;
    ma_uint32 channels;
    ma_uint32 sampleRate;
    ma_uint64 cursor;
};

static ma_result ma_ffmpeg_ds_read(ma_data_source* pDataSource, void* pFramesOut, ma_uint64 frameCount, ma_uint64* pFramesRead) {
    auto* ds = reinterpret_cast<ma_ffmpeg_data_source*>(pDataSource);
    if (!ds || !ds->stream) return MA_INVALID_ARGS;

    size_t read = ds->stream->read_pcm(reinterpret_cast<float*>(pFramesOut), static_cast<size_t>(frameCount));
    if (pFramesRead) *pFramesRead = read;
    ds->cursor += read;
    if (read == 0) {
        if (ds->stream->is_buffering()) {
            std::memset(pFramesOut, 0, frameCount * ds->channels * sizeof(float));
            return MA_BUSY;
        }
        if (ds->stream->is_ended()) {
            return MA_AT_END;
        }
    }
    return MA_SUCCESS;
}

static ma_result ma_ffmpeg_ds_seek(ma_data_source* pDataSource, ma_uint64 frameIndex) {
    auto* ds = reinterpret_cast<ma_ffmpeg_data_source*>(pDataSource);
    if (!ds || !ds->stream) return MA_INVALID_ARGS;

    if (ds->sampleRate > 0) {
        int64_t ms = (frameIndex * 1000) / ds->sampleRate;
        ds->stream->seek(ms);
        ds->cursor = frameIndex;
    }
    return MA_SUCCESS;
}

static ma_result ma_ffmpeg_ds_get_data_format(ma_data_source* pDataSource, ma_format* pFormat, ma_uint32* pChannels, ma_uint32* pSampleRate, ma_channel* pChannelMap, size_t channelMapCap) {
    auto* ds = reinterpret_cast<ma_ffmpeg_data_source*>(pDataSource);
    if (!ds) return MA_INVALID_ARGS;

    if (pFormat) *pFormat = ds->format;
    if (pChannels) *pChannels = ds->channels;
    if (pSampleRate) *pSampleRate = ds->sampleRate;
    if (pChannelMap) ma_channel_map_init_standard(ma_standard_channel_map_default, pChannelMap, channelMapCap, ds->channels);
    return MA_SUCCESS;
}

static ma_result ma_ffmpeg_ds_get_cursor(ma_data_source* pDataSource, ma_uint64* pCursor) {
    auto* ds = reinterpret_cast<ma_ffmpeg_data_source*>(pDataSource);
    if (!ds) return MA_INVALID_ARGS;
    if (pCursor) *pCursor = ds->cursor;
    return MA_SUCCESS;
}

static ma_result ma_ffmpeg_ds_get_length(ma_data_source* pDataSource, ma_uint64* pLength) {
    auto* ds = reinterpret_cast<ma_ffmpeg_data_source*>(pDataSource);
    if (!ds || !ds->stream) return MA_INVALID_ARGS;

    auto tel = ds->stream->get_telemetry();
    if (pLength) {
        if (tel.isLiveStream || tel.totalDurationSec <= 0) {
            *pLength = 0;
        } else {
            *pLength = static_cast<ma_uint64>(tel.totalDurationSec * ds->sampleRate);
        }
    }
    return MA_SUCCESS;
}

static ma_data_source_vtable g_ma_ffmpeg_ds_vtable = {
    ma_ffmpeg_ds_read,
    ma_ffmpeg_ds_seek,
    ma_ffmpeg_ds_get_data_format,
    ma_ffmpeg_ds_get_cursor,
    ma_ffmpeg_ds_get_length,
    nullptr, // set_looping
    0
};

namespace sautiflow {

StreamTelemetry get_stream_telemetry_from_decoder(ma_decoder* pDecoder) {
    if (pDecoder == nullptr || pDecoder->pBackend == nullptr) {
        return get_active_stream_telemetry();
    }
    auto* ds = reinterpret_cast<ma_ffmpeg_data_source*>(pDecoder->pBackend);
    if (ds && ds->base.vtable == &g_ma_ffmpeg_ds_vtable && ds->stream) {
        return ds->stream->get_telemetry();
    }
    return get_active_stream_telemetry();
}

} // namespace sautiflow

#if defined(_WIN32) || defined(_WIN64)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

static std::string wstring_to_utf8_path(const wchar_t* wstr) {
    if (!wstr || wstr[0] == L'\0') return {};
    int len = WideCharToMultiByte(CP_UTF8, 0, wstr, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string utf8(len - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wstr, -1, &utf8[0], len, nullptr, nullptr);
    return utf8;
}
#endif

static bool is_miniaudio_native_local_file(const char* path) {
    if (path == nullptr) return false;
    std::string s(path);
    auto dot = s.find_last_of('.');
    if (dot == std::string::npos) return false;
    std::string ext = s.substr(dot);
    for (auto &c : ext) c = (char)::tolower(c);
    return (ext == ".flac" || ext == ".mp3" || ext == ".wav" ||
            ext == ".ogg"  || ext == ".oga" || ext == ".m4a" ||
            ext == ".aac"  || ext == ".mp4");
}

static ma_result ma_decoding_backend_init_file__ffmpeg(void* pUserData, const char* pFilePath, const ma_decoding_backend_config* pConfig, const ma_allocation_callbacks* pAllocationCallbacks, ma_data_source** ppBackend) {
    (void)pUserData;
    (void)pConfig;
    (void)pAllocationCallbacks;

    if (pFilePath == nullptr || ppBackend == nullptr) {
        return MA_INVALID_ARGS;
    }

    bool isNetwork = sautiflow::FFmpegStreamSource::is_network_url(pFilePath);
    if (!isNetwork && is_miniaudio_native_local_file(pFilePath)) {
        // Return MA_NO_BACKEND so miniaudio uses its built-in dr_flac, dr_mp3, dr_wav, stb_vorbis decoders directly.
        return MA_NO_BACKEND;
    }

    ma_uint32 outChannels = 2;
    ma_uint32 outSampleRate = 48000;
    if (pUserData != nullptr) {
        const auto* initCfg = static_cast<const sautiflow::FFmpegDecoderInitConfig*>(pUserData);
        if (initCfg->targetChannels > 0) outChannels = (ma_uint32)initCfg->targetChannels;
        if (initCfg->targetSampleRate > 0) outSampleRate = (ma_uint32)initCfg->targetSampleRate;
    }
    int prebufferMs = isNetwork ? 1500 : 0;

    std::printf("[ffmpeg_backend] Requesting universal decoder for %s: %s\n",
                isNetwork ? "network URL" : "local file", pFilePath);
    std::fflush(stdout);

    auto* stream = new sautiflow::FFmpegStreamSource();
    if (!stream->open(pFilePath, outSampleRate, outChannels, prebufferMs)) {
        std::printf("[ffmpeg_backend] Universal decoder failed to open: %s\n", pFilePath);
        std::fflush(stdout);
        delete stream;
        return MA_ERROR;
    }

    auto* ds = static_cast<ma_ffmpeg_data_source*>(std::malloc(sizeof(ma_ffmpeg_data_source)));
    if (!ds) {
        stream->close();
        delete stream;
        return MA_OUT_OF_MEMORY;
    }

    ds->stream = stream;
    ds->format = ma_format_f32;
    ds->channels = outChannels;
    ds->sampleRate = outSampleRate;

    ma_data_source_config baseConfig = ma_data_source_config_init();
    baseConfig.vtable = &g_ma_ffmpeg_ds_vtable;
    ma_result res = ma_data_source_init(&baseConfig, &ds->base);
    if (res != MA_SUCCESS) {
        stream->close();
        delete stream;
        std::free(ds);
        return res;
    }

    *ppBackend = reinterpret_cast<ma_data_source*>(ds);
    return MA_SUCCESS;
}

static ma_result ma_decoding_backend_init_file_w__ffmpeg(void* pUserData, const wchar_t* pFilePathW, const ma_decoding_backend_config* pConfig, const ma_allocation_callbacks* pAllocationCallbacks, ma_data_source** ppBackend) {
#if defined(_WIN32) || defined(_WIN64)
    if (pFilePathW == nullptr || ppBackend == nullptr) {
        return MA_INVALID_ARGS;
    }
    std::string pathUtf8 = wstring_to_utf8_path(pFilePathW);
    if (pathUtf8.empty()) {
        return MA_INVALID_ARGS;
    }
    return ma_decoding_backend_init_file__ffmpeg(pUserData, pathUtf8.c_str(), pConfig, pAllocationCallbacks, ppBackend);
#else
    (void)pUserData;
    (void)pFilePathW;
    (void)pConfig;
    (void)pAllocationCallbacks;
    (void)ppBackend;
    return MA_NOT_IMPLEMENTED;
#endif
}

static void ma_decoding_backend_uninit__ffmpeg(void* pUserData, ma_data_source* pBackend, const ma_allocation_callbacks* pAllocationCallbacks) {
    (void)pUserData;
    (void)pAllocationCallbacks;

    auto* ds = reinterpret_cast<ma_ffmpeg_data_source*>(pBackend);
    if (!ds) return;

    ma_data_source_uninit(&ds->base);
    if (ds->stream) {
        ds->stream->close();
        delete ds->stream;
        ds->stream = nullptr;
    }
    std::free(ds);
}

extern "C" {
ma_decoding_backend_vtable g_ma_decoding_backend_vtable_ffmpeg = {
    nullptr, // onInit (stream callbacks)
    ma_decoding_backend_init_file__ffmpeg,
    ma_decoding_backend_init_file_w__ffmpeg, // onInitFileW
    nullptr, // onInitMemory
    ma_decoding_backend_uninit__ffmpeg
};
}
#else

namespace sautiflow {

static std::atomic<FFmpegStreamSource*> g_activeStreamSource{nullptr};

StreamTelemetry get_active_stream_telemetry() {
    return StreamTelemetry();
}

StreamTelemetry get_stream_telemetry_from_decoder(ma_decoder* pDecoder) {
    (void)pDecoder;
    return StreamTelemetry();
}

bool FFmpegStreamSource::is_network_url(const char* path) {
    if (path == nullptr) return false;
    std::string s(path);
    auto to_lower = [](std::string in) {
        for (auto &c : in) c = (char)::tolower(c);
        return in;
    };
    std::string lower = to_lower(s);
    return (lower.rfind("http://", 0) == 0 ||
            lower.rfind("https://", 0) == 0 ||
            lower.rfind("rtmp://", 0) == 0 ||
            lower.rfind("rtsp://", 0) == 0 ||
            lower.rfind("mms://", 0) == 0 ||
            lower.find(".m3u8") != std::string::npos ||
            lower.find(".mpd") != std::string::npos);
}

FFmpegStreamSource::FFmpegStreamSource() {}
FFmpegStreamSource::~FFmpegStreamSource() {}

bool FFmpegStreamSource::open(const std::string& url, int targetSampleRate, int targetChannels, int prebufferMs) {
    (void)url; (void)targetSampleRate; (void)targetChannels; (void)prebufferMs;
    set_error(StreamErrorCode::OpenFailed, "FFmpeg streaming not compiled in for this build target");
    return false;
}

void FFmpegStreamSource::close() {}
size_t FFmpegStreamSource::read_pcm(float* pOut, size_t frameCount) { (void)pOut; (void)frameCount; return 0; }
bool FFmpegStreamSource::seek(int64_t timestampMs) { (void)timestampMs; return false; }
void FFmpegStreamSource::pause() {}
void FFmpegStreamSource::resume() {}
StreamTelemetry FFmpegStreamSource::get_telemetry() const { return m_telemetry; }
void FFmpegStreamSource::set_telemetry_callback(StreamTelemetryCallback cb) { (void)cb; }
void FFmpegStreamSource::demux_and_decode_thread_func() {}
void FFmpegStreamSource::update_icy_metadata() {}
void FFmpegStreamSource::notify_telemetry() {}
void FFmpegStreamSource::set_error(StreamErrorCode code, const std::string& msg) {
    m_telemetry.state = StreamState::Error;
    m_telemetry.errorCode = code;
    std::strncpy(m_telemetry.errorMessage, msg.c_str(), sizeof(m_telemetry.errorMessage) - 1);
}

} // namespace sautiflow

static ma_result ma_decoding_backend_init_file__ffmpeg_stub(void* pUserData, const char* pFilePath, const ma_decoding_backend_config* pConfig, const ma_allocation_callbacks* pAllocationCallbacks, ma_data_source** ppBackend) {
    (void)pUserData; (void)pFilePath; (void)pConfig; (void)pAllocationCallbacks; (void)ppBackend;
    return MA_NOT_IMPLEMENTED;
}

static ma_result ma_decoding_backend_init_file_w__ffmpeg_stub(void* pUserData, const wchar_t* pFilePathW, const ma_decoding_backend_config* pConfig, const ma_allocation_callbacks* pAllocationCallbacks, ma_data_source** ppBackend) {
    (void)pUserData; (void)pFilePathW; (void)pConfig; (void)pAllocationCallbacks; (void)ppBackend;
    return MA_NOT_IMPLEMENTED;
}

static void ma_decoding_backend_uninit__ffmpeg_stub(void* pUserData, ma_data_source* pBackend, const ma_allocation_callbacks* pAllocationCallbacks) {
    (void)pUserData; (void)pBackend; (void)pAllocationCallbacks;
}

extern "C" {
ma_decoding_backend_vtable g_ma_decoding_backend_vtable_ffmpeg = {
    nullptr,
    ma_decoding_backend_init_file__ffmpeg_stub,
    ma_decoding_backend_init_file_w__ffmpeg_stub,
    nullptr,
    ma_decoding_backend_uninit__ffmpeg_stub
};
}
#endif
