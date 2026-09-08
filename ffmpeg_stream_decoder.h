#pragma once

#include "miniaudio.h"
#include <string>
#include <vector>
#include <atomic>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <functional>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations of FFmpeg structures
struct AVFormatContext;
struct AVCodecContext;
struct SwrContext;
struct AVPacket;
struct AVFrame;

extern ma_decoding_backend_vtable g_ma_decoding_backend_vtable_ffmpeg;

#ifdef __cplusplus
}
#endif

namespace sautiflow {

enum class StreamState {
    Idle = 0,
    Connecting = 1,
    Buffering = 2,
    Ready = 3,
    Playing = 4,
    Ended = 5,
    Error = -1
};

enum class StreamErrorCode {
    None = 0,
    OpenFailed = 1,
    StreamInfoNotFound = 2,
    CodecNotFound = 3,
    CodecOpenFailed = 4,
    HttpNotFound = 404,
    HttpForbidden = 403,
    NetworkTimeout = 1001,
    ConnectionAborted = 1002,
    DecodeError = 1003
};

struct StreamTelemetry {
    StreamState state{StreamState::Idle};
    StreamErrorCode errorCode{StreamErrorCode::None};
    char errorMessage[256]{0};
    double bufferedDurationSec{0.0};
    double totalDurationSec{0.0};
    double bufferPercent{0.0};
    int64_t bitrate{0};
    int sampleRate{0};
    int channels{0};
    char codecName[32]{0};
    char icyTitle[256]{0};
    char icyArtist[256]{0};
    bool isLiveStream{false};
    bool isSeekable{false};
};

using StreamTelemetryCallback = std::function<void(const StreamTelemetry&)>;

struct FFmpegDecoderInitConfig {
    int targetSampleRate{48000};
    int targetChannels{2};
};

class FFmpegStreamSource {
public:
    FFmpegStreamSource();
    ~FFmpegStreamSource();

    // Disable copy
    FFmpegStreamSource(const FFmpegStreamSource&) = delete;
    FFmpegStreamSource& operator=(const FFmpegStreamSource&) = delete;

    bool open(const std::string& url, int targetSampleRate = 48000, int targetChannels = 2, int prebufferMs = 1500);
    void close();

    // Pull decoded PCM frames (float32 interleaved). Returns frames read.
    size_t read_pcm(float* pOut, size_t frameCount);

    bool seek(int64_t timestampMs);
    void pause();
    void resume();

    StreamTelemetry get_telemetry() const;
    void set_telemetry_callback(StreamTelemetryCallback cb);

    bool is_open() const { return m_isOpen.load(); }
    bool is_buffering() const { return m_isBuffering.load(); }
    bool is_ended() const { return m_isEnded.load(); }
    bool is_stop_requested() const { return m_stopRequested.load(); }
    int get_target_sample_rate() const { return m_targetSampleRate; }
    int get_target_channels() const { return m_targetChannels; }

    static bool is_network_url(const char* path);

private:
    void demux_and_decode_thread_func();
    void update_icy_metadata();
    void notify_telemetry();
    void set_error(StreamErrorCode code, const std::string& msg);

    std::string m_url;
    int m_targetSampleRate{48000};
    int m_targetChannels{2};
    size_t m_prebufferBytes{0};
    size_t m_rebufferBytes{0};

    std::atomic<bool> m_isOpen{false};
    std::atomic<bool> m_stopRequested{false};
    std::atomic<bool> m_isPaused{false};
    std::atomic<bool> m_isBuffering{true};
    std::atomic<bool> m_isEnded{false};
    std::atomic<bool> m_seekRequested{false};
    std::atomic<int64_t> m_seekTargetMs{0};

    std::thread m_workerThread;
    mutable std::mutex m_stateMutex;
    std::condition_variable m_cv;

    // PCM Ring Buffer
    std::vector<float> m_pcmRingBuffer;
    size_t m_rbCapacityFrames{0};
    std::atomic<size_t> m_rbReadPos{0};
    std::atomic<size_t> m_rbWritePos{0};
    std::atomic<size_t> m_rbAvailableFrames{0};

    // FFmpeg state pointers
    AVFormatContext* m_fmtCtx{nullptr};
    AVCodecContext* m_codecCtx{nullptr};
    SwrContext* m_swrCtx{nullptr};
    int m_audioStreamIndex{-1};

    StreamTelemetry m_telemetry;
    StreamTelemetryCallback m_telemetryCb;
};

// Global telemetry accessor for active engine streams
StreamTelemetry get_active_stream_telemetry();

// Decoder-scoped telemetry accessor (per-decoder, thread-safe)
StreamTelemetry get_stream_telemetry_from_decoder(ma_decoder* pDecoder);

} // namespace sautiflow

