/// The web half of the image plate: a real `<img>` in a platform view.
///
/// WHAT THIS BUYS. The browser loads the URL itself, as an ordinary subresource,
/// so a host that sends no `Access-Control-Allow-Origin` still DISPLAYS - CORS
/// governs reading an image's pixels, not showing it. That is why a pasted video
/// URL always worked and a pasted image URL did not: the video was already an
/// element and the image was an XHR.
///
/// Mirrors `video_plate_web.dart`'s mechanics deliberately - the same guard set,
/// the same content-keyed view type, the same rule about not reaching into
/// `widget` from a factory closure - because that file has already been through
/// the failures this one would otherwise repeat.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class ImagePlate extends StatefulWidget {
  const ImagePlate({
    super.key,
    required this.url,
    this.fit = BoxFit.contain,
    this.onFailed,
  });

  /// Already resolved against our own origin by the caller - this widget never
  /// rewrites a URL.
  final String url;

  final BoxFit fit;

  /// Drawn when the element reports an error. See [_failed] for why this cannot
  /// be left to Flutter's `errorBuilder`.
  final Widget Function(BuildContext context)? onFailed;

  @override
  State<ImagePlate> createState() => _ImagePlateState();
}

class _ImagePlateState extends State<ImagePlate> {
  /// View types already registered with the platform-view registry.
  ///
  /// `registerViewFactory` THROWS on a repeated id, and this widget rebuilds
  /// whenever its plate repaints, so the guard is not an optimisation. Static
  /// because the registry itself is process-wide - the same reasoning as
  /// `video_plate_web.dart`.
  static final Set<String> _registered = <String>{};

  String? _viewType;

  /// The element reported `error`. Held here because a platform view has no
  /// `errorBuilder` - see [_failed].
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(ImagePlate old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _start();
  }

  void _start() {
    final String url = widget.url.trim();
    _failed = false;
    if (url.isEmpty) {
      _viewType = null;
      return;
    }
    // CONTENT-KEYED, so re-mounting the same picture reuses the same factory and
    // the guard above makes it a no-op. A counter here would mint a new element
    // per rebuild and re-download the image every repaint.
    _viewType = _register('etp-image-${url.hashCode}', url);
  }

  /// Whoever is currently showing each view type, so a cached factory can tell
  /// the LIVE widget its element failed.
  ///
  /// The factory is registered once per URL and then reused, so a callback
  /// captured at registration time would belong to the first widget that ever
  /// showed that image - long disposed by the second mount. Looking the callback
  /// up through this map at ELEMENT-CREATION time instead means the factory
  /// closure holds no widget state at all, which is the rule
  /// `video_plate_web.dart:340-342` records, and the notification still reaches
  /// whoever is on screen now.
  static final Map<String, VoidCallback> _onError = <String, VoidCallback>{};

  /// Register an `<img>` factory for [type], once.
  ///
  /// NOTHING IS READ OFF `widget` INSIDE THE CLOSURE - see [_onError].
  String _register(String type, String url) {
    if (_registered.add(type)) {
      ui_web.platformViewRegistry.registerViewFactory(type, (int _) {
        final web.HTMLImageElement el = web.HTMLImageElement()
          ..src = url
          // `100%` on both axes, because a platform view has NO intrinsic size:
          // the Flutter side supplies the bounds and the element fills them.
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.objectFit = 'contain'
          // The element composites ABOVE the Flutter canvas, so without this it
          // swallows the zoom tap, page scroll, and anything drawn over the
          // plate (the region overlay, the zoom hint chip).
          ..style.pointerEvents = 'none';
        // THE ELEMENT REPORTS ITS OWN FAILURE. A platform view gets no
        // `errorBuilder`, so without this a broken URL paints an empty box the
        // exact colour of the plate behind it - indistinguishable from a
        // question whose picture was never generated, which is the failure
        // `stimulus.dart`'s empty states exist to eliminate.
        el.onerror = ((web.Event _) => _onError[type]?.call()).toJS;
        passHostPointersThrough(el);
        return el;
      });
    }
    return type;
  }

  void _onElementError() {
    if (mounted && !_failed) setState(() => _failed = true);
  }

  @override
  void dispose() {
    final String? type = _viewType;
    // Only clear the slot if it is still OURS: a newer plate showing the same
    // image has already claimed it, and stealing it back would silence its
    // failures.
    if (type != null && _onError[type] == _onElementError) {
      _onError.remove(type);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? type = _viewType;
    if (type == null || _failed) {
      return widget.onFailed?.call(context) ?? const SizedBox.shrink();
    }
    _onError[type] = _onElementError;
    // IGNORED FOR HIT TESTING. A platform view joins the gesture arena for
    // every pointer that lands on it and wins a tap there, so the InkWell or
    // GestureDetector around a picture never fired: a click on a proctoring
    // snapshot's picture did nothing while a click on its caption opened it
    // (21 Oct 2026). The picture takes no input of its own.
    return IgnorePointer(child: HtmlElementView(viewType: type));
  }
}

/// Switch off the pointer on [el]'s host too. `flt-platform-view`, the parent
/// Flutter mounts it in just after the factory returns, takes the pointer
/// otherwise, so a click on a picture never reached the Flutter tap around it:
/// a proctoring snapshot did not open in a real browser (21 Oct 2026), while
/// tests and screen-reader mode, which route around the host, did. The camera
/// preview switches its host off the same way.
void passHostPointersThrough(web.Element el) => Timer.run(
  () => (el.parentElement as web.HTMLElement?)?.style.pointerEvents = 'none',
);
