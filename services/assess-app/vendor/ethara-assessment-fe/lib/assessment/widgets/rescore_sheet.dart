// Re-scoring an answer the candidate has already been shown.
//
// Every other re-score moves a number nobody outside this console has seen, so
// it is an ordinary working act and asking about it would be noise. Once
// results are RELEASED the candidate holds the mark: a re-grade spends a model
// call whether or not the new grade differs, and if it does differ it changes
// what they were told, silently - nothing notifies them, and the chatter line
// is the only trace. The per-answer route refuses it without `confirm` (409
// `released_confirm_required`), as the bulk requeue route does without
// `force: true`.
//
// THE GATE IS THE RELEASE, NOT THE MONEY. A confirmation on every re-score is
// one people learn to dismiss, which would protect the released case less than
// this does.
import 'package:flutter/material.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import 'buttons.dart';
import 'controls.dart';
import 'feedback.dart';

/// True when the re-score may go ahead - immediately so when no chosen attempt
/// has been released.
Future<bool> confirmRescore(
  BuildContext context, {
  required List<Attempt> released,
}) async {
  if (released.isEmpty) return true;
  final bool one = released.length == 1;
  final bool? go = await showSheet<bool>(
    context,
    title: one
        ? 'Re-score an answer on a released result?'
        : 'Re-score answers on ${released.length} released results?',
    sub: one
        ? 'This candidate can already see the mark this may change.'
        : 'These candidates can already see the marks this may change.',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Notice(
          tone: Tone.warn,
          strong: 'This spends a model call, and can move a published mark.',
          text:
              'The grader is paid for whether or not the new grade differs. '
              'If it does differ, the new mark replaces the one the candidate '
              'has already been shown, and nothing tells them it changed.',
        ),
        const SizedBox(height: 12),
        Text(
          one
              ? 'If the re-grade fails, the current mark stays and the reason '
                    'is recorded on the candidate.'
              : '${released.length} of the chosen answers are on released '
                    'results. If a re-grade fails, that mark stays and the '
                    'reason is recorded on the candidate.',
          style: context.type.body,
        ),
      ],
    ),
    actions: <Widget>[
      Btn(
        'Keep the Mark',
        tooltip: 'Leave every mark as it is. Nothing is spent.',
        onPressed: () => Navigator.of(context).pop(false),
      ),
      Btn.danger(
        'Re-score Anyway',
        tooltip:
            'Queue the re-grade. It costs a model call, and a new grade '
            'replaces a mark the candidate has already seen.',
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
  return go ?? false;
}

/// [confirmRescore], then [AppStore.rescoreAnswers] - the one path every
/// re-score button on every screen takes, so the question cannot be forgotten
/// on the fourth one.
Future<void> rescoreConfirmed(
  BuildContext context,
  AppStore store,
  Map<String, List<String>?> byAttempt, {
  required Iterable<Attempt> attempts,
}) async {
  final List<Attempt> released = <Attempt>[
    for (final Attempt a in attempts)
      if (a.resultsReleased && byAttempt.containsKey(a.id)) a,
  ];
  if (!await confirmRescore(context, released: released)) return;
  // The flag is the operator's answer to the sheet, so it is sent only when
  // there WAS a sheet - see `ApiClient.rescore`.
  await store.rescoreAnswers(byAttempt, confirmed: released.isNotEmpty);
}
