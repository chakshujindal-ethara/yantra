// The answer key, rendered once.
//
// WHY THIS IS A SHARED WIDGET. Three surfaces drew a question's answer key and
// all three disagreed: the preview sheet drew nothing when there were no
// dimensions, so a draft's key looked like a key the server did not have, and
// each surface decided differently whether an A/B question counts as keyed.
import 'package:flutter/material.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import 'feedback.dart';
import 'marks.dart';
import 'panel.dart';

/// The structured answer key - the reviewer's actual decision surface.
class AnswerKeyView extends StatelessWidget {
  final AppStore store;
  final Question question;

  const AnswerKeyView({super.key, required this.store, required this.question});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;

    // Keyed by SHAPE, not by how it is scored. `image_ab` is graded by a rubric
    // and still carries an axis of options per rating criterion, so asking
    // `isSubjective` here sent it down the rubric path and its axes rendered
    // nowhere - the one thing an A/B reviewer needs to check.
    if (!question.type.hasOptionKey) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The LABELLED marking guide when the server sent one, and the
          // anonymous bullets only when it did not. Never both: they are two
          // renderings of the same JSON, so showing both prints the same prose
          // twice under two different headings.
          if (question.answerKey.isNotEmpty)
            for (final (String, List<String>) s in question.answerKey.sections)
              Padding(
                padding: const EdgeInsets.only(bottom: 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Eyebrow(s.$1),
                    const SizedBox(height: 5),
                    for (final String line in s.$2)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          line,
                          style: context.type.body.copyWith(height: 1.5),
                        ),
                      ),
                  ],
                ),
              )
          else if (question.rubric.isEmpty)
            Text(
              'The grader will author a rubric at scoring time. Supplying one '
              'here is stronger.',
              style: context.type.bodyMuted,
            )
          else
            for (int i = 0; i < question.rubric.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Mono('${i + 1}', size: 10.5, color: t.textMuted),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        question.rubric[i],
                        style: context.type.body.copyWith(height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
          if (question.boxKey.isNotEmpty) ...<Widget>[
            const Hr(),
            const Eyebrow('Expected labels'),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final MapEntry<int, String> e in question.boxKey.entries)
                  StatusBadge('${e.key}  ${e.value}', Tone.inert),
              ],
            ),
          ],
        ],
      );
    }

    // The server's rule (`_check_answer_key`): every mcq / msq axis needs a
    // key, while an image_ab needs only one - a rating axis is left to the
    // grader by design, and the server accepts that key.
    final bool keyless = question.type == QType.imageAb
        ? !question.dims.any((QDimension d) => d.hasKey)
        : question.dims.isEmpty ||
              question.dims.any((QDimension d) => !d.hasKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final QDimension d in question.dims)
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // One axis needs no heading - and a draft's key is synthesised
                // as a single axis named 'Answer', which is a placeholder, not
                // something to print at a reviewer.
                if (question.dims.length > 1) ...<Widget>[
                  Eyebrow(d.name),
                  const SizedBox(height: 5),
                ],
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final QOption o in d.options)
                      StatusBadge(
                        o.correct ? '✓  ${o.label}' : o.label,
                        o.correct ? Tone.accent : Tone.inert,
                      ),
                  ],
                ),
              ],
            ),
          ),
        if (keyless)
          const Notice(
            tone: Tone.bad,
            strong: 'No correct option marked.',
            text:
                'This question would score zero for every candidate, and an '
                'assessment carrying it will refuse to launch.',
          ),
      ],
    );
  }
}
