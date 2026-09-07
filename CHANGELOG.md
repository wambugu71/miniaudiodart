# Changelog
## v0.6.26 — 2026-09-08
- **[In-App Update Detection & Multi-Platform Resolution]** Added automated release detection against GitHub Releases API with strict OS and CPU ABI matching (`dart:ffi` `Abi.current()`), distinguishing Android ARM64 (`sautiflow_android_arm64.apk`), Android ARMv7 (`sautiflow_android_armv7.apk`), macOS, Windows, and Linux without platform confusion.
- **[Background Isolate Streaming & Resumable Downloads]** Offloaded binary download, chunk streaming, and file writing to a dedicated background worker Isolate with throttled progress updates to keep the UI at a buttery smooth 120 FPS. Integrated HTTP Range headers (`206 Partial Content`) to automatically resume interrupted downloads upon network reconnection.
- **[Material 3 Expressive Dialog & Wavy Progress]** Implemented `M3EDialog` update prompt with animated `M3EProgressIndicator.linearWavy`, even tabular byte sizing (`FontFeature.tabularFigures()`), and in-flight cancel / restart / resume controls.
- **[Network Drop Watchdog & Safe File Handles]** Added an 18-second inactivity watchdog to gracefully handle silent network drops, with guaranteed file handle closure to prevent file locks.
- **[Android In-App Package Installation]** Wired native `FileProvider` and `REQUEST_INSTALL_PACKAGES` permission in `MainActivity.kt` for seamless APK installation prompt.
- **[Settings Screen Update Status]** Added interactive "Check for Updates" tile and dynamic "UPDATE AVAILABLE" category badge in Settings.

## v0.6.25 
- Bugs fixes and performance  improvements
- Added ability to select  backend  for  android(only). 
- Decoupled homescreen UI

## 0.6.24
- **[Android Online Stream Architecture Fix]** Resolved online stream playback stalls on Android by implementing a resilient two-stage resampler initialization in `ffmpeg_stream_decoder.cpp`. Falls back gracefully from SoXR to FFmpeg's native `SWR_ENGINE_SWR` engine with 32-tap high-precision sinc filtering, eliminating `AVERROR(EINVAL)` (-22) failures when `libsoxr` is not present in Android prebuilts.
- **[Track Switch & Decoder Mutex Starvation Elimination]** Resolved decoder mutex lock starvation in `audio_engine.cpp` during track changes and playlist jumps by releasing `decoderMutex` before waiting on `decodeProducerCv`. Slashed track loading latency from 20+ seconds down to 1 millisecond.
- **[Stream Probing Zero-Rate Guards]** Guarded `soxr_onInit` and `src_onInit` against unprobed / non-positive sample rates during dynamic stream format discovery, preventing `MA_ERROR` aborts.
- **[Android MediaSession Timeline Telemetry]** Corrected `bufferedPosition` in `mobile_system_audio.dart` to report absolute media timeline position (`currentPositionMs + bufferAheadMs`), preventing Android MediaSession underflow stalls and lockscreen notification dismissals.
- **[Push Stream Instant Start]** Maintained responsive 32KB initial buffer threshold in `pushStream` for immediate audio start on chunked and live radio streams.
- **[Isolate Stream Telemetry Wire-up]** Connected real-time stream telemetry from `IsolateAudioPlayer` into `MiniAudioSystemAudioController`.

## 0.6.23
- **[Universal Native Streaming Build Support]** Enabled `-DSAUTIFLOW_ENABLE_FFMPEG=1` across all platform build systems (Windows, Linux, Android, iOS, and macOS). Fixed network streaming support detection (`isNetworkStreamingSupported`), eliminated unhandled isolate `ArgumentError` crashes on network source enqueueing, and rebuilt Windows native DLLs.
- **[Clean-Room Dynamic System Bass DSP]** Implemented dual-cascade 4-pole multi-band ladder matrix dynamic bass DSP with 19 acoustic transducer hardware presets and smooth sample-by-sample parameter de-zippering.
- **[Acoustic Hardware Transducer Presets]** Exposed dynamic profile selection and dynamic drive control across native C++ engine, Dart FFI bindings, and SautiPlay EQ screen.
- **[Audio Engine Quality & Playback Fixes]** Enabled Lookahead Safety Limiter by default to prevent inter-sample clipping, added perceptual cubic volume curve mapping and dB volume controls, integrated ISO 226 equal-loudness contour compensation in real-time spectrum analyzer, smooth audio ducking ramp, and dynamic status polling for lower idle CPU consumption.

## 0.6.22
- **[Real-time Synced Lyrics Engine]** Integrated online YouTube Music timed lyrics fetching and offline companion `.lrc` / `.txt` local file import with auto-scroll active line viewport centering, interactive click-to-seek, and frosted album art overlay.
- **[Dynamic Studio DSP Suite]** Added full Studio Dynamic Range Compressor (threshold, ratio, attack, release, knee, auto-makeup gain), Downward Expander & Adaptive Noise Floor Reducer, and Split-Band / Wide-Band De-Esser.
- **[Subsonic Protection & Quality Foundation]** Implemented 18Hz clean-room high-pass subsonic filter, 2x polyphase half-band oversampling for saturation stages, multi-arch DAZ/FTZ denormals flushing (x86_64 and ARM64/NEON), and libsoxr Very High Quality sinc resampler defaults.
- **[UI/UX Material 3 Expressive]** Redesigned 3D beveled dark metallic `ModernAudioKnob` with radial glow, optimized mobile album art layering, and added Telegram community links to settings.

## 0.6.21
- **[Native Streaming Engine]** Integrated embedded FFmpeg (`libavformat` + `libavcodec` + `libswresample`) decoding backend into miniaudio with 10-second lock-free jitter ring buffer, live ICY metadata parsing, and seamless DSP/effects pipeline integration.
- **[Zero-Latency Spatial Surround]** Added real-time 3D spatial surround suite (Field Expander, Haas Spatializer, ViPER Headphone Surround+, Matrix 5.1 HRTF) with per-sample anti-pop smoothing.
- **[DSP Wet/Dry & Dynamics]** Parametric Reverb wet/dry gain staging, BS.1770 loudness normalizer telemetry, and psychoacoustic noise-shaping dither.
- **[Sample-Accurate Crossfade]** Implemented non-blocking crossfade pipeline with graceful abort and stall watchdog.
- **[DLNA & Cast]** Added cross-platform DLNA cast-out and integrated DLNA MediaRenderer receiver.
- **[Sautiplay M3E Redesign]** Modernized UI with Material 3 Expressive carousels, reactive search with suggestions, and unified Dark Blue theme.
- **[CI/CD Release Automation]** Automated multi-platform release build generation and instant Telegram channel release notifications.

## 0.6.20
- **[DSP Engine & Audio Architecture]** Upgraded Sautiflow engine & Sautiplay app with 64-bit float DSP pipeline, Auto Bit-Perfect hardware matching, Ambiophonics. crossfeed, and psychoacoustic noise-shaping dither modes.
- **[Dynamic Cover Art & Theme Engine]** Added Material 3 Isolate-driven Dynamic Cover Art color extraction (`ArtworkThemeService`) that extracts harmonious palette schemes from album art on the fly without UI stuttering.
- **[Interactive Waveform Seek Bar]** Added interactive waveform seek bar widget (`WaveformSeekBarWidget`) with background waveform extraction (`WaveformExtractorService`) and robust pending seek state reset handling across track changes.
- **[GPU GLSL Visualizers]** Added 15 custom GPU GLSL audio-reactive visualizer presets with mobile-optimized pinned control bar and dynamic animation pause/resume on playback state changes.
- **[Network Sources & Media Streaming]** Added FTP and DLNA/UPnP network source browser, local folder caching, built-in HTTP local media server (`LocalMediaServer`), and Network Stream player navigation.
- **[App Onboarding]** Integrated `showcaseview` package with themed `AppShowcase` for step-by-step interactive feature onboarding for new app installs.
- **[Library & Storage]** Added Album and Genre hierarchical groupings for local library, and fixed mobile profile and playlist export file saving on Android and iOS.
- **[UI Refactoring & Polish]** Reorganized Settings screen into clean category sub-screens with unified Material 3 styling and fixed lint rule compliance.

## 0.6.19
- **[AutoEQ & Presets]** Added native AutoEQ profile parser service supporting `GraphicEQ.txt` lines and `ParametricEQ.txt` text blocks (`autoeq_parser.dart`).
- **[AutoEQ UI]** Added unified AutoEQ & Presets Importer UI in `sautiplay` to import and apply `.txt`, `.irs`, `.wav`, and `.vdc` profiles on the fly.
- **[AutoEQ Engine]** Integrated automatic `Preamp` master limiter gain headroom scaling to prevent digital clipping when applying AutoEQ boosts.
- **[UI/Fixes]** Fixed `NestedScrollView` + `Scrollbar` `ScrollController` position conflict in `sautiplay` tab views.
- More  features added.

## 0.6.18
- Bugs  fixes and improvements in the audio engine .
- Updated  versions across the  pkg and sautiplay app. 


## 0.6.17

- **[Android]** Added MethodChannel hardware audio inspection for Android `AudioServiceActivity` in `sautiplay`.
- **[Android]** Fixed JNI reflection hidden API restrictions on Android 9+ and resolved `IsolateAudioPlayer` inspection compatibility.

## 0.6.16

- Fixed minor bugs and improved performance and stability.
- Updated sautiplay app to use the latest version of sautiflow.
## 0.6.15

- **[Core/FFI]** Added real-time native hardware output inspection API (`AEHardwareInfo` & `ae_get_hardware_info`).
  - Exposes active audio backend (`WASAPI`, `AAudio`, `Core Audio`, `PulseAudio`, `ALSA`), negotiated hardware sample rate, bit depth, buffer frame size, latency in ms, active soundcard device name, and exclusive mode status.
- **[Apps/UI]** Added interactive Hardware Audio Output & Device Inspector modal sheet to `sautiplay` Now Playing Screen.

- **[Core]** Fixed bugs and fixed crossfade in the sautiflow library.
- **[Apps/UI]** For `sautiplay`: added Sauti DSP Suite effects, implemented UI improvements, boosted performance, and fixed bugs.

## 0.6.4

- Version bump for release.

## 0.6.3

- **[Build]** Added unsigned iOS `.ipa` generation to the GitHub Actions workflow for sideloading iOS applications.
- **[Docs]** Updated `sautiplay` README with instructions on how to install the `.ipa` using unsigned methods like Sideloadly or AltStore.

## 0.6.2

Fix missing C++ headers in published package

## 0.6.1

- **[Core]** Added new `getPipelineState()` API to query the true native C++ audio engine pipeline state.
- Accurately tracks the flow from input source (sample rate, bit-depth format) -> internal DSP processing -> natively negotiated real hardware output format.
- **[Apps/UI]** Implemented the pipeline state viewer (Info Button) inside the Sautiplay app EQ Screen.

## 0.6.0

- **[DSP Effects]** Added new Stereo Widening feature using a hybrid Haas Effect + Mid/Side (M/S) Matrix algorithm.
  - Exposes `setStereoWiden({required bool enabled, required double width, required double delayMs})` directly in `MiniAudioPlayer` and `IsolateAudioPlayer`.
  - Enables professional, mono-compatible "wide soundstage" manipulation without destructive phase cancellation.
- **[UI/Apps]** Integrated fully functional "Stereo Stage" configuration knobs into the Example app and Sautiplay EQ screens.
- **[Apps]** Added persistent state saving for the Stereo Widening options in Sautiplay's SharedPreferences.

## 0.5.0

- **[Pitch & Spatialization]** Added new advanced audio features natively using miniaudio:
  - Added robust Pitch Control with `setPitch(double)`.
  - Added 3D Spatial Audio: Enable via `setSpatializationEnabled(bool)` and position sound sources in a 3D environment via `setPosition(x,y,z)`, `setDirection()`, and `setVelocity()`.
  - Configurable 3D Audio parameters: Doppler effect, attenuation models, rolloff factor, min/max gain, and distance thresholds.
  - Added customizable Fading: `setFade(startVol, endVol, durationMs)`.
  - Added granular Playback Scheduling: `scheduleStartTimeInPcmFrames(time)` and `scheduleStopTimeInPcmFrames(time)`.
- **[Example App]** Updated the demonstration app with UI sliders to configure Pitch shifting and 3D Spatial Audio in real-time.

- Integrated `libsamplerate` (Secret Rabbit Code) for audiophile-grade audio resampling.
- Added extensive new resampling algorithms via Flutter FFI to the native C++ audio engine:
  - `srcSincBestQuality`
  - `srcSincMediumQuality`
  - `srcSincFastest`
  - `srcZeroOrderHold`
  - `srcLinear`
- Exposed the new algorithms in `MiniAudioPlayer.setEngineResampleAlgorithm(ResampleAlgorithm)`.
- Updated Windows and Android CMake build systems to natively compile `libsamplerate` alongside `faad2` and `miniaudio`.
- Added m4a AAC decoding support via `faad2`.
- Enhanced example application with UI dropdown to dynamically change resampling algorithms on the fly.

## 0.4.0-dev

- Added standalone object-oriented filter API wrapping miniaudio natively (`MiniaudioLpf1`, `MiniaudioLpf2`, `MiniaudioLpf`, `MiniaudioHpf1`, etc).
- Added standalone `MiniaudioBiquad` filter wrapping.
- Added standalone `MiniaudioResampler` with support for algorithms (`linear`, `sinc`) and dithering modes.
- Added support for `s24` and `s32` AudioFormats in the native engine mappings.
- Re-architected C++ FFI to expose these standalone filters independently of the main `AudioEngineHandle` player.
- **[Real-Time DSP]** Injected custom `ma_lpf1`, `ma_hpf1`, and `ma_biquad` as native nodes in the main AudioEngineHandle data callback.
- **[Real-Time DSP]** Exposed `setEngineResampleAlgorithm` and `setEngineDitherMode` to dynamically re-configure the global audio device.
- Updated documentation and the example app to include interactive, real-time SLIDER and DROPDOWN controls for testing the native backend integrations.

## 0.3.0-dev

- Started unified mixed multiband FX implementation.
- Added new public Dart model types for user-defined band chains:
  - `EqBandType` (`peak`, `bandpass`, `notch`, `lowshelf`, `highshelf`)
  - `EqBandConfig` (per-band `frequencyHz`, `q`, `gainDb`, `slope`, `enabled`)
- Added `MiniAudioPlayer` APIs:
  - `initMultibandFx(bands, enabled: true)`
  - `setMultibandFxBands(bands)`
  - `setMultibandFxEnabled(enabled)`
  - `clearMultibandFx()`
- Wired new mixed multiband FX path through Dart FFI and native C/C++ ABI (`ae_set_multiband_fx_*`).
- Added initial realtime analyzer frame API for visualization pipelines:
  - Native C ABI: `ae_set_analyzer_enabled`, `ae_configure_analyzer`, `ae_poll_analyzer_frame`
  - Dart FFI + `MiniAudioPlayer` surface:
    - `configureAnalyzer(frameSize: ...)`
    - `setAnalyzerEnabled(enabled)`
    - `getLatestAnalyzerFrame()`
    - `analyzerStream`
- Added transition crossfade controls end-to-end:
  - `setCrossfadeEnabled(bool)`
  - `setCrossfadeDurationMs(int)` (native clamp `0..10000`)
- Updated output sample-rate handling so `setOutputSampleRate(0)` now applies native device rate mode.

## 0.2.0

- Added new miniaudio-powered FX APIs:
  - `setBandpass(enabled, cutoffHz, q)`
  - `setPeakEq(enabled, gainDb, q, frequencyHz)`
  - `setNotch(enabled, q, frequencyHz)`
  - `setLowshelf(enabled, gainDb, slope, frequencyHz)`
  - `setHighshelf(enabled, gainDb, slope, frequencyHz)`
- Wired new FX end-to-end across native engine, Dart FFI, and public `MiniAudioPlayer` API.
- Expanded example EQ screen with interactive controls for the new FX for easier testing.
- Updated documentation and feature lists to include the new filter/EQ set.

## 0.1.0

- Initial release of `sautiflow`.
- Cross-platform audio playback engine via miniaudio and Dart FFI.
- Playlist controls: play, pause, stop, seek, next, previous, jump, shuffle, loop.
- Audio effects support: gain, pan, EQ, reverb, low/high-pass, delay.
- Platform support: Android, iOS, macOS, Linux, and Windows.

## 0.6.8
- Fixed Linux build error (cmath / std::abs)
- Fixed Windows build error (coroutine deprecation warning)


## 0.6.9
- CI deployment fix (bump version after successful publish)


## 0.6.10
- GitHub Actions CI workflow fix: remove branch triggers from publish workflow to fix pub.dev tag refType error


## 0.6.11
- Fix Linux build error: add missing cstdint include for uint32_t in TubeSimulator

