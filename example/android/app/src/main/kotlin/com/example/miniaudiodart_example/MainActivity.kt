package com.example.miniaudiodart_example

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        init {
            try {
                System.loadLibrary("sautiflow")
            } catch (e: Throwable) {
                try {
                    System.loadLibrary("audio_engine")
                } catch (e2: Throwable) {
                    // Ignore load error fallback
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.wambugu.sautiflow/hardware").setMethodCallHandler { call, result ->
            if (call.method == "getHardwareAudioSpecs") {
                try {
                    val audioManager = applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val sampleRateStr = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
                    val bufferSizeStr = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)

                    val defaultHalRate = sampleRateStr?.toIntOrNull() ?: 48000
                    var sampleRate = defaultHalRate
                    val periodFrames = bufferSizeStr?.toIntOrNull() ?: 192

                    var deviceName = "Default Output Device"
                    var bitDepth = 32
                    var isFloat = true
                    var deviceType = "Speakers / Output Device"

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                        var selectedPriority = -1
                        var selectedDevice: AudioDeviceInfo? = null

                        for (dev in devices) {
                            val type = dev.type
                            var priority = 1
                            // 11 = TYPE_USB_DEVICE, 22 = TYPE_USB_HEADSET
                            if (type == 11 || type == 22) priority = 4
                            // 8 = TYPE_BLUETOOTH_A2DP, 26 = TYPE_BLUETOOTH_LE
                            else if (type == 8 || type == 26) priority = 3
                            // 3 = TYPE_WIRED_HEADSET, 4 = TYPE_WIRED_HEADPHONES
                            else if (type == 3 || type == 4) priority = 2

                            if (priority > selectedPriority) {
                                selectedPriority = priority
                                selectedDevice = dev
                            }
                        }

                        selectedDevice?.let { dev ->
                            val name = dev.productName?.toString()
                            if (!name.isNullOrEmpty()) {
                                deviceName = name
                            }
                            val devType = dev.type
                            if (devType == 11 || devType == 22) {
                                deviceType = "USB DAC"
                            } else if (devType == 8 || devType == 26) {
                                deviceType = "Bluetooth Wireless"
                            } else if (devType == 3 || devType == 4) {
                                deviceType = "3.5mm Headphone Jack"
                            }

                            val devRates = dev.sampleRates
                            if (devRates.isNotEmpty()) {
                                sampleRate = devRates.maxOrNull() ?: defaultHalRate
                            }

                            val encodings = dev.encodings
                            var maxBits = 16
                            var floatFmt = false
                            for (enc in encodings) {
                                // 4 = ENCODING_PCM_FLOAT, 21 = ENCODING_PCM_24BIT_PACKED, 22 = ENCODING_PCM_32BIT, 2 = ENCODING_PCM_16BIT
                                if (enc == 4) {
                                    floatFmt = true
                                    if (32 > maxBits) maxBits = 32
                                } else if (enc == 21) {
                                    if (24 > maxBits) maxBits = 24
                                } else if (enc == 22) {
                                    if (32 > maxBits) maxBits = 32
                                } else if (enc == 2) {
                                    if (16 > maxBits) maxBits = 16
                                }
                            }
                            if (maxBits > 0) bitDepth = maxBits
                            isFloat = floatFmt
                        }
                    }

                    val latencyMs = (periodFrames.toDouble() * 2.0 / sampleRate.toDouble()) * 1000.0

                    val resultMap = mapOf(
                        "deviceName" to deviceName,
                        "sampleRate" to sampleRate,
                        "bitDepth" to bitDepth,
                        "isFloat" to isFloat,
                        "channels" to 2,
                        "periodSizeFrames" to periodFrames,
                        "periodCount" to 2,
                        "latencyMs" to latencyMs,
                        "deviceType" to deviceType
                    )
                    result.success(resultMap)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
