// Deleting, and the sentence that has to be true before it happens.
//
// "Delete" means TAKE IT OUT OF THE BANK, and whether that can be an erase is
// the SERVER's decision, not this file's: a question an assessment uses or
// that anybody has answered is retired instead, because erasing it would take
// the answers with it (`response.question_id` is ondelete="cascade") and
// silently change recorded scores. So nothing here decides anything - the
// screen asks the API for a PREVIEW, this sheet renders what came back, and
// the button re-sends the same call with the preview flag off.
import 'package:flutter/material.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../theme.dart';
import 'buttons.dart';
import 'controls.dart';
import 'feedback.dart';

/// Confirm a delete, naming what it will touch. True means go ahead.
///
/// [subject] is what the operator selected, in their words - "3 questions",
/// "Forklift Safety SOP". [preview] is the server's answer about it.
Future<bool> confirmDelete(
  BuildContext context, {
  required String subject,
  required DeletePreview preview,
  bool isGenerator = false,
}) async {
  // A generator an assessment uses is KEPT (moved to Deleted), and that
  // is history being kept every bit as much as a retired question is -
  // `keepsHistory` counts both, so an archive-only outcome (every question
  // already retired by an earlier delete, so `retiredCount` is 0) no longer
  // prints "This cannot be undone" over a generator that survives.
  final bool archives = preview.keptGenerators > 0;
  final bool keeps = preview.keepsHistory;
  final bool one = preview.keptGenerators == 1;
  // "with it" reads wrong under a two-generator delete, and the drafts and
  // files belong to the generators, not to the questions listed above them.
  final String withThem = preview.generatorCount == 1 ? 'it' : 'them';
  final bool? go = await showSheet<bool>(
    context,
    title: 'Delete $subject?',
    sub: keeps
        // Recommended, not enforced: inform the operator, do not overrule.
        ? 'Some of this is in use. Archiving is the safer choice - but you '
              'can delete it if you mean to.'
        : 'This cannot be undone.',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (keeps) ...<Widget>[
          Notice(
            tone: Tone.warn,
            strong: 'History is kept, not deleted.',
            text: <String>[
              if (archives)
                '${preview.keptGenerators} '
                    '${one ? 'generator is' : 'generators are'} used by an '
                    'assessment, so ${one ? 'it moves' : 'they move'} to '
                    'Deleted: gone from every list for good, with '
                    '${one ? 'its' : 'their'} assessments and results kept.',
              if (preview.retiredCount > 0)
                '${preview.retiredCount} of these questions are used by an '
                    'assessment or have already been answered. Those move to '
                    'Deleted, out of the bank and Archived for good, and can '
                    'never be picked again, but the assessments using them '
                    'keep them, and every answer a candidate gave stays '
                    'exactly as it is.',
              'Nobody\'s score changes.',
            ].join(' '),
          ),
          const SizedBox(height: 12),
        ],
        // TWO OBJECTS, AND THE GENERATORS COME FIRST. Every count below used
        // to be rendered as one undifferentiated list led by
        // `preview.deletedCount`, which on this route is the generators'
        // QUESTIONS - so erasing an unused generator that had approved
        // nothing read "Deleted 0 / Draft questions deleted with it 0 / SOP
        // files deleted with it 0". Three zeros over an irreversible erase,
        // and the one number that was not zero - the generator itself - was
        // never on the sheet at all.
        if (isGenerator) ...<Widget>[
          _Line(
            label: keeps ? 'Generators erased for good' : 'Generators deleted',
            value: '${preview.deletedGenerators}',
            muted: preview.deletedGenerators == 0,
          ),
          if (archives)
            _Line(
              label: 'Generators moved to Deleted, results kept',
              value: '${preview.keptGenerators}',
            ),
          _Line(
            label: 'Questions erased for good',
            value: '${preview.deletedCount}',
            muted: preview.deletedCount == 0,
          ),
          if (preview.retiredCount > 0)
            _Line(
              label: 'Questions moved to Deleted, results kept',
              value: '${preview.retiredCount}',
            ),
          if (preview.answerCount > 0)
            _Line(
              label: 'Candidate answers preserved',
              value: '${preview.answerCount}',
            ),
          // ZERO MEANS SAY NOTHING. On the archive branch nothing is deleted
          // with the generator at all, and a line reading "SOP files deleted
          // with it 0" promised a deletion that was never going to happen.
          if (preview.draftCount > 0)
            _Line(
              label: 'Draft questions deleted with $withThem',
              value: '${preview.draftCount}',
            ),
          if (preview.fileCount > 0)
            _Line(
              label: 'SOP files deleted with $withThem',
              value: '${preview.fileCount}',
            ),
        ] else ...<Widget>[
          _Line(
            label: keeps ? 'Erased for good' : 'Deleted',
            value: '${preview.deletedCount}',
            muted: preview.deletedCount == 0,
          ),
          if (keeps)
            _Line(
              label: 'Moved to Deleted, results kept',
              value: '${preview.retiredCount}',
            ),
          if (preview.answerCount > 0)
            _Line(
              label: 'Candidate answers preserved',
              value: '${preview.answerCount}',
            ),
        ],
        if (preview.assessmentNames.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Text('Assessments affected', style: context.type.fieldLabel),
          const SizedBox(height: 4),
          Text(
            preview.assessmentNames.join(', '),
            style: context.type.body.copyWith(height: 1.5),
          ),
          const SizedBox(height: 4),
          Text(
            'These keep every question they already hold.',
            style: context.type.tiny,
          ),
        ],
      ],
    ),
    actions: <Widget>[
      Btn(
        'Cancel',
        size: BtnSize.lg,
        onPressed: () => Navigator.of(context).pop(false),
      ),
      // DANGER, and last - the affirmative sits where every other sheet in
      // the app puts it.
      Btn.danger(
        keeps ? 'Delete anyway' : 'Delete',
        size: BtnSize.lg,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
  return go == true;
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.muted = false});

  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: muted ? context.type.bodyMuted : context.type.body,
            ),
          ),
          Text(
            value,
            style: context.type.body.copyWith(
              fontWeight: FontWeight.w600,
              color: muted ? t.textMuted : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// The bar that appears once rows are ticked: what is selected, and what can
/// be done to it. Shown only while something IS selected, and Clear sits
/// beside the action so leaving a selection is as easy as acting on it.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.count,
    required this.noun,
    required this.onClear,
    this.onDelete,
    this.secondary,
    this.busy = false,
  });

  final int count;
  final String noun;
  final VoidCallback onClear;

  /// Null hides Delete, as the bank and the generators do for now.
  final VoidCallback? onDelete;

  /// A safer action shown before Delete - the bank's Archive or Restore.
  final Widget? secondary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: t.infoBg,
        borderRadius: Radii.card,
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '$count $noun${count == 1 ? '' : 's'} selected',
            style: context.type.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Btn('Clear', size: BtnSize.sm, onPressed: busy ? null : onClear),
          if (secondary != null) ...<Widget>[
            const SizedBox(width: 8),
            secondary!,
          ],
          if (onDelete != null) ...<Widget>[
            const SizedBox(width: 8),
            Btn.danger(
              'Delete',
              size: BtnSize.sm,
              icon: Icons.delete_outline,
              busy: busy,
              onPressed: busy ? null : onDelete,
            ),
          ],
        ],
      ),
    );
  }
}
