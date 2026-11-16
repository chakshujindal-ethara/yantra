// Editing a question - a reviewer fixes a generated question in place and
// approves it, instead of denying it and paying for another generation.
//
// ONE SHAPE, BOTH RECORDS. A draft and a bank question each arrive with their
// key as axes of options (`dimensions`, with record ids and each axis's
// `input_kind`), and each save sends that tree back. A draft's flat
// `options_json` / `correct_answer_json` pair is never sent: it cannot carry a
// template's several axes or their kinds, so saving through it dropped them.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../services/file_pick_web.dart';
import '../domain/enums.dart';
import '../domain/models.dart';
import '../screens/exam/stimulus.dart';
import '../state/app_store.dart';
import '../theme.dart';
import 'buttons.dart';
import 'controls.dart';
import 'feedback.dart';
import 'marks.dart';
import 'panel.dart';

/// One editable option row, independent of which record it came from.
class _EditOption {
  /// The server id, when this option already exists. Null means "new".
  final String? id;
  final TextEditingController text;
  bool correct;

  _EditOption({this.id, required String name, required this.correct})
    : text = TextEditingController(text: name);

  void dispose() => text.dispose();
}

/// One keyed axis of a question, with its own options.
///
/// A legacy A/B question has a single axis called "Answer". A
/// TEMPLATE-authored question has one axis per question the examiner wrote,
/// each with its own option set - which is why an axis has to be a thing the
/// editor can hold a list of, rather than a first-plus-the-rest.
class _EditAxis {
  final String? id;
  final TextEditingController name;
  final List<_EditOption> options;

  /// The control the candidate answers this axis with (`input_kind`), which
  /// decides whether it takes one answer or several. Sent back on save.
  final String kind;

  _EditAxis({
    this.id,
    required String label,
    required this.options,
    this.kind = '',
  }) : name = TextEditingController(text: label);

  void dispose() {
    name.dispose();
    for (final _EditOption o in options) {
      o.dispose();
    }
  }
}

/// Edit a DRAFT before approving it.
Future<void> showDraftEditor(
  BuildContext context,
  AppStore store,
  Question draft,
) => showSheet<void>(
  context,
  title: 'Edit Draft',
  sub: 'Fix it here rather than denying and regenerating.',
  wide: true,
  body: _QuestionEditor(store: store, question: draft, isDraft: true),
);

/// Edit a BANK question, including which option is correct.
Future<void> showBankEditor(
  BuildContext context,
  AppStore store,
  Question question,
) => showSheet<void>(
  context,
  title: 'Edit Question',
  sub: 'Changes apply to everyone who has already sat it.',
  wide: true,
  body: _QuestionEditor(store: store, question: question, isDraft: false),
);

class _QuestionEditor extends StatefulWidget {
  final AppStore store;
  final Question question;
  final bool isDraft;

  const _QuestionEditor({
    required this.store,
    required this.question,
    required this.isDraft,
  });

  @override
  State<_QuestionEditor> createState() => _QuestionEditorState();
}

class _QuestionEditorState extends State<_QuestionEditor> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;

  // Three fields the API has always accepted and no widget ever offered.
  late final TextEditingController _desc;
  late final TextEditingController _time;
  late final TextEditingController _reasoning;
  final List<_EditOption> _options = <_EditOption>[];

  /// The bank's dimension id, so a save updates that axis rather than
  /// replacing it - replacing would delete every option and take the answers
  /// referencing them with it.
  String? _dimensionId;
  String _dimensionName = 'Answer';

  /// EVERY axis this question keys, each with its own options.
  ///
  /// THE DEFECT THIS REPLACES. The editor used to show `dims.first` and keep
  /// axes 2..n as opaque passthrough JSON, which was survivable when an A/B
  /// question had one rating axis. A TEMPLATE-authored question keys one axis
  /// per question the examiner wrote - "Was the instruction applied?", "Is the
  /// subject preserved?", ... - so opening one showed a single axis's Yes/No
  /// and silently hid the rest. The reviewer could not see, let alone fix, the
  /// answer key they were being asked to approve.
  final List<_EditAxis> _axes = <_EditAxis>[];

  late Difficulty _difficulty;

  /// Retiring is the answer to "this question is wrong and I cannot fix it".
  /// The route and the store already accepted `active`; nothing sent it.
  late bool _active;

  /// Whether this question is out of the bank, which is NOT what [_active]
  /// says. Held here rather than read off `widget.question` because restoring
  /// refreshes the store while the Question this sheet was handed stays
  /// exactly as it was opened.
  late bool _retired;

  /// A restore in flight. The sheet is built once by `showDialog` and does not
  /// listen to the store, so the button's spinner has to come from here.
  bool _restoring = false;

  /// Keyed by OPTIONS, not scoring - decides whether an option list shows.
  bool get _keyed => widget.question.type.hasOptionKey;

  /// The candidate picks ONE option on this axis, so one correct option at
  /// most: msq and a checkboxes axis take several. The server's
  /// `takes_one_answer`; scoring is an exact-set match per axis, so a second
  /// correct option here is a key nobody can earn.
  bool _takesOne(_EditAxis a) =>
      widget.question.type != QType.msq &&
      a.kind != 'checkboxes' &&
      a.kind != 'checkboxGrid';

  @override
  void initState() {
    super.initState();
    final Question q = widget.question;
    _name = TextEditingController(text: q.name);
    _prompt = TextEditingController(text: q.prompt);
    _desc = TextEditingController(text: q.desc);
    _time = TextEditingController(
      text: q.timeMinutes > 0 ? '${q.timeMinutes}' : '',
    );
    _reasoning = TextEditingController(text: q.officialReasoning);
    _difficulty = q.difficulty;
    // `recordActive`, NOT the derived `active`. `Question.active` is the
    // product fact (`recordActive && !retired`), so seeding from it opens a
    // retired question with this toggle already off, and saving then writes
    // `active: false` and ARCHIVES the record. Archiving is the one outcome
    // the retired design exists to avoid: Odoo filters archived rows out of
    // relational reads, so `assessment.question_ids` silently loses the
    // question and a paper somebody already sat gets shorter. This toggle
    // writes the wire flag, so it has to be seeded from the wire flag.
    _active = q.recordActive;
    _retired = q.retired;

    // EVERY axis, not just the first. Axes 2..n used to be kept as opaque
    // passthrough so a save would not delete them; that meant a
    // template-authored question - one axis per examiner question - showed
    // one Yes/No and hid the rest of the key it was asking a human to approve.
    //
    // A DRAFT TOO. Its row's `dimensions` is the server's `draft_dimensions`
    // (record ids and `input_kind` per axis); a payload with only the flat
    // pair becomes one id-less "Answer" axis in `Question.fromJson`.
    for (final QDimension dim in q.dims) {
      final bool known = dim.id.isNotEmpty;
      _axes.add(
        _EditAxis(
          id: known ? dim.id : null,
          label: dim.name,
          kind: dim.inputKind,
          options: <_EditOption>[
            // An option on an axis with no record has none either: a
            // synthesised option's id is its TEXT, which is not a record id.
            for (final QOption o in dim.options)
              _EditOption(
                id: known && o.id.isNotEmpty ? o.id : null,
                name: o.label,
                correct: o.correct,
              ),
          ],
        ),
      );
    }
    if (_axes.isEmpty) {
      _axes.add(_EditAxis(label: 'Answer', options: <_EditOption>[]));
    }
    // The single-axis fields stay in step with axis one, so every existing
    // read of them (save shape, option list, dimension id) keeps working.
    _dimensionId = _axes.first.id;
    _dimensionName = _axes.first.name.text;
    _options.addAll(_axes.first.options);
  }

  /// The whole intended key: every axis the examiner authored, each with its
  /// own options.
  ///
  /// `live` is axis one's option list (the single-axis path still owns it, so
  /// an mcq/msq draft keeps behaving exactly as before). Axes 2..n now come
  /// from real editable state rather than passthrough JSON.
  List<Map<String, dynamic>> _dimensionRows(List<_EditOption> live) {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (int i = 0; i < _axes.length; i++) {
      final _EditAxis axis = _axes[i];
      final List<_EditOption> opts = i == 0
          ? live
          : axis.options
                .where((_EditOption o) => o.text.text.trim().isNotEmpty)
                .toList();
      rows.add(<String, dynamic>{
        if (i == 0 && _dimensionId != null) 'id': _dimensionId,
        if (i > 0 && axis.id != null) 'id': axis.id,
        'name': i == 0 ? _dimensionName : axis.name.text.trim(),
        // Kept, or a save would turn a checkboxes axis back into one pick.
        'input_kind': axis.kind,
        'options': <Map<String, dynamic>>[
          for (final _EditOption o in opts)
            <String, dynamic>{
              // Carrying the id is what makes this an edit rather than a
              // delete-and-recreate, which would break the answers pointing
              // at these options.
              if (o.id != null) 'id': o.id,
              'name': o.text.text.trim(),
              'is_correct': o.correct,
            },
        ],
      });
    }
    return rows;
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _desc.dispose();
    _time.dispose();
    _reasoning.dispose();
    for (final _EditOption o in _options) {
      o.dispose();
    }
    // Axis one shares its options with `_options`, so only dispose its name.
    for (int i = 0; i < _axes.length; i++) {
      if (i == 0) {
        _axes[i].name.dispose();
      } else {
        _axes[i].dispose();
      }
    }
    super.dispose();
  }

  /// Enforced here as a courtesy; the server enforces it as a guarantee
  /// (`_check_answer_key`), per axis: two options; one correct at most where
  /// [_takesOne]; a correct one on every mcq/msq axis. An A/B axis may be left
  /// to the grader unkeyed (a rating), as long as one axis is keyed.
  String? get _problem {
    if (!_keyed) return null;
    final bool one = _axes.length == 1;
    final bool everyAxisKeyed = widget.question.type != QType.imageAb;
    bool anyKeyed = false;
    for (final _EditAxis axis in _axes) {
      final String name = axis.name.text.trim();
      final List<_EditOption> live = axis.options
          .where((_EditOption o) => o.text.text.trim().isNotEmpty)
          .toList();
      if (live.length < 2) {
        return one
            ? 'A question needs at least two options.'
            : 'Axis "$name" needs at least two options.';
      }
      final int correct = live.where((_EditOption o) => o.correct).length;
      anyKeyed = anyKeyed || correct > 0;
      if (correct == 0 && everyAxisKeyed) {
        return one
            ? 'Nothing is marked correct, so nobody could ever score on it.'
            : 'Axis "$name" has nothing marked correct.';
      }
      if (correct > 1 && _takesOne(axis)) {
        return one
            ? 'A single-answer question can only have one correct option.'
            : 'Axis "$name" takes one answer, so only one option can be '
                  'correct.';
      }
    }
    if (!anyKeyed) {
      return 'Nothing is marked correct, so nobody could ever score on it.';
    }
    return null;
  }

  /// Radio behaviour WITHIN one axis.
  ///
  /// Axes are independent - a photo can pass "instruction applied" and fail
  /// "subject preserved" - so ticking an option must only clear its own axis.
  /// Clearing across axes would wipe the rest of the answer key.
  void _toggleIn(_EditAxis axis, _EditOption row, bool value) {
    setState(() {
      if (_takesOne(axis) && value) {
        for (final _EditOption o in axis.options) {
          o.correct = false;
        }
      }
      row.correct = value;
    });
  }

  /// Put the question back in the bank - the same call the bank row's
  /// "Restore" button makes.
  ///
  /// The new state is read back from the refreshed bank rather than assumed:
  /// `restoreQuestion` turns a refusal into a toast instead of an exception,
  /// so assuming success would leave this dialog offering circulation the
  /// server had just declined.
  Future<void> _restore() async {
    setState(() => _restoring = true);
    try {
      await widget.store.restoreQuestion(widget.question.id);
    } finally {
      if (mounted) {
        setState(() {
          _restoring = false;
          _retired =
              widget.store.bankById(widget.question.id)?.retired ?? _retired;
        });
      }
    }
  }

  Future<void> _save() async {
    final List<_EditOption> live = _options
        .where((_EditOption o) => o.text.text.trim().isNotEmpty)
        .toList();

    // A REFUSED SAVE KEEPS THE SHEET OPEN over what was typed: the store
    // answers whether the server took it, and the toast says why not.
    final bool saved;
    if (widget.isDraft) {
      saved = await widget.store.saveDraft(
        widget.question.id,
        name: _name.text.trim(),
        prompt: _prompt.text.trim(),
        description: _desc.text.trim(),
        difficulty: _difficulty.wire,
        timeMinutes: int.tryParse(_time.text.trim()) ?? 0,
        officialReasoning: _reasoning.text.trim(),
        // The axis tree only, as the bank save sends: the server refuses both
        // spellings in one request, and the flat pair has no axes or kinds.
        dimensions: _keyed ? _dimensionRows(live) : null,
      );
    } else {
      saved = await widget.store.saveBankQuestion(
        widget.question.id,
        name: _name.text.trim(),
        prompt: _prompt.text.trim(),
        description: _desc.text.trim(),
        difficulty: _difficulty.wire,
        timeMinutes: int.tryParse(_time.text.trim()) ?? 0,
        officialReasoning: _reasoning.text.trim(),
        // Never `false`: clearing the record flag is Odoo's archive, which
        // drops the question out of papers already built and out of the
        // app's bank with no Restore. Switching off archives the bank's way,
        // below; `true` still revives a record archived the old way.
        active: _active ? true : null,
        dimensions: !_keyed ? null : _dimensionRows(live),
      );
      if (saved && !_active && widget.question.recordActive) {
        await widget.store.archiveQuestions(<String>[widget.question.id]);
      }
    }
    if (saved && mounted) popIfCurrent(context);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String? problem = _problem;
    final bool busy = widget.store.isBusy(
      widget.isDraft
          ? 'draft:${widget.question.id}'
          : 'bank:${widget.question.id}',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!widget.isDraft)
          const Notice(
            tone: Tone.warn,
            strong: 'This question may already have been answered.',
            text:
                'Marks are decided against the live answer key, so correcting '
                'it here re-decides the results of everyone who has sat it. '
                'An option a candidate actually chose cannot be removed.',
          ),
        const SizedBox(height: 12),
        Field(
          label: 'Title',
          child: TextField(
            controller: _name,
            style: context.type.body.copyWith(fontSize: 13),
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        const SizedBox(height: 12),
        Field(
          label: 'Question',
          child: TextField(
            controller: _prompt,
            minLines: 2,
            maxLines: 6,
            style: context.type.body.copyWith(fontSize: 13),
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        // The stimulus, edited here rather than on the review-queue card.
        // Drafts only - `/api/v1/drafts/<id>/apply_image` has no bank twin.
        // `needsImage` alone is too narrow: it names the types that REQUIRE a
        // plate, while an mcq or a rubric question may merely carry one - see
        // `layoutDrawsMedia` - and that asset still has to be editable. So an
        // image already on the draft qualifies it too.
        if (widget.isDraft &&
            (widget.question.type.needsImage ||
                widget.question.images.isNotEmpty)) ...<Widget>[
          const SizedBox(height: 12),
          _EditableStimulus(store: widget.store, draftId: widget.question.id),
        ],
        const SizedBox(height: 12),
        Field(
          label: 'Description',
          help: 'Optional, shown to the candidate under the question.',
          child: TextField(
            controller: _desc,
            minLines: 1,
            maxLines: 4,
            style: context.type.body.copyWith(fontSize: 13),
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        const SizedBox(height: 12),
        Field(
          label: 'Time (minutes)',
          help: 'Blank or 0 means no per-question budget.',
          child: TextField(
            controller: _time,
            keyboardType: TextInputType.number,
            style: context.type.body.copyWith(fontSize: 13),
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        // Offered on BOTH forms. It was sent on every draft save while being
        // rendered nowhere, which quietly erased the server's copy whenever
        // the detail fetch had not landed; the bank save did not carry it at
        // all, so the same prose was uneditable there. Both halves are fixed
        // together - the field is visible here and `saveBankQuestion` now
        // passes it through - because a box that saves on one form and is
        // dropped on the other is the same bug wearing the other shoe.
        const SizedBox(height: 12),
        Field(
          label: 'Answer rationale',
          help:
              'Why the correct answer is correct. Never shown to the '
              'candidate.',
          child: TextField(
            controller: _reasoning,
            minLines: 2,
            maxLines: 6,
            style: context.type.body.copyWith(fontSize: 13),
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: Field(
                label: 'Difficulty',
                child: Wrap(
                  spacing: 5,
                  children: <Widget>[
                    for (final Difficulty d in Difficulty.values)
                      Btn(
                        d.label,
                        size: BtnSize.sm,
                        pressed: _difficulty == d,
                        onPressed: () => setState(() => _difficulty = d),
                      ),
                  ],
                ),
              ),
            ),
            // A draft is not in circulation, so only bank questions retire.
            if (!widget.isDraft) ...<Widget>[
              const SizedBox(width: 12),
              // AN ARCHIVED QUESTION GETS NO TOGGLE AT ALL. The switch writes
              // the WIRE flag `active`, which stays true on an archived (wire:
              // `retired`) record - see the seeding in initState - so the sheet
              // rendered "In circulation - can be drawn into a new assessment"
              // over a bank row that was showing an Archived pill and a Restore
              // button. The active flag is not what decides that; retirement
              // is. So the slot states the fact and offers the one move that
              // changes it.
              //
              // TWO FLAGS, ONE WORD. A question is out of the bank if EITHER
              // `retired` is set or the wire `active` is cleared, and the UI
              // calls both "Archived" because the difference is invisible to
              // the operator: `Question.active` is the derived
              // `recordActive && !retired`, so one pill covers both. Do not
              // try to merge the fields - the model comment on `retired`
              // explains why archiving a question the Odoo way would shrink
              // papers already sat.
              Expanded(
                child: _retired
                    ? Field(
                        label: 'Circulation',
                        // Deleted is final: no Restore, and the server
                        // refuses one anyway.
                        help: widget.question.deleted
                            ? 'Deleted for good. Papers that already use it '
                                  'keep it, with every answer and score.'
                            : 'Papers that already use it keep it. It cannot '
                                  'be drawn into a new assessment until it is '
                                  'restored.',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: <Widget>[
                              Pill(
                                widget.question.deleted
                                    ? 'Deleted'
                                    : 'Archived',
                                Tone.inert,
                              ),
                              if (!widget.question.deleted) ...<Widget>[
                                const SizedBox(width: 8),
                                Btn(
                                  'Restore',
                                  size: BtnSize.sm,
                                  busy: _restoring,
                                  onPressed: _restore,
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                    : SwitchRow(
                        name: _active ? 'In circulation' : 'Archived',
                        hint: _active
                            ? 'Can be drawn into a new assessment.'
                            : 'Kept for the record, never served again.',
                        value: _active,
                        onChanged: (bool v) => setState(() => _active = v),
                      ),
              ),
            ],
          ],
        ),
        if (_keyed) ...<Widget>[
          // ONE SECTION PER AXIS. A legacy A/B question has a single axis
          // called "Answer" and renders exactly as it always did; a
          // template-authored question keys one axis per examiner question, and
          // every one of them has to be visible to the human approving the key.
          for (int ai = 0; ai < _axes.length; ai++) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: _axes.length == 1
                      ? const Eyebrow('Options')
                      : TextField(
                          controller: _axes[ai].name,
                          style: context.type.body.copyWith(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'What this axis asks',
                          ),
                          onChanged: (String v) => setState(() {
                            if (ai == 0) _dimensionName = v;
                          }),
                        ),
                ),
                const SizedBox(width: 9),
                StatusBadge(
                  _takesOne(_axes[ai])
                      ? 'one correct'
                      : 'several may be correct',
                  Tone.inert,
                ),
                const SizedBox(width: 8),
                Btn(
                  'Add Option',
                  size: BtnSize.sm,
                  onPressed: () => setState(() {
                    final _EditOption fresh = _EditOption(
                      name: '',
                      correct: false,
                    );
                    _axes[ai].options.add(fresh);
                    if (ai == 0) _options.add(fresh);
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final _EditOption row in _axes[ai].options)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 116,
                      child: SwitchRow(
                        name: 'Correct',
                        hint: '',
                        value: row.correct,
                        onChanged: (bool v) => _toggleIn(_axes[ai], row, v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: row.text,
                        style: context.type.body.copyWith(fontSize: 13),
                        decoration: const InputDecoration(isDense: true),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    IconBtn(
                      Icons.close,
                      tooltip: row.id == null
                          ? 'Remove'
                          : 'Remove - refused if a candidate chose it',
                      onPressed: () => setState(() {
                        _axes[ai].options.remove(row);
                        if (ai == 0) _options.remove(row);
                        row.dispose();
                      }),
                    ),
                  ],
                ),
              ),
          ],
        ],
        if (problem != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(problem, style: context.type.small.copyWith(color: t.destText)),
        ],
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            const Spacer(),
            Btn('Cancel', onPressed: () => Navigator.of(context).pop()),
            const SizedBox(width: 8),
            Btn.primary(
              'Save',
              busy: busy,
              onPressed: problem == null ? _save : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// The question's plates, each replaceable in place. It lives in the editor,
/// not on the review-queue card whose job is approve-or-deny; the affordance
/// is centred on each plate so there is no doubt which slot it belongs to.
class _EditableStimulus extends StatefulWidget {
  final AppStore store;
  final String draftId;

  const _EditableStimulus({required this.store, required this.draftId});

  @override
  State<_EditableStimulus> createState() => _EditableStimulusState();
}

class _EditableStimulusState extends State<_EditableStimulus> {
  /// The slot currently uploading, so only that plate shows a spinner.
  String? _busySlot;

  /// Read live rather than from a captured Question: the sheet is built once by
  /// `showDialog` and does not listen to the store, so a plate replaced here
  /// would otherwise keep painting the picture it replaced.
  Question? get _draft => widget.store.draftById(widget.draftId);

  /// One entry per slot the module will accept, paired with whatever is in it.
  /// Falls back to the module's own pair when the draft has no assets to read
  /// slots from - a FAILED render leaves nothing behind.
  List<(String, Asset?)> get _plates {
    final Question? q = _draft;
    final List<Asset> assets = q?.images ?? const <Asset>[];
    if (assets.isNotEmpty) {
      final List<Asset> sorted = <Asset>[...assets]
        ..sort((Asset a, Asset b) => a.slot.compareTo(b.slot));
      return <(String, Asset?)>[
        for (final Asset a in sorted) (a.slot.toLowerCase(), a),
      ];
    }
    final List<String> fallback = q?.type == QType.imageAb
        ? const <String>['a', 'b']
        : const <String>['a'];
    return <(String, Asset?)>[for (final String s in fallback) (s, null)];
  }

  Future<void> _pick(String slot) async {
    final PickedFile? file = await pickFile(
      accept: '.png,.jpg,.jpeg,.webp,.gif',
    );
    if (file == null) return;
    setState(() => _busySlot = slot);
    try {
      await widget.store.applyUploadedImage(
        widget.draftId,
        image: base64Encode(file.bytes),
        slot: slot,
      );
    } finally {
      if (mounted) setState(() => _busySlot = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<(String, Asset?)> plates = _plates;
    final bool sideFree = _draft?.isSideFreeAb ?? false;
    return Field(
      label: plates.length == 1 ? 'Image' : 'Images',
      help: 'Click a plate to replace it. The upload applies immediately.',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final (int i, (String slot, Asset? asset))
              in plates.indexed) ...<Widget>[
            Expanded(
              child: _Plate(
                label: sideFree
                    ? sideFreeCaption(asset?.label ?? '', i)
                    : (asset?.label.isNotEmpty ?? false)
                    ? asset!.label
                    : 'Slot ${slot.toUpperCase()}',
                asset: asset,
                busy: _busySlot == slot,
                onReplace: widget.store.isLive ? () => _pick(slot) : null,
              ),
            ),
            if (slot != plates.last.$1) const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

class _Plate extends StatefulWidget {
  final String label;
  final Asset? asset;
  final bool busy;
  final VoidCallback? onReplace;

  const _Plate({
    required this.label,
    required this.asset,
    required this.busy,
    required this.onReplace,
  });

  @override
  State<_Plate> createState() => _PlateState();
}

class _PlateState extends State<_Plate> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Asset? asset = widget.asset;
    final bool on = widget.onReplace != null && !widget.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(widget.label.toUpperCase(), style: context.type.eyebrow),
        const SizedBox(height: 5),
        MouseRegion(
          cursor: on ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: on ? widget.onReplace : null,
            child: Container(
              decoration: BoxDecoration(
                color: t.bgMuted,
                borderRadius: Radii.card,
                border: Border.all(color: _hover && on ? t.primary : t.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (asset != null)
                      StimulusArt(asset: asset)
                    else
                      const MissingStimulus(),
                    // Scrim on hover only: a permanent wash over every plate
                    // would make a good render look muddy.
                    if (_hover && on)
                      ColoredBox(
                        color: t.bgApp.o(.45),
                        child: const SizedBox.expand(),
                      ),
                    Center(
                      child: widget.busy
                          ? const Spinner()
                          : _ReplaceDisc(active: on, raised: _hover && on),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The replace affordance carries its own surface, legible over any picture.
class _ReplaceDisc extends StatelessWidget {
  final bool active;
  final bool raised;

  const _ReplaceDisc({required this.active, required this.raised});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: active ? (raised ? 1 : .82) : .35,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: raised ? t.primary : t.bgApp.o(.92),
          shape: BoxShape.circle,
          border: Border.all(color: raised ? t.primary : t.border),
        ),
        child: Icon(
          Icons.file_upload_outlined,
          size: 20,
          // The same literal `Btn.primary` uses for its label: the palette has
          // no on-primary token, and the primary swatch is dark in both themes.
          color: raised ? const Color(0xFFFFFFFF) : t.textSecondary,
        ),
      ),
    );
  }
}
