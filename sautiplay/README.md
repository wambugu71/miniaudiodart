# Sautiplay

Sautiplay is a clean, fast music player built for people who care about how their music actually sounds. It runs on **Sautiflow**, a custom low-latency C++ audio engine designed to step around noisy system mixers, handle varied song sample rates cleanly, and deliver near bit-perfect audio directly to your DAC or headphones.

No ads, no tracking, and no bloated menus—just pure sound and full control over your listening experience.

![Sautiplay](../docs/assets/sautiflow.png)

## Download the App

You can download the latest pre-compiled binaries for your platform directly from our GitHub Releases page:

**[📥 Download Latest Sautiplay Release](https://github.com/wambugu71/sautiflow/releases/latest)** | **[💬 Join Telegram Community](https://t.me/+MilnrgkNkbFiYmY0)**

Available platforms include:

- **Android**: sautiflow_android_arm64.apk and sautiflow_android_armv7.apk
- **Windows**: sautiflow_windows.zip
- **Linux**: sautiflow_linux.tar.gz
- **macOS**: sautiflow_macos.zip
- **iOS**: sautiflow_ios.ipa

*Note: All production builds are fully obfuscated and compiled with optimized settings.*

## Sideloading on iOS

To install the Sautiplay `.ipa` on an iOS device, you will need to sign it yourself since it is provided unsigned. You can use tools like [Sideloadly](https://sideloadly.io/) or [AltStore](https://altstore.io/) to sign and install the `.ipa` onto your iPhone or iPad using your own Apple ID.

## Why I Built Sautiplay (The Origin Story)

Sautiplay started back in **2023**. At first, I just wanted a simple, basic music player for Android that could deliver clean, near bit-perfect sound.

Existing music apps were frustrating. Most were bloated, full of ads, or cluttered with complex menus. But the bigger problem was how Android itself handles audio:

- **Songs have all kinds of sample rates**: Real music libraries are random. You have 44.1 kHz CD rips, 48 kHz video/stream audio, 96 kHz hi-res files, and more. By default, Android shoves everything through a cheap system resampler to fit whatever fixed rate it wants. To avoid having to juggle separate resampler apps and tools, I wanted a top-quality resampler built directly into the player.
- **Forced OEM sound "enhancements"**: Most phone makers inject their own equalizers, Dolby Atmos, or DTS:X into the audio pipeline. These often sound bad and mess with your music, and usually the only way to bypass them was rooting the phone.

So instead of using existing high-level wrappers, I built my own low-latency C++ audio engine (**Sautiflow**).

### How the Engine Actually Works

- **Bypassing OEM junk without root (on supported devices)**: The engine talks directly to Android's AAudio API and requests low-latency MMAP (Memory-Mapped) mode. On supported devices, this writes audio straight to the hardware driver, stepping clean around Android's shared mixer and bypassing forced OEM sound processing (Dolby Atmos, DTS:X, and factory EQs) completely root-free. Because Android hardware varies and some devices or vendor HALs might reject direct MMAP or bit-perfect streams, the engine gracefully falls back while still staying in the lowest-latency mode the device will allow.
- **Top-tier built-in resamplers**: Instead of letting Android do a sloppy job resampling your tracks, the engine integrates industry-standard resamplers — **`libsamplerate`**, **`r8brain`**, and **`libsoxr`**. When a local track has to be converted, it's done with high-precision sinc math so you get zero phase distortion or muffled highs. The only exception is online/network streams, which play through FFmpeg's default resampler for fast, reliable live decoding.
- **Auto sample rate matching**: If your phone or external DAC supports it, the engine automatically switches its sample rate to match whatever track you're playing.
- **Handling real-world Android quirks**: Android devices are unpredictable. Some phones gladly accept bit-perfect or direct MMAP streams, while others reject them outright. The engine is built for this reality: even if a device rejects strict bit-perfect mode, it still locks in low-latency AAudio buffers and uses its own clean internal resampler. You get the cleanest possible sound your hardware will allow without the operating system getting in the way.

## Features

Sautiplay showcases the full extent of the sautiflow audio engine. Key features include:

- **Audiophile-Grade Playback**: Crystal clear audio reproduction using miniaudio, with libsamplerate, r8brain, and libsoxr for high-fidelity local resampling (and FFmpeg's default resampler for live streams).
- **Gapless Transitions**: Seamless playback between tracks in your queue.
- **Advanced DSP & Audio Effects**:
  - 3-band & Multiband Equalizers
  - Reverb, Delay, and Stereo Widening
  - Parametric shaping (Low-pass, High-pass, Band-pass, Notch, Peak EQ, Low-shelf, High-shelf)
- **Comprehensive Playlist Management**: Add, remove, move, and shuffle tracks dynamically.
- **Network Streaming**: Native URL streaming support built right into the app.
- **Cross-Platform**: A unified UI and audio experience across Android, Windows, Linux, macOS, and iOS.

## Developer Guide: Cross-Platform Setup & Building

Sautiplay is cross-platform by design. The interface is built with Flutter, while low-latency audio processing is handled by a single, shared C++ engine (**Sautiflow**) connected directly via Dart FFI. The exact same DSP algorithms, resamplers, and mixer logic run across Android, Windows, Linux, macOS, and iOS.

### 1. Prerequisites by Platform

- **Android**:
  - Flutter SDK
  - Android Studio & Android SDK
  - Android NDK (install via *Android Studio > SDK Manager > SDK Tools > NDK*)
  - CMake (install via SDK Manager)
- **Windows**:
  - Flutter SDK
  - Visual Studio 2022 (with the *Desktop development with C++* workload)
  - CMake
- **Linux**:
  - Flutter SDK
  - C++ compiler (`clang` or `gcc`), `cmake`, `ninja-build`, `pkg-config`
  - Audio headers: `sudo apt install cmake ninja-build libasound2-dev libpulse-dev pkg-config`
- **macOS & iOS**:
  - Flutter SDK
  - Xcode & Command Line Tools
  - CocoaPods: `sudo gem install cocoapods`

### 2. Platform Configuration Snippets

#### Android Setup (`AndroidManifest.xml`)
For background playback, lockscreen transport controls, and notification controls, configure `android/app/src/main/AndroidManifest.xml`. Note that `AudioServiceActivity` replaces the default FlutterActivity:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Required permissions for background audio & Android 13+ notifications -->
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

    <application ...>
        <!-- Main Activity must use or extend AudioServiceActivity -->
        <activity
            android:name="com.ryanheise.audioservice.AudioServiceActivity"
            android:exported="true"
            android:launchMode="singleTask">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>

        <!-- Background Media Playback Service -->
        <service
            android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService" />
            </intent-filter>
        </service>

        <!-- Headphone & Bluetooth hardware button receiver -->
        <receiver
            android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON" />
            </intent-filter>
        </receiver>
    </application>
</manifest>
```

#### Android Native Streaming (`android/gradle.properties`)
To enable native cURL streaming for online radio and web streams on Android, set these native flags:

```properties
MINIAUDIODART_ENABLE_CURL=ON
MINIAUDIODART_CURL_INCLUDE_DIR=/path/to/curl/include
MINIAUDIODART_CURL_LIBRARY=/path/to/libcurl.so
```

#### Dart Initialization & Audio Session (`main.dart`)
Initialize the audio session for background music and boot the native Sautiflow engine:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Configure audio session for background music playback
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  // 2. Initialize Sautiflow engine with system audio integration
  final player = MiniAudioPlayer();
  await player.init(enableSystemAudio: true);

  runApp(const MyApp());
}

// Update lockscreen / notification metadata on track changes:
await player.updateNowPlaying(
  title: "Track Title",
  artist: "Artist Name",
  album: "Album Name",
  duration: Duration(minutes: 3, seconds: 45),
);
```

### 3. Building & Running

1. **Clone and fetch dependencies**:
   ```bash
   git clone https://github.com/wambugu71/sautiflow.git
   cd sautiflow/sautiplay
   flutter pub get
   ```

2. **Run with compile-time stream URLs**:
   Endpoints are passed via `--dart-define` so they are never hardcoded:
   ```bash
   flutter run --dart-define=STREAM_URL_1="your_stream_url_1" --dart-define=STREAM_URL_2="your_stream_url_2"
   ```

3. **Building Release Binaries**:
   - **Android APK**:
     ```bash
     flutter build apk --release --dart-define=STREAM_URL_1="..." --dart-define=STREAM_URL_2="..."
     ```
   - **Windows Portable**:
     ```bash
     flutter build windows --release --dart-define=STREAM_URL_1="..." --dart-define=STREAM_URL_2="..."
     ```
   - **Linux App**:
     ```bash
     flutter build linux --release --dart-define=STREAM_URL_1="..." --dart-define=STREAM_URL_2="..."
     ```
   - **macOS App**:
     ```bash
     flutter build macos --release --dart-define=STREAM_URL_1="..." --dart-define=STREAM_URL_2="..."
     ```
   - **iOS IPA**:
     ```bash
     flutter build ipa --release --no-codesign --dart-define=STREAM_URL_1="..." --dart-define=STREAM_URL_2="..."
     ```

## Frequently Asked Questions (FAQ)

#### 1. Why does my Android device say "Hardware declined Exclusive Mode. Falling back to Shared Mixer!"?
Android devices have wildly different hardware abstraction layers (HALs) and firmware restrictions. When you turn on Bit-Perfect Exclusive mode, Sautiplay requests direct, exclusive access to the audio hardware (via AAudio MMAP). Some internal phone DACs and vendor ROMs decline this exclusive lock. When that happens, Sautiplay doesn't crash or fail—it notifies you with a snackbar and falls back to low-latency shared mode, using its own clean internal floating-point engine for any required processing.

#### 2. How does Auto Sample-Rate Matching differ from Bit-Perfect mode?
Bit-Perfect mode attempts to grab exclusive hardware ownership so no other app or system sound can mix in. **Auto Sample-Rate Match** detects the exact sample rate of the song you're playing (44.1 kHz, 48 kHz, 96 kHz, 192 kHz, etc.) and asks the DAC to switch its internal clock to match that track. If both options are turned on, Sautiplay automatically handles the hardware sample rate switching and exclusive lock together.

#### 3. How does Sautiplay bypass Dolby Atmos, DTS:X, and OEM equalizers without root?
On supported Android devices, Sautiplay requests low-latency MMAP (Memory-Mapped) streams through Android's native AAudio C API. When supported, MMAP audio writes directly to the ALSA driver and DSP hardware, bypassing Android's user-space `AudioFlinger` mixer where OEM sound "enhancements" (forced Dolby, DTS:X, factory equalizers) are normally injected. No root or bootloader unlocking is required.

#### 4. Which resampler should I choose between libsamplerate, r8brain, and libsoxr?
All three are high-grade sinc resamplers:
- **`libsamplerate`** (Secret Rabbit Code): The classic audiophile sinc converter with transparent frequency response.
- **`r8brain`**: Ultra-clean linear-phase and minimum-phase resampler with over -160 dB stopband attenuation and high efficiency.
- **`libsoxr`**: The SoX resampler, known for studio-grade fidelity with very low CPU overhead.
For local playback, all three deliver mathematically transparent rate conversion with zero audible distortion or treble smear.

#### 5. Why do online and YouTube Music streams use FFmpeg's resampler instead?
Live network streams (like YouTube Music or web radio) require real-time chunk demuxing, variable network bitrates, and dynamic buffering. FFmpeg's built-in `swresample` is tightly integrated into the streaming decoder pipeline to guarantee glitch-free, instant live playback without buffer underruns.

#### 6. What does 64-Bit Float Processing mode do?
Standard digital audio processing uses 32-bit float (around 144–150 dB of dynamic range). Sautiplay's optional 64-Bit Float Processing mode computes all equalizer, filter, crossfeed, and volume math in double precision. This provides over 320 dB of internal calculation headroom, completely eliminating accumulated rounding errors or clipping during complex multi-effect chains.

#### 7. Can I import AutoEQ profiles or custom headphone impulse responses (IRs)?
Yes. Sautiplay includes built-in AutoEQ import (supporting both parametric and graphic EQ curves for thousands of headphones), Viper4Android VDC/DDC profile parsing, and a Convolver that can load custom stereo impulse response WAV files for acoustic room simulation or headphone correction.

#### 8. Can I cast music or use Sautiplay as a wireless receiver?
Yes. Sautiplay can cast out to UPnP/DLNA network speakers and smart TVs. It also includes a built-in DLNA MediaRenderer service that turns Sautiplay into a wireless receiver, letting you stream music from other phones, tablets, or computers on your local Wi-Fi network directly into Sautiplay.

#### 9. Are there ads, tracking, or accounts required?
None. Sautiplay is 100% open source, privacy-focused, and offline-first. There are no ads, no telemetry, and no mandatory account sign-ins.

## Community & Discussion

Join our Telegram group for updates, questions, and discussion:
👉 **[Join Sautiplay / Sautiflow Telegram Group](https://t.me/+MilnrgkNkbFiYmY0)**

## Credits & Acknowledgements

Sautiplay and the Sautiflow engine rely on several fantastic open-source projects and tools:

- **MATLAB**: Used extensively for DSP modeling, filter simulation, acoustic response curves, and verifying resampler behavior before writing the C++ code.
- **miniaudio** (David Reid): The core multi-platform audio library powering low-level playback and hardware device backends (AAudio, WASAPI, CoreAudio, ALSA, PulseAudio).
- **libsamplerate** (Erik de Castro Lopo / Secret Rabbit Code): High-quality sample rate converter for local playback.
- **r8brain-free-src** (Aleksey Vaneev / Voxengo): High-performance, professional-grade sample rate converter.
- **libsoxr** (Rob Sykes): High-quality SoX resampler library.
- **FFmpeg**: Powers network stream demuxing, audio decoding, and default resampling for live streams.
- **Flutter & Dart**: Powers the cross-platform Material 3 Expressive UI and native FFI bindings.

## Support

If you enjoy using Sautiplay or the sautiflow engine, consider supporting the development!

<a href="https://buymeacoffee.com/wambugu" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
