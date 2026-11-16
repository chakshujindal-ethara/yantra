/// The non-web half of the audio plate.
///
/// A Flutter VM test (and any future desktop or mobile host) has no
/// `HTMLAudioElement`, so this draws the plate's frame with the clip name and no
/// player. The real `<audio controls>` lives in `audio_plate_web.dart` and is
/// chosen by the conditional export in `audio_plate.dart`.
///
/// Every public name and constructor signature here must match the web half.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../theme.dart';
import 'clip_controls.dart';
import 'video_plate.dart' show audioClipName;

class AudioPlate extends StatelessWidget {
  const AudioPlate({
    super.key,
    required this.asset,
    this.caption = '',
    this.allowDownload = false,
    this.controls,
  });

  final Asset asset;
  final String caption;
  final bool allowDownload;
  final ClipControls? controls;

  @override
  Widget build(BuildContext context) {
    final Widget name = Row(
      children: <Widget>[
        const Icon(Icons.audiotrack_outlined, size: 16, color: Colors.white70),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            audioClipName(asset, caption),
            style: context.type.small.copyWith(color: Colors.white),
          ),
        ),
      ],
    );
    final ClipControls? c = controls;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: const BoxDecoration(
        color: Color(0xFF14171C),
        borderRadius: Radii.card,
      ),
      child: c == null
          ? name
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                name,
                const SizedBox(height: 10),
                ClipControlsBar(
                  controls: c,
                  player: const SizedBox(height: 54),
                ),
              ],
            ),
    );
  }
}
