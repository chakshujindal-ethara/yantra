// A framed image that opens a full-screen, pan-and-zoom lightbox on click.
//
// Wraps any in-place image thumbnail: the pointer picks up the zoom-in
// cursor over it, and a click opens the raw image large, where both a form
// creator (designer) and a respondent (preview) can zoom in to inspect
// detail and back out. Images only - videos keep their own player.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import '../../widgets/buttons.dart' show popIfCurrent;
import '../exam/stimulus.dart';

/// Wrap a framed image with hover-to-zoom-cursor + click-to-open behaviour.
class ZoomableImage extends StatelessWidget {
  const ZoomableImage({super.key, required this.url, required this.child});

  /// The full-resolution image to open in the lightbox.
  final String url;

  /// The in-place thumbnail (already framed/clipped by the caller).
  final Widget child;

  void _open(BuildContext context) => showImageLightbox(context, url);

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.zoomIn,
      child: GestureDetector(onTap: () => _open(context), child: child),
    );
  }
}

/// Open the pan-and-zoom lightbox directly - for surfaces whose in-place
/// image handles its own taps (the annotation plate) and so cannot be
/// wrapped in [ZoomableImage].
void showImageLightbox(BuildContext context, String url) =>
    showImageGallery(context, <GalleryPage>[(url: url, title: '', sub: '')], 0);

/// One picture in [showImageGallery], with its caption (either may be empty).
typedef GalleryPage = ({String url, String title, String sub});

/// The same lightbox over several pictures, opened on [index]: previous/next
/// buttons and the Left/Right keys step through them, and each page starts
/// unzoomed.
Future<void> showImageGallery(
  BuildContext context,
  List<GalleryPage> pages,
  int index,
) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.92),
  builder: (BuildContext _) => _Lightbox(pages: pages, index: index),
);

class _Lightbox extends StatefulWidget {
  const _Lightbox({required this.pages, required this.index});
  final List<GalleryPage> pages;
  final int index;

  @override
  State<_Lightbox> createState() => _LightboxState();
}

class _LightboxState extends State<_Lightbox> {
  final TransformationController _ctrl = TransformationController();
  static const double _min = 1.0;
  static const double _max = 6.0;

  late int _at = widget.index.clamp(0, widget.pages.length - 1);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Step to the page [by] away, unzoomed; nothing past either end.
  void _go(int by) {
    final int next = _at + by;
    if (next < 0 || next >= widget.pages.length) return;
    setState(() {
      _at = next;
      _ctrl.value = Matrix4.identity();
    });
  }

  double get _scale => _ctrl.value.getMaxScaleOnAxis();

  void _zoomBy(double factor) {
    final double target = (_scale * factor).clamp(_min, _max);
    // Scale about the viewport centre.
    final Size size = MediaQuery.of(context).size;
    final Offset c = Offset(size.width / 2, size.height / 2);
    final Matrix4 m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(target, target, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    setState(() => _ctrl.value = m);
  }

  void _reset() => setState(() => _ctrl.value = Matrix4.identity());

  @override
  Widget build(BuildContext context) {
    final GalleryPage page = widget.pages[_at];
    final bool many = widget.pages.length > 1;
    final TextStyle onDark = context.type.body.copyWith(color: Colors.white);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          child: Stack(
            children: <Widget>[
              // The zoomable image, filling the dialog.
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _ctrl,
                  minScale: _min,
                  maxScale: _max,
                  child: Center(
                    // Through the shared helper so the lightbox carries the
                    // same bearer its own thumbnail did. It did not, which is
                    // how a picture could render in the grid and be blank
                    // when opened.
                    // Keyed per page, so one page's failed load does not
                    // carry over to the next.
                    child: KeyedSubtree(
                      key: ValueKey<int>(_at),
                      child: stimulusImage(
                        page.url,
                        onError: (BuildContext c) =>
                            Text('Image unavailable', style: onDark),
                      ),
                    ),
                  ),
                ),
              ),
              // Caption, top-left.
              if (page.title.isNotEmpty || page.sub.isNotEmpty)
                Positioned(
                  top: 16,
                  left: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (page.title.isNotEmpty)
                        Text(
                          page.title,
                          style: onDark.copyWith(fontWeight: FontWeight.w600),
                        ),
                      if (page.sub.isNotEmpty)
                        Text(
                          page.sub,
                          style: context.type.small.copyWith(
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                    ],
                  ),
                ),
              if (many) ...<Widget>[
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _CircleBtn(
                      icon: Icons.chevron_left,
                      tooltip: 'Previous',
                      onTap: _at > 0 ? () => _go(-1) : null,
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _CircleBtn(
                      icon: Icons.chevron_right,
                      tooltip: 'Next',
                      onTap: _at < widget.pages.length - 1
                          ? () => _go(1)
                          : null,
                    ),
                  ),
                ),
              ],
              // Controls, top-right.
              Positioned(
                top: 16,
                right: 16,
                child: Row(
                  children: <Widget>[
                    _CircleBtn(
                      icon: Icons.zoom_out,
                      tooltip: 'Zoom out',
                      onTap: () => _zoomBy(1 / 1.4),
                    ),
                    const SizedBox(width: 8),
                    _CircleBtn(
                      icon: Icons.zoom_in,
                      tooltip: 'Zoom in',
                      onTap: () => _zoomBy(1.4),
                    ),
                    const SizedBox(width: 8),
                    _CircleBtn(
                      icon: Icons.crop_free,
                      tooltip: 'Reset',
                      onTap: _reset,
                    ),
                    const SizedBox(width: 8),
                    _CircleBtn(
                      icon: Icons.close,
                      tooltip: 'Close',
                      onTap: () => popIfCurrent(context),
                    ),
                  ],
                ),
              ),
              // Hint, bottom-centre.
              Positioned(
                left: 0,
                right: 0,
                bottom: 20,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: Radii.pill,
                    ),
                    child: Text(
                      many
                          ? 'Scroll or pinch to zoom · drag to pan · '
                                'left/right arrows to step'
                          : 'Scroll or pinch to zoom · drag to pan',
                      style: context.type.small.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;

  /// Null draws the button dimmed and inert (the end of a gallery).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.14),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              icon,
              size: 20,
              color: Colors.white.withValues(alpha: onTap == null ? 0.3 : 1),
            ),
          ),
        ),
      ),
    );
  }
}
