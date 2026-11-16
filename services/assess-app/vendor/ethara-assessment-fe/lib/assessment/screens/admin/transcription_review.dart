/// What an admin sees under a marked Transcription answer: how the client
/// rule came out, both texts, where they differ, the clip answers against the
/// correct ones, and each mistake the LLM judge weighed.
library;

import 'package:flutter/material.dart';

import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../domain/transcription.dart';
import '../../theme.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';

/// A deduction of 13 points or more is critical: the judge is told to cost a
/// critical mistake exactly 20 and a minor one exactly 5, and the server
/// counts them at the same line (`scoring._store_scored`).
bool isCriticalDeduction(double points) => points <= -13;

class TranscriptionReviewView extends StatelessWidget {
  const TranscriptionReviewView({
    super.key,
    required this.review,
    this.deductions = const <JudgeNote>[],
    this.redact = _same,
  });

  final TranscriptionReview review;

  /// The judge's deductions, each read as critical or minor by its size.
  final List<JudgeNote> deductions;

  /// The screen's PII redaction for the candidate's own words.
  final String Function(String text) redact;

  static String _same(String s) => s;

  @override
  Widget build(BuildContext context) {
    final TranscriptionReview v = review;
    final bool hindi = v.language == 'hi';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Pill(
              v.clientRulePassed ? 'Client rule: pass' : 'Client rule: fail',
              v.clientRulePassed ? Tone.ok : Tone.bad,
            ),
            Text(
              '${v.critical} critical · ${v.minor} minor '
              '(fails at 1 critical or 5 minor)',
              style: context.type.small,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _TextBox(label: 'Correct transcription', text: v.correctText),
        const SizedBox(height: 8),
        _TextBox(
          label: "Candidate's transcription",
          text: redact(v.answerText),
        ),
        if (v.differences.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Eyebrow('Word differences (${v.differences.length})'),
          const SizedBox(height: 6),
          for (final TranscriptionDifference d in v.differences)
            _Line(
              tag: switch (d.kind) {
                'missing' => 'Missing',
                'added' => 'Added',
                _ => 'Different',
              },
              tone: d.kind == 'missing'
                  ? Tone.bad
                  : (d.kind == 'added' ? Tone.warn : Tone.info),
              text: switch (d.kind) {
                'missing' => d.correct,
                'added' => redact(d.answer),
                _ => '${d.correct}  →  ${redact(d.answer)}',
              },
              note: d.after.isEmpty ? 'at the start' : 'after "${d.after}"',
            ),
        ],
        const SizedBox(height: 14),
        const Eyebrow('Clip answers'),
        const SizedBox(height: 6),
        _ClipRow(
          label: 'Category',
          correct: clipCategoryLabel(v.correctClip.category, hindi: hindi),
          answer: clipCategoryLabel(v.answerClip.category, hindi: hindi),
          right: v.correctClip.category == v.answerClip.category,
        ),
        _ClipRow(
          label: 'Characteristics',
          correct: _chars(v.correctClip),
          answer: _chars(v.answerClip),
          right:
              v.correctClip.characteristics.toSet().containsAll(
                v.answerClip.characteristics,
              ) &&
              v.answerClip.characteristics.toSet().containsAll(
                v.correctClip.characteristics,
              ),
        ),
        _ClipRow(
          label: 'Speakers',
          correct: _speakers(v.correctClip),
          answer: _speakers(v.answerClip),
          right: _speakers(v.correctClip) == _speakers(v.answerClip),
        ),
        if (deductions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          const Eyebrow('Mistakes the judge weighed'),
          const SizedBox(height: 6),
          for (final JudgeNote n in deductions)
            _Line(
              tag: isCriticalDeduction(n.points) ? 'Critical' : 'Minor',
              tone: isCriticalDeduction(n.points) ? Tone.bad : Tone.warn,
              text: n.reason,
              note: n.evidence.isEmpty ? '' : redact(n.evidence),
            ),
        ],
      ],
    );
  }

  static String _chars(ClipAnswers c) => c.characteristics.isEmpty
      ? 'None ticked'
      : c.characteristics.map(clipCharacteristicLabel).join(', ');

  static String _speakers(ClipAnswers c) => c.speakers.isEmpty
      ? '0'
      : '${c.speakers.length}: ${<String>[for (final SpeakerAnswer s in c.speakers) '${speakerGenderLabel(s.gender)} / ${speakerNativityLabel(s.nativity)}'].join('; ')}';
}

class _TextBox extends StatelessWidget {
  const _TextBox({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Eyebrow(label),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            color: t.bgSubtle,
            borderRadius: Radii.buttonLg,
            border: Border.all(color: t.border),
          ),
          child: SelectableText(
            text.trim().isEmpty ? '(empty)' : text,
            style: context.type.body.copyWith(fontSize: 16, height: 1.6),
          ),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.tag,
    required this.tone,
    required this.text,
    required this.note,
  });

  final String tag;
  final Tone tone;
  final String text;
  final String note;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(width: 92, child: Pill(tag, tone)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(text, style: context.type.body.copyWith(height: 1.5)),
              if (note.isNotEmpty) Text(note, style: context.type.tiny),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ClipRow extends StatelessWidget {
  const _ClipRow({
    required this.label,
    required this.correct,
    required this.answer,
    required this.right,
  });

  final String label;
  final String correct;
  final String answer;
  final bool right;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(width: 120, child: Text(label, style: context.type.small)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Correct: $correct', style: context.type.body),
              Text(
                'Candidate: $answer',
                style: context.type.body.copyWith(
                  color: right
                      ? context.tokens.successText
                      : context.tokens.destText,
                ),
              ),
            ],
          ),
        ),
        Pill(right ? 'Right' : 'Wrong', right ? Tone.ok : Tone.bad),
      ],
    ),
  );
}
