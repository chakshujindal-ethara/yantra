/// The video plate, resolved per platform.
///
/// `package:web` cannot compile under the VM test runner, so the browser half
/// is isolated behind this conditional import - the same shape the proctor and
/// the file picker already use.
library;

import 'package:flutter/widgets.dart'
    show BuildContext, InheritedWidget, Widget;

import '../../domain/models.dart' show Asset;
import 'audio_plate.dart' show AudioPlate;
import 'video_plate_stub.dart'
    if (dart.library.js_interop) 'video_plate_web.dart'
    show VideoPlate;

export 'video_plate_stub.dart'
    if (dart.library.js_interop) 'video_plate_web.dart';

/// Marks the media plates below as covered by an overlay on the SAME page (the
/// exam's blocking surfaces: fullscreen, webcam, time up), so a native player
/// there stops taking the clicks meant for the overlay. A dialog on its own
/// route needs no marker: `MediaElementView` reads the route itself.
class MediaInert extends InheritedWidget {
  const MediaInert({super.key, required this.inert, required super.child});

  final bool inert;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaInert>()?.inert ?? false;

  @override
  bool updateShouldNotify(MediaInert oldWidget) => inert != oldWidget.inert;
}

/// A public video-HOSTING link, as opposed to a direct video FILE. Neither
/// YouTube nor Vimeo serve raw bytes at their public URLs - both require
/// their own embeddable player - so a link like `youtube.com/watch?v=...`
/// handed straight to `<video src>` mounts a real element that never has
/// anything to decode: no error, no frame, just a silent 0:00 forever.
///
/// Resolves to the platform (`yt`/`vimeo`) and the bare video id, not a
/// URL - `__videoEmbed`'s player constructors take an id directly, and
/// there is no embed URL to build here at all: the `controls: 0`
/// player is created from the id, not loaded from a query-param'd src.
///
/// Lives here, not in `video_plate_web.dart`, because the detection itself
/// touches no web API - a non-web caller (the help-text video popup trigger)
/// needs the same answer without pulling in `dart:js_interop`.
({String kind, String id})? publicVideoEmbedRef(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasScheme) return null;
  final String host = uri.host.toLowerCase();
  final List<String> segs = uri.pathSegments
      .where((String s) => s.isNotEmpty)
      .toList();

  if (host == 'youtu.be') {
    final String id = segs.isNotEmpty ? segs.first : '';
    return id.isEmpty ? null : (kind: 'yt', id: id);
  }
  if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    String? id;
    if (segs.isNotEmpty && segs.first == 'watch') {
      id = uri.queryParameters['v'];
    } else if (segs.length >= 2 &&
        (segs[0] == 'embed' || segs[0] == 'shorts')) {
      id = segs[1];
    }
    return (id == null || id.isEmpty) ? null : (kind: 'yt', id: id);
  }
  if (host == 'vimeo.com' || host.endsWith('.vimeo.com')) {
    // `vimeo.com/123456789` or `player.vimeo.com/video/123456789` - the id
    // is always the last path segment on both shapes.
    final String id = segs.isNotEmpty ? segs.last : '';
    return RegExp(r'^\d+$').hasMatch(id) ? (kind: 'vimeo', id: id) : null;
  }
  return null;
}

/// What a media URL actually needs on screen.
///
/// ONE ANSWER, SHARED. This decision used to live in four places that
/// disagreed: `_looksImage` in the designer, `_looksVideoUrl` in the preview,
/// an inline copy in the preview's A/B tiles, and `_looks_like_video` on the
/// server. All four tested the extension of the WHOLE url, so two very
/// ordinary shapes were classified as images and handed to `Image.network`,
/// which mounts an element with nothing to decode - a dead plate, no error:
///
///   * a YouTube or Vimeo link, which has no extension at all;
///   * `https://cdn.example.com/clip.mp4?sig=abc`, whose extension is hidden
///     behind the query string every signed CDN URL carries.
///
/// [MediaKind.image] stays the default for an unknown shape, which is what the
/// old tests encode: our own `/api/v1/forms/media/<uuid>.png` proxy paths and
/// most pasted links are stills.
enum MediaKind {
  /// A public host's own player - see [publicVideoEmbedRef].
  embeddedVideo,

  /// A direct video FILE, playable by a `<video src>`.
  videoFile,

  /// A direct AUDIO file, playable by an `<audio src>` - see `AudioPlate`.
  audio,

  /// Anything else, drawn as a still.
  image,
}

/// The audio extensions Form Studio accepts (the server's allow-list: mp3, wav,
/// m4a, ogg, aac, flac). `.mp4` stays a video even though m4a is the same
/// container: the extension is the only signal a pasted link carries.
const List<String> _audioExtensions = <String>[
  '.mp3',
  '.wav',
  '.m4a',
  '.ogg',
  '.aac',
  '.flac',
];

/// The kind of media at [raw].
///
/// The extension is read off the PATH, not the whole string, so a query or a
/// fragment cannot hide it. Mirrors `studio_form._looks_like_video` on the
/// server, which decides the same thing at publish time - the two must agree or
/// a clip renders here and publishes as a picture.
MediaKind mediaKindOf(String raw) {
  final String src = raw.trim();
  if (src.isEmpty) return MediaKind.image;
  if (publicVideoEmbedRef(src) != null) return MediaKind.embeddedVideo;

  // A relative proxy path (`/api/v1/forms/media/x.mp4`) parses fine and has
  // the path we want; anything unparseable falls back to the raw string.
  final String path = (Uri.tryParse(src)?.path ?? src).toLowerCase();
  if (_audioExtensions.any(path.endsWith)) return MediaKind.audio;
  return (path.endsWith('.mp4') ||
          path.endsWith('.webm') ||
          path.endsWith('.mov'))
      ? MediaKind.videoFile
      : MediaKind.image;
}

/// True when [raw] is a clip of either sort (video OR audio), so it belongs in
/// a player rather than an image.
bool isVideoMedia(String raw) => mediaKindOf(raw) != MediaKind.image;

/// The kind of a clip asset: the server's `kind: "audio"` wins, because a
/// candidate clip url is a token path with no extension to read; otherwise the
/// url decides, exactly as [mediaKindOf].
MediaKind mediaKindOfAsset(Asset asset) =>
    asset.kind == 'audio' ? MediaKind.audio : mediaKindOf(asset.url ?? '');

/// The plate for one clip asset: [AudioPlate] for audio, [VideoPlate] for every
/// other clip. THE ONE PLACE this choice is made, so a new call site cannot
/// hand an mp3 to a `<video>` element and get a black rectangle.
Widget clipPlateFor(
  Asset asset, {
  String caption = '',
  bool allowDownload = false,
}) => mediaKindOfAsset(asset) == MediaKind.audio
    ? AudioPlate(asset: asset, caption: caption, allowDownload: allowDownload)
    : VideoPlate(asset: asset, caption: caption, allowDownload: allowDownload);

/// The name the audio plate prints for a clip: the caption the caller passed,
/// else the asset's label, else the file name in the url, else "Audio clip".
///
/// The file name counts only when the last path segment LOOKS like a file
/// (`clip.mp3`): a candidate clip url ends in a bare id (`.../qvideo/<token>/9`)
/// and printing "9" would be worse than the generic words.
String audioClipName(Asset asset, String caption) {
  if (caption.trim().isNotEmpty) return caption.trim();
  if (asset.label.trim().isNotEmpty) return asset.label.trim();
  final String path = Uri.tryParse((asset.url ?? '').trim())?.path ?? '';
  final String last = path.split('/').last;
  // A copied link is stored as `<32 hex>.mp3`: a storage key, not a name.
  if (RegExp(r'^[0-9a-f]{32}\.').hasMatch(last)) return 'Audio clip';
  return last.contains('.') ? last : 'Audio clip';
}
