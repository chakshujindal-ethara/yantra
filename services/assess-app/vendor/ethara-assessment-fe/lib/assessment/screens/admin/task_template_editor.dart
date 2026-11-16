// The task-template editor: author the shape of ONE task, then generate N of it.
//
// REUSES THE FORM MODEL. A template stores the Form Studio designer's own
// `sections` document, so this edits `FormItem` / `FormOption` rather than a
// parallel structure. That is what keeps a template from drifting away from what
// the designer would produce, and it is why `to_question_specs()` on the server
// can borrow `studio_form._item_spec` unchanged.
//
// WHY NOT THE FULL DESIGNER. The Form Studio screen is a whole-page editor for a
// multi-section form with media, grids, scales and a publish flow. A template is
// one small shape - a handful of questions with the SOP's own axes - and the
// examiner reaches it mid-way through configuring a generation run. A focused
// dialog keeps them on the page they are working on; the underlying document is
// identical either way.
//
// EVERY KIND `_item_spec` ON THE SERVER CAN TURN INTO A QUESTION IS OFFERED
// HERE - not a hand-picked subset. The first version of this editor only
// offered 4 of the 13 kinds `studio_form._item_spec` actually handles, which
// meant an operator wanting an annotation/labelling template (exactly the
// `imageAnnotation` kind `_item_spec` maps to `image_label`) or a real A/B
// media comparison (`comparePair` -> `image_ab`) had no way to author one here
// even though Form Studio itself could. `kTemplateKinds` below is the kind
// list `_item_spec` recognises, MINUS the four that are content
// blocks/uploads rather than questions (`textBlock`, `imageBlock`,
// `videoBlock`, `fileUpload` - offering those would let an examiner build a
// template that "generates" nothing).
//
// `FormItem` and `FormOption` are MUTABLE by design (the designer edits them in
// place), so this mutates and calls setState rather than rebuilding immutable
// copies.
import 'package:flutter/material.dart';

import '../../../services/file_pick_stub.dart'
    if (dart.library.html) '../../../services/file_pick_web.dart';
import '../../../services/json_export.dart';
import '../../domain/enums.dart';
import '../../domain/form_models.dart';
import '../../domain/models.dart';
import '../../state/app_store.dart';
import '../../theme.dart';
import '../../widgets/controls.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import 'form_item_editor.dart';

/// The response primitives an examiner can pick, with plain-English labels.
///
/// CLOSED ON PURPOSE and mirrored from the server's `TASK_RESPONSE_PRIMITIVES`:
/// a primitive is a way a human can answer, not a subject area. A new project
/// brings new axes and options (data), never a new primitive (code).
const Map<String, String> kResponsePrimitives = <String, String>{
  'single_choice': 'Pick one option',
  'multi_choice': 'Pick any number of options',
  'free_text': 'Write an answer',
  'compare_two': 'Compare two candidates',
  'annotate_image': 'Mark points on an image',
  'author_prompt': 'Write a prompt for an image',
  'author_video_prompt': 'Write a prompt for a clip',
  'describe_media': 'Describe an image or clip',
};

/// Every item kind the server's `_item_spec` can turn into a real, gradeable
/// question - the full set minus the four content-block/upload kinds it has no
/// question-type mapping for at all.
const List<FormItemKind> kTemplateKinds = <FormItemKind>[
  FormItemKind.multipleChoice,
  FormItemKind.checkboxes,
  FormItemKind.dropdown,
  FormItemKind.choiceGrid,
  FormItemKind.checkboxGrid,
  FormItemKind.linearScale,
  FormItemKind.rating,
  FormItemKind.shortAnswer,
  FormItemKind.paragraph,
  FormItemKind.comparePair,
  FormItemKind.imageAnnotation,
  // The `author_prompt` / `author_video_prompt` primitives already routed to
  // `image_prompt` / `video_prompt` on the server; this is the designer kind
  // that finally expresses them, so a template can author one too.
  FormItemKind.promptWriting,
];

bool _isChoice(FormItemKind k) =>
    k == FormItemKind.multipleChoice ||
    k == FormItemKind.checkboxes ||
    k == FormItemKind.dropdown;

bool _isGrid(FormItemKind k) =>
    k == FormItemKind.choiceGrid || k == FormItemKind.checkboxGrid;

class TaskTemplateEditor extends StatefulWidget {
  const TaskTemplateEditor({
    super.key,
    required this.store,
    required this.generatorId,
    this.template,
  });

  final AppStore store;
  final String generatorId;

  /// The template being edited. Null for a new one; id 0 for a model draft the
  /// examiner has not saved yet.
  final TaskTemplate? template;

  @override
  State<TaskTemplateEditor> createState() => _TaskTemplateEditorState();
}

class _TaskTemplateEditorState extends State<TaskTemplateEditor> {
  late String _name;
  late String _instructions;
  late String _response;
  late List<FormItem> _items;
  late String _rubricCriteria;
  late String _rubricPassCondition;
  late String _rubricConstraints;
  late String _annotationTargets;
  late int _annotationExpectedCount;
  late String _mediaBrief;
  bool _saving = false;
  int _seq = 0;

  /// Which answer-key fields this primitive actually uses.
  ///
  /// Driven off the primitive rather than the question type so the editor
  /// speaks the examiner's language, and so a primitive added to
  /// [kResponsePrimitives] only has to be named here to get its fields.
  static const Set<String> _rubricPrimitives = <String>{
    'free_text',
    'describe_media',
  };
  static const Set<String> _annotationPrimitives = <String>{'annotate_image'};
  // WHICH PRIMITIVES NEED A BRIEF: every one that puts a plate in front of the
  // candidate, which is exactly `_mediaSlotsByPrimitive` below.
  //
  // `compare_two` WAS MISSING, and it is the one that shows the MOST media -
  // two plates. So an image-comparison template had no way to say what those
  // plates should show: `answer_contract()` carries `media_brief` to the
  // generator to "anchor the stimulus so every generated item is a variation on
  // the same task", and with the field hidden the examiner could not write one,
  // `_compose()` blanked it, and every generated pair was a different subject
  // invented per item. A drafted brief was discarded the same way.
  //
  // `describe_media` IS DELIBERATELY ABSENT, and so is its media slot below.
  // TASK_PRIMITIVE_TO_QUESTION_TYPE maps it to `subjective_rubric`, which is in
  // NEITHER IMAGE_QUESTION_TYPES nor VIDEO_QUESTION_TYPES - so nothing renders
  // a plate for it, and the whole backend mentions it only as a constant. This
  // editor promised a slot labelled "The media to describe" and a brief to
  // describe it with, and generation then produced a prose question with no
  // picture. Promising media the pipeline cannot deliver is worse than not
  // offering the primitive at all: the examiner writes a brief, sees it saved,
  // and finds out at review.
  static const Set<String> _mediaBriefPrimitives = <String>{
    'compare_two',
    'author_prompt',
    'author_video_prompt',
    'annotate_image',
  };

  bool get _needsRubric => _rubricPrimitives.contains(_response);
  bool get _needsAnnotation => _annotationPrimitives.contains(_response);
  bool get _needsMediaBrief => _mediaBriefPrimitives.contains(_response);
  bool get _isVideoPrimitive => _response == 'author_video_prompt';

  /// Which primitives put a picture or a clip in front of the candidate, and
  /// how many slots. Compare-two shows the pair side by side; the rest show one.
  ///
  /// `describe_media` is absent on purpose - see [_mediaBriefPrimitives].
  static const Map<String, List<String>> _mediaSlotsByPrimitive =
      <String, List<String>>{
        'compare_two': <String>['Response A', 'Response B'],
        'annotate_image': <String>['The image to mark'],
        'author_prompt': <String>['The target image'],
        'author_video_prompt': <String>['The target clip'],
      };

  bool get _showsMedia => _mediaSlotsByPrimitive.containsKey(_response);
  List<String> get _mediaSlotLabels =>
      _mediaSlotsByPrimitive[_response] ?? const <String>[];

  /// Says WHEN the media appears, because it does not exist yet. The slots are
  /// a placeholder for what generation will produce, not an upload the
  /// examiner is being asked for.
  String get _mediaSlotNote => switch (_response) {
    'compare_two' => 'Generation renders both, one carrying the planted flaw.',
    'author_prompt' || 'author_video_prompt' =>
      'Generation renders this from the brief above; the candidate writes '
          'the prompt that would produce it.',
    _ => 'Generation renders this from the brief above.',
  };

  /// How many targets the examiner has actually typed, so the count field can
  /// show what it would derive rather than a bare 0.
  int get _targetLineCount => _annotationTargets
      .split('\n')
      .where((String l) => l.trim().isNotEmpty)
      .length;

  @override
  void initState() {
    super.initState();
    final TaskTemplate? tpl = widget.template;
    _name = tpl?.name ?? '';
    _instructions = tpl?.instructions ?? '';
    _response = tpl?.response ?? 'single_choice';
    _rubricCriteria = tpl?.rubricCriteria ?? '';
    _rubricPassCondition = tpl?.rubricPassCondition ?? '';
    _rubricConstraints = tpl?.rubricConstraints ?? '';
    _annotationTargets = tpl?.annotationTargets ?? '';
    _annotationExpectedCount = tpl?.annotationExpectedCount ?? 0;
    _mediaBrief = tpl?.mediaBrief ?? '';
    _items = _itemsOf(tpl);
  }

  /// Flatten the stored sections into a flat item list.
  ///
  /// A template is one shape, so sections add nothing an examiner can use here -
  /// but the SERVER shape keeps them, and a draft may arrive with more than one,
  /// so read every section rather than only the first. Dropping items from a
  /// second section would silently lose authored content.
  List<FormItem> _itemsOf(TaskTemplate? tpl) {
    final List<FormItem> out = <FormItem>[];
    for (final dynamic section in tpl?.structure ?? const <dynamic>[]) {
      if (section is! Map) continue;
      final List<dynamic> items =
          (section['items'] as List<dynamic>?) ?? const <dynamic>[];
      for (final dynamic item in items) {
        if (item is Map<String, dynamic>) out.add(FormItem.fromJson(item));
      }
    }
    return out;
  }

  /// What would stop this template GENERATING - nothing else.
  ///
  /// A TEMPLATE HAS NO ANSWER KEY, AND THAT IS CORRECT. The key belongs to
  /// each generated instance: the model decides, per item, which option is
  /// right for the stimulus it just invented. This list used to demand a
  /// correct option / correct verdict / golden value per question, so an
  /// examiner authoring a perfectly good three-axis task was shown six
  /// warnings telling them to mark answers that must not exist yet - and the
  /// picker badged the template "Generates nothing".
  ///
  /// What genuinely blocks generation is a shape the generator cannot
  /// reproduce: no name, no questions, a choice with fewer than two options,
  /// a grid with no rows or columns.
  List<String> get _problems {
    final List<String> out = <String>[];
    if (_name.trim().isEmpty) out.add('Give the task a name.');
    if (_items.isEmpty) out.add('Add at least one question.');
    for (final FormItem it in _items) {
      final String title = it.title.trim().isEmpty
          ? 'an untitled question'
          : '"${it.title.trim()}"';
      if (_isChoice(it.kind)) {
        final int usable = it.options
            .where((FormOption o) => o.label.trim().isNotEmpty)
            .length;
        if (usable < 2) {
          out.add('$title needs at least two options.');
        }
      } else if (_isGrid(it.kind)) {
        if (it.rows.isEmpty || it.columns.isEmpty) {
          out.add('$title needs at least one row and one column.');
        }
      } else if (it.kind == FormItemKind.comparePair) {
        final int usable = it.options
            .where((FormOption o) => o.label.trim().isNotEmpty)
            .length;
        if (usable < 2) {
          out.add('$title needs at least two verdict options.');
        }
      }
    }
    return out;
  }

  /// Save without closing, so an in-progress template can be put down.
  ///
  /// THE ID IS CAPTURED. The editor is a modal whose state died with it: `_save`
  /// posted and popped, so there was no way to keep working after a save and no
  /// way to save twice without minting a second template. `_savedId` holds what
  /// the server assigned on the first save, which turns every later one into an
  /// UPDATE of the same row.
  Future<bool> _persist() async {
    setState(() => _saving = true);
    final TaskTemplate saved = _compose();
    final TaskTemplate? result = await widget.store.saveTaskTemplate(saved);
    if (!mounted) return false;
    setState(() {
      _saving = false;
      if (result != null && result.id != 0) _savedId = result.id;
    });
    return result != null;
  }

  /// The template this dialog currently describes.
  ///
  /// SHARED BY SAVE AND EXPORT ON PURPOSE. An export that rebuilt this itself
  /// would drift the moment a field is added here - you would save one shape
  /// and export another, and the difference would only show up in a file
  /// someone opens later. One composer, two consumers.
  TaskTemplate _compose() {
    final TaskTemplate? existing = widget.template;
    return TaskTemplate(
      // `_savedId` first: after the first save this editor is editing a real
      // record, whatever it was opened with.
      id: _savedId ?? existing?.id ?? 0,
      name: _name.trim().isEmpty ? 'Untitled task' : _name.trim(),
      instructions: _instructions.trim(),
      response: _response,
      // One section on the way out: the examiner edits a flat list, and the
      // server only cares about the items.
      structure: <dynamic>[
        <String, dynamic>{
          'id': 'sec-1',
          'title': 'Questions',
          'items': _items.map((FormItem i) => i.toJson()).toList(),
        },
      ],
      // A model draft the examiner has now edited stays `llm_edited`; an
      // untouched draft is never saved at all, so there is no third state.
      authoredBy: existing?.authoredBy ?? 'manual',
      // The examiner's own answer key. Sent only for the primitives that use
      // it, so switching a template from one primitive to another does not
      // carry the previous shape's key along with it.
      rubricCriteria: _needsRubric ? _rubricCriteria.trim() : '',
      rubricPassCondition: _needsRubric ? _rubricPassCondition.trim() : '',
      rubricConstraints: _needsRubric ? _rubricConstraints.trim() : '',
      annotationTargets: _needsAnnotation ? _annotationTargets.trim() : '',
      annotationExpectedCount: _needsAnnotation ? _annotationExpectedCount : 0,
      mediaBrief: _needsMediaBrief ? _mediaBrief.trim() : '',
      originId: existing?.originId ?? int.tryParse(widget.generatorId),
    );
  }

  /// Save and close - the original behaviour, kept as the primary action.
  Future<void> _save() async {
    if (await _persist() && mounted) popIfCurrent(context);
  }

  /// Save and stay. The reason the editor is no longer a one-shot form.
  Future<void> _saveDraft() async {
    await _persist();
  }

  /// The exported document: a Form Studio import file with the template's own
  /// fields carried alongside it.
  ///
  /// WHY THIS SHAPE. `TaskTemplate.structure` already IS Form Studio
  /// `sections`, verbatim - so putting it under a `sections` key costs nothing
  /// and makes the file something Form Studio's Import button opens directly.
  /// A drafted template can therefore be reviewed as a real form, with real
  /// preview, instead of only inside this dialog. Everything a form does not
  /// understand lives under `template`, which the form parser ignores.
  ///
  /// `instructions` IS DELIBERATELY NOT THE FORM DESCRIPTION. Generator
  /// instructions are never shown to a candidate, but a form description IS -
  /// mapping one to the other would leak examiner-facing notes into an exam the
  /// moment someone imported this and published it. It travels under
  /// `template` only.
  Map<String, dynamic> _exportDoc() {
    final TaskTemplate t = _compose();
    return <String, dynamic>{
      'title': t.name,
      'sections': t.structure,
      // Not published: an import is a draft until a human says otherwise.
      'published': false,
      'template': <String, dynamic>{
        'name': t.name,
        'response': t.response,
        'instructions': t.instructions,
        'authored_by': t.authoredBy,
        if (_needsRubric) 'rubric_criteria': t.rubricCriteria,
        if (_needsRubric) 'rubric_pass_condition': t.rubricPassCondition,
        if (_needsRubric) 'rubric_constraints': t.rubricConstraints,
        if (_needsAnnotation) 'annotation_targets': t.annotationTargets,
        if (_needsAnnotation)
          'annotation_expected_count': t.annotationExpectedCount,
        if (_needsMediaBrief) 'media_brief': t.mediaBrief,
        if (widget.template?.originName.isNotEmpty ?? false)
          'origin_name': widget.template!.originName,
      },
      'exported_at': DateTime.now().toIso8601String(),
    };
  }

  /// Write the current dialog state to a JSON file.
  ///
  /// EXPORTS WHAT IS ON SCREEN, NOT WHAT IS STORED, and does not save first.
  /// The case this exists for is a model draft the examiner is still reading:
  /// they want the drafted questions out as a file before deciding whether to
  /// keep them, and forcing a save to get that would put drafts nobody wanted
  /// into the template list.
  void _export() {
    final Map<String, dynamic> doc = _exportDoc();
    final String name = jsonFileName(
      _name.trim().isEmpty ? 'task-template' : _name.trim(),
      fallback: 'task-template',
    );
    downloadJson(name, doc);
    final int items = _items.length;
    widget.store.toaster.ok(
      '$name downloaded - $items question${items == 1 ? '' : 's'}. '
      'Form Studio can import it.',
    );
  }

  /// What the server assigned on the first save, so every later save updates
  /// that row rather than minting another template.
  int? _savedId;

  /// Whether there is anything here worth warning about losing.
  ///
  /// DELIBERATELY NOT A DIRTY FLAG. Tracking edits would mean threading a
  /// setter through every field in a 1000-line editor, and getting one wrong
  /// gives a guard that silently stops guarding. "Is there content" is one
  /// expression, always correct, and errs toward asking - which is the right
  /// direction for a modal whose state dies with it.
  bool get _hasContent =>
      _name.trim().isNotEmpty ||
      _instructions.trim().isNotEmpty ||
      _items.isNotEmpty;

  Future<void> _close() async {
    if (!_hasContent) {
      popIfCurrent(context);
      return;
    }
    final bool? discard = await showSheet<bool>(
      context,
      title: 'Close without saving?',
      sub: 'Anything you have not saved is lost when this closes.',
      body: Text(
        'A half-authored template is a normal thing to save. Nothing '
        'generates from it until you add it to a run.',
        style: context.type.body,
      ),
      actions: <Widget>[
        Btn(
          'Keep Editing',
          tooltip: 'Go back to the template.',
          onPressed: () => Navigator.of(context).pop(false),
        ),
        Btn.danger(
          'Discard',
          tooltip: 'Close without saving. The edits are lost.',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (discard == true && mounted) popIfCurrent(context);
  }

  void _addItem() {
    setState(() {
      _seq++;
      _items = <FormItem>[
        ..._items,
        FormItem(
          'item-${DateTime.now().microsecondsSinceEpoch}-$_seq',
          FormItemKind.multipleChoice,
          options: <FormOption>[
            FormOption('o-$_seq-1', ''),
            FormOption('o-$_seq-2', ''),
          ],
        ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<String> problems = _problems;
    final bool isDraft = widget.template?.id == 0 && widget.template != null;

    return Dialog(
      backgroundColor: t.bgApp,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 780),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.template == null
                          ? 'New task template'
                          : isDraft
                          ? 'Review the drafted template'
                          : 'Edit task template',
                      style: context.type.body,
                    ),
                  ),
                  if (isDraft) const StatusBadge('Model draft', Tone.inert),
                ],
              ),
            ),
            if (isDraft)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18),
                child: Notice(
                  tone: Tone.info,
                  text:
                      'Drafted from the SOP. Check the wording and the answer '
                      'keys - nothing is saved until you press Save.',
                ),
              ),
            // WHAT WOULD GO WRONG IF THIS GENERATED, standing rather than
            // transient.
            //
            // These arrived as a `toaster.info` per warning. A toast lasts three
            // seconds and belongs to the tab that saw it, so the one signal
            // saying "this template will generate the wrong thing" was gone on
            // dismiss, on reload, and to whoever opened the template next - and
            // a template that shows a candidate no picture looks exactly like
            // one that does. Read off the record, so it is here every visit and
            // clears itself when the cause is fixed.
            if (widget.template?.shapeWarnings.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(left: 18, right: 18, top: 8),
                child: Notice(
                  tone: Tone.warn,
                  text: widget.template!.shapeWarnings
                      .map((String w) => '- $w')
                      .join('\n'),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Eyebrow('Task name'),
                    const SizedBox(height: 4),
                    FormTextInput(
                      id: 'tpl-name',
                      value: _name,
                      hint: 'e.g. Judge prompt adherence',
                      onChanged: (String v) => setState(() => _name = v),
                    ),
                    const SizedBox(height: 14),
                    const Eyebrow('What a candidate does'),
                    const SizedBox(height: 4),
                    _ResponsePicker(
                      value: _response,
                      onChanged: (String v) => setState(() => _response = v),
                    ),
                    const SizedBox(height: 14),
                    const Eyebrow('Instructions for the generator'),
                    const SizedBox(height: 4),
                    FormTextInput(
                      id: 'tpl-instructions',
                      value: _instructions,
                      maxLines: 3,
                      hint:
                          'What this shape is for. Never shown to a candidate.',
                      onChanged: (String v) => _instructions = v,
                    ),
                    // THE EXAMINER'S OWN ANSWER KEY. Shown per primitive: a
                    // written answer is graded against a rubric, an annotation
                    // task against a list of things to mark, and a generated
                    // stimulus needs a brief. Without these the model invented
                    // its own key per item, so two items of the SAME task were
                    // marked to different standards.
                    if (_needsRubric) ...<Widget>[
                      const SizedBox(height: 18),
                      const Eyebrow('How the answer is marked'),
                      const SizedBox(height: 4),
                      Text(
                        'One criterion per line. The grader marks against '
                        'these, so every item of this task is judged the same '
                        'way.',
                        style: context.type.bodyMuted,
                      ),
                      const SizedBox(height: 6),
                      FormTextInput(
                        id: 'tpl-rubric-criteria',
                        value: _rubricCriteria,
                        maxLines: 4,
                        hint:
                            'Identifies the specific flaw\n'
                            'Explains the impact on the user\n'
                            'Proposes a concrete fix',
                        onChanged: (String v) => _rubricCriteria = v,
                      ),
                      const SizedBox(height: 10),
                      const Eyebrow('A passing answer must'),
                      const SizedBox(height: 4),
                      FormTextInput(
                        id: 'tpl-rubric-pass',
                        value: _rubricPassCondition,
                        hint: 'e.g. Names the flaw AND proposes a fix',
                        onChanged: (String v) => _rubricPassCondition = v,
                      ),
                      const SizedBox(height: 10),
                      const Eyebrow('Limits the answer must respect'),
                      const SizedBox(height: 4),
                      FormTextInput(
                        id: 'tpl-rubric-constraints',
                        value: _rubricConstraints,
                        hint: 'e.g. Under 150 words, no bullet lists',
                        onChanged: (String v) => _rubricConstraints = v,
                      ),
                    ],
                    if (_needsAnnotation) ...<Widget>[
                      const SizedBox(height: 18),
                      const Eyebrow('What the candidate must mark'),
                      const SizedBox(height: 4),
                      Text(
                        'One expected annotation per line. Coverage and '
                        'precision are graded against this list.',
                        style: context.type.bodyMuted,
                      ),
                      const SizedBox(height: 6),
                      FormTextInput(
                        id: 'tpl-annotation-targets',
                        value: _annotationTargets,
                        maxLines: 4,
                        hint:
                            'Extra finger on the left hand\n'
                            'Misspelled text on the sign\n'
                            'Melted edge on the cup',
                        onChanged: (String v) =>
                            setState(() => _annotationTargets = v),
                      ),
                      const SizedBox(height: 10),
                      const Eyebrow('Marks in a complete answer'),
                      const SizedBox(height: 4),
                      _ExpectedCountField(
                        value: _annotationExpectedCount,
                        derived: _targetLineCount,
                        onChanged: (int v) =>
                            setState(() => _annotationExpectedCount = v),
                      ),
                    ],
                    if (_needsMediaBrief) ...<Widget>[
                      const SizedBox(height: 18),
                      Eyebrow(
                        _isVideoPrimitive
                            ? 'What the clip must show'
                            : 'What the image must show',
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Anchors the stimulus so every generated item is a '
                        'variation on the same task.',
                        style: context.type.bodyMuted,
                      ),
                      const SizedBox(height: 6),
                      FormTextInput(
                        id: 'tpl-media-brief',
                        value: _mediaBrief,
                        maxLines: 3,
                        hint: _isVideoPrimitive
                            ? 'e.g. A 5s clip of a cat leaping onto a '
                                  'windowsill, slow motion'
                            : 'e.g. A person holding a coffee cup beside a '
                                  'shop sign',
                        onChanged: (String v) => _mediaBrief = v,
                      ),
                    ],
                    // WHAT THE CANDIDATE WILL BE LOOKING AT. Nothing on this
                    // screen used to say a task carries media at all: a
                    // compare-two template is a page of Yes/No questions, and
                    // the two image slots the candidate actually sees exist
                    // only once generation has run. The examiner could not tell
                    // an image task from a text one.
                    if (_showsMedia) ...<Widget>[
                      const SizedBox(height: 18),
                      Eyebrow(
                        _isVideoPrimitive
                            ? 'The clip a candidate sees'
                            : 'The image a candidate sees',
                      ),
                      const SizedBox(height: 6),
                      _MediaSlots(
                        slots: _mediaSlotLabels,
                        isVideo: _isVideoPrimitive,
                        note: _mediaSlotNote,
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: <Widget>[
                        const Expanded(child: Eyebrow('Questions')),
                        Btn(
                          'Add Question',
                          size: BtnSize.sm,
                          icon: Icons.add,
                          onPressed: _addItem,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_items.isEmpty)
                      const EmptyLine(
                        'No questions yet. Add the axes this task judges.',
                      ),
                    for (int i = 0; i < _items.length; i++)
                      // THE FORM STUDIO ITEM CARD, not a lookalike.
                      //
                      // A template is the shape of a Form Studio form, so it
                      // must be able to express anything the designer can -
                      // including the media BLOCKS a generated question fills
                      // in. This screen used to draw its own 13-kind
                      // reimplementation with no help text, no description, no
                      // duplicate and no blocks at all; sharing the widget is
                      // what makes the two surfaces identical instead of
                      // merely similar.
                      //
                      // No `form:` - a template is one flat list of axes with
                      // no sections, so the section-jump controls stand down.
                      FormItemEditor(
                        key: ValueKey<String>(_items[i].id),
                        store: widget.store,
                        item: _items[i],
                        index: i,
                        showDragHandle: false,
                        onEdit: (VoidCallback mutate) => setState(mutate),
                        onDuplicate: () => setState(() {
                          _items = <FormItem>[
                            ..._items.sublist(0, i + 1),
                            _remintItem(_items[i]),
                            ..._items.sublist(i + 1),
                          ];
                        }),
                        onDelete: () => setState(() {
                          _items = <FormItem>[..._items]..removeAt(i);
                        }),
                      ),
                  ],
                ),
              ),
            ),
            if (problems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Notice(
                  tone: Tone.warn,
                  text: 'Fix before generating:\n- ${problems.join('\n- ')}',
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
              child: Row(
                children: <Widget>[
                  // LEFT OF THE SAVE ACTIONS, because it is not one. Export
                  // writes a file and changes nothing here, so it should not
                  // sit in the row a reflexive click lands on.
                  Btn(
                    'Export JSON',
                    size: BtnSize.sm,
                    icon: Icons.file_download_outlined,
                    tooltip: _items.isEmpty
                        ? 'Add a question first - there is nothing to export.'
                        : 'Download this template as JSON. Form Studio can '
                              'import the file to open it as a real form.',
                    onPressed: _items.isEmpty ? null : _export,
                  ),
                  const Spacer(),
                  Btn('Cancel', size: BtnSize.sm, onPressed: _close),
                  const SizedBox(width: 8),
                  Btn(
                    'Save Draft',
                    size: BtnSize.sm,
                    busy: _saving,
                    tooltip:
                        'Save what you have and keep editing. A template does '
                        'not have to be finished to be stored.',
                    onPressed: _saving ? null : _saveDraft,
                  ),
                  const SizedBox(width: 8),
                  Btn(
                    'Save Template',
                    variant: BtnVariant.primary,
                    size: BtnSize.sm,
                    busy: _saving,
                    // Saveable with problems outstanding: a half-authored
                    // template is a normal state, and losing the work would be
                    // worse than storing something the examiner will finish.
                    tooltip: problems.isEmpty
                        ? 'Available on the Generation tab.'
                        : 'Saved as-is. The warnings above still apply when '
                              'you generate.',
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pick the response primitive, in plain English rather than wire codes.
class _ResponsePicker extends StatelessWidget {
  const _ResponsePicker({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: t.border),
        borderRadius: Radii.input,
        color: t.bgApp,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: kResponsePrimitives.containsKey(value)
              ? value
              : 'single_choice',
          isDense: true,
          isExpanded: true,
          items: <DropdownMenuItem<String>>[
            for (final MapEntry<String, String> e
                in kResponsePrimitives.entries)
              DropdownMenuItem<String>(
                value: e.key,
                child: Text(e.value, style: context.type.small),
              ),
          ],
          onChanged: (String? v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// Two images with a set of verdict options - the same shape as
/// `comparePair` -> `image_ab`, the type your saved A/B templates already use,
/// authored here through a proper media picker instead of the generic
/// multiple-choice path.
class _ComparePairEditor extends StatefulWidget {
  const _ComparePairEditor({
    required this.store,
    required this.item,
    required this.onChanged,
  });

  final AppStore store;
  final FormItem item;
  final VoidCallback onChanged;

  @override
  State<_ComparePairEditor> createState() => _ComparePairEditorState();
}

class _ComparePairEditorState extends State<_ComparePairEditor> {
  bool _busyA = false;
  bool _busyB = false;

  Future<void> _pick(bool isA) async {
    setState(() => isA ? _busyA = true : _busyB = true);
    try {
      final PickedFile? file = await pickFile(
        accept: '.png,.jpg,.jpeg,.webp,.gif',
      );
      if (file == null) return;
      final String? url = await widget.store.uploadFormMedia(
        name: file.name,
        bytes: file.bytes,
        contentType: _guessContentType(file.name),
      );
      if (url != null && url.isNotEmpty) {
        if (isA) {
          widget.item.mediaUrl = url;
        } else {
          widget.item.mediaUrlB = url;
        }
        widget.onChanged();
      }
    } finally {
      if (mounted) setState(() => isA ? _busyA = false : _busyB = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: _MediaSlot(
                label: 'Image A',
                url: widget.item.mediaUrl,
                busy: _busyA,
                onPick: () => _pick(true),
                onClear: () {
                  widget.item.mediaUrl = '';
                  widget.onChanged();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _MediaSlot(
                label: 'Image B',
                url: widget.item.mediaUrlB,
                busy: _busyB,
                onPick: () => _pick(false),
                onClear: () {
                  widget.item.mediaUrlB = '';
                  widget.onChanged();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Verdict options', style: context.type.tiny),
        _ChoiceOptionsEditor(
          item: widget.item,
          onChanged: widget.onChanged,
          onTick: (int i, bool correct) {
            widget.item.options[i].correct = correct;
            widget.onChanged();
          },
        ),
      ],
    );
  }
}

/// One image with N numbered markers, each with the correct label - the
/// minimal version of `imageAnnotation`: coordinates are optional
/// (`_item_spec` falls back to a plain numbered list when no [LabelRegion] was
/// drawn), so this offers "how many markers, what does each one mean" without
/// needing interactive on-image drawing.
class _AnnotationEditor extends StatefulWidget {
  const _AnnotationEditor({
    required this.store,
    required this.item,
    required this.onChanged,
  });

  final AppStore store;
  final FormItem item;
  final VoidCallback onChanged;

  @override
  State<_AnnotationEditor> createState() => _AnnotationEditorState();
}

class _AnnotationEditorState extends State<_AnnotationEditor> {
  bool _busy = false;

  Future<void> _pick() async {
    setState(() => _busy = true);
    try {
      final PickedFile? file = await pickFile(
        accept: '.png,.jpg,.jpeg,.webp,.gif',
      );
      if (file == null) return;
      final String? url = await widget.store.uploadFormMedia(
        name: file.name,
        bytes: file.bytes,
        contentType: _guessContentType(file.name),
      );
      if (url != null && url.isNotEmpty) {
        widget.item.mediaUrl = url;
        widget.onChanged();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FormItem it = widget.item;
    final int count = it.regions.isNotEmpty
        ? it.regions.length
        : it.annotationCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 8),
        _MediaSlot(
          label: 'Image',
          url: it.mediaUrl,
          busy: _busy,
          onPick: _pick,
          onClear: () {
            it.mediaUrl = '';
            widget.onChanged();
          },
        ),
        const SizedBox(height: 8),
        if (it.regions.isEmpty)
          _NumberField(
            label: 'Number of markers',
            value: it.annotationCount,
            onChanged: (int v) {
              it.annotationCount = v;
              widget.onChanged();
            },
          ),
        const SizedBox(height: 8),
        Text('What each marker should be labelled', style: context.type.tiny),
        for (int n = 1; n <= count; n++)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 22,
                  child: Text('$n.', style: context.type.small),
                ),
                Expanded(
                  child: FormTextInput(
                    id: 'ann-${it.id}-$n',
                    value: it.goldenLabels[n] ?? '',
                    hint: 'The correct label for marker $n',
                    onChanged: (String v) {
                      it.goldenLabels[n] = v;
                      widget.onChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One uploaded (or missing) image, with its own busy spinner.
class _MediaSlot extends StatelessWidget {
  const _MediaSlot({
    required this.label,
    required this.url,
    required this.busy,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final String url;
  final bool busy;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool has = url.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: t.border),
        borderRadius: Radii.input,
        color: t.bgApp,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: context.type.tiny),
          const SizedBox(height: 4),
          if (has)
            Text(
              url,
              style: context.type.small,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          else
            Text('No image yet', style: context.type.tiny),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Btn(
                has ? 'Replace' : 'Upload',
                size: BtnSize.sm,
                busy: busy,
                tooltip: has
                    ? 'Every generated item shows a candidate this image.'
                    : 'Uploads to the same storage Form Studio media uses.',
                onPressed: onPick,
              ),
              if (has) ...<Widget>[
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  tooltip: 'Remove',
                  onPressed: onClear,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A compact integer stepper with a label, for scale bounds and counts.
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      children: <Widget>[
        Text(label, style: context.type.tiny),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: t.border),
            borderRadius: Radii.input,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                // The last two icon-only controls in the app with no tooltip
                // (SNo 20). A bare +/- pair beside a number is guessable by
                // sighted users and silent to a screen reader, which reads
                // "button" twice with nothing to tell them apart.
                tooltip: 'One fewer',
                icon: const Icon(Icons.remove, size: 14),
                onPressed: value <= 0 ? null : () => onChanged(value - 1),
              ),
              SizedBox(
                width: 24,
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: context.type.small,
                ),
              ),
              IconButton(
                tooltip: 'One more',
                icon: const Icon(Icons.add, size: 14),
                onPressed: () => onChanged(value + 1),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A tiny inline text field that appends a chip and clears on submit - grid
/// columns.
class _AddChipButton extends StatefulWidget {
  const _AddChipButton({required this.hint, required this.onAdd});

  final String hint;
  final ValueChanged<String> onAdd;

  @override
  State<_AddChipButton> createState() => _AddChipButtonState();
}

class _AddChipButtonState extends State<_AddChipButton> {
  final TextEditingController _c = TextEditingController();

  void _submit() {
    final String v = _c.text.trim();
    if (v.isEmpty) return;
    widget.onAdd(v);
    _c.clear();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return SizedBox(
      width: 140,
      child: TextField(
        controller: _c,
        style: context.type.small,
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint,
          hintStyle: context.type.tiny,
          border: OutlineInputBorder(
            borderRadius: Radii.input,
            borderSide: BorderSide(color: t.border),
          ),
        ),
        onSubmitted: (_) => _submit(),
        onEditingComplete: _submit,
      ),
    );
  }
}

/// Same guess Form Studio's own uploader makes, kept local rather than
/// reaching into its private `_contentTypeFor`.
String _guessContentType(String name) {
  final String ext = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : '';
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    _ => 'application/octet-stream',
  };
}

/// How many marks a complete annotation answer has.
///
/// Separate from the target list because a task can legitimately ask for "any
/// three of these five". Zero is not a blank: it MEANS "derive it from the
/// list", which the field says out loud rather than showing a bare 0 the
/// examiner would read as an error.
class _ExpectedCountField extends StatelessWidget {
  const _ExpectedCountField({
    required this.value,
    required this.derived,
    required this.onChanged,
  });

  final int value;
  final int derived;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final int effective = value > 0 ? value : derived;
    return Row(
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.remove, size: 18),
          tooltip: 'One fewer',
          onPressed: value <= 0 ? null : () => onChanged(value - 1),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value > 0 ? '$value' : '$derived',
            textAlign: TextAlign.center,
            style: context.type.body,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 18),
          tooltip: 'One more',
          onPressed: () => onChanged(effective + 1),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value > 0
                ? 'A complete answer marks $value of the targets above.'
                : 'Every target above ($derived).',
            style: context.type.bodyMuted,
          ),
        ),
      ],
    );
  }
}

/// Placeholder slots showing that a task carries media.
///
/// The pictures do not exist while the template is being authored - generation
/// renders them per item - so this states the SHAPE: how many slots, what each
/// one is, and when it gets filled. Without it a compare-two template looked
/// identical to a page of text questions.
class _MediaSlots extends StatelessWidget {
  const _MediaSlots({
    required this.slots,
    required this.isVideo,
    required this.note,
  });

  final List<String> slots;
  final bool isVideo;
  final String note;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (final String label in slots) ...<Widget>[
              Expanded(
                child: Container(
                  height: 96,
                  decoration: BoxDecoration(
                    color: t.bgSubtle,
                    border: Border.all(color: t.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(
                        isVideo ? Icons.movie_outlined : Icons.image_outlined,
                        size: 20,
                        color: t.textMuted,
                      ),
                      const SizedBox(height: 6),
                      Text(label, style: context.type.small),
                    ],
                  ),
                ),
              ),
              if (label != slots.last) const SizedBox(width: 10),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(note, style: context.type.bodyMuted),
      ],
    );
  }
}

class _ChoiceOptionsEditor extends StatelessWidget {
  const _ChoiceOptionsEditor({
    required this.item,
    required this.onChanged,
    required this.onTick,
  });

  final FormItem item;
  final VoidCallback onChanged;
  final void Function(int index, bool correct) onTick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 8),
        for (int i = 0; i < item.options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: <Widget>[
                // The answer key: a checkbox reads as "this is correct", which
                // is what an examiner is actually setting - even for
                // `dropdown`, which is still single-answer underneath.
                Checkbox(
                  value: item.options[i].correct,
                  visualDensity: VisualDensity.compact,
                  onChanged: (bool? v) => onTick(i, v ?? false),
                ),
                Expanded(
                  child: FormTextInput(
                    id: 'opt-${item.id}-${item.options[i].id}',
                    value: item.options[i].label,
                    hint: "The option label, in the SOP's own words",
                    onChanged: (String v) {
                      item.options[i].label = v;
                      onChanged();
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 15),
                  tooltip: 'Remove this option',
                  onPressed: () {
                    item.options.removeAt(i);
                    onChanged();
                  },
                ),
              ],
            ),
          ),
        Btn(
          'Add option',
          size: BtnSize.sm,
          icon: Icons.add,
          tooltip: 'Add another answer choice to this question',
          onPressed: () {
            item.options.add(
              FormOption(
                'o-${item.id}-${DateTime.now().microsecondsSinceEpoch}',
                '',
              ),
            );
            onChanged();
          },
        ),
      ],
    );
  }
}

/// A duplicated item needs its own ids, or the copy's text fields share edit
/// state with the original's through identical widget keys. Mirrors the
/// designer's own `_reminted`, which is private to that file.
FormItem _remintItem(FormItem src) {
  final Map<String, dynamic> j = src.toJson();
  j['id'] = formNewId('item');
  if (j['options'] is List) {
    for (final Object? o in j['options'] as List) {
      if (o is Map<String, dynamic>) o['id'] = formNewId('opt');
    }
  }
  return FormItem.fromJson(j);
}
