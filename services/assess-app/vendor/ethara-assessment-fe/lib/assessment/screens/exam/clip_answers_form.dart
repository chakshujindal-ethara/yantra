/// Category, characteristics and speakers for one clip: the candidate's
/// "About this clip" panel and, in Form Studio, the author's correct answers.
///
/// One widget for both, so the two cannot drift: the author keys exactly the
/// choices the candidate is offered.
library;

import 'package:flutter/material.dart';

import '../../domain/transcription.dart';
import '../../theme.dart';
import '../../widgets/controls.dart';

class ClipAnswersForm extends StatelessWidget {
  const ClipAnswersForm({
    super.key,
    required this.clip,
    required this.language,
    required this.onChanged,
    this.readOnly = false,
    this.labelPrefix = '',
  });

  final ClipAnswers clip;

  /// Hindi shows the client's Hindi names beside the English ones.
  final String language;

  /// Called with a fresh copy after every change.
  final ValueChanged<ClipAnswers> onChanged;
  final bool readOnly;

  /// "Correct " in Form Studio, so each label says whose answer it is.
  final String labelPrefix;

  void _edit(void Function(ClipAnswers c) change) {
    if (readOnly) return;
    final ClipAnswers next = clip.copy();
    change(next);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final bool hindi = language == 'hi';
    final String prefix = labelPrefix;
    String cap(String s) =>
        prefix.isEmpty ? s : '$prefix${s[0].toLowerCase()}${s.substring(1)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          cap('Whole-audio category').toUpperCase(),
          style: context.type.fieldLabel,
        ),
        const SizedBox(height: 4),
        SelectField<String>(
          label: cap('Whole-audio category'),
          value: clip.category,
          maxWidth: 420,
          options: <(String, String)>[
            for (final (String code, String _, String _) in kClipCategories)
              (code, clipCategoryLabel(code, hindi: hindi)),
          ],
          onChanged: (String v) => _edit((ClipAnswers c) => c.category = v),
        ),
        const SizedBox(height: 4),
        Text(
          'Anything but None: the clip is not transcribed.',
          style: context.type.tiny,
        ),
        if (clip.transcribed) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            '${cap('Audio characteristics')} (tick all you hear)'.toUpperCase(),
            style: context.type.fieldLabel,
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final double w = box.maxWidth >= 300
                  ? (box.maxWidth - 12) / 2
                  : box.maxWidth;
              return Wrap(
                spacing: 12,
                runSpacing: 2,
                children: <Widget>[
                  for (final (String code, String en, String hi, String what)
                      in kClipCharacteristics)
                    SizedBox(
                      width: w,
                      child: _Tick(
                        label: en,
                        sub: hindi ? hi : '',
                        tooltip: what,
                        checked: clip.characteristics.contains(code),
                        onChanged: readOnly
                            ? null
                            : (bool on) => _edit((ClipAnswers c) {
                                c.characteristics.remove(code);
                                if (on) c.characteristics.add(code);
                                // Catalogue order, which is how the server
                                // stores them: a reload then reads back the
                                // same list and nothing is re-sent.
                                c.characteristics.sort(
                                  (String a, String b) =>
                                      _order(a).compareTo(_order(b)),
                                );
                              }),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            cap('Identified speakers').toUpperCase(),
            style: context.type.fieldLabel,
          ),
          const SizedBox(height: 4),
          SelectField<int>(
            label: cap('Identified speakers'),
            value: clip.speakers.length,
            maxWidth: 420,
            options: <(int, String)>[
              (0, '0 (no intelligible speech)'),
              for (int n = 1; n < kMaxSpeakers; n++) (n, '$n'),
              (kMaxSpeakers, '$kMaxSpeakers or more'),
            ],
            onChanged: (int n) =>
                _edit((ClipAnswers c) => c.setSpeakerCount(n)),
          ),
          for (int i = 0; i < clip.speakers.length; i++) ...<Widget>[
            const SizedBox(height: 10),
            Text('Speaker ${i + 1}', style: context.type.bodySecondary),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                SelectField<String>(
                  label: 'Speaker ${i + 1} gender',
                  value: clip.speakers[i].gender,
                  maxWidth: 210,
                  options: kSpeakerGenders,
                  onChanged: (String v) =>
                      _edit((ClipAnswers c) => c.speakers[i].gender = v),
                ),
                SelectField<String>(
                  label: 'Speaker ${i + 1} nativity',
                  value: clip.speakers[i].nativity,
                  maxWidth: 210,
                  options: kSpeakerNativities,
                  onChanged: (String v) =>
                      _edit((ClipAnswers c) => c.speakers[i].nativity = v),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

int _order(String code) => kClipCharacteristics.indexWhere(
  ((String, String, String, String) c) => c.$1 == code,
);

class _Tick extends StatelessWidget {
  const _Tick({
    required this.label,
    required this.sub,
    required this.tooltip,
    required this.checked,
    required this.onChanged,
  });

  final String label;
  final String sub;
  final String tooltip;
  final bool checked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<bool>? change = onChanged;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: Radii.button,
        onTap: change == null ? null : () => change(!checked),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: checked,
                  onChanged: change == null
                      ? null
                      : (bool? v) => change(v ?? false),
                  activeColor: context.tokens.primary,
                  semanticLabel: label,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: context.type.body.copyWith(fontSize: 13),
                    ),
                    if (sub.isNotEmpty) Text(sub, style: context.type.tiny),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
