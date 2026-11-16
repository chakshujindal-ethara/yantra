// Stimulus plates and the zoom lightbox - HANDOVER §2.11, §4.5.
//
// A stimulus is the thing the question is about, never decoration, so every
// plate is zoomable and the hint names the action (`cursor: zoom-in`). The
// prototype draws its imagery inline rather than fetching it; the same widgets
// accept a URL for the live backend.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/api_client.dart'
    show isOurMediaOrigin, mediaAuthHeaders, resolveMediaUrl;
import '../../domain/models.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import 'image_plate.dart';

/// A plate's caption on a side-free image_ab pair ([abIsSideFree]).
///
/// The module stamps "Response A"/"Response B" on both slots whatever the axes
/// ask, so a label that only names a side gives way to where the plate sits,
/// which is how the prompt describes the pair. Any other label is the plate's
/// own name and is kept.
String sideFreeCaption(String label, int index) =>
    label.trim().isNotEmpty && !abNamesSide(label)
    ? label
    : switch (index) {
        0 => 'Left image',
        1 => 'Right image',
        _ => 'Image ${index + 1}',
      };

/// `.plate` - an image slot with a caption and a zoom affordance.
class StimulusPlate extends StatefulWidget {
  final Asset asset;
  final String caption;

  /// Draw the numbered detection overlay, for a labelling question.
  final bool showRegions;

  const StimulusPlate({
    super.key,
    required this.asset,
    required this.caption,
    this.showRegions = false,
  });

  @override
  State<StimulusPlate> createState() => _StimulusPlateState();
}

class _StimulusPlateState extends State<StimulusPlate> {
  bool _hover = false;

  /// The image's OWN width/height, once it has loaded. Null until then.
  ///
  /// WHY THE PLATE ADAPTS AT ALL. The frame was a hardcoded `AspectRatio(4/3)`,
  /// so a portrait photograph - which is most of what a phone in a warehouse
  /// produces - painted as a narrow strip down the middle of a wide grey box,
  /// with more plate than picture. It was not a correctness problem, but it is
  /// the first thing anyone notices on a media question.
  ///
  /// SAFE TO CHANGE, and that had to be checked: `RegionOverlayImage` derives
  /// its own aspect from the loaded bitmap and lays its markers out inside its
  /// own `AspectRatio`, so a numbered box is positioned against the IMAGE and
  /// never against this frame. Matching the frame to the image simply removes
  /// the letterbox between the two.
  double? _aspect;
  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;

  /// The shape a plate may take. Beyond these it letterboxes as before.
  ///
  /// An exam plate has neighbours - the options sit beside it - so an
  /// unclamped 9:16 would push the answer controls off the first screen and a
  /// panorama would collapse to a letterbox slit. The clamp keeps a portrait
  /// image tall enough to read and short enough to answer next to.
  static const double _minAspect = 0.62; // a little narrower than 2:3
  static const double _maxAspect = 2.4; // a little wider than 21:9

  @override
  void initState() {
    super.initState();
    _resolveSize();
  }

  @override
  void didUpdateWidget(covariant StimulusPlate old) {
    super.didUpdateWidget(old);
    if (old.asset.url != widget.asset.url) {
      _aspect = null;
      _resolveSize();
    }
  }

  @override
  void dispose() {
    _detachSize();
    super.dispose();
  }

  void _resolveSize() {
    _detachSize();
    final String url = widget.asset.url ?? '';
    if (url.isEmpty) return;
    final ImageProvider? provider = stimulusImageProvider(url);
    if (provider == null) return;
    final ImageStream stream = provider.resolve(ImageConfiguration.empty);
    final ImageStreamListener listener = ImageStreamListener((
      ImageInfo info,
      bool _,
    ) {
      // An `<img>`-backed image throws from `.image` because there are no
      // readable pixels behind it - the same guard `RegionOverlayImage`
      // carries. Falling back to the old fixed frame is exactly right here:
      // unlike the overlay, nothing about this is load-bearing.
      double? aspect;
      try {
        if (info.image.height != 0) {
          aspect = info.image.width / info.image.height;
        }
        info.dispose();
      } on UnsupportedError {
        aspect = null;
      }
      if (aspect == null) return;
      final double clamped = aspect.clamp(_minAspect, _maxAspect);
      if (mounted && _aspect != clamped) setState(() => _aspect = clamped);
    }, onError: (Object _, StackTrace? _) {});
    _sizeStream = stream;
    _sizeListener = listener;
    stream.addListener(listener);
  }

  void _detachSize() {
    final ImageStream? st = _sizeStream;
    final ImageStreamListener? l = _sizeListener;
    if (st != null && l != null) st.removeListener(l);
    _sizeStream = null;
    _sizeListener = null;
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // ONLY flex when there is a height to flex WITHIN.
    //
    // `Flexible` was added so the 4:3 plate shrinks instead of overflowing a
    // bounded box - correct, and kept. But a flex child under an UNBOUNDED
    // height is a RenderFlex assertion ("non-zero flex but incoming height
    // constraints are unbounded"), and unbounded is the exam runner's normal
    // case: the question body lives inside a SingleChildScrollView
    // (exam_screen.dart:465). So every question carrying a plate - both
    // labelling types, image_prompt, image_ab, video_prompt - threw on layout
    // and the stimulus never painted. A candidate got numbered inputs beside
    // a picture that was not there, which is not a question anybody can
    // answer.
    //
    // Bounded (the lightbox, a sized panel) keeps the shrink-to-fit; unbounded
    // takes its natural size off the width, which is what a scrolling column
    // wants anyway.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // An EMPTY caption draws nothing, not an empty line. `mediaPlates`
          // suppresses a label that only repeats the question prompt, and the
          // eyebrow plus its 6px gap would otherwise leave a blank band above
          // every such plate.
          if (widget.caption.trim().isNotEmpty) ...<Widget>[
            Text(widget.caption.toUpperCase(), style: context.type.eyebrow),
            const SizedBox(height: 6),
          ],
          _plate(context, t, flexible: c.hasBoundedHeight),
        ],
      ),
    );
  }

  Widget _plate(BuildContext context, AppTokens t, {required bool flexible}) {
    final Widget plate = MouseRegion(
      cursor: SystemMouseCursors.zoomIn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => showLightbox(
          context,
          widget.asset,
          widget.caption,
          showRegions: widget.showRegions,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: t.bgMuted,
            borderRadius: Radii.card,
            border: Border.all(color: t.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: <Widget>[
              AspectRatio(
                // The image's own shape once known; 4:3 while it loads, which
                // is also the fallback for a provider that cannot report a
                // size.
                aspectRatio: _aspect ?? 4 / 3,
                child: StimulusArt(
                  asset: widget.asset,
                  showRegions: widget.showRegions,
                ),
              ),
              // `.zh` - the zoom hint chip, resting at opacity 0 and revealed
              // on hover.
              Positioned(
                right: 9,
                bottom: 9,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  opacity: _hover ? 1 : 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: t.bgApp.o(.92),
                      borderRadius: Radii.buttonSm,
                      border: Border.all(color: t.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.zoom_in, size: 13, color: t.textSecondary),
                        const SizedBox(width: 5),
                        Text(
                          'Zoom',
                          style: context.type.tiny.copyWith(
                            fontWeight: FontWeight.w600,
                            color: t.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return flexible ? Flexible(child: plate) : plate;
  }
}

/// The bytes behind a `data:` URL, decoded at most once per URL.
///
/// WHY CACHED: the store refreshes every 2s while a generation job runs, and
/// decoding inside `build` handed `Image.memory` a NEW list each time - a new
/// list is a new cache key, so Flutter dropped the painted frame and re-decoded
/// ~3.7MB. That was the flicker on the review queue and the drafts tab. Same
/// list in, same key, frame survives.
///
/// Null when the payload will not decode, so callers fall through to their
/// empty state rather than throwing inside a build. Oldest entry is evicted
/// past [_kMaxDecoded]; a few stimuli are on screen at once, and holding a
/// workload of PNGs for the life of the process is the other failure mode.
Uint8List? _dataUrlBytes(String src) {
  final int comma = src.indexOf(',');
  if (comma <= 0) return null;
  try {
    return _decoded.putIfAbsent(src, () {
      if (_decoded.length >= _kMaxDecoded) _decoded.remove(_decoded.keys.first);
      return base64Decode(src.substring(comma + 1));
    });
  } catch (_) {
    return null;
  }
}

final Map<String, Uint8List> _decoded = <String, Uint8List>{};

/// How many decoded data-URL images stay in memory.
///
/// RAISED FROM 24. The cache exists because the store polls every 2s during a
/// generation run and a fresh `Uint8List` each build is a new cache key, so
/// without it ~3.7 MB is re-decoded on every tick and the plates visibly
/// flicker. 24 was enough for one question at a time and not for a review
/// queue: past the cap, eviction reinstated exactly the flicker the cache was
/// added to remove, on the screen that shows the most images at once.
const int _kMaxDecoded = 96;

/// The generated stimulus artwork: drawn synthetically when the question
/// carries no [Asset.url], and the server's real image when it does.
///
/// STATEFUL ONLY TO HOLD A RETRY COUNTER. A fetch that failed must be
/// re-attemptable, and Flutter caches an `Image.network` by its URL - so the
/// counter is folded into the cache key to force a real second request rather
/// than a second look at the same cached failure.
class StimulusArt extends StatefulWidget {
  final Asset asset;
  final bool showRegions;

  const StimulusArt({super.key, required this.asset, this.showRegions = false});

  @override
  State<StimulusArt> createState() => _StimulusArtState();
}

class _StimulusArtState extends State<StimulusArt> {
  int _attempt = 0;

  Asset get asset => widget.asset;
  bool get showRegions => widget.showRegions;

  void _retry() {
    if (!mounted) return;
    setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    final String? src = asset.url;
    if (src != null && src.isNotEmpty) {
      // A DATA URL is not a network URL.
      //
      // The module renders question images itself and returns them inline as
      // `data:image/png;base64,...`. `Image.network` cannot fetch that - it
      // fails silently on web and paints nothing, which is how a stimulus
      // panel ended up blank while the server had sent a valid PNG. The bytes
      // have to be decoded and handed to `Image.memory`.
      if (src.startsWith('data:')) {
        final Uint8List? bytes = _dataUrlBytes(src);
        // A data URL that will not decode IS a failure, not an absence - the
        // server sent bytes and they were unreadable. Retry is offered because
        // the usual cause is a truncated payload from an interrupted fetch.
        if (bytes == null) return StimulusUnavailable(onRetry: _retry);
        return _withRegions(
          context,
          // gaplessPlayback keeps the last frame on screen while a new one
          // resolves, so a rebuild never flashes empty.
          Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: _failed,
          ),
        );
      }
      final String resolved = resolveMediaUrl(src);
      // OUR OWN ORIGIN OR SOMEONE ELSE'S, and the answer decides BOTH lines
      // below. Judged on the resolved URL, before the retry counter is folded
      // in, so a retry cannot change the verdict.
      final bool ours = isOurMediaOrigin(resolved);

      // A FOREIGN ORIGIN GOES STRAIGHT TO AN `<img>` ELEMENT.
      //
      // Flutter's `fallback` strategy reaches the same element eventually, but
      // only AFTER an XHR has failed - one wasted round trip per picture, and
      // the result arrives as a `WebImageInfo` whose `.image` getter throws, so
      // anything measuring pixels breaks. Going element-first for a host that
      // was never going to send CORS headers avoids both. Our own proxies stay
      // on the byte path, where the bearer works and `showRegions` can measure.
      if (!ours && !showRegions) {
        return ImagePlate(
          url: resolved,
          onFailed: (BuildContext c) => StimulusUnavailable(onRetry: _retry),
        );
      }

      return _withRegions(
        context,
        Image.network(
          // The retry counter rides in the query string so a second press is a
          // second REQUEST. Flutter's image cache is keyed on the URL, so
          // re-rendering the same one hands back the cached failure and the
          // button does nothing.
          _attempt == 0
              ? resolved
              : '$resolved${resolved.contains('?') ? '&' : '?'}'
                    '_retry=$_attempt',
          // THE BEARER GOES ONLY WHERE IT IS OWED, and on this widget that is
          // what decides whether a third-party picture renders at all.
          //
          // The admin proxies are auth="user" and this app holds a bearer, not
          // a cookie. Without the header every bank/draft image answered 401
          // and the panel drew "has not rendered" over a stored picture - so
          // our own origin must keep it.
          //
          // BUT A NON-EMPTY `headers` MAP DISABLES THE `<img>` PATH OUTRIGHT
          // (`containsNetworkImageHeaders` routes to `loadViaDecode()`), and an
          // XHR needs the far host to send `Access-Control-Allow-Origin`, which
          // almost no image host does. Sending our token to someone else's CDN
          // was therefore not merely useless, it was what STOPPED the picture
          // rendering: an `<img>` would have displayed it, because a browser
          // needs CORS to READ an image, not to SHOW one.
          //
          // This widget is what `StimulusPlate` draws, so it is every A/B
          // comparison plate, the review queue and the question editor - the
          // reason a pasted URL still failed there after `stimulusImage` was
          // fixed. The two must stay in step; see `stimulusImage` below.
          headers: ours ? mediaAuthHeaders : const <String, String>{},
          webHtmlElementStrategy: ours
              ? WebHtmlElementStrategy.never
              : WebHtmlElementStrategy.fallback,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          // A FETCH THAT FAILS MUST SAY SO.
          //
          // Without this an `Image` whose load errors paints NOTHING - an empty
          // box the exact colour of the plate behind it. That is how a CORS
          // refusal on the media proxies (the server answered 200 with a valid
          // PNG; the browser discarded it over a duplicated Allow-Origin
          // header) looked identical to a question whose image had simply not
          // been generated yet, on every admin screen at once. The empty state
          // is the honest answer, and it is the same one the "not rendered yet"
          // path already shows.
          errorBuilder: _failed,
        ),
      );
    }
    return CustomPaint(
      painter: _WarehousePainter(
        tokens: context.tokens,
        seed: asset.id,
        regions: showRegions ? asset.regions : const <LabelRegion>[],
      ),
      child: const SizedBox.expand(),
    );
  }

  /// What an image draws when its bytes never arrive or will not decode.
  ///
  /// DELIBERATELY DIFFERENT from "nothing has been generated yet". The two
  /// were the same widget, and that is how a CORS refusal on the media proxies
  /// - the server answered 200 with a valid PNG and the browser discarded it
  /// over a duplicated Allow-Origin header - looked identical, on every admin
  /// screen at once, to a bank whose pictures had not been rendered yet.
  Widget _failed(BuildContext _, Object _, StackTrace? _) =>
      StimulusUnavailable(onRetry: _retry);

  /// Overlay the numbered boxes on a real image.
  ///
  /// The boxes are fractions of the image, so they must be painted in the same
  /// box the image occupies - not over the whole panel, or every coordinate
  /// shifts as the aspect ratio changes.
  Widget _withRegions(BuildContext context, Widget image) {
    if (!showRegions || asset.regions.isEmpty) return image;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        image,
        CustomPaint(
          painter: _RegionPainter(
            tokens: context.tokens,
            regions: asset.regions,
          ),
          child: const SizedBox.expand(),
        ),
      ],
    );
  }
}

/// A synthetic warehouse-floor frame with optional numbered annotation boxes.
///
/// It is deterministic: every shape is derived from the asset id, so the same
/// stimulus draws identically on every run.
class _WarehousePainter extends CustomPainter {
  final AppTokens tokens;
  final String seed;
  final List<LabelRegion> regions;

  _WarehousePainter({
    required this.tokens,
    required this.seed,
    required this.regions,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // Floor.
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = tokens.bgMuted);

    // Perspective floor lines, so the frame reads as a space rather than a
    // flat swatch.
    final Paint line = Paint()
      ..color = tokens.textMuted.o(.22)
      ..strokeWidth = 1;
    for (int i = 1; i < 8; i++) {
      final double y = h * (i / 8);
      canvas.drawLine(Offset(0, y), Offset(w, y), line);
    }
    for (int i = 1; i < 10; i++) {
      final double x = w * (i / 10);
      canvas.drawLine(Offset(x, h * .34), Offset(x, h), line);
    }

    // Horizon and racking.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h * .34),
      Paint()..color = tokens.zebra,
    );
    final Paint rack = Paint()..color = tokens.textMuted.o(.35);
    for (int i = 0; i < 6; i++) {
      final double x = w * (.04 + i * .16);
      canvas.drawRect(Rect.fromLTWH(x, h * .06, w * .10, h * .26), rack);
    }

    // Palette-tinted crates, so the frame carries the module's own hues rather
    // than arbitrary colour.
    final List<Color> crateColors = <Color>[
      tokens.seq1.o(.75),
      tokens.seq2.o(.7),
      tokens.c2.o(.6),
    ];
    for (int i = 0; i < 5; i++) {
      final double x = w * (.08 + i * .18);
      final double ch = h * (.14 + (i % 3) * .05);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, h - ch - h * .08, w * .12, ch),
          const Radius.circular(3),
        ),
        Paint()..color = crateColors[i % crateColors.length],
      );
    }

    // The numbered detection overlay.
    for (final LabelRegion r in regions) {
      final Rect box = Rect.fromLTWH(r.x * w, r.y * h, r.w * w, r.h * h);
      canvas.drawRect(
        box,
        Paint()
          ..color = tokens.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawRect(box, Paint()..color = tokens.primary.o(.10));

      // The numeral sits in a filled disc so it stays legible over any part of
      // the frame.
      const double rad = 11;
      final Offset c = Offset(box.left + rad + 2, box.top + rad + 2);
      canvas.drawCircle(c, rad, Paint()..color = tokens.primary);
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: '${r.number}',
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _WarehousePainter old) =>
      old.tokens != tokens || old.seed != seed || old.regions != regions;
}

// The video slot used to live here as a MOCK: a play icon over a black box, a
// hardcoded "0:12 / 0:35" and a progress bar frozen at 34%. It never loaded a
// file and never could be played, so a video question was unanswerable - the
// candidate saw a still frame of a clip that did not exist and was asked to
// describe it. The real player lives in `video_plate.dart`.

/// The empty state for a stimulus that never landed. A question whose image
/// failed to render must say so, not show a blank frame.
class MissingStimulus extends StatelessWidget {
  const MissingStimulus({super.key});

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
          Icon(
            Icons.image_not_supported_outlined,
            size: 26,
            color: t.textMuted,
          ),
          const SizedBox(height: 8),
          Text(
            'No image yet for this question.',
            style: context.type.bodyMuted,
          ),
        ],
      ),
    );
  }
}

/// A picture that EXISTS and could not be fetched, said out loud.
///
/// WHY THIS IS NOT [MissingStimulus]. The two used to be the same widget, on
/// the reasoning that a reviewer cannot act on the difference. They can, and
/// the difference is the whole diagnosis: "no image yet" is an authoring state
/// that resolves itself when the render cron runs, while a failed fetch is a
/// 401, an expired S3 signature or a CORS refusal - none of which will ever
/// resolve on their own, and all of which the server logs as a healthy 200.
/// Collapsing them is how a duplicated `Access-Control-Allow-Origin` header
/// looked, on every admin screen at once, exactly like a bank of questions
/// whose images had not been generated yet.
///
/// [onRetry] re-attempts the load. Most failures here are transient in the
/// sense that matters - a signature that has since been re-minted, a token
/// that has since been refreshed - so one press is often the whole fix.
class StimulusUnavailable extends StatelessWidget {
  final VoidCallback? onRetry;

  const StimulusUnavailable({super.key, this.onRetry});

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
          Icon(Icons.cloud_off_outlined, size: 26, color: t.warnText),
          const SizedBox(height: 8),
          Text(
            'This image could not be loaded.',
            style: context.type.body.copyWith(color: t.textPrimary),
          ),
          // The explanation only where there is room for it: a half-width
          // plate (a left/right pair) is too short, and the title plus Retry
          // say enough there.
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) =>
                box.maxWidth < 360
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
                    child: Text(
                      'It exists on the server. Sign-in, storage access or '
                      'the browser refused the fetch.',
                      textAlign: TextAlign.center,
                      style: context.type.tiny,
                    ),
                  ),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 10),
            Btn(
              'Retry',
              size: BtnSize.sm,
              tooltip:
                  'Fetch the image again. A stale signature or an '
                  'expired token is often gone by the second try.',
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

/// The lightbox: zoom steps by 0.4, clamped 1-6, reset returns to 1.
///
/// It closes on a backdrop click, on the Close control, and on Escape - but
/// NOT on a click that lands on the artwork itself, because that is a pan
/// gesture, not a dismissal.
void showLightbox(
  BuildContext context,
  Asset asset,
  String caption, {
  bool showRegions = false,
}) {
  showDialog<void>(
    context: context,
    barrierColor: const Color(0xEB0F0B13),
    builder: (BuildContext ctx) =>
        _Lightbox(asset: asset, caption: caption, showRegions: showRegions),
  );
}

class _Lightbox extends StatefulWidget {
  final Asset asset;
  final String caption;
  final bool showRegions;

  const _Lightbox({
    required this.asset,
    required this.caption,
    required this.showRegions,
  });

  @override
  State<_Lightbox> createState() => _LightboxState();
}

class _LightboxState extends State<_Lightbox> {
  double _zoom = 1;

  void _step(double d) => setState(() => _zoom = (_zoom + d).clamp(1, 6));

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Dialog.fullscreen(
      backgroundColor: const Color(0x00000000),
      child: Stack(
        children: <Widget>[
          // The backdrop closes; the stage does not.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => popIfCurrent(context),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 6,
                child: AnimatedScale(
                  scale: _zoom,
                  duration: const Duration(milliseconds: 80),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * .92,
                      maxHeight: MediaQuery.of(context).size.height * .82,
                    ),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: StimulusArt(
                        asset: widget.asset,
                        showRegions: widget.showRegions,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: Row(
              children: <Widget>[
                _LbBtn(icon: Icons.remove, onPressed: () => _step(-.4)),
                const SizedBox(width: 7),
                _LbBtn(
                  label: 'Reset',
                  onPressed: () => setState(() => _zoom = 1),
                ),
                const SizedBox(width: 7),
                _LbBtn(icon: Icons.add, onPressed: () => _step(.4)),
                const SizedBox(width: 7),
                _LbBtn(label: 'Close', onPressed: () => popIfCurrent(context)),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Text(
              '${widget.caption}  \u00b7  scroll to zoom  \u00b7  Esc to close',
              textAlign: TextAlign.center,
              style: context.type.small.copyWith(color: t.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _LbBtn extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final VoidCallback onPressed;

  const _LbBtn({this.icon, this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          height: 32,
          padding: EdgeInsets.symmetric(horizontal: label == null ? 8 : 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.bgApp,
            borderRadius: Radii.button,
            border: Border.all(color: t.border),
          ),
          child: icon != null
              ? Icon(icon, size: 16, color: t.textSecondary)
              : Text(label!, style: context.type.button),
        ),
      ),
    );
  }
}

/// Draws the numbered boxes over a real stimulus image.
///
/// The synthetic `_WarehousePainter` draws its own art AND its boxes; this one
/// draws boxes only, so it can sit on top of a PNG the server rendered.
class _RegionPainter extends CustomPainter {
  _RegionPainter({required this.tokens, required this.regions});

  final AppTokens tokens;
  final List<LabelRegion> regions;

  @override
  void paint(Canvas canvas, Size size) {
    // WHY PLACEMENT IS TRACKED. Every chip used to be pinned to its own box's
    // top-left corner with no regard for the chips already drawn. Overlapping
    // detections - a fedora inside a person, a sign on a building - therefore
    // stacked their chips on the same pixels, and the upper one hid the lower.
    // A six-box image rendered as 1,2,3,3,5,6: one number duplicated, one
    // absent, and no way for a candidate to tell which box either belonged to.
    // The server-side overlay solved this long ago (services/imaging.py
    // place_badge); the client overlay never did, so the same question was
    // readable as a baked PNG and unreadable when drawn live.
    final List<Rect> placed = <Rect>[];
    for (final LabelRegion r in regions) {
      final Rect box = Rect.fromLTWH(
        r.x * size.width,
        r.y * size.height,
        r.w * size.width,
        r.h * size.height,
      );
      canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = tokens.primary,
      );
      // The number goes in a filled chip: an outline alone is not identifiable
      // when several boxes overlap.
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: '${r.number}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final Rect chip = placeChip(box, tp.width + 10, 16, placed, size);
      placed.add(chip);
      canvas.drawRRect(
        RRect.fromRectAndRadius(chip, const Radius.circular(3)),
        Paint()..color = tokens.primary,
      );
      tp.paint(canvas, Offset(chip.left + 5, chip.top + 2));
    }
  }

  /// The first chip position that clears the chips already drawn.
  ///
  /// Mirrors the server's `place_badge`: try the anchors around the box in
  /// preference order, take the first that is on-canvas and collides with
  /// nothing, and fall back to stepping down-right so a chip is displaced
  /// rather than hidden. A number sitting slightly off its box is legible; a
  /// number underneath another number is not.
  ///
  /// Exposed for test via [debugPlaceLabelChip] - the placement rule is the
  /// whole defect, so it has to be assertable without pumping a widget and
  /// reading pixels back.
  static Rect placeChip(
    Rect box,
    double cw,
    double ch,
    List<Rect> placed,
    Size size,
  ) {
    final List<Offset> anchors = <Offset>[
      Offset(box.left, box.top - ch), // above, flush left
      Offset(box.left, box.top), // inside top-left
      Offset(box.right - cw, box.top - ch), // above, flush right
      Offset(box.right - cw, box.top), // inside top-right
      Offset(box.left, box.bottom), // below, flush left
      Offset(box.left - cw, box.top), // left of the box
      Offset(box.right, box.top), // right of the box
    ];
    for (final Offset a in anchors) {
      final Rect c = Rect.fromLTWH(a.dx, a.dy, cw, ch);
      if (c.left < 0 ||
          c.top < 0 ||
          c.right > size.width ||
          c.bottom > size.height) {
        continue;
      }
      if (placed.any((Rect p) => p.overlaps(c))) continue;
      return c;
    }
    // Every anchor is taken: step along a diagonal until something is clear.
    for (int i = 1; i <= 12; i++) {
      final double dx = (box.left + i * (cw + 2)).clamp(0.0, size.width - cw);
      final double dy = (box.top + i * (ch + 2)).clamp(0.0, size.height - ch);
      final Rect c = Rect.fromLTWH(dx, dy, cw, ch);
      if (!placed.any((Rect p) => p.overlaps(c))) return c;
    }
    return Rect.fromLTWH(box.left, box.top, cw, ch);
  }

  @override
  bool shouldRepaint(covariant _RegionPainter old) =>
      old.regions != regions || old.tokens != tokens;
}

/// Where a numbered chip lands, for test.
///
/// `_RegionPainter` is private and the placement rule IS the defect that made a
/// six-box image render as 1,2,3,3,5,6, so the rule needs to be assertable
/// directly rather than by pumping a widget and reading pixels back.
Rect debugPlaceLabelChip(
  Rect box,
  double chipWidth,
  double chipHeight,
  List<Rect> placed,
  Size size,
) => _RegionPainter.placeChip(box, chipWidth, chipHeight, placed, size);

// ── Form Studio additions ───────────────────────────────────────────────────
//
// Everything below serves the Form Studio designer/preview, which share this
// file's decode cache but none of the exam plumbing. Self-contained on
// purpose: the exam widgets above evolve with the exam runner, and these must
// not be caught in that.

/// A stimulus URL made fetchable, respecting who actually serves it.
///
/// `/media/...` files sit BESIDE the app bundle (the form-studio plates are
/// static files on the app's own host), so they resolve against the page
/// origin; every other relative path (`/api/v1/forms/media/`,
/// `/pro_assessment/qimage/`) is an Odoo route and gets the API base.
String stimulusMediaUrl(String url) {
  final String src = url.trim();
  if (src.startsWith('/media/')) return src;
  return resolveMediaUrl(src);
}

/// The right ImageProvider for a stimulus URL, whatever its scheme.
///
/// `NetworkImage` silently paints nothing for a `data:` URL on web, so a
/// pasted inline image must go through the same decode-and-cache path the
/// exam stimuli use. Null when the payload will not decode.
///
/// CARRIES THE BEARER, like every other media fetch in this app. The admin
/// proxies are `auth="user"` and this client holds a token, not a cookie, so a
/// header-less provider answers 401 - and an `ImageProvider` that fails paints
/// nothing at all, which is indistinguishable from a picture that was never
/// generated. This helper existing and NOT sending the header was worse than
/// it not existing, because every caller assumed it was the safe way.
ImageProvider? stimulusImageProvider(String url) {
  final String src = url.trim();
  if (src.isEmpty) return null;
  if (src.startsWith('data:')) {
    final Uint8List? bytes = _dataUrlBytes(src);
    return bytes == null ? null : MemoryImage(bytes);
  }
  return NetworkImage(
    stimulusMediaUrl(src),
    // CORS-EXEMPT: this provider feeds the ANNOTATION EDITOR, which reads
    // `.image` off the resolved result to get the pixel dimensions the region
    // overlay is pinned to. Under `WebHtmlElementStrategy.fallback` a
    // cross-origin image resolves to a `WebImageInfo` whose `.image` getter
    // throws `UnsupportedError` (`_web_image_info_web.dart`), and
    // `_RegionOverlayImageState._resolve` reads it inside a listener whose
    // `onError` swallows everything - so the overlay would silently pin its
    // boxes to nothing. Staying on the byte-fetch default is deliberate: the
    // editor only ever annotates OUR OWN stored media, which is same-origin and
    // needs the bearer, so the third-party case this exemption gives up does
    // not arise here.
    headers: mediaAuthHeaders,
  );
}

/// ONE WAY TO PUT A STIMULUS URL ON SCREEN. Use this, never a bare
/// `Image.network`.
///
/// Three things go wrong when a screen rolls its own, and all three have:
///
///   * NO BEARER. The `/assessments_be/admin_*` proxies are `auth="user"` and
///     this client authenticates with a token. A header-less fetch 401s, and a
///     failed `Image` paints an empty box the colour of the plate behind it -
///     so a thumbnail rendered here could be visible while the same picture
///     opened in a lightbox was blank.
///   * A `data:` URL HANDED TO `Image.network`, which fails silently on web.
///     The module inlines rendered PNGs that way.
///   * NO `errorBuilder`, which is what turns every one of the above into a
///     blank rectangle rather than a state anyone can report.
///
/// [onError] lets a caller keep its own empty state; the default says the
/// fetch FAILED rather than that nothing exists - see [StimulusUnavailable]
/// for why those two must not look alike.
Widget stimulusImage(
  String url, {
  BoxFit fit = BoxFit.contain,
  Widget Function(BuildContext context)? onError,
}) {
  Widget failed(BuildContext c, Object _, StackTrace? _) =>
      onError?.call(c) ?? const StimulusUnavailable();

  final String src = url.trim();
  if (src.isEmpty) {
    return Builder(builder: (BuildContext c) => failed(c, '', null));
  }
  if (src.startsWith('data:')) {
    final Uint8List? bytes = _dataUrlBytes(src);
    if (bytes == null) {
      return Builder(builder: (BuildContext c) => failed(c, '', null));
    }
    return Image.memory(
      bytes,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: failed,
    );
  }
  final String resolved = stimulusMediaUrl(src);
  final bool ours = isOurMediaOrigin(resolved);
  // ELEMENT-FIRST FOR A FOREIGN HOST, byte path for our own - see the same
  // decision in `StimulusArt`. An `<img>` displays what an XHR cannot fetch,
  // because a browser needs CORS to READ pixels and not to SHOW them.
  if (!ours) {
    return ImagePlate(
      url: resolved,
      fit: fit,
      onFailed: onError ?? (BuildContext c) => const StimulusUnavailable(),
    );
  }
  return Image.network(
    resolved,
    // THE BEARER GOES ONLY WHERE IT IS OWED, and this is not tidiness - it
    // decides whether a third-party picture can render at all. Setting headers
    // forces the byte-fetch path and disables the `<img>` element path
    // entirely, and an XHR needs the far host to send
    // `Access-Control-Allow-Origin`, which almost no image host does. So
    // sending our token to someone else's CDN is what BROKE those images: an
    // `<img>` would have displayed them, because a browser needs CORS to READ
    // an image, not to SHOW one.
    //
    // Our own `auth="user"` admin proxies still get it, and must - see
    // `mediaAuthHeaders`.
    headers: ours ? mediaAuthHeaders : const <String, String>{},
    webHtmlElementStrategy: ours
        ? WebHtmlElementStrategy.never
        : WebHtmlElementStrategy.fallback,
    fit: fit,
    gaplessPlayback: true,
    errorBuilder: failed,
  );
}

/// A real image with a numbered region overlay pinned to its pixels.
///
/// Resolves the provider's intrinsic size, then lays the image out at its OWN
/// aspect ratio (letterboxed inside whatever box the parent gives it) with the
/// region canvas filling that same box - so a fraction of the canvas IS a
/// fraction of the image. Used by the Form Studio designer (drag to DRAW boxes
/// via [onRegionDrawn]) and its preview (tap a marker via [onRegionTap], the
/// active one emphasized).
class RegionOverlayImage extends StatefulWidget {
  final ImageProvider provider;
  final List<LabelRegion> regions;

  /// The region drawn emphasized (the one whose answer is being edited).
  final int? activeNumber;

  /// Tapping a numbered marker. A tap that misses every marker goes to
  /// [onBackgroundTap] instead.
  final ValueChanged<int>? onRegionTap;
  final VoidCallback? onBackgroundTap;

  /// Author mode: drag on the image to draw a new box. Called on release with
  /// a FRACTIONAL region whose number is 0 - the caller assigns the real
  /// number. When set, drags draw; taps still hit-test existing markers.
  ///
  /// A TAP THAT MISSES EVERY MARKER PLACES A POINT, sized [pointSize] square
  /// and centred on the tap, and arrives through this same callback. Clicking is
  /// how an examiner marks "the defect is HERE": dragging a box demands they
  /// decide how big the defect is, which is a judgement the question does not
  /// ask for and the grader never reads - only the NUMBER and its golden answer
  /// are marked. A point is still a region on the wire (`box_2d`, Gemini's
  /// 0-1000 space), so nothing downstream needed a new shape.
  final ValueChanged<LabelRegion>? onRegionDrawn;

  /// Side of a click-placed point, as a fraction of the image. Big enough to
  /// see and to hit again with [onRegionTap]'s slop, small enough to read as a
  /// pin rather than a box.
  final double pointSize;

  const RegionOverlayImage({
    super.key,
    required this.provider,
    required this.regions,
    this.activeNumber,
    this.onRegionTap,
    this.onBackgroundTap,
    this.onRegionDrawn,
    this.pointSize = .035,
  });

  @override
  State<RegionOverlayImage> createState() => _RegionOverlayImageState();
}

class _RegionOverlayImageState extends State<RegionOverlayImage> {
  double? _aspect;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// The box being dragged out right now, in fractions. Draw mode only.
  Rect? _draft;
  Offset? _dragFrom;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant RegionOverlayImage old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      _aspect = null;
      _resolve();
    }
  }

  void _resolve() {
    _detach();
    final ImageStream stream = widget.provider.resolve(
      ImageConfiguration.empty,
    );
    final ImageStreamListener listener = ImageStreamListener((
      ImageInfo info,
      bool _,
    ) {
      // AN `<img>`-BACKED IMAGE CANNOT REPORT ITS SIZE HERE. When Flutter falls
      // back to an HTML element (a cross-origin host with no CORS headers) the
      // `ImageInfo` it hands back throws `UnsupportedError` from `.image`,
      // because there are no readable pixels behind it - that is the whole
      // reason it took the element path. The listener's `onError` would swallow
      // that throw and leave `_aspect` null forever, which silently drops the
      // region overlay and the click-to-place gesture.
      //
      // 4/3 IS A GUESS, and a guess is wrong here: this widget's contract is
      // that a fraction of the canvas IS a fraction of the image, so a wrong
      // aspect mislocates every box the examiner draws. So the providers that
      // feed THIS widget are deliberately kept on the byte path
      // (`stimulusImageProvider` sends headers and never asks for the element
      // fallback); annotation genuinely needs pixel access. This guard only
      // stops a future caller turning that into an invisible failure.
      double aspect;
      try {
        aspect = info.image.height == 0
            ? 4 / 3
            : info.image.width / info.image.height;
        info.dispose();
      } on UnsupportedError {
        aspect = 4 / 3;
      }
      if (mounted && _aspect != aspect) setState(() => _aspect = aspect);
    }, onError: (Object _, StackTrace? _) {});
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _detach() {
    final ImageStream? s = _stream;
    final ImageStreamListener? l = _listener;
    if (s != null && l != null) s.removeListener(l);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  /// The region under a tap, preferring the SMALLEST hit when boxes nest or
  /// overlap - the big box would otherwise shadow every box inside it. The
  /// number chip above each box counts as part of it, and a small slop makes
  /// hairline boxes tappable at all.
  int? _hit(Offset pos, Size size) {
    const double slop = 6;
    const double chipH = 16;
    LabelRegion? best;
    double bestArea = double.infinity;
    double bestDist = double.infinity;
    for (final LabelRegion r in widget.regions) {
      final Rect box = Rect.fromLTWH(
        r.x * size.width,
        r.y * size.height,
        r.w * size.width,
        r.h * size.height,
      );
      final Rect zone = Rect.fromLTRB(
        box.left - slop,
        box.top - slop - (box.top - chipH < 0 ? 0 : chipH),
        box.right + slop,
        box.bottom + slop,
      );
      if (!zone.contains(pos)) continue;
      final double area = box.width * box.height;
      final double dist = (pos - box.center).distance;
      // SMALLEST FIRST, THEN NEAREST - SNo 171.
      //
      // Smallest-area still wins, so a box nested inside a bigger one is still
      // reachable. But `area < bestArea` alone could not separate markers of the
      // SAME size: click-placed points are all `pointSize` square, so two that
      // overlap tie on area, the strict comparison keeps whichever came first in
      // the list, and every other marker in that cluster became permanently
      // unclickable - the examiner could see point 5 and only ever select
      // point 4.
      //
      // The tie-break is distance from the tap to the box centre, which is what
      // a person means by clicking one of two overlapping pins: the one they
      // clicked nearer the middle of. The epsilon is because these are
      // fractions scaled by a canvas width, so equal boxes are equal to within
      // floating-point noise rather than exactly.
      const double eps = 0.5;
      final bool smaller = area < bestArea - eps;
      final bool tiedButNearer = area <= bestArea + eps && dist < bestDist;
      if (smaller || tiedButNearer) {
        bestArea = area;
        bestDist = dist;
        best = r;
      }
    }
    return best?.number;
  }

  static Offset _frac(Offset p, Size size) => Offset(
    (p.dx / size.width).clamp(0.0, 1.0),
    (p.dy / size.height).clamp(0.0, 1.0),
  );

  @override
  Widget build(BuildContext context) {
    if (_aspect == null) {
      return Image(
        image: widget.provider,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    }
    final Widget overlay = CustomPaint(
      painter: _FormRegionPainter(
        tokens: context.tokens,
        regions: widget.regions,
        activeNumber: widget.activeNumber,
        draft: _draft,
      ),
      child: const SizedBox.expand(),
    );
    final bool interactive =
        widget.onRegionTap != null || widget.onRegionDrawn != null;
    return Center(
      child: AspectRatio(
        aspectRatio: _aspect!,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image(
              image: widget.provider,
              fit: BoxFit.fill,
              gaplessPlayback: true,
            ),
            if (!interactive)
              overlay
            else
              LayoutBuilder(
                builder: (BuildContext ctx, BoxConstraints c) {
                  final Size size = Size(c.maxWidth, c.maxHeight);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (TapUpDetails d) {
                      final int? n = _hit(d.localPosition, size);
                      if (n != null) {
                        // An existing marker always wins the tap, so a second
                        // click on a point SELECTS it rather than stacking
                        // another point on top of it.
                        widget.onRegionTap?.call(n);
                        return;
                      }
                      // AUTHOR MODE: a tap on empty image places a point.
                      // Centred on the click and clamped so a point placed at
                      // the very edge stays fully on the picture - a box hanging
                      // off the frame would serve a `box_2d` outside 0-1000.
                      if (widget.onRegionDrawn != null) {
                        final Offset c = _frac(d.localPosition, size);
                        final double s = widget.pointSize;
                        widget.onRegionDrawn!(
                          LabelRegion(
                            number: 0,
                            x: (c.dx - s / 2).clamp(0.0, 1.0 - s),
                            y: (c.dy - s / 2).clamp(0.0, 1.0 - s),
                            w: s,
                            h: s,
                          ),
                        );
                        return;
                      }
                      widget.onBackgroundTap?.call();
                    },
                    // Draw mode: a drag rubber-bands a new box. The fractions
                    // are clamped so a drag that leaves the image commits a
                    // box that stays on it.
                    onPanStart: widget.onRegionDrawn == null
                        ? null
                        : (DragStartDetails d) =>
                              setState(() => _dragFrom = d.localPosition),
                    onPanUpdate: widget.onRegionDrawn == null
                        ? null
                        : (DragUpdateDetails d) {
                            final Offset from = _dragFrom ?? d.localPosition;
                            setState(() {
                              _draft = Rect.fromPoints(
                                _frac(from, size),
                                _frac(d.localPosition, size),
                              );
                            });
                          },
                    onPanEnd: widget.onRegionDrawn == null
                        ? null
                        : (DragEndDetails d) {
                            final Rect? r = _draft;
                            setState(() {
                              _draft = null;
                              _dragFrom = null;
                            });
                            // A sub-1% sliver is a slipped click, not a box.
                            if (r != null && r.width > .01 && r.height > .01) {
                              widget.onRegionDrawn!(
                                LabelRegion(
                                  number: 0,
                                  x: r.left,
                                  y: r.top,
                                  w: r.width,
                                  h: r.height,
                                ),
                              );
                            }
                          },
                    onPanCancel: widget.onRegionDrawn == null
                        ? null
                        : () => setState(() {
                            _draft = null;
                            _dragFrom = null;
                          }),
                    child: overlay,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Draws the numbered boxes for [RegionOverlayImage]: the active region
/// emphasized and painted last (its outline stays on top of any neighbour it
/// overlaps), the in-progress draft box with no number chip.
class _FormRegionPainter extends CustomPainter {
  _FormRegionPainter({
    required this.tokens,
    required this.regions,
    this.activeNumber,
    this.draft,
  });

  final AppTokens tokens;
  final List<LabelRegion> regions;
  final int? activeNumber;
  final Rect? draft;

  @override
  void paint(Canvas canvas, Size size) {
    // Chips already placed, so an overlapping one can step aside - SNo 171.
    // Shared across both passes below: the active marker's chip must dodge the
    // inactive ones too, and vice versa.
    final List<Rect> placed = <Rect>[];
    for (final LabelRegion r in regions) {
      if (r.number != activeNumber) {
        _paintRegion(canvas, size, r, false, placed);
      }
    }
    for (final LabelRegion r in regions) {
      if (r.number == activeNumber) _paintRegion(canvas, size, r, true, placed);
    }
    final Rect? d = draft;
    if (d != null) {
      final Rect box = Rect.fromLTWH(
        d.left * size.width,
        d.top * size.height,
        d.width * size.width,
        d.height * size.height,
      );
      canvas.drawRect(box, Paint()..color = tokens.primary.o(.12));
      canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = tokens.primary,
      );
    }
  }

  void _paintRegion(
    Canvas canvas,
    Size size,
    LabelRegion r,
    bool active,
    List<Rect> placed,
  ) {
    final Rect box = Rect.fromLTWH(
      r.x * size.width,
      r.y * size.height,
      r.w * size.width,
      r.h * size.height,
    );
    if (active) {
      canvas.drawRect(box, Paint()..color = tokens.primary.o(.16));
    }
    canvas.drawRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 3 : 2
        ..color = tokens.primary,
    );
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: '${r.number}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final double chipW = tp.width + 10;
    // THE NUMBER MUST BE READABLE, WHICH MEANS IT MUST NOT BE UNDER ANOTHER ONE.
    //
    // The chip was always drawn at (box.left, box.top - 16). Two markers on the
    // same defect - which is normal, an examiner marks a cluster of related
    // flaws - drew their chips on exactly the same pixels, so the cluster read
    // as ONE marker with a single number and the examiner had no way to tell
    // which points existed. Reported as SNo 171.
    //
    // Candidate positions, in order of preference: above-left (the authored
    // look), then stepped right along the top, then below-left, then stepped
    // right along the bottom. The first one clear of every chip already drawn
    // wins; if a plate is dense enough that none is clear, the last candidate is
    // used rather than dropping the number - an unnumbered box is worse than a
    // crowded one, because the answer key is keyed BY number.
    final double above = box.top - 16 < 0 ? box.top : box.top - 16;
    final double below = box.bottom + 16 > size.height
        ? math.max(0, box.bottom - 16)
        : box.bottom;
    final List<Offset> candidates = <Offset>[
      Offset(box.left, above),
      Offset(box.left + chipW + 2, above),
      Offset(box.left + (chipW + 2) * 2, above),
      Offset(box.left, below),
      Offset(box.left + chipW + 2, below),
      Offset(box.left + (chipW + 2) * 2, below),
    ];
    Rect chip = Rect.fromLTWH(
      candidates.first.dx,
      candidates.first.dy,
      chipW,
      16,
    );
    for (final Offset at in candidates) {
      // Kept on the picture: a chip pushed past the right edge would be clipped
      // to nothing, which is the same invisible-number failure by another route.
      final double left = math.min(at.dx, math.max(0, size.width - chipW));
      final Rect tryChip = Rect.fromLTWH(left, at.dy, chipW, 16);
      chip = tryChip;
      if (!placed.any((Rect p) => p.overlaps(tryChip))) break;
    }
    placed.add(chip);
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, const Radius.circular(3)),
      Paint()..color = tokens.primary,
    );
    tp.paint(canvas, Offset(chip.left + 5, chip.top + 2));
  }

  @override
  bool shouldRepaint(covariant _FormRegionPainter old) =>
      old.regions != regions ||
      old.tokens != tokens ||
      old.activeNumber != activeNumber ||
      old.draft != draft;
}
