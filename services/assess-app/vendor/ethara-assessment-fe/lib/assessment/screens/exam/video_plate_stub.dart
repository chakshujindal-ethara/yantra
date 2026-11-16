/// The non-web half of the video plate.
///
/// A Flutter VM test (and any future desktop/mobile host) has no
/// `HTMLVideoElement`, so this renders the same empty state the plate shows
/// when a clip is missing. The real player lives in `video_plate_web.dart` and
/// is chosen by the conditional import in `video_plate.dart`.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../theme.dart';

class VideoPlate extends StatelessWidget {
  const VideoPlate({
    super.key,
    required this.asset,
    this.caption = '',
    this.allowDownload = false,
  });

  final Asset asset;
  final String caption;
  final bool allowDownload;

  @override
  Widget build(BuildContext context) => const MissingVideo();
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
