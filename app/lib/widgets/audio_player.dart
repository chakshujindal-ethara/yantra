import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/portal_tokens.dart';
import 'audio_engine.dart';

/// Plays a clip whose address is fetched on the first Play (a presigned link that lives five minutes):
/// play and pause, the position as a slider you can drag, the time, and what went wrong.
class AudioPlayer extends StatefulWidget {
  const AudioPlayer({super.key, required this.url, this.label = 'Audio', this.engine});

  /// Fetches a playable URL; called on the first Play and again after an error.
  final Future<String> Function() url;
  final String label;

  /// Tests pass a [MemoryAudioEngine]; the app uses the platform's.
  final AudioEngine? engine;

  @override
  State<AudioPlayer> createState() => _AudioPlayerState();
}

class _AudioPlayerState extends State<AudioPlayer> {
  late final AudioEngine _engine = widget.engine ?? createAudioEngine();
  bool _loaded = false;
  bool _loading = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _engine
      ..onTime = (p, d) {
        if (mounted) {
          setState(() {
            _position = p;
            _duration = d;
          });
        }
      }
      ..onEnded = () {
        if (mounted) setState(() => _playing = false);
      }
      ..onError = (m) {
        if (mounted) {
          setState(() {
            _error = m;
            _playing = false;
            _loaded = false; // the link may have expired: the next Play fetches a fresh one
          });
        }
      };
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      _engine.pause();
      setState(() => _playing = false);
      return;
    }
    setState(() => _error = null);
    if (!_loaded) {
      setState(() => _loading = true);
      try {
        _engine.load(await widget.url());
        _loaded = true;
      } on Object catch (e) {
        if (mounted) setState(() => _error = describeError(e));
        return;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
    await _engine.play();
    if (mounted && _error == null) setState(() => _playing = true);
  }

  static String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    final theme = Theme.of(context);
    if (!_engine.supported) {
      return Row(
        key: const Key('audio-unsupported'),
        children: [
          Icon(Icons.volume_off_outlined, size: Sizes.iconSm, color: t.textMuted),
          const SizedBox(width: Space.x8),
          Expanded(
            child: Text('${widget.label}: audio plays in the browser', style: theme.textTheme.bodySmall?.copyWith(color: t.textSecondary)),
          ),
        ],
      );
    }
    final max = _duration.inMilliseconds.toDouble();
    return Container(
      key: const Key('audio-player'),
      padding: const EdgeInsets.symmetric(horizontal: Space.x8, vertical: Space.x4),
      decoration: BoxDecoration(
        color: t.bgMuted,
        borderRadius: Radii.rMd,
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('audio-play'),
                tooltip: _playing ? 'Pause ${widget.label}' : 'Play ${widget.label}',
                onPressed: _loading ? null : _toggle,
                icon: _loading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill, color: t.primary, size: 32),
              ),
              Expanded(
                child: Slider(
                  key: const Key('audio-seek'),
                  value: max <= 0 ? 0 : _position.inMilliseconds.clamp(0, max).toDouble(),
                  max: max <= 0 ? 1 : max,
                  semanticFormatterCallback: (_) => '${_clock(_position)} of ${_clock(_duration)}',
                  onChanged: max <= 0 ? null : (v) => _engine.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Text('${_clock(_position)} / ${_clock(_duration)}', style: AppTheme.figure(context)),
              const SizedBox(width: Space.x8),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.x8, 0, Space.x8, Space.x6),
              child: Text(
                _error!,
                key: const Key('audio-error'),
                style: theme.textTheme.bodySmall?.copyWith(color: t.destText),
              ),
            ),
        ],
      ),
    );
  }
}
