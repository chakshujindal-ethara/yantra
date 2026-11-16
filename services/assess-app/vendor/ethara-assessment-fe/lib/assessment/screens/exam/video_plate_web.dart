/// The WEB half of the video plate: a real HTML5 `<video>` element.
///
/// Selected by the conditional import in `video_plate.dart`. Kept in its own
/// file because `package:web` and `dart:ui_web` do not compile under the VM
/// test runner - importing them unconditionally broke every widget test in the
/// suite with a wall of `toJS isn't defined` errors from inside the package.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../../data/api_client.dart'
    show kApiBaseUrl, kApiPrefix, mediaAuthHeaders, resolveMediaUrl;
import '../../domain/models.dart';
import '../../theme.dart';
import 'video_plate.dart' show MediaInert, publicVideoEmbedRef;

/// The admin media proxies, which are `auth="user"` and want the bearer.
///
/// The candidate routes (`/pro_assessment/qvideo/<token>/<id>`) are
/// `auth="public"` and carry their credential in the path, so they must stay on
/// the plain `src` path below - see [_VideoPlateState._start].
// WHICH CLIPS NEED THE BEARER - stated as what must NOT get one, because the
// other way round fails silently.
//
// This used to be an allow-list: fetch with the header only when the URL
// contained `<MEDIA_PREFIX>/admin_`. It was `/etp_assessment/admin_` until the
// backend fork re-prefixed those routes, the stale value stopped matching, and
// every admin video preview took the no-auth branch, sent no bearer to an
// `auth="user"` route and rendered dead. Nothing errored; the gate just never
// fired. A build that forgets `--dart-define=MEDIA_PREFIX` reproduces it.
//
// Inverted, the same drift now fails the harmless way: we send the header to a
// route that did not need it, rather than withholding it from one that did.
//
// The two exclusions are not optional:
//
//   * CANDIDATE EXAM MEDIA carries its credential in the path and is
//     `auth="public"`. It must stay bearer-free - a signed-in admin's token on
//     an exam URL identifies them as somebody who is not that candidate.
//   * ANYTHING OFF OUR OWN ORIGIN (a public S3 link, an embed host) must never
//     receive this app's access token. The old `contains(...)` test would have
//     handed it to any third-party URL that happened to carry that substring.
const String _kMediaPrefix = String.fromEnvironment(
  'MEDIA_PREFIX',
  defaultValue: '/assessments_be',
);
const String _kExamMediaPrefix = '$_kMediaPrefix/exam/';

/// Token-scoped candidate media, which authenticates by its path.
bool _isCandidateMedia(String url) =>
    url.contains(_kExamMediaPrefix) || url.contains('/exam/q');

/// Served by OUR backend, so our credential belongs on it.
///
/// With an empty [kApiBaseUrl] (the same-origin production topology) media
/// paths stay relative, so a leading slash is the test. Otherwise the resolved
/// URL carries the API base verbatim - see `resolveMediaUrl`.
bool _isOurOrigin(String url) =>
    kApiBaseUrl.isEmpty ? url.startsWith('/') : url.startsWith(kApiBaseUrl);

/// A native `<video>`/`<audio>` with its own controls, inert while a dialog or
/// menu is open over its page, or a same-page overlay marks it [MediaInert].
///
/// A platform view takes the pointer wherever it sits, even under a dialog
/// Flutter draws on top: a sheet button over the clip's control bar never
/// fired, the click seeked the clip instead (Publish -> Cancel over an Audio
/// block in Form Studio). Inert by DOM `pointer-events`, not by swapping the
/// element out, so playback keeps its place while the dialog is open.
class MediaElementView extends StatefulWidget {
  const MediaElementView(this.viewType, {super.key, this.onElement});

  final String viewType;

  /// Hands the DOM element to a parent that drives it (the audio plate's
  /// −3 s / +3 s / Speed). Called each time the platform view is created.
  final void Function(web.HTMLElement element)? onElement;

  @override
  State<MediaElementView> createState() => _MediaElementViewState();
}

class _MediaElementViewState extends State<MediaElementView> {
  web.HTMLElement? _el;
  bool _covered = false;

  void _sync() => _el?.style.pointerEvents = _covered ? 'none' : '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _covered =
        ModalRoute.of(context)?.isCurrent == false || MediaInert.of(context);
    _sync();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(
    viewType: widget.viewType,
    onPlatformViewCreated: (int id) {
      final web.HTMLElement el =
          ui_web.platformViewRegistry.getViewById(id) as web.HTMLElement;
      _el = el;
      _sync();
      widget.onElement?.call(el);
    },
  );
}

/// True when the clip at [resolvedUrl] must be fetched WITH the bearer and
/// handed to the element as a blob: an admin proxy of ours, while signed in.
/// Shared with `AudioPlate`, whose `<audio>` element has the same limit - a DOM
/// media element cannot carry an `Authorization` header.
///
/// Never Form Studio media: that route is public and answers a clip with a 302
/// to S3, so the element loads it straight from the bucket. A bearer fetch
/// would pull the bytes through this page instead, and a cross-origin redirect
/// would need CORS on the bucket.
bool mediaNeedsBearer(String resolvedUrl) =>
    mediaAuthHeaders.isNotEmpty &&
    !_isCandidateMedia(resolvedUrl) &&
    !resolvedUrl.contains('$kApiPrefix/forms/media/') &&
    _isOurOrigin(resolvedUrl);

// ── `__videoEmbed` bridge (web/index.html) ──────────────────────────────
//
// One call each, matching `__docPreview`'s shape - see that bridge's own
// doc comment for why this stays hand-written JS interop instead of full
// typed bindings for two external SDKs.

@JS('__videoEmbed.mountYouTube')
external JSPromise<JSString> _mountYouTube(web.Element el, JSString videoId);

@JS('__videoEmbed.mountVimeo')
external JSPromise<JSString> _mountVimeo(web.Element el, JSString videoId);

@JS('__videoEmbed.play')
external void _embedPlayJs(JSString id);

@JS('__videoEmbed.pause')
external void _embedPauseJs(JSString id);

@JS('__videoEmbed.seek')
external void _embedSeekJs(JSString id, JSNumber seconds);

@JS('__videoEmbed.setMuted')
external void _embedSetMutedJs(JSString id, JSBoolean muted);

@JS('__videoEmbed.destroy')
external void _embedDestroyJs(JSString id);

@JS('__videoEmbed.pollJson')
external JSString? _embedPollJs(JSString id);

/// `mm:ss`, capped at an hour before falling back to `h:mm:ss` - no video
/// question is anywhere near that long, but a clip whose duration has not
/// loaded yet reads as `0:00`, not a crash.
String _fmtTime(double seconds) {
  final int s = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final int h = s ~/ 3600;
  final int m = (s % 3600) ~/ 60;
  final int r = s % 60;
  final String mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
  final String ss = r.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// A real HTML5 `<video>` inside the Flutter canvas.
///
/// WHY A PLATFORM VIEW: the module generates video questions (`video_prompt`,
/// the A/B clip comparisons) and returns the clips inline as
/// `data:video/mp4;base64,...`. Flutter web has no built-in video widget, and
/// the `video_player` package pulls a large plugin chain for what the browser
/// already does natively. Registering a `<video>` element keeps the dependency
/// list at three and gives the candidate the browser's own controls, which
/// they already know how to use.
///
/// The element is registered ONCE per source: `registerViewFactory` throws if
/// the same type id is registered twice, and a candidate scrubbing back and
/// forth rebuilds this widget constantly.
///
/// WHY SOME CLIPS ARE FETCHED FIRST: a DOM `<video>` is a plain subresource
/// load and there is no way to put an `Authorization` header on it. The image
/// plate gets away with `Image.network(..., headers: mediaAuthHeaders)` because
/// on web that takes an XHR path, but this element cannot. So when the draft
/// reviewer is looking at an admin proxy URL - `auth="user"`, no cookie, this
/// app holds a bearer - the bytes are fetched WITH the header and handed to the
/// element as a blob URL instead. That was a silent regression: the backend
/// stopped inlining `data:video/mp4;base64,...` in favour of an admin URL, and
/// the reviewer got a dead player where the clip used to play.
class VideoPlate extends StatefulWidget {
  const VideoPlate({
    super.key,
    required this.asset,
    this.caption = '',
    this.allowDownload = false,
  });

  final Asset asset;
  final String caption;

  /// Off by default. A candidate who can download the clip can share it, and
  /// the whole point of a generated question is that it has not been seen.
  final bool allowDownload;

  @override
  State<VideoPlate> createState() => _VideoPlateState();
}

class _VideoPlateState extends State<VideoPlate> {
  static final Set<String> _registered = <String>{};

  /// Distinguishes one minted blob from the next in a view type.
  ///
  /// Blob URLs cannot be keyed by their content the way a server URL can: two
  /// mounts of the same clip mint two different `blob:` URLs, and the first is
  /// revoked when its widget goes away. Reusing a view type across them would
  /// hand the second mount a factory that still points at revoked bytes, which
  /// plays as a black rectangle.
  static int _blobSeq = 0;

  /// The view type currently on screen. Null while the bearer fetch is still
  /// running, or when there is nothing to play.
  String? _viewType;

  /// True when [_viewType] is a public host's OWN embedded player rather
  /// than this app's `<video>` element - the download controls below apply
  /// only to bytes this app actually serves, so they say nothing for a
  /// YouTube/Vimeo frame this app never touches.
  bool _isEmbed = false;

  static int _embedSeq = 0;

  /// Set once `mountYouTube`/`mountVimeo` resolves. Every embed call below
  /// is keyed on this, not on [_viewType] - the view type only identifies
  /// the DOM element; this identifies the live player instance riding
  /// inside it.
  String? _playerId;

  /// The stable DOM id the container element was given, so the fullscreen
  /// button has something to look the element back up by - nothing else
  /// keeps a Dart-side reference to it once the view factory returns it.
  String? _containerElId;

  Timer? _poll;
  double _currentTime = 0;
  double _duration = 0;
  bool _playing = false;
  bool _muted = true;

  /// The object URL this state minted and therefore owes a revoke on. Null on
  /// the direct-src path, which owns nothing.
  String? _objectUrl;

  /// True once a fetch came back refused or broken, so the plate can fall back
  /// to [MissingVideo] rather than mount a player that will never paint.
  bool _failed = false;

  /// Bumped by every [_start]. An in-flight fetch compares the serial it was
  /// launched with against this before touching state, so a fast source change
  /// - the reviewer clicking through drafts - cannot let the older clip land
  /// on top of the newer one.
  int _load = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(VideoPlate old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id || old.asset.url != widget.asset.url) {
      _start();
    }
  }

  @override
  void dispose() {
    // Without this the fetched clip stays alive for the life of the tab. A
    // reviewer walking a bank of video questions would accumulate every one.
    _revoke();
    _stopEmbed();
    super.dispose();
  }

  void _stopEmbed() {
    _poll?.cancel();
    _poll = null;
    final String? id = _playerId;
    if (id != null) {
      _playerId = null;
      _embedDestroyJs(id.toJS);
    }
  }

  /// Decide how this source has to be loaded, and start doing it.
  ///
  /// Never calls `setState`: it runs from [initState] and [didUpdateWidget],
  /// both of which are followed by a build anyway. Only the async completion
  /// below needs to ask for one.
  void _start() {
    final int serial = ++_load;
    _revoke();
    _stopEmbed();
    _viewType = null;
    _isEmbed = false;
    _failed = false;
    _currentTime = 0;
    _duration = 0;
    _playing = false;
    _muted = true;

    final String? src = widget.asset.url;
    if (src == null || src.isEmpty) return;

    // A YouTube/Vimeo link is a page on a public host, not this app's own
    // media - it never wants resolveMediaUrl (that is for OUR relative
    // proxy paths) or the admin bearer fetch below (their embed player
    // loads itself; there is nothing here to authenticate).
    final ({String kind, String id})? embed = publicVideoEmbedRef(src);
    if (embed != null) {
      _isEmbed = true;
      final String elId =
          'etp-video-embed-el-${widget.asset.id}-'
          '${_embedSeq++}';
      _containerElId = elId;
      _viewType = _registerEmbed(elId, embed, serial);
      return;
    }

    final String url = resolveMediaUrl(src);
    final Map<String, String> auth = mediaAuthHeaders;
    if (!mediaNeedsBearer(url)) {
      // The candidate path, the signed-out case, and anything hosted
      // elsewhere. The element loads it itself, with no credential of ours.
      _viewType = _register(
        'etp-video-${widget.asset.id}-${url.hashCode}',
        url,
      );
      return;
    }
    unawaited(_loadWithBearer(url, auth, serial));
  }

  /// Pull the clip with the `Authorization` header and republish it as a blob.
  Future<void> _loadWithBearer(
    String url,
    Map<String, String> auth,
    int serial,
  ) async {
    final web.Blob blob;
    try {
      final web.Headers headers = web.Headers();
      for (final MapEntry<String, String> h in auth.entries) {
        headers.append(h.key, h.value);
      }
      final web.Response res = await web.window
          .fetch(url.toJS, web.RequestInit(method: 'GET', headers: headers))
          .toDart;
      // A refused admin GET answers with a JSON or HTML body, and that body
      // would happily become a blob the element then fails to decode. Checking
      // the status is what turns a 401 into the empty state instead of a
      // player that sits there black with no explanation.
      if (!res.ok) throw StateError('HTTP ${res.status}');
      blob = await res.blob().toDart;
    } catch (_) {
      if (!mounted || serial != _load) return;
      setState(() => _failed = true);
      return;
    }

    final String minted = web.URL.createObjectURL(blob);
    if (!mounted || serial != _load) {
      // Disposed, or a newer clip took over while these bytes were in the air.
      // Nobody will ever mount this one, so let go of it here.
      web.URL.revokeObjectURL(minted);
      return;
    }
    setState(() {
      _objectUrl = minted;
      _viewType = _register(
        'etp-video-${widget.asset.id}-blob-${_blobSeq++}',
        minted,
      );
    });
  }

  void _revoke() {
    final String? held = _objectUrl;
    if (held == null) return;
    _objectUrl = null;
    web.URL.revokeObjectURL(held);
  }

  /// Register [type] to play [url], unless it already is, and return it.
  ///
  /// [allowDownload] is read here rather than inside the factory: the registry
  /// is process-wide, so the closure outlives this state and must not reach
  /// back into a widget that may already be gone.
  String _register(String type, String url) {
    if (_registered.add(type)) {
      final bool allowDownload = widget.allowDownload;
      // THE STILL FRAME, which no client read until now. The serializer has
      // always sent `poster_url` beside the clip, so every video opened as a
      // black rectangle: nothing about it said what the clip was of, or even
      // whether it had loaded rather than failed. Resolved through the same
      // `resolveMediaUrl` as the clip, because it is served by the same proxy.
      final String? poster = widget.asset.posterUrl;
      // The element's own name for a screen reader (see the audio plate).
      final String name = <String>[
        widget.caption.trim(),
        widget.asset.label.trim(),
        'Video',
      ].firstWhere((String s) => s.isNotEmpty);
      ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
        final web.HTMLVideoElement el = web.HTMLVideoElement()
          // Already absolute against the Odoo origin, or a blob: URL of bytes
          // fetched with the bearer. A bare server-relative path would resolve
          // against the app's own host (:8200 under `make serve`) and 404.
          ..src = url
          ..controls = true
          // No autoplay: a clip that starts talking the moment the question
          // opens is startling, and the candidate may not have their sound set.
          ..autoplay = false
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.objectFit = 'contain'
          ..style.background = '#000'
          ..style.borderRadius = '10px';
        el.setAttribute('aria-label', name);
        if (poster != null && poster.isNotEmpty) {
          el.poster = resolveMediaUrl(poster);
        }
        if (!allowDownload) {
          // Hides the download item in Chrome's native menu. Not a security
          // control - the bytes are in the page - but it removes the obvious
          // affordance, same as the image plate does.
          el.setAttribute('controlsList', 'nodownload');
          el.setAttribute('disablePictureInPicture', 'true');
          el.oncontextmenu = (web.Event e) {
            e.preventDefault();
          }.toJS;
        }
        return el;
      });
    }
    return type;
  }

  /// Register [type] to hold a public host's player with its OWN chrome
  /// turned off (`controls: 0`/`controls: false`) - no title card, no
  /// suggested-video panel, no logo, nothing this app did not put there
  /// itself. [_type] is always a fresh string (an incrementing sequence
  /// is baked into it in [_start]), so this always registers a genuinely
  /// new factory rather than reusing a stale one from an earlier mount.
  String _registerEmbed(
    String elId,
    ({String kind, String id}) ref,
    int serial,
  ) {
    final String type = elId;
    if (_registered.add(type)) {
      ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
        final web.HTMLDivElement el = web.HTMLDivElement()
          ..id = elId
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.background = '#000'
          ..style.borderRadius = '10px'
          ..style.overflow = 'hidden'
          // The embed is driven through the JS bridge and wears this app's
          // own control bar, so the container never needs pointer input. On
          // Flutter web a platform view composites ABOVE the canvas: left
          // interactive, this div would trap page scroll while the pointer is
          // over it and swallow clicks meant for a dialog drawn on top. Making
          // it inert hands wheel and click events back to Flutter. Set here
          // too (not only on the inner iframe) so scroll passes through in the
          // beat before the player's own frame has mounted.
          ..style.pointerEvents = 'none';
        unawaited(_mount(el, ref, serial));
        return el;
      });
    }
    return type;
  }

  /// Create the player inside [el] and start polling it for playback
  /// state. Runs from inside the view factory above, so it must check
  /// [mounted]/[serial] before touching state - by the time the SDK
  /// resolves, a fast source change may have moved this state on already.
  Future<void> _mount(
    web.Element el,
    ({String kind, String id}) ref,
    int serial,
  ) async {
    late final String id;
    try {
      final JSString jsId = ref.kind == 'yt'
          ? await _mountYouTube(el, ref.id.toJS).toDart
          : await _mountVimeo(el, ref.id.toJS).toDart;
      id = jsId.toDart;
    } catch (_) {
      if (!mounted || serial != _load) return;
      setState(() => _failed = true);
      return;
    }
    if (!mounted || serial != _load) {
      // Disposed, or a newer source took over while the SDK was loading -
      // nobody will ever see this player, so let it go rather than leak it.
      _embedDestroyJs(id.toJS);
      return;
    }
    setState(() => _playerId = id);
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final JSString? raw = _embedPollJs(id.toJS);
      if (raw == null || !mounted) return;
      final Map<String, dynamic> data =
          jsonDecode(raw.toDart) as Map<String, dynamic>;
      setState(() {
        _currentTime = (data['t'] as num?)?.toDouble() ?? _currentTime;
        _duration = (data['d'] as num?)?.toDouble() ?? _duration;
        _playing = data['playing'] == true;
        _muted = data['muted'] == true;
      });
    });
  }

  void _embedPlay() {
    final String? id = _playerId;
    if (id != null) _embedPlayJs(id.toJS);
  }

  void _embedPause() {
    final String? id = _playerId;
    if (id != null) _embedPauseJs(id.toJS);
  }

  void _embedSeekTo(double seconds) {
    final String? id = _playerId;
    if (id != null) _embedSeekJs(id.toJS, seconds.toJS);
  }

  void _embedToggleMuted() {
    final String? id = _playerId;
    if (id == null) return;
    final bool next = !_muted;
    _embedSetMutedJs(id.toJS, next.toJS);
    setState(() => _muted = next);
  }

  void _embedFullscreen() {
    final String? elId = _containerElId;
    if (elId == null) return;
    final web.Element? el = web.document.getElementById(elId);
    el?.requestFullscreen();
  }

  /// A control bar this app owns, over a player with its own turned off -
  /// play/pause, a seek bar, elapsed/total time, mute, fullscreen. None of
  /// it reads as YouTube's or Vimeo's own chrome because none of it is;
  /// every pixel here is this app's usual dark theme.
  Widget _embedControlsBar(BuildContext context) {
    final double dur = _duration > 0 ? _duration : 0;
    final double cur = dur > 0 ? _currentTime.clamp(0, dur) : 0;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 20, 10, 4),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white.o(.3),
                thumbColor: Colors.white,
              ),
              child: SizedBox(
                height: 14,
                child: Slider(
                  value: cur,
                  min: 0,
                  max: dur > 0 ? dur : 1,
                  onChanged: dur > 0
                      ? (double v) => setState(() => _currentTime = v)
                      : null,
                  onChangeEnd: dur > 0 ? _embedSeekTo : null,
                ),
              ),
            ),
            Row(
              children: <Widget>[
                _embedIconBtn(
                  _playing ? Icons.pause : Icons.play_arrow,
                  _playing ? 'Pause' : 'Play',
                  _playing ? _embedPause : _embedPlay,
                ),
                _embedIconBtn(
                  _muted ? Icons.volume_off : Icons.volume_up,
                  _muted ? 'Unmute' : 'Mute',
                  _embedToggleMuted,
                ),
                Text(
                  '${_fmtTime(cur)} / ${_fmtTime(dur)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                _embedIconBtn(Icons.fullscreen, 'Fullscreen', _embedFullscreen),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _embedIconBtn(IconData icon, String tooltip, VoidCallback onTap) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 18, color: Colors.white),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String? src = widget.asset.url;
    if (src == null || src.isEmpty || _failed) return const MissingVideo();
    final String? type = _viewType;

    // A platform-view iframe composites ABOVE the Flutter canvas, so it also
    // paints above any dialog Flutter draws on top of this page - the embed
    // shows through the scrim and steals the region where the modal's own
    // buttons should be. While this route is NOT the top-most one (a
    // `showDialog`/`showSheet` is open), swap the live frame for a still
    // placeholder so nothing composites over the sheet. The player keeps
    // running muted underneath and the frame returns on the next build once
    // the dialog pops. A `<video>` element (the non-embed branch) does not
    // paint over the sheet but does take its clicks: see [MediaElementView].
    final bool covered = ModalRoute.of(context)?.isCurrent == false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: Radii.card,
          child: SizedBox(
            height: 300,
            // Null only on the fetched path, and only until the bytes land.
            child: type == null
                ? const _LoadingVideo()
                : _isEmbed
                ? (covered
                      ? const _CoveredVideo()
                      : Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            HtmlElementView(viewType: type),
                            // The player mounts before its SDK has actually
                            // resolved [_playerId] - a beat where the div is
                            // on screen but nothing is playing yet.
                            if (_playerId == null) const _LoadingVideo(),
                            if (_playerId != null) _embedControlsBar(context),
                          ],
                        ))
                : MediaElementView(type),
          ),
        ),
        if (widget.caption.isNotEmpty) ...<Widget>[
          const SizedBox(height: 7),
          Text(widget.caption, style: context.type.small),
        ],
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Icon(Icons.videocam_outlined, size: 13, color: t.textMuted),
            const SizedBox(width: 6),
            Text(
              // The nodownload/no-context-menu controls below only apply to
              // bytes this app serves - an embed plays inside the HOST's own
              // frame, which this app has no control over either way.
              _isEmbed
                  ? 'Video'
                  : widget.allowDownload
                  ? 'Video'
                  : 'Video - download disabled',
              style: context.type.tiny,
            ),
          ],
        ),
      ],
    );
  }
}

/// Stands in for the live embed while a dialog is open over the page. Same
/// height and black as the player so the panel does not jump when the frame
/// is pulled and put back. A faint play glyph keeps it reading as the video
/// rather than an error - the real frame returns the moment the dialog pops.
class _CoveredVideo extends StatelessWidget {
  const _CoveredVideo();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      color: const Color(0xFF000000),
      child: const Icon(
        Icons.play_circle_outline,
        size: 44,
        color: Color(0x66FFFFFF),
      ),
    );
  }
}

/// The wait on the admin path only: the whole file must download before the
/// element can be given anything, where a plain `src` would have streamed.
/// Same height and same black as the player, so the panel does not jump.
class _LoadingVideo extends StatelessWidget {
  const _LoadingVideo();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      color: const Color(0xFF000000),
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}

/// The empty state for a video that never arrived, in the same plain wording
/// the image plate uses.
class MissingVideo extends StatelessWidget {
  const MissingVideo({super.key});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 220,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.bgMuted,
        borderRadius: Radii.card,
        border: Border.all(color: t.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.videocam_off_outlined, size: 26, color: t.textMuted),
          const SizedBox(height: 8),
          Text(
            'No video yet for this question.',
            style: context.type.bodyMuted,
          ),
        ],
      ),
    );
  }
}
