#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32) || defined(_WIN64)
#define AE_API __declspec(dllexport)
#else
#define AE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C"
{
#endif

    typedef struct AudioEngineHandle AudioEngineHandle;

    typedef struct PlayerStatus
    {
        double position_seconds;
        double duration_seconds;
        int is_playing;
        int current_index;
        int playlist_count;
        int shuffle_enabled;
        int loop_mode; /* 0=off, 1=all, 2=one */
    } PlayerStatus;

    typedef enum AELoopMode
    {
        AE_LOOP_OFF = 0,
        AE_LOOP_ALL = 1,
        AE_LOOP_ONE = 2
    } AELoopMode;

    typedef enum AEAudioFormat
    {
        AE_FORMAT_F32 = 0,
        AE_FORMAT_S16 = 1,
        AE_FORMAT_U8 = 2,
        AE_FORMAT_S24 = 3,
        AE_FORMAT_S32 = 4
    } AEAudioFormat;

    typedef enum AEResampleAlgorithm
    {
        AE_RESAMPLE_ALGORITHM_MINIAUDIO_LINEAR = 0,
        AE_RESAMPLE_ALGORITHM_SRC_SINC_BEST_QUALITY = 1,
        AE_RESAMPLE_ALGORITHM_SRC_SINC_MEDIUM_QUALITY = 2,
        AE_RESAMPLE_ALGORITHM_SRC_SINC_FASTEST = 3,
        AE_RESAMPLE_ALGORITHM_SRC_ZERO_ORDER_HOLD = 4,
        AE_RESAMPLE_ALGORITHM_SRC_LINEAR = 5,
        AE_RESAMPLE_ALGORITHM_CUSTOM = 6,
        AE_RESAMPLE_ALGORITHM_SOXR_VHQ_LINEAR_PHASE = 7,
        AE_RESAMPLE_ALGORITHM_SOXR_VHQ_MINIMUM_PHASE = 8,
        AE_RESAMPLE_ALGORITHM_SOXR_HQ = 9,
        AE_RESAMPLE_ALGORITHM_SOXR_FAST = 10,
        AE_RESAMPLE_ALGORITHM_R8BRAIN_24_LINEAR_PHASE = 11,
        AE_RESAMPLE_ALGORITHM_R8BRAIN_24_MINIMUM_PHASE = 12
    } AEResampleAlgorithm;

    typedef enum AEDitherMode
    {
        AE_DITHER_MODE_NONE = 0,
        AE_DITHER_MODE_RECTANGLE = 1,
        AE_DITHER_MODE_TRIANGLE = 2,
        AE_DITHER_MODE_LIPSHITZ = 3,
        AE_DITHER_MODE_F_WEIGHTED = 4,
        AE_DITHER_MODE_MOD_E_WEIGHTED = 5,
        AE_DITHER_MODE_SHIBATA = 6,
        AE_DITHER_MODE_LOW_SHIBATA = 7,
        AE_DITHER_MODE_HIGH_SHIBATA = 8
    } AEDitherMode;

    typedef enum AEEqBandType
    {
        AE_EQ_BAND_PEAK = 0,
        AE_EQ_BAND_BANDPASS = 1,
        AE_EQ_BAND_NOTCH = 2,
        AE_EQ_BAND_LOWSHELF = 3,
        AE_EQ_BAND_HIGHSHELF = 4,
        AE_EQ_BAND_LOWPASS = 5,
        AE_EQ_BAND_HIGHPASS = 6,
        AE_EQ_BAND_BELL = 7,
        AE_EQ_BAND_TILT = 8
    } AEEqBandType;

    typedef struct AEPipelineState
    {
        // Input true format
        int input_format;
        int input_sample_rate;
        int input_channels;

        // DSP/Processing requested format
        int processing_format;
        int processing_sample_rate;
        int processing_channels;

        // Real Output Target Config (what the OS hardware negotiated)
        int output_format;
        int output_sample_rate;
        int output_channels;

        // Effects Enabled Flags
        int eq_enabled;
        int reverb_enabled;
        int limiter_enabled;
        int stereo_widen_enabled;
        int stereo_enhancement_enabled;
        int spatialization_enabled;
        int delay_enabled;

        // Basic settings
        float gain;
        float pan;
        float pitch;
        float rate;
        int pitch_correction_enabled;
    } AEPipelineState;

    AE_API AudioEngineHandle *ae_create_engine(int sample_rate, int channels);
    AE_API void ae_destroy_engine(AudioEngineHandle *engine);

    AE_API bool ae_set_playlist(AudioEngineHandle *engine, const char **paths, int count);
    AE_API bool ae_add_to_playlist(AudioEngineHandle *engine, const char *path);
    AE_API bool ae_insert_to_playlist(AudioEngineHandle *engine, int index, const char *path);
    AE_API bool ae_remove_from_playlist(AudioEngineHandle *engine, int index);
    AE_API bool ae_move_playlist_item(AudioEngineHandle *engine, int from_index, int to_index);
    AE_API void ae_clear_playlist(AudioEngineHandle *engine);

    AE_API bool ae_play(AudioEngineHandle *engine);
    AE_API bool ae_pause(AudioEngineHandle *engine);
    AE_API bool ae_stop(AudioEngineHandle *engine);
    AE_API bool ae_seek(AudioEngineHandle *engine, double percent_0_to_1);
    AE_API bool ae_next(AudioEngineHandle *engine);
    AE_API bool ae_prev(AudioEngineHandle *engine);
    AE_API bool ae_jump_to(AudioEngineHandle *engine, int index);
    AE_API bool ae_jump_to_with_position(AudioEngineHandle *engine, int index, double position_seconds);
    AE_API int ae_is_network_streaming_supported(void);
    AE_API int ae_get_stream_telemetry(AudioEngineHandle *engine,
                                       int *out_state,
                                       int *out_error_code,
                                       double *out_buffered_duration_sec,
                                       double *out_total_duration_sec,
                                       double *out_buffer_percent,
                                       int64_t *out_bitrate,
                                       char *out_codec_name, int codec_name_len,
                                       char *out_icy_title, int icy_title_len,
                                       char *out_icy_artist, int icy_artist_len);
    AE_API int ae_is_stream_live(AudioEngineHandle *engine);

    AE_API void ae_set_loop_mode(AudioEngineHandle *engine, int loop_mode);
    AE_API void ae_set_shuffle_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_reshuffle(AudioEngineHandle *engine);

    // A-B Repeat (Precise segment looping)
    AE_API void ae_set_ab_repeat(AudioEngineHandle *engine, int enabled, double start_seconds, double end_seconds);
    AE_API void ae_get_ab_repeat(AudioEngineHandle *engine, int *out_enabled, double *out_start_seconds, double *out_end_seconds);

    // Track transition controls.
    // Note: current implementation performs a short transition fade-in on track switches.
    AE_API void ae_set_crossfade_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int ae_get_crossfade_enabled(AudioEngineHandle *engine);
    // Clamped to [0, 10000]. 0 disables transition fade.
    AE_API void ae_set_crossfade_duration_ms(AudioEngineHandle *engine, int duration_ms);
    AE_API int ae_get_crossfade_duration_ms(AudioEngineHandle *engine);

    // Loudness-Aware Crossfade controls
    AE_API void ae_set_loudness_crossfade_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int ae_get_loudness_crossfade_enabled(AudioEngineHandle *engine);
    AE_API void ae_set_next_replay_gain(AudioEngineHandle *engine, float gain_db);

    AE_API PlayerStatus ae_get_status(AudioEngineHandle *engine);
    AE_API AEPipelineState ae_get_pipeline_state(AudioEngineHandle *engine);
    AE_API const char *ae_get_last_error(AudioEngineHandle *engine);
    AE_API void ae_clear_last_error(AudioEngineHandle *engine);

    AE_API void ae_set_reverb_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_reverb_params(AudioEngineHandle *engine, float mix, float feedback, float delay_ms);
    AE_API void ae_set_reverb_params_ex(AudioEngineHandle *engine, float mix, float room_size, float damping, float pre_delay_ms, float width);
    AE_API void ae_set_reverb_gains(AudioEngineHandle *engine, float wet, float dry);
    AE_API void ae_get_reverb_gains(AudioEngineHandle *engine, float *out_wet, float *out_dry);
    AE_API void ae_get_reverb_params_ex(AudioEngineHandle *engine, int *out_enabled, float *out_mix, float *out_room_size, float *out_damping, float *out_pre_delay_ms, float *out_width);
    AE_API void ae_set_eq_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_eq_gains(AudioEngineHandle *engine, float low_gain, float mid_gain, float high_gain);
    AE_API void ae_set_gain(AudioEngineHandle *engine, float gain);
    AE_API void ae_set_replay_gain(AudioEngineHandle *engine, float gain_db);
    AE_API void ae_set_pan(AudioEngineHandle *engine, float pan_minus1_to_plus1);
    AE_API void ae_set_rate(AudioEngineHandle *engine, float rate);
    AE_API float ae_get_rate(AudioEngineHandle *engine);
    AE_API void ae_set_pitch(AudioEngineHandle *engine, float pitch);
    AE_API float ae_get_pitch(AudioEngineHandle *engine);
    AE_API void ae_set_pitch_correction(AudioEngineHandle *engine, int enabled);
    AE_API int ae_get_pitch_correction(AudioEngineHandle *engine);
    AE_API void ae_set_lowpass_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_lowpass_cutoff(AudioEngineHandle *engine, float hz);
    AE_API void ae_set_highpass_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_highpass_cutoff(AudioEngineHandle *engine, float hz);
    AE_API void ae_set_delay_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_delay_params(AudioEngineHandle *engine, float mix, float feedback, float delay_ms);
    AE_API void ae_set_stereo_widen(AudioEngineHandle *engine, int enabled, float width, float delay_ms);
    AE_API void ae_set_stereo_enhancement_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int ae_get_stereo_enhancement_enabled(AudioEngineHandle *engine);
    AE_API void ae_set_stereo_enhancement_mix(AudioEngineHandle *engine, float mix);
    typedef enum AECrossfeedAlgorithm
    {
        AE_CROSSFEED_OFF = 0,
        AE_CROSSFEED_SIMPLE = 1,
        AE_CROSSFEED_BS2B = 2,
        AE_CROSSFEED_MEIER = 3,
        AE_CROSSFEED_NATURAL = 4,
        AE_CROSSFEED_RACE = 5
    } AECrossfeedAlgorithm;

    AE_API void ae_set_crossfeed_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_crossfeed_preset(AudioEngineHandle *engine, int preset);
    AE_API void ae_set_crossfeed_algorithm(AudioEngineHandle *engine, int algorithm);
    AE_API void ae_set_crossfeed_params(AudioEngineHandle *engine, float mix, float delay_ms, float cutoff_hz, int output_compensation);
    AE_API void ae_get_crossfeed_params(AudioEngineHandle *engine, int *out_algorithm, float *out_mix, float *out_delay_ms, float *out_cutoff_hz, int *out_output_compensation);
    AE_API void ae_set_race_params(AudioEngineHandle *engine, float delay_ms, float alpha, float lpf_hz);
    AE_API void ae_set_dynamic_bass_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_dynamic_bass_params(AudioEngineHandle *engine, int preset, float gain);

    // Crystalizer (audiophile transient reconstruction + air enhancement)
    // intensity: [0.0, 1.0] — reconstruction strength (default 0.5)
    // high_shelf_enabled: 1 = enable gentle 8kHz air shelf, 0 = off
    // high_shelf_gain_db: [0.0, 6.0] — shelf boost amount in dB (default 2.0)
    AE_API void ae_set_crystalizer_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_crystalizer_params(AudioEngineHandle *engine, float intensity, int high_shelf_enabled, float high_shelf_gain_db);
    AE_API float ae_get_crystalizer_intensity(AudioEngineHandle *engine);
    AE_API void ae_set_bandpass_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_bandpass_params(AudioEngineHandle *engine, float cutoff_hz, float q);
    AE_API void ae_set_peak_eq_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_peak_eq_params(AudioEngineHandle *engine, float gain_db, float q, float frequency_hz);
    AE_API void ae_set_notch_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_notch_params(AudioEngineHandle *engine, float q, float frequency_hz);
    AE_API void ae_set_lowshelf_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_lowshelf_params(AudioEngineHandle *engine, float gain_db, float slope, float frequency_hz);
    AE_API void ae_set_highshelf_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_highshelf_params(AudioEngineHandle *engine, float gain_db, float slope, float frequency_hz);

    // Spatialization (3D Audio)
    AE_API void ae_set_spatialization_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_position(AudioEngineHandle *engine, float x, float y, float z);
    AE_API void ae_set_direction(AudioEngineHandle *engine, float x, float y, float z);
    AE_API void ae_set_velocity(AudioEngineHandle *engine, float x, float y, float z);
    AE_API void ae_set_sound_cone(AudioEngineHandle *engine, float inner_angle_rad, float outer_angle_rad, float outer_gain);
    // Attenuation models: 0=None, 1=Inverse, 2=Linear, 3=Exponential
    AE_API void ae_set_attenuation_model(AudioEngineHandle *engine, int model);
    AE_API void ae_set_rolloff(AudioEngineHandle *engine, float rolloff);
    AE_API void ae_set_min_gain(AudioEngineHandle *engine, float min_gain);
    AE_API void ae_set_max_gain(AudioEngineHandle *engine, float max_gain);
    AE_API void ae_set_min_distance(AudioEngineHandle *engine, float min_distance);
    AE_API void ae_set_max_distance(AudioEngineHandle *engine, float max_distance);
    AE_API void ae_set_doppler_factor(AudioEngineHandle *engine, float doppler_factor);

    // Listener 3D Spatialization Controls
    AE_API void ae_set_listener_position(AudioEngineHandle *engine, float x, float y, float z);
    AE_API void ae_set_listener_direction(AudioEngineHandle *engine, float x, float y, float z);
    AE_API void ae_set_listener_velocity(AudioEngineHandle *engine, float x, float y, float z);
    AE_API void ae_set_listener_world_up(AudioEngineHandle *engine, float x, float y, float z);
    AE_API void ae_set_listener_cone(AudioEngineHandle *engine, float inner_angle_rad, float outer_angle_rad, float outer_gain);

    // Fading & Scheduling
    // Wait fade: sets a target volume over ms time
    AE_API void ae_set_fade_in_milliseconds(AudioEngineHandle *engine, float volume_beg, float volume_end, int time_ms);
    // Scheduling start/stop using absolute engine time (pcm frames). -1 means no schedule.
    AE_API void ae_set_start_time_in_pcm_frames(AudioEngineHandle *engine, uint64_t absolute_time);
    AE_API void ae_set_stop_time_in_pcm_frames(AudioEngineHandle *engine, uint64_t absolute_time);
    AE_API uint64_t ae_get_engine_time_in_pcm_frames(AudioEngineHandle *engine);

    // End Callback processing
    typedef void (*AE_EndCallback)(void *pUserData, AudioEngineHandle *engine);
    AE_API void ae_set_end_callback(AudioEngineHandle *engine, AE_EndCallback callback, void *pUserData);

    // Advanced Audio Controls
    AE_API void ae_set_exclusive_mode(AudioEngineHandle *engine, int enabled);
    AE_API int ae_get_exclusive_mode(AudioEngineHandle *engine);

    AE_API void ae_set_output_format(AudioEngineHandle *engine, int format);
    AE_API int ae_get_output_format(AudioEngineHandle *engine);

    AE_API void ae_set_output_sample_rate(AudioEngineHandle *engine, int sample_rate);
    AE_API int ae_get_output_sample_rate(AudioEngineHandle *engine);

    AE_API void ae_set_output_channels(AudioEngineHandle *engine, int channels);
    AE_API int ae_get_output_channels(AudioEngineHandle *engine);

    // User-configurable Output Buffer (0 frames / 0 count = auto-selected by engine/backend)
    // Valid ranges: period_frames in [16, 16384], period_count in [2, 16]
    AE_API void ae_set_output_buffer(AudioEngineHandle *engine, int period_frames, int period_count);
    AE_API void ae_get_output_buffer(AudioEngineHandle *engine, int *out_period_frames, int *out_period_count);

    AE_API void ae_set_engine_resample_algorithm(AudioEngineHandle *engine, int algorithm);
    AE_API int ae_get_engine_resample_algorithm(AudioEngineHandle *engine);

    AE_API void ae_set_engine_dither_mode(AudioEngineHandle *engine, int dither_mode);
    AE_API int ae_get_engine_dither_mode(AudioEngineHandle *engine);

    // 64-Bit Float DSP Processing Mode (-320dB Headroom)
    AE_API void ae_set_64bit_processing_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int ae_get_64bit_processing_enabled(AudioEngineHandle *engine);

    // Auto Sample-Rate Match Hardware Rate & Bit-Depth Matching
    AE_API void ae_set_auto_sample_rate_match_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int ae_get_auto_sample_rate_match_enabled(AudioEngineHandle *engine);

    // Backward-compatibility aliases for Auto Sample-Rate Match
    AE_API void ae_set_auto_bit_perfect_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int ae_get_auto_bit_perfect_enabled(AudioEngineHandle *engine);
    AE_API int ae_consume_pending_rate_change(AudioEngineHandle *engine);

    // Phase Inversion (Polarity Flip)
    AE_API void ae_set_phase_inversion(AudioEngineHandle *engine, int invert_left, int invert_right);
    AE_API void ae_get_phase_inversion(AudioEngineHandle *engine, int *out_invert_left, int *out_invert_right);

    // L/R Channel Swap (mirrors left and right output channels)
    AE_API void ae_set_lr_swap(AudioEngineHandle *engine, int enabled);
    AE_API int  ae_get_lr_swap(AudioEngineHandle *engine);

    // Per-Channel Gain (independent L and R trim)
    // gain_left, gain_right: linear multipliers [0.0, 4.0] (1.0 = unity, ~+12 dB max)
    AE_API void ae_set_channel_gains(AudioEngineHandle *engine, float gain_left, float gain_right);
    AE_API void ae_get_channel_gains(AudioEngineHandle *engine, float *out_gain_left, float *out_gain_right);

    // Audio Limiter & Clipping Detection
    AE_API void ae_set_limiter_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_limiter_params(AudioEngineHandle *engine, float threshold, float attack_ms, float release_ms);

    // Dynamic Range Compressor
    // detector: 0 = peak, 1 = RMS. stereo_link: 1 = linked, 0 = dual mono.
    // auto_makeup: derive makeup from threshold/ratio (overrides makeup_gain_db).
    // mix: 0 = dry, 1 = fully compressed.
    AE_API void ae_set_compressor_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_compressor_params(AudioEngineHandle *engine, float threshold_db, float ratio, float knee_db, float attack_ms, float release_ms, float makeup_gain_db, int detector, int stereo_link, int auto_makeup, float mix);
    AE_API float ae_get_compressor_gain_reduction_db(AudioEngineHandle *engine);
    AE_API void ae_set_clipping_detection_enabled(AudioEngineHandle *engine, int enabled);
    AE_API uint64_t ae_get_clipped_samples_count(AudioEngineHandle *engine);
    AE_API void ae_reset_clipped_samples_count(AudioEngineHandle *engine);

    // ==========================================
    // Release 1 Quality Foundation Subsystems
    // ==========================================

    typedef struct AELoudnessMetrics
    {
        float momentary_lufs;     // ~400 ms sliding window
        float short_term_lufs;    // ~3000 ms sliding window
        float integrated_lufs;    // Accumulated gated programme loudness
        float loudness_range_lra; // Loudness range (LU)
    } AELoudnessMetrics;

    typedef struct AETruePeakMetrics
    {
        float left_dbtp;   // Left channel peak in dBTP
        float right_dbtp;  // Right channel peak in dBTP
        float max_dbtp;    // Max peak across channels in dBTP
    } AETruePeakMetrics;

    typedef struct AEQualityTelemetry
    {
        float sample_peak_db;
        float true_peak_dbtp;
        float momentary_lufs;
        float short_term_lufs;
        float integrated_lufs;
        float loudness_range_lra;
        float crest_factor_db;
        float limiter_gain_reduction_db;
        double resampler_latency_ms;
        double total_engine_latency_ms;
        uint64_t clipped_samples_count;
        uint64_t underrun_count;
    } AEQualityTelemetry;

    typedef struct AEResamplingPolicyInfo
    {
        int is_bypassed;              // 1 if 1:1 input/output rate match (no SRC)
        int mode;                     // 0=Bypass, 1=AutoDAC, 2=IntegerPolyphase, 3=SincHighQuality, 4=SoxrVHQ
        int input_sample_rate;
        int engine_sample_rate;
        int device_sample_rate;
        double resampler_latency_ms;
        double filter_passband_ratio; // e.g. 0.45 * fs
        int is_linear_phase;
    } AEResamplingPolicyInfo;

    // Loudness Meter & Normalizer (ITU-R BS.1770-4 / EBU R128)
    AE_API void ae_set_loudness_meter_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int  ae_get_loudness_meter_enabled(AudioEngineHandle *engine);
    AE_API AELoudnessMetrics ae_get_loudness_metrics(AudioEngineHandle *engine);
    AE_API void ae_reset_loudness_meter(AudioEngineHandle *engine);

    AE_API void ae_set_loudness_normalizer_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int  ae_get_loudness_normalizer_enabled(AudioEngineHandle *engine);
    AE_API void ae_set_loudness_normalizer_target(AudioEngineHandle *engine, float target_lufs);
    AE_API float ae_get_loudness_normalizer_target(AudioEngineHandle *engine);
    // Currently applied normalizer gain in dB (0 when disabled/bypassed).
    AE_API float ae_get_loudness_normalizer_gain_db(AudioEngineHandle *engine);

    // True-Peak Meter & Look-Ahead True-Peak Limiter
    AE_API void ae_set_true_peak_meter_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int  ae_get_true_peak_meter_enabled(AudioEngineHandle *engine);
    AE_API AETruePeakMetrics ae_get_true_peak(AudioEngineHandle *engine);

    AE_API void ae_set_lookahead_limiter_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int  ae_get_lookahead_limiter_enabled(AudioEngineHandle *engine);
    AE_API void ae_set_lookahead_limiter_params(AudioEngineHandle *engine, float ceiling_dbtp, float attack_ms, float release_ms);
    AE_API void ae_get_lookahead_limiter_params(AudioEngineHandle *engine, float *out_ceiling_dbtp, float *out_attack_ms, float *out_release_ms);
    AE_API float ae_get_lookahead_limiter_gain_reduction_db(AudioEngineHandle *engine);

    // Click-Free Parameter Automation
    AE_API void ae_set_parameter_smoothing_ms(AudioEngineHandle *engine, float smoothing_ms);
    AE_API float ae_get_parameter_smoothing_ms(AudioEngineHandle *engine);

    // Resampling Policy & Unified Quality Telemetry Snapshot
    AE_API AEResamplingPolicyInfo ae_get_resampling_policy_info(AudioEngineHandle *engine);
    AE_API AEQualityTelemetry ae_get_quality_telemetry(AudioEngineHandle *engine);

    // Latency Compensation (Plugin Delay Compensation - PDC)
    AE_API double ae_get_engine_latency_samples(AudioEngineHandle *engine);
    AE_API double ae_get_engine_latency_ms(AudioEngineHandle *engine);

    // Custom Real-Time Filter Parameters
    AE_API void ae_set_custom_lpf1_params(AudioEngineHandle *engine, int enabled, double cutoff_hz);
    AE_API void ae_set_custom_hpf1_params(AudioEngineHandle *engine, int enabled, double cutoff_hz);
    AE_API void ae_set_custom_biquad_params(AudioEngineHandle *engine, int enabled, double b0, double b1, double b2, double a0, double a1, double a2);

    // Push Stream API (Dart-driven streaming)
    AE_API void ae_init_push_stream(AudioEngineHandle *engine);
    // Use unsigned char instead of uint8_t as it is more standard and avoids <cstdint> vs <stdint.h> issues
    AE_API void ae_push_stream_chunk(AudioEngineHandle *engine, const unsigned char *data, size_t size);
    AE_API void ae_end_push_stream(AudioEngineHandle *engine); // Signal EOF or Abort
    AE_API int ae_get_push_stream_buffered_bytes(AudioEngineHandle *engine);

    // Multiband Equalizer
    // band_count: number of EQ bands
    // frequencies: array of center frequencies for each band (Hz)
    // q_factors: array of Q factors for each band (default 1.0 if null)
    AE_API void ae_init_multiband_eq(AudioEngineHandle *engine, int band_count, float *frequencies, float *q_factors);
    AE_API void ae_set_multiband_eq_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_multiband_eq_gain(AudioEngineHandle *engine, int band_index, float gain_db);
    AE_API float ae_get_multiband_eq_gain(AudioEngineHandle *engine, int band_index);

    // Unified multiband FX chain (mixed filter types).
    // band_count: number of bands in the chain.
    // types: array of AEEqBandType values (required).
    // frequencies: array of per-band center/cutoff frequencies (required).
    // q_factors: optional array; default 1.0 when null.
    // gains_db: optional array; default 0.0 when null.
    // slopes: optional array; default 1.0 when null.
    // enabled_flags: optional per-band enabled flags; default true when null.
    AE_API void ae_set_multiband_fx_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_set_multiband_fx_bands(
        AudioEngineHandle *engine,
        int band_count,
        const int *types,
        const float *frequencies,
        const float *q_factors,
        const float *gains_db,
        const float *slopes,
        const int *enabled_flags);
    AE_API void ae_clear_multiband_fx(AudioEngineHandle *engine);

    // Realtime analyzer frames (post-FX, mono mixdown).
    // frame_size: number of mono samples per analyzer snapshot.
    typedef enum AE_FFT_WINDOW_TYPE
    {
        AE_FFT_WINDOW_HANN = 0,
        AE_FFT_WINDOW_HAMMING = 1,
        AE_FFT_WINDOW_BLACKMAN_HARRIS = 2,
        AE_FFT_WINDOW_FLAT_TOP = 3
    } AE_FFT_WINDOW_TYPE;

    AE_API void ae_set_analyzer_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_configure_analyzer(AudioEngineHandle *engine, int frame_size);
    AE_API int ae_get_analyzer_frame_size(AudioEngineHandle *engine);
    AE_API void ae_configure_analyzer_window(AudioEngineHandle *engine, int window_type);
    AE_API int ae_get_analyzer_window_type(AudioEngineHandle *engine);
    AE_API void ae_generate_fft_window(int window_type, float *out_window, int size);
    AE_API void ae_apply_fft_window(const float *in_samples, float *out_samples, int size, int window_type);
    // Copies latest analyzer snapshot into out_samples (up to max_samples).
    // Returns number of samples copied.
    AE_API int ae_poll_analyzer_frame(AudioEngineHandle *engine, float *out_samples, int max_samples);
    AE_API uint64_t ae_get_analyzer_dropped_frames(AudioEngineHandle *engine);

    // ==========================================
    // Standalone Filters & Resampler (miniaudio direct bindings)
    // ==========================================
    typedef struct AELpf1 AELpf1;
    typedef struct AELpf2 AELpf2;
    typedef struct AELpf AELpf;

    typedef struct AEHpf1 AEHpf1;
    typedef struct AEHpf2 AEHpf2;
    typedef struct AEHpf AEHpf;

    typedef struct AEBiquad AEBiquad;
    typedef struct AEBpf2 AEBpf2;
    typedef struct AEBpf AEBpf;
    typedef struct AENotch2 AENotch2;
    typedef struct AEPeak2 AEPeak2;
    typedef struct AELoshelf2 AELoshelf2;
    typedef struct AEHishelf2 AEHishelf2;
    typedef struct AEResampler AEResampler;

    // LPF1
    AE_API AELpf1 *ae_lpf1_create(int format, int channels, int sample_rate, double cutoff_hz);
    AE_API void ae_lpf1_destroy(AELpf1 *filter);
    AE_API void ae_lpf1_reinit(AELpf1 *filter, int format, int channels, int sample_rate, double cutoff_hz);
    AE_API int ae_lpf1_process(AELpf1 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // LPF2
    AE_API AELpf2 *ae_lpf2_create(int format, int channels, int sample_rate, double cutoff_hz, double q);
    AE_API void ae_lpf2_destroy(AELpf2 *filter);
    AE_API void ae_lpf2_reinit(AELpf2 *filter, int format, int channels, int sample_rate, double cutoff_hz, double q);
    AE_API int ae_lpf2_process(AELpf2 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // LPF (High order Butterworth)
    AE_API AELpf *ae_lpf_create(int format, int channels, int sample_rate, double cutoff_hz, int order);
    AE_API void ae_lpf_destroy(AELpf *filter);
    AE_API void ae_lpf_reinit(AELpf *filter, int format, int channels, int sample_rate, double cutoff_hz, int order);
    AE_API int ae_lpf_process(AELpf *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // HPF1
    AE_API AEHpf1 *ae_hpf1_create(int format, int channels, int sample_rate, double cutoff_hz);
    AE_API void ae_hpf1_destroy(AEHpf1 *filter);
    AE_API void ae_hpf1_reinit(AEHpf1 *filter, int format, int channels, int sample_rate, double cutoff_hz);
    AE_API int ae_hpf1_process(AEHpf1 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // HPF2
    AE_API AEHpf2 *ae_hpf2_create(int format, int channels, int sample_rate, double cutoff_hz, double q);
    AE_API void ae_hpf2_destroy(AEHpf2 *filter);
    AE_API void ae_hpf2_reinit(AEHpf2 *filter, int format, int channels, int sample_rate, double cutoff_hz, double q);
    AE_API int ae_hpf2_process(AEHpf2 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // HPF (High order Butterworth)
    AE_API AEHpf *ae_hpf_create(int format, int channels, int sample_rate, double cutoff_hz, int order);
    AE_API void ae_hpf_destroy(AEHpf *filter);
    AE_API void ae_hpf_reinit(AEHpf *filter, int format, int channels, int sample_rate, double cutoff_hz, int order);
    AE_API int ae_hpf_process(AEHpf *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // BPF2
    AE_API AEBpf2 *ae_bpf2_create(int format, int channels, int sample_rate, double cutoff_hz, double q);
    AE_API void ae_bpf2_destroy(AEBpf2 *filter);
    AE_API void ae_bpf2_reinit(AEBpf2 *filter, int format, int channels, int sample_rate, double cutoff_hz, double q);
    AE_API int ae_bpf2_process(AEBpf2 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // BPF (High order)
    AE_API AEBpf *ae_bpf_create(int format, int channels, int sample_rate, double cutoff_hz, int order);
    AE_API void ae_bpf_destroy(AEBpf *filter);
    AE_API void ae_bpf_reinit(AEBpf *filter, int format, int channels, int sample_rate, double cutoff_hz, int order);
    AE_API int ae_bpf_process(AEBpf *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // Notch2
    AE_API AENotch2 *ae_notch2_create(int format, int channels, int sample_rate, double q, double cutoff_hz);
    AE_API void ae_notch2_destroy(AENotch2 *filter);
    AE_API void ae_notch2_reinit(AENotch2 *filter, int format, int channels, int sample_rate, double q, double cutoff_hz);
    AE_API int ae_notch2_process(AENotch2 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // Peak2
    AE_API AEPeak2 *ae_peak2_create(int format, int channels, int sample_rate, double gain_db, double q, double cutoff_hz);
    AE_API void ae_peak2_destroy(AEPeak2 *filter);
    AE_API void ae_peak2_reinit(AEPeak2 *filter, int format, int channels, int sample_rate, double gain_db, double q, double cutoff_hz);
    AE_API int ae_peak2_process(AEPeak2 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // LowShelf2
    AE_API AELoshelf2 *ae_loshelf2_create(int format, int channels, int sample_rate, double gain_db, double slope, double cutoff_hz);
    AE_API void ae_loshelf2_destroy(AELoshelf2 *filter);
    AE_API void ae_loshelf2_reinit(AELoshelf2 *filter, int format, int channels, int sample_rate, double gain_db, double slope, double cutoff_hz);
    AE_API int ae_loshelf2_process(AELoshelf2 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // HighShelf2
    AE_API AEHishelf2 *ae_hishelf2_create(int format, int channels, int sample_rate, double gain_db, double slope, double cutoff_hz);
    AE_API void ae_hishelf2_destroy(AEHishelf2 *filter);
    AE_API void ae_hishelf2_reinit(AEHishelf2 *filter, int format, int channels, int sample_rate, double gain_db, double slope, double cutoff_hz);
    AE_API int ae_hishelf2_process(AEHishelf2 *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // Biquad
    AE_API AEBiquad *ae_biquad_create(int format, int channels, double b0, double b1, double b2, double a0, double a1, double a2);
    AE_API void ae_biquad_destroy(AEBiquad *filter);
    AE_API void ae_biquad_reinit(AEBiquad *filter, int format, int channels, double b0, double b1, double b2, double a0, double a1, double a2);
    AE_API int ae_biquad_process(AEBiquad *filter, void *out_frames, const void *in_frames, uint64_t frame_count);

    // Resampler
    // dither_mode: AEDitherMode applied when quantizing to an integer `format`
    // (the resampler processes in the float domain internally). No-op for F32.
    AE_API AEResampler *ae_resampler_create(int format, int channels, int sample_rate_in, int sample_rate_out, int algorithm, int dither_mode);
    AE_API void ae_resampler_destroy(AEResampler *resampler);
    AE_API int ae_resampler_process(AEResampler *resampler, const void *in_frames, uint64_t *in_frame_count, void *out_frames, uint64_t *out_frame_count);
    AE_API void ae_resampler_set_rate(AEResampler *resampler, int sample_rate_in, int sample_rate_out);
    AE_API void ae_resampler_set_rate_ratio(AEResampler *resampler, float ratio_in_out);
    AE_API uint64_t ae_resampler_get_required_input_frame_count(AEResampler *resampler, uint64_t out_frame_count);
    AE_API uint64_t ae_resampler_get_expected_output_frame_count(AEResampler *resampler, uint64_t in_frame_count);
    AE_API uint64_t ae_resampler_get_input_latency(AEResampler *resampler);
    AE_API uint64_t ae_resampler_get_output_latency(AEResampler *resampler);

    // ==========================================
    // Native Clean-Room Audio DSP Suite
    // ==========================================

    // Audio Clarity Engine (0=TransientCrisp, 1=AirShelf, 2=PresenceExciter, 3=HarmonicBrilliance)
    AE_API void ae_dsp_set_clarity_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_clarity_params(AudioEngineHandle *engine, int profile, float intensity);

    // Harmonic Bass Engine (0=SubBassResonant, 1=PunchyBass, 2=HarmonicExciter, 3=PultecDeep)
    AE_API void ae_dsp_set_bass_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_bass_params(AudioEngineHandle *engine, int profile, float cutoff_hz, float boost);

    // Dynamic Transducer System (0..18 presets)
    AE_API void ae_dsp_set_dynamic_system_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_dynamic_system_params(AudioEngineHandle *engine, int profile, float strength);
    AE_API void ae_dsp_set_dynamic_system_custom_params(AudioEngineHandle *engine, float x_low, float x_high, float y_low, float y_high, float side_gain_low, float side_gain_high, float bass_gain);

    // Analog Warmth (0=Triode12AX7, 1=MagneticTape, 2=VintagePreamp)
    AE_API void ae_dsp_set_analog_warmth_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_analog_warmth_params(AudioEngineHandle *engine, int profile, float drive);

    // Dialogue Booster / Enhancer (0=Cinema, 1=Music, 2=Voice, 3=Night, 4=Custom)
    AE_API void ae_dsp_set_dialog_enhancer_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_dialog_enhancer_params(AudioEngineHandle *engine, int profile, float amount, float ducking, float clarity, float center_focus);
    AE_API float ae_dsp_get_dialog_enhancer_gain_reduction_db(AudioEngineHandle *engine);

    // Split-Band / Wideband De-Esser (0=SplitBand, 1=WideBand)
    AE_API void ae_dsp_set_de_esser_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_de_esser_preset(AudioEngineHandle *engine, int preset);
    AE_API void ae_dsp_set_de_esser_params(AudioEngineHandle *engine, int mode, float intensity);
    AE_API void ae_dsp_set_de_esser_params_ex(AudioEngineHandle *engine, int mode, float frequency_hz, float threshold_db, float ratio, float max_reduction_db, float attack_ms, float release_ms);
    AE_API float ae_dsp_get_de_esser_gain_reduction_db(AudioEngineHandle *engine);

    // Downward Expander & Noise Floor Reducer (0=VinylClean, 1=TapeHiss, 2=GentleExpansion, 3=DynamicGate, 4=Custom)
    AE_API void ae_dsp_set_expander_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_expander_preset(AudioEngineHandle *engine, int preset);
    AE_API void ae_dsp_set_expander_params(AudioEngineHandle *engine, float threshold_db, float ratio, float range_db, float attack_ms, float release_ms);
    AE_API void ae_dsp_set_expander_params_ex(AudioEngineHandle *engine, float threshold_db, float ratio, float range_db, float attack_ms, float release_ms, float knee_db, float sidechain_hpf_hz);
    AE_API float ae_dsp_get_expander_gain_reduction_db(AudioEngineHandle *engine);

    // Subsonic Filter (18 Hz clean-room HPF for DC & turntable/mic rumble removal)
    AE_API void ae_dsp_set_subsonic_filter_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int  ae_dsp_get_subsonic_filter_enabled(AudioEngineHandle *engine);

    // Master DSP Reset
    AE_API void ae_dsp_reset(AudioEngineHandle *engine);

    // ==========================================
    // Spatial Surround Suite (see surround.md)
    //   Mode 1 FieldExpander   : M/S soundstage expander + Schroeder diffuser
    //   Mode 2 DifferentialHaas: Haas precedence cross-injection spatializer
    //   Mode 3 ViperHeadphone  : VHS+ room crossfeed & early reflections
    //   Mode 4 Matrix51Hrtf    : Pro Logic II dematrix -> binaural HRTF
    // All modes are zero-latency and stereo (2-channel) only.
    // ==========================================
    typedef enum AESurroundMode
    {
        AE_SURROUND_OFF = 0,
        AE_SURROUND_MATRIX = 1,      // Cinema Matrix 5.1 (Pro Logic II cleanroom)
        AE_SURROUND_BINAURAL = 2,    // Binaural HRTF Virtualizer (from Dolby analysis_dlby2)
        AE_SURROUND_STAGE = 3,       // 3D Acoustic Stage (from AM3D Zirene re_workspace)
        AE_SURROUND_MATRIX_5_1_HRTF = 4 // Backward-compatibility alias for Matrix
    } AESurroundMode;

    AE_API void ae_dsp_set_surround_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_surround_mode(AudioEngineHandle *engine, int mode);

    // Compact setter mapped to active algorithm parameters:
    AE_API void ae_dsp_set_surround_params(AudioEngineHandle *engine,
                                           float p1,
                                           float p2,
                                           float p3,
                                           float p4);
    AE_API void ae_dsp_get_surround_params(AudioEngineHandle *engine,
                                           int *out_enabled,
                                           int *out_mode,
                                           float *out_p1,
                                           float *out_p2,
                                           float *out_p3,
                                           float *out_p4);

    // Dedicated algorithm-specific parameter setters:
    AE_API void ae_dsp_set_surround_matrix_params(AudioEngineHandle *engine,
                                                  float center_focus,
                                                  float surround_boost,
                                                  float surround_delay_ms,
                                                  float head_radius_cm);

    AE_API void ae_dsp_set_surround_binaural_params(AudioEngineHandle *engine,
                                                    int mode,
                                                    float boost,
                                                    int room_preset,
                                                    float room_mix,
                                                    int speaker_angle,
                                                    float shadow_cutoff_hz);

    AE_API void ae_dsp_set_surround_stage_params(AudioEngineHandle *engine,
                                                 int profile,
                                                 int mode,
                                                 float width,
                                                 float depth,
                                                 float cancellation,
                                                 float air_presence,
                                                 float bass_anchor_hz);

    // Extended setter for backwards compatibility & combined tuning:
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
                                              float head_radius_cm);

    // FFT Impulse Response Convolver
    AE_API void ae_dsp_set_convolver_enabled(AudioEngineHandle *engine, int enabled);
    AE_API int ae_dsp_load_convolver_ir(AudioEngineHandle *engine, const float *samples, int frame_count, int channels);
    AE_API void ae_dsp_clear_convolver_ir(AudioEngineHandle *engine);
    AE_API void ae_dsp_set_convolver_mix(AudioEngineHandle *engine, float wet, float dry);
    AE_API int ae_dsp_has_convolver_ir(AudioEngineHandle *engine);
    AE_API int ae_dsp_get_convolver_kernel_length(AudioEngineHandle *engine);

    // Master Peak Limiter & Output Level
    AE_API void ae_dsp_set_master_limiter_enabled(AudioEngineHandle *engine, int enabled);
    AE_API void ae_dsp_set_master_limiter_params(AudioEngineHandle *engine, float ceiling_db, float output_gain_db, float release_ms);
    AE_API float ae_dsp_get_limiter_gain_reduction_db(AudioEngineHandle *engine);


    // Native Track Inspection
    typedef struct AETrackInfo
    {
        int sample_rate;        // Native decoder sample rate (Hz)
        int bit_depth;          // Native decoder bit depth (bits)
        int channels;           // Native decoder channel count
        int bitrate_kbps;       // Native average bitrate (kbps)
        int is_float;           // 1 if 32-bit float, 0 if int PCM
        double duration_secs;   // Track duration in seconds
        int64_t file_size_bytes;// File size in bytes
        char format_name[32];   // Container/Codec name ("FLAC", "WAV", "MP3", "AAC", etc.)
    } AETrackInfo;

    AE_API AETrackInfo ae_inspect_file(const char *file_path);

    // Output Backend Types
    typedef enum AEAudioBackend
    {
        AE_BACKEND_AUTO         = 0, // OS default (WASAPI on Win, CoreAudio on Apple, ALSA on Linux, AAudio on Android)
        AE_BACKEND_AAUDIO       = 1, // Android low-latency AAudio (MMAP)
        AE_BACKEND_OPENSL       = 2, // Android legacy OpenSL ES
        AE_BACKEND_AUDIOTRACK   = 3, // Android standard framework AudioTrack
        AE_BACKEND_DIRECT_HIRES = 4  // Android bit-perfect Direct Hi-Res (Hexagon/MTK/Exynos/Tensor)
    } AEAudioBackend;

    // Native Hardware Audio Engine Inspection
    typedef struct AEHardwareInfo
    {
        char backend_name[32];       // "WASAPI", "AAudio", "OpenSL ES", "ALSA", "PulseAudio", "Core Audio", "AudioTrack", "Direct Hi-Res", etc.
        char device_name[256];       // Active soundcard friendly device name
        char dsp_hardware[128];      // Detected DSP chip / pipeline (e.g. "Qualcomm Hexagon v73 aDSP", "MediaTek HiFi 5 DSP", etc.)
        char soc_name[64];           // Detected SoC (e.g. "Snapdragon 8 Gen 2", "Dimensity 9200", "Tensor G3", etc.)
        int output_format;           // AEAudioFormat Enum (0=F32, 1=S16, 2=U8, 3=S24, 4=S32)
        int bit_depth;               // Hardware bit depth (8, 16, 24, 32)
        int is_float;                // 1 if 32-bit Float PCM, 0 if Int PCM
        int sample_rate;             // Hardware output sample rate in Hz
        int channels;                // Hardware output channels
        uint32_t period_size_frames; // Hardware period frame size
        uint32_t period_count;       // Hardware period count
        double latency_ms;           // Real hardware buffer processing latency in milliseconds
        int is_exclusive_mode;       // 1 if exclusive mode (WASAPI/ALSA), 0 if shared mode
        int is_direct_pcm;           // 1 if DirectOutput / AudioFlinger bypass is active, 0 otherwise
    } AEHardwareInfo;

    AE_API AEHardwareInfo ae_get_hardware_info(AudioEngineHandle *engine);
    AE_API void ae_register_android_jvm(void *vm);

    // Dynamic Output Backend Selection & Capability Query
    AE_API int ae_set_output_backend(AudioEngineHandle *engine, int backend);
    AE_API int ae_get_output_backend(AudioEngineHandle *engine);
    AE_API int ae_is_backend_supported(AudioEngineHandle *engine, int backend);

#ifdef __cplusplus
}
#endif

