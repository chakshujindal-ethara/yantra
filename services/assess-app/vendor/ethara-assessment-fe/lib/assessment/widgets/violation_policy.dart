import 'package:flutter/material.dart';

import '../domain/enums.dart';
import 'controls.dart';
import 'feedback.dart';
import 'panel.dart';

/// The violation pair - what a violation does and at which count - and the
/// sentence stating the consequence, in the words the exam uses. Shared by
/// the create form and the Configuration tab so the two cannot drift.
///
/// [ai]: the AI proctoring pair (`ai_violation_action`, `ai_max_violations`),
/// which "AI: " reasons count against apart from the regular one.
///
/// Read-only when [onAction] is null: the values are shown as text, with a
/// 0 cap said in words.
class ViolationPolicy extends StatelessWidget {
  final bool ai;
  final ViolationAction action;
  final int cap;

  /// The stepper's floor. 0 is a real value on a saved record (it ends the
  /// exam on the first violation under Auto-submit), so the Configuration
  /// tab allows it; the create form starts at 1.
  final int minCap;

  final ValueChanged<ViolationAction>? onAction;
  final ValueChanged<int>? onCap;

  const ViolationPolicy({
    super.key,
    this.ai = false,
    required this.action,
    required this.cap,
    this.minCap = 0,
    this.onAction,
    this.onCap,
  });

  String get _breached =>
      ai ? 'AI Violation Limit Breached' : 'Violation Limit Breached';

  @override
  Widget build(BuildContext context) {
    final String onLabel = ai ? 'On AI violation' : 'On violation';
    final String capLabel = ai ? 'AI threshold' : 'Threshold';
    final ({String strong, String text}) c = violationConsequence(action, cap);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FieldGrid(<Widget>[
          onAction == null
              ? Field.readonly(onLabel, action.label)
              : Field(
                  label: onLabel,
                  // The owner's rule (A-074), as `violationConsequence` states
                  // it: the action decides WHETHER, the threshold WHEN.
                  help:
                      '${ai ? 'Counts AI proctoring violations (no face, '
                                'a second face, leaving the frame, a phone) '
                                'apart from the regular ones. ' : ''}'
                      'Reaching the threshold marks the attempt $_breached '
                      'for the candidate and the organiser in both modes. '
                      'Only Auto-submit also ends the exam there, and a '
                      'threshold of 0 ends it on the first violation. Log '
                      'only never ends the exam.',
                  child: SelectField<ViolationAction>(
                    value: action,
                    onChanged: onAction!,
                    options: ViolationAction.values
                        .map((ViolationAction a) => (a, a.label))
                        .toList(),
                  ),
                ),
          onAction == null
              ? Field.readonly(
                  capLabel,
                  // 0 is not "no cap" under Auto-submit: it ends the exam on
                  // the first violation (the module's own field help).
                  cap > 0
                      ? '$cap'
                      : (action.isAuto ? 'First Violation' : 'No Limit'),
                )
              : Field(
                  label: capLabel,
                  help:
                      'The ${ai ? 'AI proctoring ' : ''}violation count that '
                      'marks the attempt $_breached in both modes, and ends '
                      'the exam under Auto-submit only.',
                  child: NumberField(
                    value: cap,
                    min: minCap,
                    max: 20,
                    // On Enter, never per keystroke: the "1" of "12" posted
                    // a cap of 1 to a running Auto-submit paper.
                    commitOnSubmit: true,
                    onChanged: onCap ?? (_) {},
                  ),
                ),
        ]),
        const SizedBox(height: 12),
        Notice(
          tone: cap > 0 || action.isAuto ? Tone.warn : Tone.inert,
          strong: ai
              ? 'AI proctoring: ${c.strong[0].toLowerCase()}'
                    '${c.strong.substring(1)}'
              : c.strong,
          text: ai
              ? c.text.replaceAll('Violation Limit Breached', _breached)
              : c.text,
        ),
      ],
    );
  }
}
