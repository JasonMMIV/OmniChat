package com.psyche.omnichat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "omnichat/call_mode"
    private val TAG = "OmniChatCallMode"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startCallMode" -> {
                    val ok = startCallMode()
                    result.success(ok)
                }
                "stopCallMode" -> {
                    stopCallMode()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var scoActive = false
    private var scoReceiver: BroadcastReceiver? = null
    private val handler = Handler(Looper.getMainLooper())

    // SCO keep-alive mechanism
    private var scoKeepAliveRunnable: Runnable? = null
    private val SCO_KEEPALIVE_INTERVAL = 5000L // 5 seconds

    // Silent audio track to keep SCO alive
    private var silentAudioTrack: AudioTrack? = null
    private var silentAudioThread: Thread? = null
    private var silentAudioRunning = false

    private fun ensureAudioManager(): AudioManager {
        if (audioManager == null) {
            audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        }
        return audioManager!!
    }

    private fun isBluetoothHeadsetConnected(): Boolean {
        val am = ensureAudioManager()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            for (device in devices) {
                if (device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP) {
                    return true
                }
            }
            return false
        }
        return am.isBluetoothScoAvailableOffCall
    }

    private fun startCallMode(): Boolean {
        val am = ensureAudioManager()

        Log.d(TAG, "Starting call mode...")
        Log.d(TAG, "Bluetooth SCO available: ${am.isBluetoothScoAvailableOffCall}")
        Log.d(TAG, "Bluetooth headset connected: ${isBluetoothHeadsetConnected()}")

        // Register SCO state receiver
        if (scoReceiver == null) {
            scoReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    val state = intent?.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)
                    Log.d(TAG, "SCO state changed: $state")
                    when (state) {
                        AudioManager.SCO_AUDIO_STATE_CONNECTED -> {
                            Log.d(TAG, "SCO connected - audio routed to Bluetooth")
                            am.isBluetoothScoOn = true
                        }
                        AudioManager.SCO_AUDIO_STATE_DISCONNECTED -> {
                            Log.d(TAG, "SCO disconnected")
                        }
                        AudioManager.SCO_AUDIO_STATE_CONNECTING -> {
                            Log.d(TAG, "SCO connecting...")
                        }
                    }
                }
            }
            val filter = IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(scoReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(scoReceiver, filter)
            }
        }

        // Request audio focus first - use appropriate stream based on connection
        var focusGranted = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // For Bluetooth, use voice communication; for speaker, use media
            val audioAttributes = if (isBluetoothHeadsetConnected()) {
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)  // For Bluetooth
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            } else {
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)  // For speaker output
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            }

            focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(audioAttributes)
                .setOnAudioFocusChangeListener { focusChange ->
                    Log.d(TAG, "Audio focus changed: $focusChange")
                }
                .build()
            focusGranted = am.requestAudioFocus(focusRequest!!) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            // For older Android versions, use appropriate stream based on connection
            val streamType = if (isBluetoothHeadsetConnected()) {
                AudioManager.STREAM_VOICE_CALL  // For Bluetooth
            } else {
                AudioManager.STREAM_MUSIC  // For speaker output
            }
            focusGranted = am.requestAudioFocus(null, streamType, AudioManager.AUDIOFOCUS_GAIN) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        Log.d(TAG, "Audio focus granted: $focusGranted")

        // Set communication mode (only for Bluetooth scenarios)
        if (isBluetoothHeadsetConnected()) {
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            Log.d(TAG, "Audio mode set to MODE_IN_COMMUNICATION for Bluetooth")
        } else {
            am.mode = AudioManager.MODE_NORMAL  // Use normal mode to allow speaker output
            Log.d(TAG, "Audio mode set to MODE_NORMAL for speaker output")
        }

        // For Bluetooth, disable speakerphone; for speaker, ensure it's available
        if (isBluetoothHeadsetConnected()) {
            am.isSpeakerphoneOn = false
            Log.d(TAG, "Speakerphone disabled for Bluetooth")
        } else {
            am.isSpeakerphoneOn = true  // Ensure speaker is available for non-Bluetooth
            Log.d(TAG, "Speakerphone enabled for speaker output")
        }

        // Unmute microphone
        am.isMicrophoneMute = false

        // Start Bluetooth SCO if available
        if (am.isBluetoothScoAvailableOffCall && !scoActive) {
            Log.d(TAG, "Starting Bluetooth SCO...")
            am.startBluetoothSco()
            scoActive = true

            // Give SCO time to connect, then enable it
            handler.postDelayed({
                if (scoActive) {
                    am.isBluetoothScoOn = true
                    Log.d(TAG, "Bluetooth SCO enabled")
                    // Start keep-alive after SCO is connected
                    startScoKeepAlive()
                    // Start silent audio to keep SCO alive
                    startSilentAudio()
                }
            }, 500)
        } else {
            Log.d(TAG, "Bluetooth SCO not available or already active")
            // Still start silent audio for non-Bluetooth scenarios
            startSilentAudio()
        }

        return focusGranted
    }

    private fun startScoKeepAlive() {
        stopScoKeepAlive() // Clear any existing

        scoKeepAliveRunnable = object : Runnable {
            override fun run() {
                if (scoActive) {
                    val am = ensureAudioManager()
                    // Only reconnect if SCO was disconnected by the system
                    if (!am.isBluetoothScoOn) {
                        Log.d(TAG, "SCO disconnected by system, attempting to reconnect...")
                        // Don't stop first, just try to start again
                        am.startBluetoothSco()
                        handler.postDelayed({
                            if (scoActive) {
                                am.isBluetoothScoOn = true
                                Log.d(TAG, "SCO reconnected")
                            }
                        }, 300)
                    }
                    // Schedule next check
                    handler.postDelayed(this, SCO_KEEPALIVE_INTERVAL)
                }
            }
        }
        handler.postDelayed(scoKeepAliveRunnable!!, SCO_KEEPALIVE_INTERVAL)
        Log.d(TAG, "SCO keep-alive started")
    }

    private fun stopScoKeepAlive() {
        scoKeepAliveRunnable?.let {
            handler.removeCallbacks(it)
            scoKeepAliveRunnable = null
            Log.d(TAG, "SCO keep-alive stopped")
        }
    }

    private fun startSilentAudio() {
        if (silentAudioRunning) return

        silentAudioRunning = true
        silentAudioThread = Thread {
            try {
                val sampleRate = 8000
                val bufferSize = AudioTrack.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )

                val audioAttributes = if (isBluetoothHeadsetConnected()) {
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION) // For Bluetooth
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                } else {
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA) // For speaker
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                }

                val audioFormat = AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()

                silentAudioTrack = AudioTrack.Builder()
                    .setAudioAttributes(audioAttributes)
                    .setAudioFormat(audioFormat)
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()

                silentAudioTrack?.play()
                Log.d(TAG, "Silent audio started")

                // Write silence continuously
                val silentBuffer = ByteArray(bufferSize)
                while (silentAudioRunning && silentAudioTrack != null) {
                    silentAudioTrack?.write(silentBuffer, 0, silentBuffer.size)
                    Thread.sleep(100) // Small delay to reduce CPU usage
                }
            } catch (e: Exception) {
                Log.e(TAG, "Silent audio error: ${e.message}")
            }
        }
        silentAudioThread?.start()
    }

    private fun stopSilentAudio() {
        silentAudioRunning = false
        try {
            silentAudioTrack?.stop()
            silentAudioTrack?.release()
            silentAudioTrack = null
            silentAudioThread?.interrupt()
            silentAudioThread = null
            Log.d(TAG, "Silent audio stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping silent audio: ${e.message}")
        }
    }

    private fun stopCallMode() {
        val am = ensureAudioManager()
        Log.d(TAG, "Stopping call mode...")

        // Stop silent audio first
        stopSilentAudio()

        // Stop keep-alive
        stopScoKeepAlive()

        // Unregister receiver
        scoReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {
                Log.e(TAG, "Error unregistering receiver: ${e.message}")
            }
            scoReceiver = null
        }

        // Stop Bluetooth SCO
        if (scoActive) {
            am.isBluetoothScoOn = false
            am.stopBluetoothSco()
            scoActive = false
            Log.d(TAG, "Bluetooth SCO stopped")
        }

        // Reset audio mode
        am.mode = AudioManager.MODE_NORMAL
        am.isSpeakerphoneOn = true
        Log.d(TAG, "Audio mode reset to NORMAL")

        // Abandon audio focus
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let {
                am.abandonAudioFocusRequest(it)
                focusRequest = null
            }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(null)
        }
        Log.d(TAG, "Audio focus abandoned")
    }

    override fun onDestroy() {
        stopCallMode()
        super.onDestroy()
    }
}
