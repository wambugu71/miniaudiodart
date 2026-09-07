package com.wambugu.sautiplay.sautiplay

import android.Manifest
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothCodecConfig
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        private const val TAG = "SautiHardware"
        private const val METHOD_CHANNEL = "com.wambugu.sautiflow/hardware"
        private const val EVENT_CHANNEL = "com.wambugu.sautiflow/hardware_stream"
        private const val REQUEST_BT_PERMISSION = 7749

        private const val ACTION_CODEC_CONFIG_CHANGED =
            "android.bluetooth.a2dp.profile.action.CODEC_CONFIG_CHANGED"

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

    // ── State ─────────────────────────────────────────────────────────────────
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var bluetoothA2dp: BluetoothA2dp? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var audioDeviceCallback: AudioDeviceCallback? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    // Comprehensive BroadcastReceiver for Wired, Bluetooth, and USB audio events
    private val hardwareReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            Log.d(TAG, "Hardware event received: ${intent.action}")
            when (intent.action) {
                Intent.ACTION_HEADSET_PLUG,
                BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED,
                ACTION_CODEC_CONFIG_CHANGED,
                BluetoothDevice.ACTION_NAME_CHANGED,
                BluetoothDevice.ACTION_ACL_CONNECTED,
                BluetoothDevice.ACTION_ACL_DISCONNECTED,
                BluetoothAdapter.ACTION_STATE_CHANGED,
                UsbManager.ACTION_USB_DEVICE_ATTACHED,
                UsbManager.ACTION_USB_DEVICE_DETACHED,
                AudioManager.ACTION_AUDIO_BECOMING_NOISY -> {
                    pushCurrentSpecs()
                }
            }
        }
    }

    private val btProfileListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
            if (profile == BluetoothProfile.A2DP) {
                bluetoothA2dp = proxy as BluetoothA2dp
                Log.d(TAG, "BluetoothA2dp profile connected")
                pushCurrentSpecs()
            }
        }

        override fun onServiceDisconnected(profile: Int) {
            if (profile == BluetoothProfile.A2DP) {
                bluetoothA2dp = null
                Log.d(TAG, "BluetoothA2dp profile disconnected")
                pushCurrentSpecs()
            }
        }
    }

    // ── Flutter Engine Setup ──────────────────────────────────────────────────
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getHardwareAudioSpecs" -> {
                    try {
                        result.success(buildSpecsMap())
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(true)
                }
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                Log.d(TAG, "EventChannel: Flutter subscribed")
                eventSink = sink
                pushCurrentSpecs()
            }

            override fun onCancel(arguments: Any?) {
                Log.d(TAG, "EventChannel: Flutter unsubscribed")
                eventSink = null
            }
        })
    }

    // ── Activity Lifecycle ────────────────────────────────────────────────────
    override fun onStart() {
        super.onStart()
        setupAudioDeviceCallback()
        requestBluetoothPermissionIfNeeded()
        registerHardwareReceiver()
    }

    override fun onStop() {
        super.onStop()
        teardownAudioDeviceCallback()
        teardownBluetoothProfile()
        unregisterHardwareReceiver()
        releaseMulticastLock()
    }

    private fun requestBluetoothPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(
                    this, Manifest.permission.BLUETOOTH_CONNECT
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                setupBluetoothProfile()
            } else {
                Log.d(TAG, "Requesting BLUETOOTH_CONNECT permission")
                requestPermissions(
                    arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                    REQUEST_BT_PERMISSION
                )
            }
        } else {
            setupBluetoothProfile()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_BT_PERMISSION) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) {
                Log.d(TAG, "BLUETOOTH_CONNECT granted — connecting BT profile")
                setupBluetoothProfile()
            } else {
                Log.d(TAG, "BLUETOOTH_CONNECT denied — BT codec/name unavailable")
            }
            pushCurrentSpecs()
        }
    }

    // ── Setup / Teardown ──────────────────────────────────────────────────────
    private fun setupAudioDeviceCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val cb = object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<AudioDeviceInfo>) {
                    Log.d(TAG, "AudioDevicesAdded: ${addedDevices.map { it.type }}")
                    pushCurrentSpecs()
                }

                override fun onAudioDevicesRemoved(removedDevices: Array<AudioDeviceInfo>) {
                    Log.d(TAG, "AudioDevicesRemoved: ${removedDevices.map { it.type }}")
                    pushCurrentSpecs()
                }
            }
            audioDeviceCallback = cb
            audioManager.registerAudioDeviceCallback(cb, mainHandler)
            Log.d(TAG, "AudioDeviceCallback registered")
        }
    }

    private fun teardownAudioDeviceCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioDeviceCallback?.let { audioManager.unregisterAudioDeviceCallback(it) }
            audioDeviceCallback = null
        }
    }

    private fun setupBluetoothProfile() {
        if (!hasBtPermission()) return
        try {
            val bm = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            bluetoothAdapter = bm?.adapter
            bluetoothAdapter?.getProfileProxy(this, btProfileListener, BluetoothProfile.A2DP)
            Log.d(TAG, "BluetoothProfile proxy requested")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to setup BT profile: ${e.message}")
        }
    }

    private fun teardownBluetoothProfile() {
        try {
            bluetoothA2dp?.let {
                bluetoothAdapter?.closeProfileProxy(BluetoothProfile.A2DP, it)
            }
            bluetoothA2dp = null
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close BT profile: ${e.message}")
        }
    }

    private fun registerHardwareReceiver() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_HEADSET_PLUG)
            addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
            addAction(ACTION_CODEC_CONFIG_CHANGED)
            addAction(BluetoothDevice.ACTION_NAME_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(hardwareReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(hardwareReceiver, filter)
            }
            Log.d(TAG, "Hardware BroadcastReceiver registered")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to register Hardware receiver: ${e.message}")
        }
    }

    private fun unregisterHardwareReceiver() {
        try {
            unregisterReceiver(hardwareReceiver)
        } catch (e: Exception) {
            // Ignore if not registered
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock == null) {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifiManager?.createMulticastLock("SautiplayMulticastLock")?.apply {
                setReferenceCounted(true)
            }
        }
        try {
            if (multicastLock?.isHeld == false) {
                multicastLock?.acquire()
                Log.d(TAG, "Wifi MulticastLock acquired")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to acquire Wifi MulticastLock: ${e.message}")
        }
    }

    private fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
                Log.d(TAG, "Wifi MulticastLock released")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to release Wifi MulticastLock: ${e.message}")
        }
    }

    // ── Core Logic ────────────────────────────────────────────────────────────
    private fun pushCurrentSpecs() {
        mainHandler.post {
            try {
                val map = buildSpecsMap()
                eventSink?.success(map)
            } catch (e: Exception) {
                Log.e(TAG, "pushCurrentSpecs error: ${e.message}")
            }
        }
    }

    private fun buildSpecsMap(): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val defaultHalSampleRate = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull() ?: 48000
        val periodFrames = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull() ?: 192

        var deviceName = "Built-in Speaker"
        var sampleRate = defaultHalSampleRate
        var bitDepth = 32
        var isFloat = true
        var deviceType = "Built-in Speaker"
        var btCodec: String? = null
        var btDeviceName: String? = null
        var btSampleRate: Int? = null
        var btBitDepth: Int? = null
        var selectedDeviceTypeCode = -1
        var supportedSampleRates: List<Int> = emptyList()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)

            var bestPriority = -1
            var bestDevice: AudioDeviceInfo? = null

            for (dev in devices) {
                val priority = devicePriority(dev.type)
                if (priority > bestPriority) {
                    bestPriority = priority
                    bestDevice = dev
                }
            }

            bestDevice?.let { dev ->
                selectedDeviceTypeCode = dev.type
                deviceType = mapDeviceType(dev.type)

                val rawName = dev.productName?.toString()
                deviceName = if (!rawName.isNullOrBlank()) {
                    rawName
                } else {
                    fallbackDeviceName(dev.type)
                }

                val (depth, float) = bestEncodingFromDevice(dev)
                bitDepth = depth
                isFloat = float

                val devRates = dev.sampleRates
                if (devRates.isNotEmpty()) {
                    supportedSampleRates = devRates.toList().sorted()
                }

                // If USB DAC or wired headset reports specific hardware sample rates:
                if (selectedDeviceTypeCode == AudioDeviceInfo.TYPE_USB_DEVICE ||
                    selectedDeviceTypeCode == AudioDeviceInfo.TYPE_USB_HEADSET ||
                    selectedDeviceTypeCode == AudioDeviceInfo.TYPE_USB_ACCESSORY
                ) {
                    if (devRates.isNotEmpty()) {
                        sampleRate = devRates.maxOrNull() ?: defaultHalSampleRate
                    }
                } else if (selectedDeviceTypeCode == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                    selectedDeviceTypeCode == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                    selectedDeviceTypeCode == AudioDeviceInfo.TYPE_LINE_ANALOG ||
                    selectedDeviceTypeCode == 19 /* TYPE_AUX_LINE */
                ) {
                    if (devRates.isNotEmpty()) {
                        sampleRate = devRates.maxOrNull() ?: defaultHalSampleRate
                    }
                }
            }
        }

        // Bluetooth codec details when BT route is active
        if (selectedDeviceTypeCode == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
            selectedDeviceTypeCode == 26 /* TYPE_BLUETOOTH_LE */ ||
            selectedDeviceTypeCode == 23 /* TYPE_HEARING_AID */
        ) {
            val btInfo = queryBluetoothCodec()
            btCodec = btInfo?.first
            btDeviceName = btInfo?.second
            btSampleRate = btInfo?.third
            btBitDepth = btInfo?.fourth
            if (!btDeviceName.isNullOrBlank()) {
                deviceName = btDeviceName
            }
            if (btSampleRate != null && btSampleRate > 0) {
                sampleRate = btSampleRate
            }
            if (btBitDepth != null && btBitDepth > 0) {
                bitDepth = btBitDepth
                isFloat = false
            }
        }

        val latencyMs = (periodFrames.toDouble() * 2.0 / sampleRate.toDouble()) * 1000.0

        return mapOf(
            "deviceName" to deviceName,
            "sampleRate" to sampleRate,
            "bitDepth" to bitDepth,
            "isFloat" to isFloat,
            "channels" to 2,
            "periodSizeFrames" to periodFrames,
            "periodCount" to 2,
            "latencyMs" to latencyMs,
            "deviceType" to deviceType,
            "bluetoothCodec" to btCodec,
            "bluetoothDeviceName" to btDeviceName,
            "btSampleRate" to btSampleRate,
            "btBitDepth" to btBitDepth,
            "supportedSampleRates" to supportedSampleRates,
            "androidVersion" to Build.VERSION.SDK_INT,
            "androidRelease" to Build.VERSION.RELEASE,
        )
    }

    private fun devicePriority(type: Int): Int = when (type) {
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> 5

        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        26 /* TYPE_BLUETOOTH_LE */,
        23 /* TYPE_HEARING_AID */ -> 4

        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        19 /* TYPE_AUX_LINE */ -> 3

        AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_HDMI_ARC,
        29 /* TYPE_HDMI_EARC */ -> 2

        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> 1

        else -> 0
    }

    private fun mapDeviceType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB DAC"

        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth Wireless"
        26 /* TYPE_BLUETOOTH_LE */ -> "Bluetooth LE Audio"
        23 /* TYPE_HEARING_AID */ -> "Bluetooth Hearing Aid"

        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "3.5mm Headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "3.5mm Headphones"
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        19 /* TYPE_AUX_LINE */ -> "Line Out (Analog)"

        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Built-in Speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Built-in Earpiece"

        AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_HDMI_ARC,
        29 /* TYPE_HDMI_EARC */ -> "HDMI Audio"

        AudioDeviceInfo.TYPE_DOCK -> "Dock / Accessory"
        else -> "Speakers / Output Device"
    }

    private fun fallbackDeviceName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Audio DAC"

        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth Headphones"
        26 /* TYPE_BLUETOOTH_LE */ -> "Bluetooth LE Device"

        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "3.5mm Wired Headphones"

        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Device Speaker"
        else -> "Output Device"
    }

    private fun bestEncodingFromDevice(dev: AudioDeviceInfo): Pair<Int, Boolean> {
        var maxBits = 16
        var isFloat = false
        for (enc in dev.encodings) {
            when (enc) {
                4  /* ENCODING_PCM_FLOAT */        -> { isFloat = true; if (32 > maxBits) maxBits = 32 }
                21 /* ENCODING_PCM_24BIT_PACKED */ -> if (24 > maxBits) maxBits = 24
                22 /* ENCODING_PCM_32BIT */        -> if (32 > maxBits) maxBits = 32
                2  /* ENCODING_PCM_16BIT */        -> if (16 > maxBits) maxBits = 16
            }
        }
        return Pair(maxBits, isFloat)
    }

    private fun queryBluetoothCodecViaReflection(
        a2dp: BluetoothA2dp,
        device: BluetoothDevice,
        deviceName: String
    ): Quadruple<String, String, Int, Int> {
        try {
            val method = a2dp.javaClass.getMethod("getCodecStatus", BluetoothDevice::class.java)
            val codecStatus = method.invoke(a2dp, device) ?: return Quadruple("SBC", deviceName, 44100, 16)

            val getConfigMethod = codecStatus.javaClass.getMethod("getCodecConfig")
            val config = getConfigMethod.invoke(codecStatus) as? BluetoothCodecConfig
                ?: return Quadruple("SBC", deviceName, 44100, 16)

            val codecName = when (config.codecType) {
                BluetoothCodecConfig.SOURCE_CODEC_TYPE_SBC     -> "SBC"
                BluetoothCodecConfig.SOURCE_CODEC_TYPE_AAC     -> "AAC"
                BluetoothCodecConfig.SOURCE_CODEC_TYPE_APTX    -> "aptX"
                BluetoothCodecConfig.SOURCE_CODEC_TYPE_APTX_HD -> "aptX HD"
                BluetoothCodecConfig.SOURCE_CODEC_TYPE_LDAC    -> "LDAC"
                6 /* SOURCE_CODEC_TYPE_LC3 */                  -> "LC3"
                7 /* SOURCE_CODEC_TYPE_OPUS */                  -> "Opus"
                else                                           -> "SBC"
            }

            val sampleRate = when (config.sampleRate) {
                BluetoothCodecConfig.SAMPLE_RATE_44100  -> 44100
                BluetoothCodecConfig.SAMPLE_RATE_48000  -> 48000
                BluetoothCodecConfig.SAMPLE_RATE_88200  -> 88200
                BluetoothCodecConfig.SAMPLE_RATE_96000  -> 96000
                BluetoothCodecConfig.SAMPLE_RATE_176400 -> 176400
                BluetoothCodecConfig.SAMPLE_RATE_192000 -> 192000
                else                                    -> 44100
            }

            val bits = when (config.bitsPerSample) {
                BluetoothCodecConfig.BITS_PER_SAMPLE_16 -> 16
                BluetoothCodecConfig.BITS_PER_SAMPLE_24 -> 24
                BluetoothCodecConfig.BITS_PER_SAMPLE_32 -> 32
                else                                    -> 16
            }

            return Quadruple(codecName, deviceName, sampleRate, bits)
        } catch (e: Exception) {
            Log.w(TAG, "Reflection getCodecStatus failed: ${e.message}")
            return Quadruple("SBC", deviceName, 44100, 16)
        }
    }

    private fun queryBluetoothCodec(): Quadruple<String, String, Int, Int>? {
        if (!hasBtPermission()) return null
        val a2dp = bluetoothA2dp ?: return null

        return try {
            var connectedDevices: List<BluetoothDevice> = emptyList()
            try {
                @Suppress("DEPRECATION")
                connectedDevices = a2dp.connectedDevices
            } catch (e: Exception) {
                // Ignore exception and try fallback
            }

            if (connectedDevices.isEmpty()) {
                try {
                    connectedDevices = a2dp.getDevicesMatchingConnectionStates(
                        intArrayOf(BluetoothProfile.STATE_CONNECTED)
                    )
                } catch (e: Exception) {
                    // Ignore exception
                }
            }

            if (connectedDevices.isEmpty()) return null

            val device = connectedDevices.first()
            @Suppress("DEPRECATION")
            val name = device.name ?: "Bluetooth Audio Device"

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                queryBluetoothCodecViaReflection(a2dp, device, name)
            } else {
                Quadruple("SBC", name, 44100, 16)
            }
        } catch (e: Exception) {
            Log.w(TAG, "queryBluetoothCodec error: ${e.message}")
            null
        }
    }

    private fun hasBtPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }
}

data class Quadruple<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)
