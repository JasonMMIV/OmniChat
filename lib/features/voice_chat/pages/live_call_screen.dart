import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/live/live_api_session.dart';
import '../../../core/services/live/live_tools.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../services/platform_audio_setup.dart';

/// Gemini Live API 即時語音通話畫面。
class LiveCallScreen extends StatefulWidget {
  const LiveCallScreen({super.key, this.sessionFactory});

  /// 測試 seam：注入 session 建構方式（預設依 [SettingsProvider] 建立）。
  final LiveApiSession Function(SettingsProvider settings)? sessionFactory;

  @override
  State<LiveCallScreen> createState() => _LiveCallScreenState();
}

class _LiveCallScreenState extends State<LiveCallScreen>
    with WidgetsBindingObserver {
  LiveApiSession? _session;
  bool _permissionGranted = false;
  bool _checkingPermission = true;

  /// 字幕開關（與標準語音模式一致）。
  bool _showSubtitles = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  /// §5.7 lifecycle：背景/前景切換接到 session 的 pause/resume
  /// （背景停止 mic + stream end，前景重啟 mic；不會重複建立資源）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final s = _session;
    if (s == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(s.resume());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break; // 短暫轉場/終結：不動作，避免 mic 反覆重啟
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        unawaited(s.pause());
    }
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
    // §5.4：與標準語音流程共用 call mode（audio focus / Bluetooth SCO /
    // speaker 路由 / mic unmute）；權限通過後才啟動。
    // 用 defaultTargetPlatform（而非 Platform.isAndroid）以便測試可覆寫。
    if (defaultTargetPlatform == TargetPlatform.android) {
      await PlatformAudioSetup.startCallMode();
    }
    await _startSession();
  }

  Future<void> _startSession() async {
    final settings = context.read<SettingsProvider>();
    final factory = widget.sessionFactory;
    final session = factory != null
        ? factory(settings)
        : LiveApiSession(
            apiKey: settings.liveApiApiKey,
            model: settings.liveApiModel,
            voice: settings.liveApiVoice,
            baseUrl: settings.resolvedLiveApiBaseUrl,
            // Function calling：宣告內建工具並以本地執行器回應。
            // search_web 需要 settings 解析使用者選定的搜尋服務。
            tools: builtInLiveTools,
            toolHandler: (name, args) async =>
                runBuiltInLiveTool(name, args, settings: settings),
            // C1：播放器 audioFocus none（保留 call mode 路由），減少包間隙
            playbackAudioContext:
                await PlatformAudioSetup.playbackAudioContext(),
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

  /// 切換字幕顯示（關閉時保留字幕區塊避免 layout 跳動，與標準模式一致）。
  void _toggleSubtitle() {
    setState(() {
      _showSubtitles = !_showSubtitles;
    });
  }

  Future<void> _end() async {
    final s = _session;
    if (s != null) {
      s.removeListener(_onSessionChanged);
      _session = null;
      await s.stop();
      s.dispose();
    }
    // §5.4：結束通話釋放 audio focus 與 call mode（與 startCallMode 對稱）。
    await PlatformAudioSetup.deactivateAudioSession();
    if (defaultTargetPlatform == TargetPlatform.android) {
      await PlatformAudioSetup.stopCallMode();
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.removeListener(_onSessionChanged);
    _session?.dispose();
    // §5.4：所有退出路徑（返回鍵、goAway 自動關閉、錯誤後離開）都必須
    // 釋放 audio focus 與 call mode，避免通話結束後持續佔用音訊資源。
    unawaited(PlatformAudioSetup.deactivateAudioSession());
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(PlatformAudioSetup.stopCallMode());
    }
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
                          child: _showSubtitles
                              ? _buildSubtitle(context)
                              : const SizedBox.shrink(),
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
                    // 右下角：字幕開關（與標準語音模式一致）
                    GestureDetector(
                      onTap: _toggleSubtitle,
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: Icon(
                          _showSubtitles ? Lucide.Captions : Lucide.CaptionsOff,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
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
      case LiveCallState.reconnecting:
        return Column(
          children: [
            Text(
              l10n.liveCallReconnecting,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.orange.shade300,
              ),
            ),
            if (session.errorMessage.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                session.errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ],
        );
      case LiveCallState.background:
        return Text(
          l10n.liveCallBackground,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white54,
          ),
        );
      case LiveCallState.active:
        final pending = session.pendingToolCalls;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              session.muted ? l10n.liveCallMuted : l10n.liveCallActive,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: session.muted
                    ? Colors.orange.shade300
                    : Colors.green.shade400,
              ),
            ),
            if (pending.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '${l10n.liveCallToolRunning}：'
                '${pending.map((c) => c.name).join(', ')}',
                style: const TextStyle(fontSize: 12, color: Colors.amber),
              ),
            ],
          ],
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
    // 優先顯示進行中的模型回覆；其次使用者語音即時轉錄；
    // 最後退回上一個完成的模型回合。
    final text = session == null
        ? ''
        : session.assistantPartial.trim().isNotEmpty
            ? session.assistantPartial
            : session.userPartial.trim().isNotEmpty
                ? session.userPartial
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
