// OPENING A LABELLING QUESTION IN THE ANNOTATION EDITOR - tracker SNo 168.
//
// The editor itself was never missing. `FormItemEditor`'s `imageAnnotation`
// body is built, wired and correct - verified live on a real plate: numbered
// boxes drawn over the image, a Point 1..N chip row, and a "Golden answers (for
// the LLM judge)" panel counting how many are keyed. What was missing is the
// path INTO it from a GENERATED question.
//
// `studio_form._item_spec` has always turned a designer item into a question.
// Nothing turned a question back, so a generated labelling draft could be READ
// and never adjusted: an examiner could see that box 4 sat in the wrong place
// and had no way to move it. `Question.as_studio_annotation_item` is that
// inverse; this sheet is the surface that uses it.
//
// IN PLACE, NOT A COPY. Saving writes the geometry and the golden labels back
// onto the SAME question - no new Studio form, no second assessment. A
// corrected question living in a fresh record would leave the paper being fixed
// exactly as broken as it was, with the good version attached to nothing
// anybody sits.
import 'package:flutter/material.dart';

import '../domain/enums.dart' show Tone;
import '../domain/form_models.dart';
import '../screens/admin/form_item_editor.dart';
import '../state/app_store.dart';
import 'buttons.dart';
import 'controls.dart';
import 'feedback.dart' show Notice;

/// Whether [store] can offer the annotation editor for the question [id].
///
/// Asks the SERVER rather than guessing from the client's own copy. The item is
/// assembled from `label_boxes_json` with a `detections_json` fallback, and the
/// admin payload deliberately reduces detections to bare NUMBERS
/// (`serializers.bank_label_boxes` - pixel geometry would paint degenerate
/// boxes in the corner), so a client-side test would refuse exactly the
/// Studio-published questions this feature exists for.
Future<Map<String, dynamic>?> fetchAnnotationItem(AppStore store, String id) =>
    store.bankStudioItem(id);

/// Edit a labelling question's markers and golden answers.
///
/// [item] is what [fetchAnnotationItem] returned. Returns true when a save
/// landed, so the caller can refresh whatever it is showing.
Future<bool> showAnnotationEditor(
  BuildContext context,
  AppStore store,
  String questionId,
  Map<String, dynamic> item,
) async {
  final bool? saved = await showSheet<bool>(
    context,
    title: 'Edit annotations',
    // The retroactive warning belongs HERE, on the sheet that does it, in the
    // same words the bank editor uses. A labelling answer is free text scored
    // against these golden labels, so moving a box or rewording a key
    // re-decides the marks of everyone who has already sat it.
    sub: 'Changes apply to everyone who has already sat it.',
    wide: true,
    body: _AnnotationEditorBody(
      store: store,
      questionId: questionId,
      item: item,
    ),
  );
  return saved ?? false;
}

class _AnnotationEditorBody extends StatefulWidget {
  const _AnnotationEditorBody({
    required this.store,
    required this.questionId,
    required this.item,
  });

  final AppStore store;
  final String questionId;
  final Map<String, dynamic> item;

  @override
  State<_AnnotationEditorBody> createState() => _AnnotationEditorBodyState();
}

class _AnnotationEditorBodyState extends State<_AnnotationEditorBody> {
  /// The item being edited. `FormItemEditor` mutates it in place, which is the
  /// contract it is written to - the designer does the same.
  late final FormItem _item = FormItem.fromJson(widget.item);

  bool _saving = false;

  /// The refusal the SERVER would make, made here so the examiner reads it
  /// before pressing Save rather than after.
  ///
  /// Same rule as `studio_form._item_spec`: every point needs its own golden
  /// answer. An unkeyed point is a mark no candidate can earn, because the
  /// judge has nothing to compare their description against - the examiner sees
  /// "5 points" and a score out of far less than five.
  List<String> get _problems {
    final List<int> numbers = _item.annotationNumbers;
    if (numbers.isEmpty) {
      return <String>[
        'Draw at least one point on the image, or set how many annotations '
            'the picture already carries.',
      ];
    }
    final List<int> unkeyed = numbers
        .where((int n) => (_item.goldenLabels[n] ?? '').trim().isEmpty)
        .toList();
    if (unkeyed.isEmpty) return const <String>[];
    return <String>[
      'Every point needs a golden answer - what a correct description of it '
          'says. Missing: ${unkeyed.join(', ')}.',
    ];
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final bool ok = await widget.store.saveBankStudioItem(
      widget.questionId,
      _item.toJson(),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    // STAYS OPEN ON A REFUSAL. Closing would drop the examiner's edits on the
    // floor while the toast explains why the server would not take them, and
    // they would have to redraw every box to try again.
    if (ok) popIfCurrent(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final List<String> problems = _problems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // No `form:` - a question is not a section in a form, so the designer's
        // section-jump controls stand down rather than being faked. Same as the
        // task template editor, which hosts this widget the same way.
        FormItemEditor(
          store: widget.store,
          item: _item,
          index: 0,
          showDragHandle: false,
          allowedKinds: const <FormItemKind>[FormItemKind.imageAnnotation],
          onEdit: (VoidCallback mutate) => setState(mutate),
          // NEITHER CONTROL IS OFFERED. A question is ONE item on this sheet:
          // there is nowhere to put a copy, and "delete" here would mean
          // deleting the question, which is the bank's own delete.
          //
          // Passing no-op callbacks (the first version) left both icons
          // rendered: Delete ran its full confirmation sheet and then toasted
          // "Question deleted" over a question that was still there. Null
          // stands them down, the same way `showDragHandle: false` stands down
          // a gesture that has no reorderable ancestor.
        ),
        if (problems.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Notice(
            tone: Tone.warn,
            text: 'Fix before saving:\n- ${problems.join('\n- ')}',
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            const Spacer(),
            Btn(
              'Cancel',
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
            Btn.primary(
              'Save annotations',
              busy: _saving,
              onPressed: problems.isEmpty && !_saving ? _save : null,
            ),
          ],
        ),
      ],
    );
  }
}
