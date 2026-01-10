import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';

/// Windows implementation of the speech_to_text plugin using UWP Speech APIs
class SpeechToTextWindows extends SpeechToTextPlatform {
  static const MethodChannel _channel = MethodChannel('speech_to_text_windows');

  /// Registers this class as the default instance of [SpeechToTextPlatform]
  static void registerWith() {
    SpeechToTextPlatform.instance = SpeechToTextWindows();
  }

  SpeechToTextWindows() {
    // Do nothing for now
  }

  @override
  Future<bool> hasPermission() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>('hasPermission');
      return result ?? false;
    } catch (e) {
      if (kDebugMode) {
        print('Error checking microphone permission: $e');
      }
      return false;
    }
  }

  @override
  Future<bool> initialize({
    debugLogging = false,
    List<SpeechConfigOption>? options,
  }) async {
    // Set up method call handler when initialize is called
    _channel.setMethodCallHandler(_handleMethodCall);
    
    final Map<String, dynamic> params = {
      'debugLogging': debugLogging,
    };
    
    // Process Windows-specific options
    if (options != null) {
      for (final option in options) {
        if (option.platform == 'windows') {
          params[option.name] = option.value;
        }
      }
    }

    try {
      final bool? result = await _channel.invokeMethod<bool>('initialize', params);
      return result ?? false;
    } catch (e) {
      if (kDebugMode) {
        print('Error initializing Windows speech recognition: $e');
      }
      return false;
    }
  }

  @override
  Future<bool> listen({
    String? localeId,
    @Deprecated('Use SpeechListenOptions.partialResults instead')
    partialResults = true,
    @Deprecated('Use SpeechListenOptions.onDevice instead') 
    onDevice = false,
    @Deprecated('Use SpeechListenOptions.listenMode instead')
    int listenMode = 0,
    @Deprecated('Use SpeechListenOptions.sampleRate instead') 
    sampleRate = 0,
    SpeechListenOptions? options,
  }) async {
    final Map<String, dynamic> params = {
      'localeId': localeId,
      'partialResults': options?.partialResults ?? partialResults,
      'onDevice': options?.onDevice ?? onDevice,
      'listenMode': options?.listenMode.index ?? listenMode,
      'sampleRate': options?.sampleRate ?? sampleRate,
      'autoPunctuation': options?.autoPunctuation ?? false,
      'enableHapticFeedback': options?.enableHapticFeedback ?? false,
      'cancelOnError': options?.cancelOnError ?? false,
    };

    try {
      final bool? result = await _channel.invokeMethod<bool>('listen', params);
      return result ?? false;
    } catch (e) {
      if (kDebugMode) {
        print('Error starting speech recognition: $e');
      }
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      if (kDebugMode) {
        print('Error stopping speech recognition: $e');
      }
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (e) {
      if (kDebugMode) {
        print('Error canceling speech recognition: $e');
      }
    }
  }

  @override
  Future<List<dynamic>> locales() async {
    try {
      final List<dynamic>? result = await _channel.invokeMethod<List<dynamic>>('locales');
      return result ?? [];
    } catch (e) {
      if (kDebugMode) {
        print('Error getting supported locales: $e');
      }
      return [];
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'textRecognition':
          if (call.arguments is String && onTextRecognition != null) {
            // Windows native sends: {"recognizedWords":"...", "finalResult": true}
            // But speech_to_text expects: {"alternates":[{"recognizedWords":"...", "confidence": 1.0}], "finalResult": true}
            // We need to transform the JSON to match the expected format
            final transformedJson = _transformRecognitionResult(call.arguments);
            onTextRecognition!(transformedJson);
          }
          break;
        case 'notifyError':
          if (call.arguments is String && onError != null) {
            onError!(call.arguments);
          }
          break;
        case 'notifyStatus':
          if (call.arguments is String && onStatus != null) {
            onStatus!(call.arguments);
          }
          break;
        case 'soundLevelChange':
          if (call.arguments is double && onSoundLevel != null) {
            onSoundLevel!(call.arguments);
          }
          break;
        default:
          if (kDebugMode) {
            print('Unknown method call: ${call.method}');
          }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error handling method call ${call.method}: $e');
      }
    }
  }

  /// Transform the Windows native JSON format to the format expected by speech_to_text
  ///
  /// Windows native sends: {"recognizedWords":"...", "finalResult": true}
  /// speech_to_text expects: {"alternates":[{"recognizedWords":"...", "recognizedPhrases": null, "confidence": 1.0}], "finalResult": true}
  String _transformRecognitionResult(String originalJson) {
    try {
      final Map<String, dynamic> original = jsonDecode(originalJson);

      // Check if already in the correct format (has 'alternates' key)
      if (original.containsKey('alternates')) {
        return originalJson;
      }

      // Transform to expected format
      final String recognizedWords = original['recognizedWords'] as String? ?? '';
      final bool finalResult = original['finalResult'] as bool? ?? false;
      final double confidence = (original['confidence'] as num?)?.toDouble() ?? 1.0;

      final Map<String, dynamic> transformed = {
        'alternates': [
          {
            'recognizedWords': recognizedWords,
            'recognizedPhrases': null,
            'confidence': confidence,
          }
        ],
        'finalResult': finalResult,
      };

      return jsonEncode(transformed);
    } catch (e) {
      if (kDebugMode) {
        print('Error transforming recognition result: $e');
      }
      // Return original if transformation fails
      return originalJson;
    }
  }
}