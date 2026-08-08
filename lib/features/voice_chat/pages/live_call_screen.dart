import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/live/live_api_session.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../services/platform_audio_setup.dart';

/// Gemini Live API 即時語音通話畫面。
class LiveCallScreen extends StatefulWidget {
  const LiveCallScreen({super.key});

  @override
  State<LiveCallScreen> createState() => _LiveCallScreenState();
}

class _LiveCallScreenState extends State<LiveCallScreen> {
  LiveApiSession? _session;
  bool _permissionGranted = false;
  bool _checkingPermission = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await PlatformAudioSetup.initAudioSessionForVoiceChat();
    await PlatformAudioSetup.activateAudioSession();
    final recorder = AudioRecorder();
    bool ok = false;
    try {
      ok = await recorder.hasPermission();
    } catch (_) {}
    try {
      await recorder.dispose();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _permissionGranted = ok;
      _checkingPermission = false;
    });
    if (!ok) return;
    await _startSession();
  }

  Future<void> _startSession() async {
    final settings = context.read<SettingsProvider>();
    final session = LiveApiSession(
      apiKey: settings.liveApiApiKey,
      model: settings.liveApiModel,
      voice: settings.liveApiVoice,
      baseUrl: settings.resolvedLiveApiBaseUrl,
    );
    session.addListener(_onSessionChanged);
    _session = session;
    unawaited(session.start());
    if (mounted) setState(() {});
  }

  void _onSessionChanged() {
    if (!mounted) return;
    if (_session?.state == LiveCallState.ended) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  Future<void> _retry() async {
    final s = _session;
    if (s != null) {
      s.removeListener(_onSessionChanged);
      _session = null;
      await s.stop();
      s.dispose();
    }
    if (!mounted) return;
    setState(() {});
    await _startSession();
  }

  Future<void> _end() async {
    final s = _session;
    if (s != null) {
      s.removeListener(_onSessionChanged);
      _session = null;
      await s.stop();
      s.dispose();
    }
    await PlatformAudioSetup.deactivateAudioSession();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_onSessionChanged);
    _session?.dispose();
    unawaited(PlatformAudioSetup.deactivateAudioSession());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final session = _session;

    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2C2C2C), Color(0xFF1E1E1E)],
              ),
            ),
          ),
          Column(
            children: [
              SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _end,
                      icon: const Icon(Lucide.X, color: Colors.white),
                    ),
                    const Spacer(),
                    Text(
                      l10n.liveCallTitle,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _buildStatus(context),
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: SingleChildScrollView(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: _buildSubtitle(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (session != null) {
                          unawaited(session.setMuted(!session.muted));
                        }
                      },
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: Icon(
                          session?.muted ?? false
                              ? Lucide.MicOff
                              : Lucide.Mic,
                          color: session?.muted ?? false
                              ? Colors.orange.shade300
                              : Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: _end,
                      child: SizedBox(
                        width: 80,
                        height: 80,
                        child: Icon(
                          Lucide.CircleStop,
                          color: Colors.red.shade300,
                          size: 64,
                        ),
                      ),
                    ),
                    const SizedBox(width: 60),
                  ],
                ),
              ),
            ],
          ),
          if (_checkingPermission)
            Container(color: const Color(0xCC000000))
          else if (!_permissionGranted)
            Container(
              color: const Color(0x99000000),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Lucide.MicOff,
                      size: 64,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.voiceChatPermissionRequired,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _init,
                      child: Text(l10n.voiceChatPermissionButton),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = _session;
    if (session == null) {
      return Text(
        l10n.liveCallConnecting,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      );
    }
    switch (session.state) {
      case LiveCallState.connecting:
        return Text(
          l10n.liveCallConnecting,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        );
      case LiveCallState.active:
        return Text(
          session.muted ? l10n.liveCallMuted : l10n.liveCallActive,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: session.muted
                ? Colors.orange.shade300
                : Colors.green.shade400,
          ),
        );
      case LiveCallState.error:
        return Column(
          children: [
            Text(
              l10n.liveCallError,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.red,
              ),
            ),
            if (session.errorMessage.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                session.errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _retry,
              icon: const Icon(Lucide.RefreshCw, size: 18),
              label: Text(l10n.liveCallRetry),
            ),
          ],
        );
      case LiveCallState.idle:
      case LiveCallState.ended:
        return const SizedBox.shrink();
    }
  }

  Widget _buildSubtitle(BuildContext context) {
    final session = _session;
    final text = session == null
        ? ''
        : session.assistantPartial.trim().isNotEmpty
            ? session.assistantPartial
            : session.turns.isEmpty
                ? ''
                : session.turns.last;
    if (text.isEmpty) {
      return const Icon(
        Lucide.AudioWaveform,
        size: 32,
        color: Colors.white38,
      );
    }
    return Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 16, color: Colors.white),
    );
  }
}
