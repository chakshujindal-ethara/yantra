import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/json.dart';
import '../core/theme/portal_tokens.dart';
import 'audio_player.dart';
import 'json_rows.dart';

/// What a unit gives the worker (or the reviewer), rendered by what each value is: a stored clip as an
/// audio player, a stored or linked image as the image, long text and prompt-like fields as prose you
/// can select, everything else as a labelled row. [mediaUrl] fetches the presigned link for the unit's
/// stored object; without it a stored reference shows as text.
class PayloadView extends StatelessWidget {
  const PayloadView(this.payload, {super.key, this.mediaUrl});

  final Json payload;
  final Future<String> Function()? mediaUrl;

  static const _proseKeys = {'text', 'prompt', 'instruction', 'instructions', 'transcript', 'question', 'context', 'passage'};
  static final _audioRef = RegExp(r'\.(wav|mp3|m4a|ogg|flac|aac|webm)$', caseSensitive: false);
  static final _imageRef = RegExp(r'\.(png|jpe?g|gif|webp|svg)$', caseSensitive: false);

  static bool _stored(String v) => v.startsWith('s3://') || v.startsWith('projects/');

  /// What one entry is.
  static PayloadKind kindOf(String key, Object? value) {
    if (value is! String) return PayloadKind.row;
    final k = key.toLowerCase();
    if (k == 'audio_ref' || k.endsWith('_audio') || (_stored(value) && _audioRef.hasMatch(value))) return PayloadKind.audio;
    if (k == 'image_ref' || k == 'image_url' || (_imageRef.hasMatch(value) && (_stored(value) || value.startsWith('http')))) {
      return PayloadKind.image;
    }
    if (_proseKeys.contains(k) || value.length > 120) return PayloadKind.prose;
    return PayloadKind.row;
  }

  @override
  Widget build(BuildContext context) {
    if (payload.isEmpty) return const Text('(empty payload)');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final e in payload.entries) _entry(context, e.key, e.value)],
    );
  }

  Widget _entry(BuildContext context, String key, Object? value) {
    final theme = Theme.of(context);
    final label = Text(humanize(key), style: theme.textTheme.labelMedium);
    final url = mediaUrl;
    switch (kindOf(key, value)) {
      case PayloadKind.audio when url != null:
        return _Labelled(
          label: label,
          child: AudioPlayer(key: Key('payload-audio-$key'), url: url, label: humanize(key)),
        );
      case PayloadKind.image:
        final v = value! as String;
        final direct = v.startsWith('http') ? v : null;
        if (direct == null && url == null) return KeyValueRow(label: key, value: value, mono: true);
        return _Labelled(
          label: label,
          child: _PayloadImage(key: Key('payload-image-$key'), url: direct == null ? url! : () async => direct, alt: humanize(key)),
        );
      case PayloadKind.prose:
        return _Labelled(
          label: label,
          child: Text('$value', key: Key('payload-prose-$key'), style: theme.textTheme.bodyLarge?.copyWith(height: 1.5)),
        );
      case PayloadKind.audio:
      case PayloadKind.row:
        return KeyValueRow(label: key, value: value, mono: value is String && _stored(value));
    }
  }
}

enum PayloadKind { audio, image, prose, row }

class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});
  final Widget label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.x6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        label,
        const SizedBox(height: Space.x4),
        child,
      ],
    ),
  );
}

class _PayloadImage extends StatefulWidget {
  const _PayloadImage({super.key, required this.url, required this.alt});
  final Future<String> Function() url;
  final String alt;

  @override
  State<_PayloadImage> createState() => _PayloadImageState();
}

class _PayloadImageState extends State<_PayloadImage> {
  late final Future<String> _url = widget.url();

  @override
  Widget build(BuildContext context) {
    final t = PortalTokens.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: FutureBuilder<String>(
        future: _url,
        builder: (context, snap) {
          final u = snap.data;
          if (u == null) {
            return snap.hasError
                ? Text('The image could not be loaded.', style: TextStyle(color: t.destText))
                : const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
          }
          return Semantics(
            image: true,
            label: widget.alt,
            child: ClipRRect(
              borderRadius: Radii.rMd,
              child: Image.network(
                u,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Text('The image could not be loaded.', style: TextStyle(color: t.destText)),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A submitted answer as a reviewer reads it: humanised field names, long text as prose, nested values in
/// mono.
class AnswerView extends StatelessWidget {
  const AnswerView(this.answer, {super.key});
  final Json answer;

  @override
  Widget build(BuildContext context) {
    if (answer.isEmpty) return const Text('(empty answer)');
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in answer.entries)
          if (e.value is String && ((e.value as String).length > 80 || (e.value as String).contains('\n')))
            _Labelled(
              label: Text(humanize(e.key), style: theme.textTheme.labelMedium),
              child: Text(e.value as String, key: Key('answer-prose-${e.key}'), style: theme.textTheme.bodyLarge?.copyWith(height: 1.5)),
            )
          else
            KeyValueRow(label: humanize(e.key), value: e.value is bool ? ((e.value as bool) ? 'Yes' : 'No') : e.value),
      ],
    );
  }
}
