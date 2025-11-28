import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

enum VoiceChatState {
  idle,
  listening,
  speaking,
}

class VoiceChatProvider with ChangeNotifier {
  final SpeechToText _speechToText = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();
  VoiceChatState _state = VoiceChatState.idle;
  String _lastWords = '';

  VoiceChatState get state => _state;
  String get lastWords => _lastWords;

  VoiceChatProvider() {
    _init();
  }

  Future<void> _init() async {
    await _speechToText.initialize();
    _flutterTts.setCompletionHandler(() {
      _changeState(VoiceChatState.idle);
    });
  }

  void clearLastWords() {
    _lastWords = '';
  }

  void startListening() async {
    if (_state == VoiceChatState.idle) {
      await _speechToText.listen(onResult: _onSpeechResult);
      _changeState(VoiceChatState.listening);
    }
  }

  void stopListening() async {
    if (_state == VoiceChatState.listening) {
      await _speechToText.stop();
      _changeState(VoiceChatState.idle);
    }
  }

  void speak(String text) async {
    if (_state == VoiceChatState.idle) {
      _changeState(VoiceChatState.speaking);
      await _flutterTts.speak(text);
    }
  }

  void _onSpeechResult(result) {
    _lastWords = result.recognizedWords;
    notifyListeners();
    if (result.finalResult) {
      _changeState(VoiceChatState.idle);
    }
  }

  void _changeState(VoiceChatState newState) {
    _state = newState;
    notifyListeners();
  }
}
