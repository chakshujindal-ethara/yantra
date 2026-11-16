/// The non-web half of the image plate.
///
/// A Flutter VM test (and any future desktop or mobile host) has no
/// `HTMLImageElement`, so this falls back to the ordinary Flutter image path -
/// which is CORRECT off-web rather than merely tolerable: `Image.network` on the
/// VM fetches bytes with no same-origin policy in the way, so there is nothing
/// for an element to fix. The `<img>` element lives in `image_plate_web.dart`
/// and is chosen by the conditional export in `image_plate.dart`.
///
/// Every public name here must match the web half's, with identical constructor
/// signatures, or the conditional export fails to type-check on one platform.
library;

import 'package:flutter/material.dart';

class ImagePlate extends StatelessWidget {
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

  /// Drawn when the image cannot be displayed. The plate has no opinion about
  /// what a failure looks like; the caller owns its own empty state.
  final Widget Function(BuildContext context)? onFailed;

  @override
  Widget build(BuildContext context) => Image.network(
    url,
    // CORS-EXEMPT: this half only ever runs OFF-WEB, where there is no
    // same-origin policy and `webHtmlElementStrategy` is inert anyway
    // (`_network_image_io.dart` stores the field and never reads it). The web
    // half of this same widget is the `<img>` element that does the real work.
    fit: fit,
    errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
        onFailed?.call(c) ?? const SizedBox.shrink(),
  );
}
