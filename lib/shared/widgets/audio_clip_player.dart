import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/services/api/attachment_kind.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/sandbox_path_resolver.dart';

/// Inline player for a locally stored audio attachment.
///
/// Used by the user-message attachment card and the composer attachment chip.
/// The widget owns one [AudioPlayer], checks file availability asynchronously
/// (multimodal plan §2.3-4: never `existsSync` on the UI isolate) and degrades
/// to a disabled "unavailable" state instead of throwing.
class AudioClipPlayer extends StatefulWidget {
  const AudioClipPlayer({
    super.key,
    required this.path,
    required this.fileName,
    this.compact = false,
  });

  final String path;
  final String fileName;

  /// Composer chips are 48 px tall — the compact variant renders only the
  /// play button and a one-line file name.
  final bool compact;

  @override
  State<AudioClipPlayer> createState() => _AudioClipPlayerState();
}

class _AudioClipPlayerState extends State<AudioClipPlayer> {
  /// Only one clip plays at a time; starting another pauses the previous one.
  static _AudioClipPlayerState? _active;

  AudioPlayer? _player;
  StreamSubscription<void>? _completeSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<void>? _playerStateSub;

  bool? _available;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  String get _fixedPath => SandboxPathResolver.fix(widget.path);

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    var ok = false;
    try {
      final file = File(_fixedPath);
      ok = await file.exists() && await file.length() > 0;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _available = ok);
    if (ok && mounted) await _ensurePlayer();
  }

  Future<void> _pauseForOther() async {
    try {
      await _player?.pause();
    } catch (_) {}
    if (mounted) setState(() => _playing = false);
  }

  Future<AudioPlayer?> _ensurePlayer() async {
    if (_player != null) return _player;
    try {
      final player = AudioPlayer();
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        await player.setPlayerMode(PlayerMode.mediaPlayer);
      }
      await player.setReleaseMode(ReleaseMode.stop);
      _completeSub = player.onPlayerComplete.listen((_) {
        if (!mounted) return;
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      });
      _positionSub = player.onPositionChanged.listen((p) {
        if (!mounted) return;
        setState(() => _position = p);
      });
      _durationSub = player.onDurationChanged.listen((d) {
        if (!mounted) return;
        setState(() => _duration = d);
      });
      _playerStateSub = player.onPlayerStateChanged.listen((state) {
        if (!mounted) return;
        final playing = state == PlayerState.playing;
        if (playing != _playing) setState(() => _playing = playing);
      });
      _player = player;
      return player;
    } catch (_) {
      return null;
    }
  }

  Future<void> _toggle() async {
    if (_available != true) return;
    final player = await _ensurePlayer();
    if (player == null) {
      if (mounted) setState(() => _available = false);
      return;
    }
    try {
      if (_playing) {
        await player.pause();
        if (_active == this) _active = null;
      } else {
        final previous = _active;
        if (previous != null && previous != this) {
          await previous._pauseForOther();
        }
        if (_position > Duration.zero && _position < _duration) {
          await player.resume();
        } else {
          await player.play(DeviceFileSource(_fixedPath));
        }
        _active = this;
      }
    } catch (_) {
      if (_active == this) _active = null;
      if (mounted) {
        setState(() {
          _available = false;
          _playing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    if (_active == this) _active = null;
    _completeSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  String get _statusText {
    if (_available == null) return '…';
    if (_available == false) {
      return AppLocalizations.of(context)?.attachmentUnavailable ?? 'Unavailable';
    }
    final total = _duration.inMilliseconds;
    if (total <= 0) {
      final ext = attachmentExtension(widget.fileName).toUpperCase();
      if (ext.isNotEmpty) return ext;
      return AppLocalizations.of(context)?.attachmentAudioLabel ?? 'Audio';
    }
    final pos = _format(_position);
    return '$pos / ${_format(_duration)}';
  }

  static String _format(Duration d) {
    final totalSeconds = d.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString();
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context);
    final available = _available != false;
    final bg = isDark ? Colors.white12 : cs.surface;
    final radius = BorderRadius.circular(widget.compact ? 10 : 12);
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    final playButton = Semantics(
      button: true,
      label: _playing
          ? (l10n?.attachmentPause ?? 'Pause')
          : (l10n?.attachmentPlay ?? 'Play'),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: available ? _toggle : null,
        child: Container(
          width: widget.compact ? 26 : 32,
          height: widget.compact ? 26 : 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: available
                ? cs.primary.withOpacity(isDark ? 0.28 : 0.16)
                : cs.onSurface.withOpacity(0.08),
          ),
          child: Icon(
            !available
                ? Icons.volume_off_rounded
                : (_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            size: widget.compact ? 16 : 19,
            color: available
                ? cs.primary
                : cs.onSurface.withOpacity(0.4),
          ),
        ),
      ),
    );

    return Container(
      constraints: BoxConstraints(maxWidth: widget.compact ? 220 : 300),
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 6 : 10,
        vertical: widget.compact ? 4 : 8,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        boxShadow: isDark || widget.compact ? const [] : const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          playButton,
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: widget.compact ? 12.5 : 13,
                    fontWeight: FontWeight.w600,
                    color: available
                        ? cs.onSurface
                        : cs.onSurface.withOpacity(0.55),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  _statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: available
                        ? cs.onSurface.withOpacity(0.58)
                        : cs.error.withOpacity(0.75),
                  ),
                ),
                if (!widget.compact && available && _duration > Duration.zero)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 2.5,
                        backgroundColor: cs.onSurface.withOpacity(0.10),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          cs.primary.withOpacity(0.7),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
