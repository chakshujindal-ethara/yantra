/// The WEB half of the audio plate: a real HTML5 `<audio controls>` element.
///
/// Selected by the conditional export in `audio_plate.dart`. Mirrors
/// `video_plate_web.dart`'s mechanics (content-keyed view type registered once,
/// nothing read off `widget` inside the factory, bearer fetch for admin proxies)
/// because that file has already been through the failures this one would
/// otherwise repeat. Differences: no poster, no YouTube/Vimeo embed, and a short
/// dark plate with the clip name above the browser's own controls.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../../data/api_client.dart' show mediaAuthHeaders, resolveMediaUrl;
import '../../domain/models.dart';
import '../../theme.dart';
import 'clip_controls.dart';
import 'video_plate.dart' show audioClipName;
import 'video_plate_web.dart' show MediaElementView, mediaNeedsBearer;

/// The browser's own audio control bar is about this tall; the platform view has
/// no intrinsic size, so the plate supplies it.
const double _kControlsHeight = 54;

class AudioPlate extends StatefulWidget {
  const AudioPlate({
    super.key,
    required this.asset,
    this.caption = '',
    this.allowDownload = false,
    this.controls,
  });

  final Asset asset;
  final String caption;

  /// −3 s / +3 s / Speed around the player, for the Transcription question.
  /// Null everywhere else: the plate is then exactly the plain player.
  final ClipControls? controls;

  /// Off by default, for the same reason as the video plate: a candidate who can
  /// download the clip can share it.
  final bool allowDownload;

  @override
  State<AudioPlate> createState() => _AudioPlateState();
}

class _AudioPlateState extends State<AudioPlate> {
  /// `registerViewFactory` THROWS on a repeated id and this widget rebuilds with
  /// its plate, so the guard is not an optimisation. Static: the registry is
  /// process-wide.
  static final Set<String> _registered = <String>{};

  /// Two mounts of the same clip mint two different `blob:` URLs and the first
  /// is revoked with its widget, so a blob view type must never be reused.
  static int _blobSeq = 0;

  String? _viewType;

  /// The object URL this state minted and owes a revoke on.
  String? _objectUrl;

  bool _failed = false;

  /// Bumped by every [_start]; an in-flight fetch compares it before touching
  /// state, so a fast source change cannot let the older clip land on the newer.
  int _load = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(AudioPlate old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id || old.asset.url != widget.asset.url) {
      _start();
    }
  }

  @override
  void dispose() {
    widget.controls?.unbind();
    _revoke();
    super.dispose();
  }

  /// Point [AudioPlate.controls] at the element the view just created.
  void _bind(web.HTMLElement element) {
    final ClipControls? controls = widget.controls;
    if (controls == null) return;
    final web.HTMLMediaElement media = element as web.HTMLMediaElement;
    controls.bind(
      seek: (double seconds) {
        final double at = media.currentTime + seconds;
        final double end = media.duration;
        media.currentTime = at < 0 ? 0 : (end.isFinite && at > end ? end : at);
      },
      applyRate: (double rate) => media.playbackRate = rate,
      toggle: () {
        if (media.paused) {
          // A refused play() (no user gesture yet) is not an error worth a log.
          media.play().toDart.ignore();
        } else {
          media.pause();
        }
      },
    );
  }

  /// Never calls `setState`: it runs from [initState] and [didUpdateWidget],
  /// both followed by a build. Only the async completion asks for one.
  void _start() {
    final int serial = ++_load;
    _revoke();
    _viewType = null;
    _failed = false;

    final String? src = widget.asset.url;
    if (src == null || src.isEmpty) return;

    final String url = resolveMediaUrl(src);
    if (!mediaNeedsBearer(url)) {
      // The candidate path, the signed-out case, and anything hosted elsewhere:
      // the element loads it itself, with no credential of ours.
      _viewType = _register(
        'etp-audio-${widget.allowDownload}-${widget.asset.id}-${url.hashCode}',
        url,
      );
      return;
    }
    unawaited(_loadWithBearer(url, serial));
  }

  /// Pull the clip with the `Authorization` header and republish it as a blob -
  /// a DOM media element cannot send one itself.
  Future<void> _loadWithBearer(String url, int serial) async {
    final web.Blob blob;
    try {
      final web.Headers headers = web.Headers();
      for (final MapEntry<String, String> h in mediaAuthHeaders.entries) {
        headers.append(h.key, h.value);
      }
      final web.Response res = await web.window
          .fetch(url.toJS, web.RequestInit(method: 'GET', headers: headers))
          .toDart;
      // A refused GET answers with a JSON or HTML body that would happily become
      // a blob the element then fails to decode.
      if (!res.ok) throw StateError('HTTP ${res.status}');
      blob = await res.blob().toDart;
    } catch (_) {
      if (!mounted || serial != _load) return;
      setState(() => _failed = true);
      return;
    }

    final String minted = web.URL.createObjectURL(blob);
    if (!mounted || serial != _load) {
      web.URL.revokeObjectURL(minted);
      return;
    }
    setState(() {
      _objectUrl = minted;
      _viewType = _register('etp-audio-blob-${_blobSeq++}', minted);
    });
  }

  void _revoke() {
    final String? held = _objectUrl;
    if (held == null) return;
    _objectUrl = null;
    web.URL.revokeObjectURL(held);
  }

  /// Register [type] to play [url], once. [allowDownload] is read here, not in
  /// the closure: the registry outlives this state.
  String _register(String type, String url) {
    if (_registered.add(type)) {
      final bool allowDownload = widget.allowDownload;
      // The element's own name for a screen reader, which otherwise announces
      // a bare "audio" with no word on which clip it is.
      final String name = audioClipName(widget.asset, widget.caption);
      ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
        final web.HTMLAudioElement el = web.HTMLAudioElement()
          ..src = url
          ..controls = true
          // Metadata only: the duration shows without pulling a 100 MB file the
          // candidate may never play. No autoplay - the clip must not start
          // talking before the candidate has their sound set.
          ..preload = 'metadata'
          ..autoplay = false
          ..style.width = '100%'
          ..style.height = '100%';
        el.setAttribute('aria-label', name);
        if (!allowDownload) {
          // Hides the download item in Chrome's menu. Not a security control -
          // the bytes are in the page - just the obvious affordance.
          el.setAttribute('controlsList', 'nodownload');
          el.oncontextmenu = (web.Event e) {
            e.preventDefault();
          }.toJS;
        }
        return el;
      });
    }
    return type;
  }

  @override
  Widget build(BuildContext context) {
    final String? src = widget.asset.url;
    if (src == null || src.isEmpty || _failed) return const _MissingAudio();
    final String? type = _viewType;
    final ClipControls? controls = widget.controls;
    final Widget player = SizedBox(
      height: _kControlsHeight,
      // Null only on the bearer path, and only until the bytes land.
      child: type == null
          ? const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            )
          : MediaElementView(type, onElement: _bind),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF14171C),
        borderRadius: Radii.card,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.audiotrack_outlined,
                size: 16,
                color: Colors.white70,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  audioClipName(widget.asset, widget.caption),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.small.copyWith(color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (controls == null)
            player
          else
            ClipControlsBar(controls: controls, player: player),
          const SizedBox(height: 6),
          Text(
            widget.allowDownload ? 'Audio' : 'Audio - download disabled',
            style: context.type.tiny.copyWith(color: Colors.white54),
          ),
          if (controls != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              clipKeysHint,
              style: context.type.tiny.copyWith(color: Colors.white54),
            ),
          ],
        ],
      ),
    );
  }
}

/// The empty state for an audio clip that never arrived, in the same plain
/// wording the video plate uses.
class _MissingAudio extends StatelessWidget {
  const _MissingAudio();

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 120,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.bgMuted,
        borderRadius: Radii.card,
        border: Border.all(color: t.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.music_off_outlined, size: 26, color: t.textMuted),
          const SizedBox(height: 8),
          Text(
            'No audio yet for this question.',
            style: context.type.bodyMuted,
          ),
        ],
      ),
    );
  }
}
