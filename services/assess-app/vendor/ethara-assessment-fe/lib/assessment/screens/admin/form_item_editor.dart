// ONE item editor, shared by Form Studio and the Task Template designer.
//
// WHY THIS FILE EXISTS. The two screens each drew their own version of the
// same thing. Form Studio had 18 item kinds, help text, descriptions,
// duplicate/delete/reorder and the media BLOCKS (`textBlock`, `imageBlock`,
// `videoBlock`) a generated question fills in; the template editor had 13
// kinds, no blocks, and no item chrome at all - a reimplementation that had
// already drifted. A template is meant to be the shape of a Form Studio form,
// so anything the designer can express, a template must be able to express
// too. Two copies could only drift further.
//
// The rule for this file: it is the DESIGNER'S code, moved verbatim. Every
// comment, padding, tooltip and hint string is the one Form Studio shipped,
// because "exactly like Form Studio" is the requirement, not an approximation
// of it.
//
// OWNERSHIP. The widget edits ONE item and nothing else. The list it lives in
// belongs to the parent, so duplicate and delete are callbacks rather than
// list surgery done here - the designer inserts into a FormSection, the
// template editor into its own structure, and neither has to know about the
// other's container.
import 'dart:async';

import 'package:flutter/material.dart';

// The web half must resolve, or Dart silently falls back to the stub whose
// pickFile is `async => null` and the chooser never opens - with `dart analyze`
// staying clean throughout. From screens/admin/ the services dir is three
// levels up, not four. (Chakshu's fix; this file inherited the broken spelling
// when the item editor was extracted out of form_designer_screen.dart.)
import '../../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../../services/file_pick_web.dart';
import '../../data/api_client.dart'
    show isOurMediaOrigin, kApiPrefix, resolveMediaUrl;
import '../../domain/enums.dart' show Tone;
import '../../domain/form_models.dart';
import '../../domain/models.dart' show Asset, LabelRegion;
import '../../domain/transcription.dart';
import '../../state/app_store.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/controls.dart';
import '../../widgets/feedback.dart' show Notice;
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import '../exam/stimulus.dart' show RegionOverlayImage, stimulusImageProvider;
import '../exam/image_plate.dart';
import '../exam/clip_answers_form.dart';
import '../exam/transcription_box.dart';
import '../exam/video_plate.dart';
import 'zoomable_image.dart';

/// The editing card for a single form item - kind picker, title, help text,
/// the kind-specific body, and the duplicate/delete/required footer.
class FormItemEditor extends StatefulWidget {
  const FormItemEditor({
    super.key,
    required this.store,
    required this.item,
    required this.index,
    required this.onEdit,
    this.onDuplicate,
    this.onDelete,
    this.form,
    this.allowedKinds,
    this.showDragHandle = true,
  });

  final AppStore store;

  /// The item being edited. Mutated in place; [onEdit] is what persists it.
  final FormItem item;

  /// Position in the parent's list - the drag handle needs it.
  final int index;

  /// "I mutated the item; save it." The parent supplies setState + persist,
  /// because only it knows where this item is stored.
  final void Function(VoidCallback mutate) onEdit;

  /// Copy this item. NULL stands the control down, exactly as
  /// [showDragHandle] does for the drag gesture: a host that has nowhere to put
  /// a copy - a sheet editing ONE question in place - must not render a button
  /// that cannot work.
  ///
  /// This was `required` and took a `() {}` no-op from that sheet, which is
  /// worse than either alternative: the icons rendered, Delete ran its whole
  /// confirmation sheet, and then toasted "Question deleted" over a question
  /// that was still there.
  final VoidCallback? onDuplicate;

  /// Remove this item, or null to stand the control down - see [onDuplicate].
  /// Deleting a QUESTION is the bank's own delete, not an annotation edit.
  final VoidCallback? onDelete;

  /// The owning form, when there is one. Section jumps and the media pickers
  /// need it; a task template has no sections, so it passes null and those
  /// controls stand down rather than being faked.
  final FormDef? form;

  /// Narrows the kind picker. Null offers every kind, which is what Form
  /// Studio does.
  final List<FormItemKind>? allowedKinds;

  final bool showDragHandle;

  /// How the media Upload button asks for a file. A seam so a test can answer
  /// the picker and read the `accept` it was given (`pickFile` is null off the
  /// web); production never sets it.
  @visibleForTesting
  static Future<PickedFile?> Function({String accept}) pick = pickFile;

  @override
  State<FormItemEditor> createState() => _FormItemEditorState();
}

/// TWO SERVER-SIDE DRIVE DOWNLOADS AT A TIME, ACROSS EVERY CARD ON SCREEN.
///
/// The designer builds every editor on the first frame - its
/// `ReorderableListView.builder` runs with `shrinkWrap` and no lazy viewport -
/// so `_resolvePrefilledShareLinks` used to fire one `/forms/media/import` per
/// media slot from a single frame's timers, with nothing throttling them but
/// the browser's per-origin limit. That route is not cheap and not async: the
/// server fetches the Drive file with its own client, follows the redirects
/// hop by hop and buffers the body, so one request occupies one Odoo worker
/// for the length of a download. A thirty-question form therefore took the
/// whole worker pool hostage - including the exams being served by it - for
/// something nobody had asked for yet.
///
/// Two lanes, not one: a lane blocked on a twenty-second timeout must not stop
/// the rest of the form resolving, and two is still well under any sane worker
/// pool. State lives at the top of the library rather than on the State,
/// because the point is a budget shared by all of them.
///
/// AN IDLE LANE HOLDS NOTHING. Parking a completed future here to chain the
/// next job onto is the obvious shape and the wrong one: a `Future` remembers
/// the zone it was made in and schedules its listeners there, so a chain that
/// outlives the work it was built for is a lane that silently stops running
/// the moment that zone is gone. Cleared back to null the instant nothing is
/// queued behind it, so a lane is only ever a live queue.
final List<Future<void>?> _mediaImportLanes = <Future<void>?>[null, null];
int _mediaImportTurn = 0;

/// Run [job] once a lane is free, and hand back what it returns.
Future<T?> _queuedMediaImport<T>(Future<T?> Function() job) {
  final int lane = _mediaImportTurn++ % _mediaImportLanes.length;
  final Future<void> ahead = _mediaImportLanes[lane] ?? Future<void>.value();
  final Future<T?> run = ahead.then((void _) => job());
  // THE LANE MUST OUTLIVE A FAILED JOB. Everything queued behind it is
  // unrelated work, and chaining the raw future would cancel all of it on the
  // first throw - and report the failure twice, since the caller awaits `run`.
  final Future<void> tail = run.then<void>((T? _) {}, onError: (Object _) {});
  _mediaImportLanes[lane] = tail;
  unawaited(
    tail.whenComplete(() {
      if (identical(_mediaImportLanes[lane], tail)) {
        _mediaImportLanes[lane] = null;
      }
    }),
  );
  return run;
}

/// Urls whose AUTOMATIC import the server has already refused this session.
///
/// Opening a form re-mounts every card and re-runs the prefill pass, so without
/// this a form whose files are shared "Restricted" re-ran its whole fan of
/// refused downloads on every visit, and re-toasted every refusal. The verdict
/// is restored instead: the retry notice is on screen immediately and the only
/// thing that spends a request is the examiner pressing "Try again".
///
/// Session-scoped on purpose. A sharing setting fixed in Drive is picked up by
/// a reload, which is already the gesture for anything else stale here.
final Set<String> _autoImportRefused = <String>{};

class _FormItemEditorState extends State<FormItemEditor> {
  // PER-ITEM UI STATE, not form state. Which marker is selected, whether the
  // media row is in upload mode, which golden label is showing - none of it is
  // saved, and all of it is about THIS item, so it lives with the item's
  // editor rather than on whichever screen happens to host it.
  final Map<String, bool> _uploadMode = <String, bool>{};
  final Map<String, int?> _selMarker = <String, int?>{};
  final Map<String, int> _goldenSel = <String, int>{};

  /// The pending Drive probe per media slot, keyed `'<itemId>:<slot>'`.
  ///
  /// `_resolveShareLink` is wired to `onChanged`, so without this every
  /// keystroke in a media field opened its own `HEAD` with an 8-second timeout.
  /// Restarted on each change and cancelled in [dispose], so a card closed
  /// mid-probe leaves no timer behind.
  final Map<String, Timer> _probeDebounce = <String, Timer>{};

  /// Which media slots had their AUTOMATIC import fail, keyed the same way.
  ///
  /// WHY A FLAG AND NOT JUST THE URL SHAPE. A Drive file link is imported by
  /// this app on paste, so the manual "Copy into this app" offer is not merely
  /// redundant while that is under way - it is a false affordance, and it was
  /// reported as one: the notice and its button flash on screen for the length
  /// of the round trip and then vanish when the import lands, so the examiner
  /// is told to do something that is already being done and is finished before
  /// they can act on it.
  ///
  /// So the offer is suppressed for anything auto-imported and brought back
  /// ONLY here, when the attempt actually failed - which is the one case where
  /// a human decision is genuinely needed. Cleared on the next edit to the
  /// field, so a fresh paste starts from a clean slate.
  final Map<String, bool> _importFailed = <String, bool>{};

  /// Whether this card is collapsed. View state only, never persisted.
  ///
  /// A SECTION COULD COLLAPSE AND A QUESTION COULD NOT, which is the asymmetry
  /// that was reported: the two cards otherwise offer the same affordances
  /// (drag, duplicate, delete), so the one missing control read as an oversight
  /// rather than a decision - and it is the control that matters most, because a
  /// 47-item form is unnavigable when every option list is expanded.
  ///
  /// Held per-item on the STATE rather than in the parent's set: this widget
  /// already owns its other UI-only maps, and lifting it would make every
  /// host screen carry collapse plumbing it does not otherwise need.
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _resolvePrefilledShareLinks();
  }

  @override
  void didUpdateWidget(covariant FormItemEditor old) {
    super.didUpdateWidget(old);
    // A DIFFERENT QUESTION IN THE SAME SLOT. The designer reuses these States
    // as the list is reordered or re-rendered, so a card that now shows another
    // item has to re-examine what that item is carrying.
    if (old.item.id != widget.item.id) _resolvePrefilledShareLinks();
  }

  /// Import any Drive link this item ALREADY holds.
  ///
  /// THE BUG THIS CLOSES. `_resolveShareLink` is wired to the media field's
  /// `onChanged` and to nothing else, so it only ever ran for a link somebody
  /// TYPED. A link that arrived any other way - a JSON import, a duplicated
  /// form, a template, reopening a form saved before the import landed - was
  /// never resolved at all. The plate then drew the Drive share PAGE, which
  /// cannot render as an image, and reported "Copying that Drive file into this
  /// app..." while nothing whatsoever was happening. Re-pasting the identical
  /// link appeared to fix it, because pasting is the one path that was wired.
  ///
  /// Reported against a 30-question JSON import where every media item stuck.
  ///
  /// Cheap to be wrong about: `_resolveShareLink` returns immediately unless
  /// the value is a Drive FILE link, and an already-imported slot holds this
  /// app's own proxy url, which is not one.
  ///
  /// AND CHEAP TO DO. Opening a form must not turn into a fan of blocking
  /// server-side downloads, so these queue two at a time through
  /// `_queuedMediaImport`, say nothing when they succeed, and are not re-tried
  /// on the next visit once the server has refused them - see
  /// `_importShareLink` and `_autoImportRefused`. Marked `prefill` for exactly
  /// those three differences from a link somebody typed.
  void _resolvePrefilledShareLinks() {
    final FormItem it = widget.item;
    for (final (String slot, String value, void Function(String) apply) entry
        in <(String, String, void Function(String))>[
      ('a', it.mediaUrl, (String v) => it.mediaUrl = v),
      ('b', it.mediaUrlB, (String v) => it.mediaUrlB = v),
    ]) {
      final (String slot, String value, void Function(String) apply) = entry;
      if (value.trim().isEmpty) continue;
      unawaited(_resolveShareLink(it, value, apply, slot: slot, prefill: true));
    }
  }

  @override
  void dispose() {
    // A card can be deleted or scrolled out of the tree with a probe pending;
    // the timer would then fire against a disposed State.
    for (final Timer t in _probeDebounce.values) {
      t.cancel();
    }
    _probeDebounce.clear();
    super.dispose();
  }

  /// Mutate the item, then hand persistence back to the parent. Local
  /// setState covers the UI-state maps above, which the parent knows nothing
  /// about.
  void _edit(VoidCallback body) {
    setState(() {});
    widget.onEdit(body);
  }

  @override
  Widget build(BuildContext context) => _card();

  /// Copy the item, and SAY SO. The copy itself is the parent's business - it
  /// owns the list - so this adds only the acknowledgement, which a section's
  /// duplicate already gave and a question's did not: the new card appears
  /// below the original, and on a form long enough to scroll that is off
  /// screen, so without a toast the click looked like it had done nothing.
  void _duplicate() {
    final VoidCallback? go = widget.onDuplicate;
    if (go == null) return;
    go();
    widget.store.toaster.ok('Question duplicated');
  }

  /// Deleting a question throws away its options, its answer key and its
  /// media, and the designer has no undo - so it asks first, exactly as
  /// `form_designer_screen._confirmDeleteSection` does for a section. This was
  /// the one destructive control in the designer that fired on a single click.
  Future<void> _confirmDelete() async {
    final FormItem it = widget.item;
    final String title = it.title.trim();
    final bool? yes = await showSheet<bool>(
      context,
      title: it.kind.isQuestion ? 'Delete this question?' : 'Delete this block?',
      sub: 'This cannot be undone.',
      body: Text(
        '${formItemLabel(it)}'
        '${title.isEmpty ? '' : ' ("$title")'} will be permanently deleted.',
        style: context.type.body,
      ),
      actions: <Widget>[
        Btn('Cancel', onPressed: () => Navigator.of(context).pop(false)),
        Btn.danger(
          it.kind.isQuestion ? 'Delete Question' : 'Delete Block',
          tooltip: 'Permanently delete this item, with its options and '
              'answer key.',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    // The sheet is awaited, so the card can be gone by the time it closes -
    // the host dialog can be dismissed underneath it.
    if (yes != true || !mounted) return;
    final VoidCallback? go = widget.onDelete;
    if (go == null) return;
    go();
    widget.store.toaster.ok(
      it.kind.isQuestion ? 'Question deleted' : 'Block deleted',
    );
  }

  /// What a collapsed question shows in place of its body: the question text and
  /// a one-line shape summary, so a long form stays scannable and every card is
  /// still identifiable. Mirrors `form_designer_screen._collapsedSummary`.
  Widget _collapsedSummary(FormItem it, AppTokens t) {
    final String title = it.title.trim();
    final int opts = it.options.length;
    final List<String> bits = <String>[
      formItemLabel(it),
      if (it.kind.isGrid)
        '${it.rows.length}x${it.columns.length}'
      else if (opts > 0)
        '$opts option${opts == 1 ? '' : 's'}',
      if (it.required) 'required',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title.isEmpty
              ? (it.kind.isQuestion ? 'Untitled question' : 'Untitled block')
              : title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.type.body.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 3),
        Row(
          children: <Widget>[
            // 15/8, not 14/7: the same glyph at the same size and the same
            // gap as a collapsed section's - see
            // `form_designer_screen._collapsedSummary`.
            Icon(Icons.unfold_more, size: 15, color: t.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${bits.join(' · ')} · collapsed',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.small.copyWith(color: t.textMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _card() {
    final AppTokens t = context.tokens;
    final FormItem it = widget.item;
    final FormDef? f = widget.form;
    final int ii = widget.index;

    // THE CARD IS BUILT LIKE A `Panel`, BECAUSE IT HAS TO ALIGN WITH ONE.
    //
    // A section is a `Panel`: a header strip with the title on the left and its
    // controls on the RIGHT EDGE, a hairline, then a padded body. This card was
    // a single padded `Container` with one long `Column` in it, so its four
    // controls had no header to sit in and no edge to line up against - they
    // landed wherever the flex maths left them, which is the misalignment in
    // the screenshot. The three strips below are `Panel`'s own geometry
    // (15/12 head, 15/14 body, 15/10 foot, `borderSubtle` under the head and
    // `border` over the foot - see `Panel.build`), so a question's controls now
    // sit at the same inset from their card's edge as a section's do from
    // theirs, at the same size, in the same order.
    //
    // Not literally a `Panel`: this one is nested inside a section's body and
    // carries `bgSubtle` to read as the inner card, where `Panel` hard-codes
    // `bgApp`. Only the colour differs.
    return Container(
      decoration: BoxDecoration(
        color: t.bgSubtle,
        borderRadius: Radii.card,
        border: Border.all(color: t.border),
      ),
      // Clipped like a `Panel`, so the head's hairline stops at the rounded
      // corner instead of running out through it.
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // `.ph` - the header strip. The kind picker stands in for a panel's
          // title; the four controls are the `headActions`.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.borderSubtle)),
            ),
            child: Row(
              children: <Widget>[
                // EXPANDED, as `Panel`'s own header does it - the title side
                // owns the gap, so the actions cannot be pushed in by it.
                //
                // `Flexible` + `Spacer` (what this was) happens to place the
                // icons correctly, because Flexible's loose fit lets the picker
                // Row shrink to 220px and the Spacer then takes the whole
                // remainder. It is kept out anyway: `Panel` documents a real
                // mid-header failure for that pair when the left side FILLS,
                // and two headers that must stay aligned should not be built
                // two different ways.
                Expanded(
                  child: Row(
                    children: <Widget>[
                      // Flexible inside it, so on a narrow window the picker
                      // gives way instead of pushing the controls off the card.
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                      // KIND PLUS "IS AUDIO", not the kind alone: Video and
                      // Audio are one wire kind (`videoBlock`) told apart by
                      // `media_kind`, and the picker offers both.
                      child: SelectField<(FormItemKind, bool)>(
                        value: (it.kind, isAudioBlock(it)),
                        // NARROWED BY [allowedKinds], which was declared and
                        // never read - so a host that asked for one kind still
                        // got all fifteen, and the annotation sheet offered to
                        // retype a labelling question into an MCQ. Doing that
                        // from a sheet that saves back onto a BANK question
                        // would rewrite what the paper asks, not where a box
                        // sits.
                        //
                        // The item's OWN kind is always included, or a picker
                        // could open on a value it does not offer - which is a
                        // Flutter assertion, not a graceful degradation.
                        options: <((FormItemKind, bool), String)>[
                          for (final FormItemKind k in <FormItemKind>{
                            it.kind,
                            ...?widget.allowedKinds,
                            if (widget.allowedKinds == null)
                              ...FormItemKind.values,
                          }) ...<((FormItemKind, bool), String)>[
                            ((k, false), k.label),
                            if (k == FormItemKind.videoBlock)
                              ((k, true), 'Audio'),
                          ],
                        ],
                        onChanged: ((FormItemKind, bool) pick) => _edit(() {
                          final (FormItemKind k, bool audio) = pick;
                          // The declared medium is set on arriving at Video or
                          // Audio and cleared on leaving them: a leftover
                          // 'audio' on an image block would publish its picture
                          // as a clip (`studio_form._item_media_is_video`).
                          if (k == FormItemKind.videoBlock) {
                            it.mediaKind = audio ? 'audio' : 'video';
                          } else if (k == FormItemKind.transcription) {
                            // A transcription's clip is always audio, and an
                            // Audio block's clip carries straight over.
                            it.mediaKind = 'audio';
                          } else if (it.kind == FormItemKind.videoBlock ||
                              it.kind == FormItemKind.transcription) {
                            it.mediaKind = '';
                          }
                          it.kind = k;
                          // A kind the candidate answers with ONE pick keeps
                          // one correct answer: the server refuses more there
                          // (`takes_one_answer`), so Checkboxes with two ticked
                          // turned into a Multiple choice nobody could save.
                          _keepOneCorrect(it);
                          if (k == FormItemKind.choiceGrid) {
                            it.gridKey.updateAll(
                              (int _, Set<String> v) =>
                                  v.length > 1 ? <String>{v.first} : v,
                            );
                          }
                          // Arriving on a kind that needs structure it does not
                          // have yet: seed the defaults the designer opens on.
                          // A comparison, or a single media block, is exempt -
                          // each stays option-less (a display) until the creator
                          // adds one. Prompt writing is exempt too: its options
                          // are the OPTIONAL rating axes, and seeding one would
                          // put an unasked-for axis above every prompt box.
                          if (k.hasOptions &&
                              k != FormItemKind.comparePair &&
                              k != FormItemKind.imageBlock &&
                              k != FormItemKind.videoBlock &&
                              k != FormItemKind.promptWriting) {
                            // Top up to TWO, the smallest list that is actually
                            // a choice - the server refuses fewer ("one option
                            // is not a choice"), so stopping at one handed the
                            // author a question that could not publish. Tops up
                            // rather than replaces, so switching between choice
                            // kinds keeps whatever the author already typed.
                            while (it.options.length < 2) {
                              it.options.add(formNewOption(it.options.length));
                            }
                          }
                          if (k.isGrid && it.rows.isEmpty) {
                            it.rows.addAll(<String>['Row 1', 'Row 2']);
                          }
                          if (k.isGrid && it.columns.isEmpty) {
                            it.columns.addAll(<String>['Column 1', 'Column 2']);
                          }
                        }),
                      ),
                        ),
                      ),
                    ],
                  ),
                ),
                // The four controls, in a section header's order and with a
                // section header's icons - see `form_designer_screen._section`.
                // Spread with no gaps between them, as `Panel` spreads its
                // `headActions`; an `IconBtn` is a 27x27 box that already
                // carries its own breathing room.
                IconBtn(
                  _collapsed ? Icons.expand_more : Icons.expand_less,
                  tooltip: _collapsed ? 'Expand question' : 'Collapse question',
                  onPressed: () => setState(() => _collapsed = !_collapsed),
                ),
                // A drag handle is only meaningful inside a Reorderable list.
                // The task template editor draws a plain flat list, and a
                // ReorderableDragStartListener with no reorderable ancestor
                // throws the moment it is dragged - so the handle stands down
                // rather than offering a gesture that cannot work.
                if (widget.showDragHandle)
                  ReorderableDragStartListener(
                    index: ii,
                    child: IconBtn(
                      Icons.drag_indicator,
                      tooltip: 'Drag to reorder',
                      onPressed: () {},
                    ),
                  ),
                // DUPLICATE AND DELETE BELONG UP HERE, not in a footer.
                //
                // They used to sit below an `Hr()` at the bottom of the card,
                // which put the same two actions in two different places
                // depending on whether the reader was looking at a section or a
                // question - and on a long question the footer scrolls out of
                // sight, so the controls moved as the card grew. Nothing is
                // gated: a section refuses to delete its last one, but a
                // section is allowed to hold no questions at all.
                // Each stands down when the host cannot honour it, the same way
                // the drag handle above does.
                if (widget.onDuplicate != null)
                  IconBtn(
                    Icons.copy_outlined,
                    tooltip: 'Duplicate question',
                    onPressed: _duplicate,
                  ),
                if (widget.onDelete != null)
                  IconBtn(
                    Icons.delete_outline,
                    tooltip: 'Delete question',
                    onPressed: _confirmDelete,
                  ),
              ],
            ),
          ),
          // `.pb` - the body, on a panel body's padding.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // COLLAPSED SHOWS THE QUESTION, NOT NOTHING. The title is the
                // only thing that identifies which item this is, so hiding it
                // would make a collapsed form a stack of anonymous kind
                // pickers.
                if (_collapsed)
                  _collapsedSummary(it, t)
                else ...<Widget>[
                  FormTextInput(
                    id: 'it-title-${it.id}',
                    value: it.title,
                    hint: it.kind.isQuestion ? 'Question' : 'Title',
                    onChanged: (String v) => _edit(() => it.title = v),
                  ),
                  const SizedBox(height: 8),
                  FormTextInput(
                    id: 'it-help-${it.id}',
                    value: it.help,
                    hint: it.kind == FormItemKind.textBlock
                        ? 'Body text (optional)'
                        : 'Help text (optional)',
                    onChanged: (String v) => _edit(() => it.help = v),
                  ),
                  const SizedBox(height: 14),
                  _itemBody(f, it),
                ],
              ],
            ),
          ),
          // `.pfoot` - the Required switch, on a panel footer's strip.
          //
          // A rule drawn by hand (`Hr()`) inside the body put the switch on a
          // hairline that did not reach the card's edge, where a section's
          // footer rule does. It also stands down entirely on a display block
          // that cannot be answered - an empty strip read as a card that had
          // lost its buttons - and on a collapsed card, where a section shows
          // its summary and nothing else.
          if (it.isAnswerable && !_collapsed)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: t.border)),
              ),
              child: Row(
                children: <Widget>[
                  const Spacer(),
                  Text(
                    it.kind.isGrid ? 'Require every row' : 'Required',
                    style: context.type.small,
                  ),
                  const SizedBox(width: 6),
                  Switcher(
                    value: it.required,
                    onChanged: (bool v) => _edit(() => it.required = v),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// THE REGISTRY. One entry per [FormItemKind], each pointing at the exact
  /// method that already drew that kind's body - no behaviour changed, only
  /// how it is reached. Adding a new kind is now "add one line here" instead
  /// of finding and extending a switch expression.
  ///
  /// INSTANCE-level, not static: every builder below is a bound method that
  /// closes over this State's own `_edit`, `_uploadMode`, `_selMarker`,
  /// `_goldenSel` and `widget.store` - a top-level static map of free
  /// functions cannot hold these without threading all of that through a
  /// parameter list the registry would then have to carry too. Built once
  /// per State (in [initState]), not per build: the methods themselves are
  /// stable for the State's lifetime, so there is nothing to recompute.
  late final Map<FormItemKind, Widget Function(FormDef?, FormItem)>
  _bodyRegistry = <FormItemKind, Widget Function(FormDef?, FormItem)>{
    FormItemKind.shortAnswer: (FormDef? f, FormItem it) =>
        _subjective(f, it, 'Short answer text'),
    FormItemKind.paragraph: (FormDef? f, FormItem it) =>
        _subjective(f, it, 'Long answer text'),
    FormItemKind.multipleChoice: _options,
    FormItemKind.checkboxes: _options,
    FormItemKind.dropdown: _options,
    FormItemKind.linearScale: _scale,
    FormItemKind.rating: _rating,
    FormItemKind.choiceGrid: _grid,
    FormItemKind.checkboxGrid: _grid,
    FormItemKind.textBlock: (FormDef? f, FormItem it) =>
        const SizedBox.shrink(),
    FormItemKind.imageBlock: (FormDef? f, FormItem it) =>
        _media(f, it, image: true),
    FormItemKind.videoBlock: (FormDef? f, FormItem it) =>
        _media(f, it, image: false),
    FormItemKind.imageAnnotation: _annotation,
    FormItemKind.comparePair: _comparePair,
    FormItemKind.promptWriting: _promptWriting,
    FormItemKind.transcription: _transcription,
  };

  Widget _itemBody(FormDef? f, FormItem it) {
    final Widget Function(FormDef?, FormItem)? builder =
        _bodyRegistry[it.kind];
    // Every FormItemKind value has an entry above; this only trips if a
    // future kind is added to the enum and forgotten here - fail loud in
    // debug rather than draw nothing and let the gap go unnoticed.
    assert(builder != null, 'No editor body registered for ${it.kind}');
    return builder?.call(f, it) ?? const SizedBox.shrink();
  }

  /// TRANSCRIPTION: the clip, its language, and the correct answers the LLM
  /// judge marks against - the transcription, then the clip's category,
  /// characteristics and speakers, drawn with the same controls the candidate
  /// answers with (`ClipAnswersForm`), so the two cannot offer different
  /// choices.
  Widget _transcription(FormDef? f, FormItem it) {
    final String lang = it.transcriptionLanguage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _mediaUrlRow(
          f,
          it,
          slot: 'main',
          value: it.mediaUrl,
          hint: 'Audio URL (https://…)',
          accept: _audAccept,
          apply: (String v) => it.mediaUrl = v,
        ),
        if (it.mediaUrl.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          _mediaPlate(it, url: it.mediaUrl, slot: 'main', forceVideo: true),
        ],
        const SizedBox(height: 14),
        Text('LANGUAGE', style: context.type.fieldLabel),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          children: <Widget>[
            for (final (String code, String name) in const <(String, String)>[
              ('hi', 'Hindi (Devanagari)'),
              ('en', 'English (small letters)'),
            ])
              Btn(
                name,
                size: BtnSize.sm,
                pressed: lang == code,
                onPressed: () => _edit(() => it.transcriptionLanguage = code),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (it.goldenClip.transcribed) ...<Widget>[
          TranscriptionBox(
            // Keyed on the language: switching it rebuilds the box with or
            // without Hindi typing.
            key: ValueKey<String>('golden-tx-${it.id}-$lang'),
            label: 'Correct transcription (for the LLM judge)',
            language: lang,
            initialText: it.goldenAnswer,
            tools: false,
            minLines: 3,
            onChanged: (String v) => _edit(() => it.goldenAnswer = v),
          ),
          const SizedBox(height: 4),
          Text(
            'What was said, in spoken form. Left empty, the item cannot be '
            'auto-scored. Never shown to respondents.',
            style: context.type.tiny.copyWith(height: 1.45),
          ),
          const SizedBox(height: 14),
        ],
        ClipAnswersForm(
          clip: it.goldenClip,
          language: lang,
          labelPrefix: 'Correct ',
          onChanged: (ClipAnswers c) => _edit(() {
            it.goldenClip.category = c.category;
            it.goldenClip.characteristics
              ..clear()
              ..addAll(c.characteristics);
            it.goldenClip.speakers
              ..clear()
              ..addAll(c.speakers);
          }),
        ),
        const SizedBox(height: 12),
        _ghost(
          'Marked by the LLM judge against these answers: it lists each '
          'mistake as critical or minor. 1 critical or 5 minor fails the '
          "clip, and the score must also reach the assessment's bar.",
        ),
      ],
    );
  }

  /// PROMPT WRITING: the stimulus the candidate is shown, then the model
  /// prompt the judge grades their attempt against.
  ///
  /// TWO SLOTS, the second optional. The from-scratch form of this question
  /// shows ONE image or clip ("write the prompt that would produce this"); the
  /// transform form shows a REFERENCE and its OUTPUT ("write the prompt that
  /// turns the first into the second"). One editor covers both: fill the
  /// second slot and the question becomes a transform.
  ///
  /// Image or video is not asked, it is READ from the URL - the server decides
  /// `image_prompt` vs `video_prompt` the same way, so a picker here could
  /// only ever disagree with it.
  Widget _promptWriting(FormDef? f, FormItem it) {
    final AppTokens t = context.tokens;
    final bool hasPair = it.mediaUrlB.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Eyebrow(hasPair ? 'Reference' : 'The image or clip'),
        const SizedBox(height: 6),
        _mediaUrlRow(
          f,
          it,
          slot: 'main',
          value: it.mediaUrl,
          hint: 'Image or video URL (https://…)',
          accept: '$_imgAccept,$_vidAccept',
          apply: (String v) => it.mediaUrl = v,
        ),
        if (it.mediaUrl.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          _promptPlate(it, it.mediaUrl, 'main'),
        ],
        const SizedBox(height: 14),
        Eyebrow(hasPair ? 'Output' : 'Output (optional)'),
        const SizedBox(height: 4),
        Text(
          'Leave empty to ask for a prompt that produces the media above. '
          'Fill it in to ask for the prompt that turns the reference INTO '
          'this output.',
          style: context.type.tiny.copyWith(height: 1.45),
        ),
        const SizedBox(height: 6),
        _mediaUrlRow(
          f,
          it,
          slot: 'output',
          value: it.mediaUrlB,
          hint: 'Image or video URL (https://…)',
          accept: '$_imgAccept,$_vidAccept',
          apply: (String v) => it.mediaUrlB = v,
        ),
        if (hasPair) ...<Widget>[
          const SizedBox(height: 8),
          _promptPlate(it, it.mediaUrlB, 'output'),
        ],
        const SizedBox(height: 14),
        Field(
          label: 'Golden prompt (for the LLM judge)',
          help: 'The prompt a perfect answer writes. Left empty, the item '
              'cannot be auto-scored. Never shown to respondents.',
          child: FormTextInput(
            id: 'golden-prompt-${it.id}',
            value: it.goldenAnswer,
            hint: 'The prompt that would produce this…',
            maxLines: 4,
            onChanged: (String v) => _edit(() => it.goldenAnswer = v),
          ),
        ),
        const SizedBox(height: 14),
        // OPTIONAL axes. Unlike every other option-carrying kind an empty list
        // is the normal case here - the written prompt is the answer - so the
        // list opens empty and says what adding one would do.
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                it.options.isEmpty
                    ? 'Rating axes (optional): add one to have the candidate '
                          'also rate the media before writing their prompt.'
                    : 'Rating axes: answered above the prompt box.',
                style: context.type.tiny.copyWith(
                  height: 1.45,
                  color: t.textMuted,
                ),
              ),
            ),
            if (it.options.isEmpty) ...<Widget>[
              const SizedBox(width: 8),
              Btn(
                'Add an axis',
                tooltip: 'Add a rating the candidate answers alongside their '
                    'written prompt.',
                size: BtnSize.sm,
                icon: Icons.add_task_outlined,
                onPressed: () =>
                    _edit(() => it.options.add(formNewOption(0))),
              ),
            ],
          ],
        ),
        if (it.options.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          _options(f, it),
        ],
      ],
    );
  }

  /// One prompt-writing plate, drawn as the respondent will see it: an image
  /// in the shared 4:3 frame, a clip in the real player.
  Widget _promptPlate(FormItem it, String url, String slot) =>
      _mediaPlate(it, url: url, slot: slot);

  Widget _comparePair(FormDef? f, FormItem it) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _mediaPair(f, it),
      const SizedBox(height: 14),
      if (it.options.isEmpty) ...<Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ghost(
            'No options: the pair is shown as context only. Add a verdict '
            'to ask which side wins right under the images.',
          ),
        ),
        // One click prefills the standard A/B/Tie verdict so the creator
        // doesn't retype it every time.
        Row(
          children: <Widget>[
            Btn(
              'Add A / B / Tie verdict',
              tooltip: 'Prefill the standard verdict options in one click.',
              size: BtnSize.sm,
              icon: Icons.add_task_outlined,
              onPressed: () => _edit(() {
                it.options
                  ..add(FormOption(formNewId('opt'), 'Response A'))
                  ..add(FormOption(formNewId('opt'), 'Response B'))
                  ..add(FormOption(formNewId('opt'), 'Tie'));
                it.required = true;
              }),
            ),
          ],
        ),
        const SizedBox(height: 4),
      ],
      _options(f, it),
      const SizedBox(height: 14),
      const Hr(),
      const SizedBox(height: 10),
      // THE WRITTEN HALF IS OPTIONAL, AND THIS IS WHERE IT IS CHOSEN.
      //
      // The verdict above is keyed on an option and marked in code, so the
      // comparison already scores without a word of prose. Asking for a
      // justification adds a mark of its own - and something to mark it
      // against, which is why the rationale below appears with it and is
      // required by publish. Off, the candidate never sees the box at all.
      Row(
        children: <Widget>[
          Text('Require justification', style: context.type.small),
          const SizedBox(width: 8),
          Switcher(
            value: it.requireJustification,
            onChanged: (bool v) =>
                _edit(() => it.requireJustification = v),
          ),
        ],
      ),
      const SizedBox(height: 6),
      if (it.requireJustification) ...<Widget>[
        const SizedBox(height: 6),
        Field(
          label: 'Answer rationale (for the LLM judge)',
          help: 'The reasoning a correct verdict rests on. The judge marks '
              'each candidate justification against this, so the form '
              'cannot be published while it is empty. Never shown to '
              'candidates.',
          child: FormTextInput(
            id: 'ab-rationale-${it.id}',
            value: it.goldenAnswer,
            hint: 'Why the keyed side wins...',
            maxLines: 3,
            onChanged: (String v) => _edit(() => it.goldenAnswer = v),
          ),
        ),
      ] else
        _ghost(
          'The candidate answers on the verdict alone - no justification box, '
          'and the question is worth its verdict.',
        ),
    ],
  );

  Widget _ghost(String text) => Text(
    text,
    style: context.type.bodyMuted.copyWith(fontStyle: FontStyle.italic),
  );

  /// A free-text question in the designer: the respondent's ghost, then the
  /// GOLDEN ANSWER the examiner authors - the canonical answer the LLM judge
  /// grades worker text against (the harness's solutions.json, one item's
  /// worth). Respondents never see it.
  Widget _subjective(FormDef? f, FormItem it, String ghost) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _ghost(ghost),
      const SizedBox(height: 12),
      Field(
        label: 'Golden answer (for the LLM judge)',
        help: 'The canonical correct answer, in concrete terms. Left empty, '
            'the item cannot be auto-scored. Never shown to respondents.',
        child: FormTextInput(
          id: 'golden-${it.id}',
          value: it.goldenAnswer,
          hint: 'What a perfect answer states…',
          maxLines: 3,
          onChanged: (String v) => _edit(() => it.goldenAnswer = v),
        ),
      ),
    ],
  );

  /// Single-select kinds hold ONE correct option; checkboxes may hold many.
  /// imageBlock/videoBlock have no separate checkboxes sibling kind, so
  /// `multiSelect` carries the same distinction for them.
  static bool _multiKey(FormItem it) =>
      it.kind == FormItemKind.checkboxes ||
      ((it.kind == FormItemKind.imageBlock ||
              it.kind == FormItemKind.videoBlock) &&
          it.multiSelect);

  /// On a one-pick item, only the first correct option stays correct: the
  /// server refuses more (`takes_one_answer`).
  static void _keepOneCorrect(FormItem it) {
    if (_multiKey(it)) return;
    bool kept = false;
    for (final FormOption o in it.options) {
      if (o.correct && kept) o.correct = false;
      kept = kept || o.correct;
    }
  }

  Widget _options(FormDef? f, FormItem it) {
    final AppTokens t = context.tokens;
    final bool multiKey = _multiKey(it);

    // The leading marker doubles as the ANSWER-KEY toggle: tap to mark the
    // correct option(s). Green check = in the key. Never shown to
    // respondents - the preview renders its own plain markers.
    Widget lead(int i) {
      final FormOption o = it.options[i];
      return SizedBox(
        width: 22,
        child: Tooltip(
          message: o.correct
              ? 'Correct answer - tap to unmark'
              : 'Tap to mark as the correct answer',
          child: InkWell(
            onTap: () => _edit(() {
              if (!o.correct && !multiKey) {
                for (final FormOption x in it.options) {
                  x.correct = false;
                }
              }
              o.correct = !o.correct;
            }),
            borderRadius: Radii.buttonSm,
            child: Icon(
              o.correct
                  ? Icons.check_circle
                  : (multiKey
                        ? Icons.check_box_outline_blank
                        : Icons.radio_button_unchecked),
              size: 16,
              color: o.correct ? t.successText : t.textMuted,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // ONE PLAIN ROW PER OPTION: the key toggle, the label, remove.
        //
        // This was a LayoutBuilder that reflowed a per-option "Go to Section N"
        // picker under the label on a narrow window. Option-level branching is
        // gone (see `FormOption`), and with it the only thing that row ever had
        // to make space for.
        for (int i = 0; i < it.options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                lead(i),
                const SizedBox(width: 8),
                Expanded(
                  child: FormTextInput(
                    id: 'opt-${it.options[i].id}',
                    value: it.options[i].label,
                    hint: 'Option ${i + 1}',
                    onChanged: (String v) =>
                        _edit(() => it.options[i].label = v),
                  ),
                ),
                const SizedBox(width: 4),
                IconBtn(
                  Icons.close,
                  tooltip: 'Remove option',
                  onPressed: it.options.length == 1
                      ? null
                      : () => _edit(() => it.options.removeAt(i)),
                ),
              ],
            ),
          ),
        // NO 'Add "Other"'. A free-text Other choice cannot be scored: it is not
        // one of the authored options, so it can never match the answer key, and
        // every candidate who picks it is marked wrong whatever they type. The
        // publish path had ALREADY been dropping it with a warning
        // ('the "Other" free-text option is not deliverable in an exam and was
        // dropped'), so offering the control only invited an examiner to author
        // something the server would silently discard.
        Row(
          children: <Widget>[
            Btn(
              'Add option',
              size: BtnSize.sm,
              icon: Icons.add,
              tooltip: 'Add another answer choice to this question',
              onPressed: () => _edit(
                () => it.options.add(formNewOption(it.options.length)),
              ),
            ),
          ],
        ),
        // NO PER-QUESTION "Shuffle option order" ROW. Randomising choices is
        // now a decision about the FORM, taken once behind the header's settings
        // gear (`FormDef.shuffleQuestions`), instead of a toggle repeated on
        // every choice question a few rows above it.
      ],
    );
  }

  Widget _scale(FormDef? f, FormItem it) {
    // A stored golden value can fall outside [scaleMin, scaleMax] after the
    // range is narrowed from underneath it; clamp for DISPLAY only so the
    // picker never offers a value it does not carry as an option, but leave
    // the stored int alone in case the range widens back.
    final int? golden = it.scaleGolden?.clamp(it.scaleMin, it.scaleMax);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            NumberField(
              value: it.scaleMin,
              min: 0,
              max: 1,
              onChanged: (int v) => _edit(() => it.scaleMin = v),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('to', style: context.type.small),
            ),
            NumberField(
              value: it.scaleMax,
              min: 2,
              max: 10,
              onChanged: (int v) => _edit(() => it.scaleMax = v),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: FormTextInput(
                id: 'scale-min-${it.id}',
                value: it.scaleMinLabel,
                hint: 'Label for ${it.scaleMin} (optional)',
                onChanged: (String v) => _edit(() => it.scaleMinLabel = v),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FormTextInput(
                id: 'scale-max-${it.id}',
                value: it.scaleMaxLabel,
                hint: 'Label for ${it.scaleMax} (optional)',
                onChanged: (String v) => _edit(() => it.scaleMaxLabel = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // THE KEY IS REQUIRED, so "No key" is not on offer.
        //
        // It used to be the FIRST option and the default, with help text
        // explaining that leaving it there meant the item "cannot be
        // auto-scored" - an invitation to publish a question worth nothing.
        // Publishing now refuses without a key, so offering the choice only let
        // an examiner build something the server would reject.
        //
        // AN UNSET SCALE IS NOT SILENTLY GIVEN ONE. Defaulting to the midpoint
        // would invent an answer the examiner never chose, which is the worse
        // failure: it publishes and marks every candidate against a guess. So an
        // unset item shows "Not set" - visible, and gone once a real value is
        // picked - and publishing refuses with a message naming the question.
        _keyPicker(
          label: 'Golden answer (for auto-scoring)',
          help: 'The value a perfect response picks. Required - the item '
              'cannot be published without it. Never shown to respondents.',
          value: golden,
          values: <int>[for (int v = it.scaleMin; v <= it.scaleMax; v++) v],
          onChanged: (int v) => _edit(() => it.scaleGolden = v),
        ),
      ],
    );
  }

  /// A REQUIRED numeric answer key, offered as a one-way choice.
  ///
  /// "Not set" appears only while the key IS unset, and disappears once a real
  /// value is picked - so the state is visible and nameable, but not somewhere
  /// an examiner can deliberately return to. Defaulting to a value instead
  /// would invent an answer nobody chose and publish happily, which is the
  /// worse of the two failures: the form would then score every candidate
  /// against a guess.
  Widget _keyPicker({
    required String label,
    required String help,
    required int? value,
    required List<int> values,
    required ValueChanged<int> onChanged,
  }) {
    final AppTokens t = context.tokens;
    return Field(
      label: label,
      help: help,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 190,
            child: SelectField<int?>(
              value: value,
              options: <(int?, String)>[
                if (value == null) (null, 'Not set'),
                for (final int v in values) (v, '$v'),
              ],
              onChanged: (int? v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
          if (value == null) ...<Widget>[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Set the key to publish this form.',
                style: context.type.tiny.copyWith(color: t.warnText),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _rating(FormDef? f, FormItem it) {
    final AppTokens t = context.tokens;
    // A stored golden value can fall outside 1..ratingMax after the range is
    // narrowed from underneath it; clamp for DISPLAY only, same reasoning as
    // the linear scale's golden clamp above.
    final int? golden = it.ratingGolden?.clamp(1, it.ratingMax);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Wrap, not Row: ten stars beside the counter must fold under it on a
        // narrow card rather than overflow.
        Wrap(
          spacing: 2,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: NumberField(
                value: it.ratingMax,
                min: 3,
                max: 10,
                onChanged: (int v) => _edit(() => it.ratingMax = v),
              ),
            ),
            for (int i = 0; i < it.ratingMax; i++)
              // Filled up to the GOLDEN value, not the respondent's answer -
              // this editor never collects a response, only the key.
              Tooltip(
                message: 'Golden answer: ${i + 1} star${i == 0 ? '' : 's'}',
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => _edit(() => it.ratingGolden = i + 1),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      golden != null && i < golden
                          ? Icons.star
                          : Icons.star_border,
                      size: 18,
                      color: golden != null && i < golden
                          ? t.primary
                          : t.textMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // NO "CLEAR". It removed the golden answer, described as leaving the
        // item "answerable but not auto-scored" - exactly the state publishing
        // now refuses. Re-keying is a click on a different star, so nothing is
        // lost by dropping the unset path: a key can be changed, not taken away.
        Text(
          golden == null
              ? 'Tap a star to set the golden answer. Required - the item '
                    'cannot be published without one.'
              : 'Golden answer: $golden star${golden == 1 ? '' : 's'}. '
                    'Tap another star to change it.',
          style: context.type.tiny.copyWith(
            color: golden == null ? t.warnText : t.textMuted,
            height: 1.45,
          ),
        ),
      ],
    );
  }

  Widget _grid(FormDef? f, FormItem it) {
    Widget listEditor({
      required String label,
      required List<String> values,
      required String idPrefix,
      required String addLabel,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Eyebrow(label),
        const SizedBox(height: 6),
        for (int i = 0; i < values.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                SizedBox(width: 20, child: Mono('${i + 1}.')),
                Expanded(
                  child: FormTextInput(
                    // Position-keyed: grid labels are plain strings with no
                    // id of their own, and rows are only appended/removed at
                    // an index, so the position IS the identity here.
                    id: '$idPrefix-${it.id}-$i',
                    value: values[i],
                    hint: '$label ${i + 1}',
                    onChanged: (String v) => _edit(() => values[i] = v),
                  ),
                ),
                IconBtn(
                  Icons.close,
                  tooltip: 'Remove',
                  onPressed: values.length == 1
                      ? null
                      : () => _edit(() => values.removeAt(i)),
                ),
              ],
            ),
          ),
        Btn(
          addLabel,
          size: BtnSize.sm,
          icon: Icons.add,
          onPressed: () =>
              _edit(() => values.add('$label ${values.length + 1}')),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Cols2(
          left: listEditor(
            label: 'Row',
            values: it.rows,
            idPrefix: 'grow',
            addLabel: 'Add row',
          ),
          right: listEditor(
            label: 'Column',
            values: it.columns,
            idPrefix: 'gcol',
            addLabel: 'Add column',
          ),
        ),
        const SizedBox(height: 14),
        // NOT OPTIONAL, AND NOT PER-ROW OPTIONAL EITHER.
        //
        // This read "Answer key (optional)" and offered "No key" on every row.
        // A grid is one axis PER ROW on the server, and an axis with no keyed
        // option is not a component at all - it enters neither the numerator nor
        // the denominator - so an unkeyed row is a question the examiner drew,
        // the candidate answered, and nobody scored. A 4-row grid with 2 keys
        // silently marks out of 2. `_item_spec` already refuses these
        // ("rows without an answer key"), so the old label promised something
        // the server would not accept.
        const Eyebrow('Answer Key'),
        const SizedBox(height: 6),
        Text(
          // A CHECKBOX GRID ROW IS AN MSQ, so its key is a set, and the help
          // has to say what "right" means: the server marks a row correct only
          // on an EXACT set match (`response._dimension_marks`), so a
          // respondent who ticks one of two keyed columns scores that row 0.
          // An examiner who thinks the key means "any of these" would key
          // several columns and wonder why the cohort failed.
          it.kind == FormItemKind.checkboxGrid
              ? 'The correct column(s) for each row. Every row needs at least '
                    'one - a row with no key cannot be scored, so the form '
                    'will not publish until each is set. A row counts as right '
                    'only when the respondent ticks exactly the columns keyed '
                    'here. Respondents never see this.'
              : 'The correct column for each row. Every row needs one - a row '
                    'with no key cannot be scored, so the form will not '
                    'publish until each is set. Respondents never see this.',
          style: context.type.tiny.copyWith(height: 1.45),
        ),
        const SizedBox(height: 8),
        for (int r = 0; r < it.rows.length; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: it.kind == FormItemKind.checkboxGrid
                ? _gridKeyChecks(it, r)
                : _gridKeySelect(it, r),
          ),
      ],
    );
  }

  /// One row's key as per-column toggles - the checkbox grid.
  ///
  /// Deliberately the SAME shape the respondent sees (a row of columns to tick)
  /// and the same icon language as the options editor's key toggle above, so
  /// "what a perfect answer looks like" reads the same in both places. A
  /// dropdown could not express a two-column key at all, which is the defect
  /// this replaces.
  Widget _gridKeyChecks(FormItem it, int r) {
    final AppTokens t = context.tokens;
    final Set<String> keys = it.gridKey[r] ?? <String>{};
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 150,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              it.rows[r],
              style: context.type.small.copyWith(
                // Unkeyed rows are the ones that block publish, so they say so
                // before the examiner presses Publish and reads a refusal.
                color: keys.isEmpty ? t.warnText : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              for (final String c in it.columns)
                _gridKeyChip(it, r, c, on: keys.contains(c)),
              if (keys.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Not set',
                    style: context.type.tiny.copyWith(color: t.warnText),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _gridKeyChip(
    FormItem it,
    int r,
    String column, {
    required bool on,
  }) {
    final AppTokens t = context.tokens;
    return InkWell(
      onTap: () => _edit(() {
        final Set<String> keys = it.gridKey[r] ?? <String>{};
        if (on) {
          keys.remove(column);
        } else {
          keys.add(column);
        }
        // An empty set is removed rather than stored: `toJson` skips an empty
        // map, and `_intKeyedSets` drops empty entries, so keeping one would
        // round-trip to nothing and read as a key that exists.
        if (keys.isEmpty) {
          it.gridKey.remove(r);
        } else {
          it.gridKey[r] = keys;
        }
      }),
      borderRadius: Radii.buttonSm,
      child: Tooltip(
        message: on
            ? 'Part of the answer key - tap to unmark'
            : 'Tap to add to the answer key',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: Radii.buttonSm,
            border: Border.all(color: on ? t.successText : t.border),
            color: on ? t.successText.o(.08) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                on ? Icons.check_box : Icons.check_box_outline_blank,
                size: 15,
                color: on ? t.successText : t.textMuted,
              ),
              const SizedBox(width: 5),
              Text(
                column,
                style: context.type.tiny.copyWith(
                  color: on ? t.successText : t.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One row's key as a single-select - the multiple-choice grid.
  ///
  /// Unchanged behaviour: radio buttons can only submit one column, so a set of
  /// two could never be matched and publish refuses it
  /// (`studio_form._item_spec`). The key is stored as a one-element set so both
  /// grid kinds share one field and one wire shape.
  Widget _gridKeySelect(FormItem it, int r) {
    final Set<String> keys = it.gridKey[r] ?? <String>{};
    final String current = keys.length == 1 && it.columns.contains(keys.first)
        ? keys.first
        : '';
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            it.rows[r],
            style: context.type.small,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 190,
          child: SelectField<String>(
            value: current,
            // "Not set" NAMES the state the row is in without offering
            // it as a destination: it is listed only while the row is
            // unkeyed, and picking a real column is a one-way move -
            // the same shape as `_keyPicker` above.
            options: <(String, String)>[
              if (current.isEmpty) ('', 'Not set'),
              for (final String c in it.columns) (c, c),
            ],
            onChanged: (String v) => _edit(() {
              if (v.isNotEmpty) it.gridKey[r] = <String>{v};
            }),
          ),
        ),
      ],
    );
  }

  /// ONE MEDIA PREVIEW, for every slot in the designer.
  ///
  /// Three things it centralises, each of which was wrong in a different way in
  /// each of the three copies this replaces:
  ///
  ///   * WHAT KIND OF MEDIA THIS IS. Decided by [mediaKindOf], not by the
  ///     extension of the whole URL, so a YouTube link and
  ///     `clip.mp4?sig=abc` both reach a player instead of being handed to
  ///     `Image.network`, which mounts an element with nothing to decode and
  ///     draws a dead plate with no error.
  ///   * HOW AN IMAGE IS FETCHED. `WebHtmlElementStrategy.fallback` tries the
  ///     bytes first and then a plain `<img>`. A browser does not need CORS to
  ///     DISPLAY an image, only to READ it - so the byte-only default was what
  ///     made every ordinary hotlinked URL fail while a "Copy image address"
  ///     link from a CORS-open host worked. This is the whole reported bug.
  ///   * WHAT A FAILURE SAYS. "Could not load that image URL" is true and
  ///     useless. Naming the cause and carrying the fix is the difference
  ///     between a dead end and an instruction.
  ///
  /// [forceVideo] is for `videoBlock`, where the examiner has already declared
  /// the medium and a URL with no extension must not fall back to a still.
  Widget _mediaPlate(
    FormItem it, {
    required String url,
    required String slot,
    bool forceVideo = false,
  }) {
    final AppTokens t = context.tokens;
    final String u = url.trim();
    if (u.isEmpty) return const SizedBox.shrink();

    final MediaKind kind = forceVideo ? MediaKind.videoFile : mediaKindOf(u);
    if (kind != MediaKind.image) {
      // The real player, same component the respondent gets - a filename in a
      // Row told the author a URL was typed, not whether it actually plays.
      // `clipPlateFor` gives an audio URL the audio player and everything else
      // (including a `forceVideo` url with no extension) the video one. An
      // Audio block says so itself: a share link has no extension to read.
      return clipPlateFor(
        Asset(
          id: '${it.id}-$slot',
          label: it.title,
          url: u,
          slot: slot,
          kind: isAudioBlock(it) || it.kind == FormItemKind.transcription
              ? 'audio'
              : null,
        ),
        allowDownload: true,
      );
    }

    // Same frame as the respondent sees: 4:3, whole image contained, never
    // cropped - the designer judges the real stimulus.
    //
    // RESOLVED, not raw: an uploaded file's URL is server-relative
    // (`/api/v1/forms/media/...`), which resolves against the admin APP's own
    // origin if handed to Image.network as-is, not Odoo's - the same bug
    // `resolveMediaUrl` exists to fix everywhere else media renders.
    final String resolved = resolveMediaUrl(u);
    return ZoomableImage(
      url: resolved,
      child: ClipRRect(
        borderRadius: Radii.card,
        child: Container(
          color: t.bgMuted,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            // ELEMENT-FIRST FOR A FOREIGN HOST. `fallback` reaches the same
            // `<img>` only after an XHR has already failed; a designer plate
            // shows a pasted third-party URL more often than anything else in
            // the app, so it pays that wasted round trip on almost every
            // paste. Our own uploads stay on the byte path.
            child: isOurMediaOrigin(resolved)
                ? Image.network(
                    resolved,
                    // CORS-EXEMPT: reached only when
                    // `isOurMediaOrigin(resolved)` is true, so this is our own
                    // uploaded media on our own origin - no cross-origin
                    // question to answer. Every foreign host takes the
                    // `ImagePlate` branch below instead.
                    fit: BoxFit.contain,
                    errorBuilder:
                        (BuildContext c, Object e, StackTrace? st) =>
                            _mediaFailed(it, slot, u),
                  )
                : ImagePlate(
                    url: resolved,
                    onFailed: (BuildContext c) => _mediaFailed(it, slot, u),
                  ),
          ),
        ),
      ),
    );
  }

  /// The empty state for a picture that would not load, carrying the fix.
  ///
  /// Reached only when BOTH paths failed - the byte fetch and the `<img>`
  /// element - which narrows the cause to a host that refuses to serve the file
  /// to this page at all, or a URL that is not an image.
  ///
  /// TEXT, NOT A SECOND BUTTON. When the URL is importable the field above this
  /// plate is already showing "Copy into this app", and two identical buttons a
  /// few pixels apart is worse than one: it reads as two different actions.
  /// So this names the cause and points at the control that already exists.
  ///
  /// AND IT MUST NOT NAME A CONTROL THAT IS NOT THERE. A Drive link is imported
  /// automatically, so it carries no "Copy into this app" button to point at -
  /// sending the examiner to look for one is the same misleading dead end this
  /// text exists to prevent. While that import is in flight the plate is drawing
  /// the share PAGE, which cannot render and never will, so the honest thing to
  /// say is that the copy is under way.
  Widget _mediaFailed(FormItem it, String slot, String url) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.broken_image_outlined, size: 20, color: t.textMuted),
            const SizedBox(height: 8),
            Text(
              looksLikeWebPageUrl(url)
                  ? 'That is a web PAGE, not an image file - a page cannot be '
                      'displayed as a picture. Right-click the image itself, '
                      'copy its image address, and paste that.'
                  : driveFileId(url) != null &&
                          _importFailed[_slotKey(it, slot)] != true
                      // TRUE AGAIN, now that the import actually starts. This
                      // message was the symptom people reported - it says a
                      // copy is under way - but it was never the defect: the
                      // defect was that no copy had been scheduled for a link
                      // that arrived by import rather than by typing. See
                      // `_resolvePrefilledShareLinks`. Deliberately says
                      // nothing else and offers nothing: the manual control is
                      // a false affordance while an import is in flight, and
                      // two tests in `form_media_url_test.dart` pin that.
                      ? 'Copying that Drive file into this app…'
                      : isImportableMediaSource(url)
                          ? 'That host will not let this app show the image. '
                              'Use "Copy into this app" above.'
                          : 'That host will not let this app show the image, '
                              'or it is not an image file. Use Upload '
                              'instead.',
              textAlign: TextAlign.center,
              style: context.type.small.copyWith(color: t.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _media(FormDef? f, FormItem it, {required bool image}) {
    // Video and Audio are one wire kind; each picker offers only its own files.
    final bool audio = isAudioBlock(it);
    final String noun = image ? 'image' : (audio ? 'audio clip' : 'video');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _mediaUrlRow(
          f,
          it,
          slot: 'main',
          value: it.mediaUrl,
          hint: image
              ? 'Image URL (https://…)'
              : (audio ? 'Audio URL (https://…)' : 'Video URL (https://…)'),
          accept: image ? _imgAccept : (audio ? _audAccept : _vidAccept),
          apply: (String v) => it.mediaUrl = v,
        ),
        if (it.mediaUrl.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          // A `videoBlock` is a clip by declaration; an `imageBlock` still
          // routes by URL, because a pasted YouTube link in an image slot is a
          // clip whatever the slot is called.
          _mediaPlate(it, url: it.mediaUrl, slot: 'main', forceVideo: !image),
        ],
        const SizedBox(height: 14),
        if (it.options.isEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ghost(
              'No options: this $noun is shown as '
              'context only. Add an option to turn it into a question the '
              'respondent answers right here, instead of it riding along on '
              'whatever question follows it.',
            ),
          ),
          Row(
            children: <Widget>[
              Btn(
                'Add an option',
                tooltip:
                    'Turn this $noun into a question '
                    'with its own answer options.',
                size: BtnSize.sm,
                icon: Icons.add_task_outlined,
                onPressed: () => _edit(() {
                  it.options.add(formNewOption(0));
                }),
              ),
            ],
          ),
        ] else ...<Widget>[
          Row(
            children: <Widget>[
              Text('Allow multiple selections', style: context.type.small),
              const SizedBox(width: 8),
              Switcher(
                value: it.multiSelect,
                onChanged: (bool v) => _edit(() {
                  it.multiSelect = v;
                  _keepOneCorrect(it);
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _options(f, it),
        ],
      ],
    );
  }

  /// The annotation editor: the image, drawn on directly. A drag rubber-bands
  /// a numbered box; a tap selects one; the chip row below deletes them.
  /// Numbers are stable - deleting box 2 never renumbers box 3 - so answers
  /// collected against this form can always name the box they meant.
  Widget _annotation(FormDef? f, FormItem it) {
    final AppTokens t = context.tokens;
    final String url = it.mediaUrl.trim();
    final int? sel = _selMarker[it.id];
    final ImageProvider? provider = stimulusImageProvider(url);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _mediaUrlRow(
          f,
          it,
          slot: 'main',
          value: it.mediaUrl,
          hint: 'Image URL (https://…)',
          accept: _imgAccept,
          apply: (String v) => it.mediaUrl = v,
        ),
        const SizedBox(height: 10),
        // The count is the item's core setting, so it shows the moment the
        // kind is picked - hiding it until an image loads read as the
        // feature being missing.
        if (it.regions.isEmpty) ...<Widget>[
          Field(
            label: 'Annotations in the image',
            help: 'The picture already carries its numbered markers: '
                'respondents get one answer field per annotation.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: NumberField(
                value: it.annotationCount,
                min: 0,
                max: 99,
                onChanged: (int v) => _edit(() => it.annotationCount = v),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (url.isEmpty)
          _ghost(
            'Add the marked image above. Respondents will describe each '
            'numbered annotation in it, one text field per annotation.',
          )
        else if (provider == null)
          _ghost('Could not read that image URL')
        else ...<Widget>[
          // CLICK TO PLACE, not drag to draw. The examiner is marking WHERE a
          // defect is, and the grader only ever reads the point's NUMBER and its
          // golden answer - never its size - so asking them to rubber-band a box
          // demanded a judgement the question does not ask for. Dragging still
          // works for the case where an area genuinely is the point.
          Text(
            it.regions.isEmpty
                ? 'Click the image to place a numbered point. Each point gets '
                      'its own golden answer below, and respondents describe '
                      'one point each. Drag instead if you want to box an area.'
                : 'Click to place another point. Click a point to select it, '
                      'or remove it with the × on its chip below.',
            style: context.type.tiny.copyWith(height: 1.45),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: Radii.card,
            child: Container(
              color: t.bgMuted,
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: RegionOverlayImage(
                  provider: provider,
                  // A fresh list each build: the painter compares list
                  // IDENTITY to decide on repaint, and the designer mutates
                  // the item's list in place.
                  regions: List<LabelRegion>.of(it.regions),
                  activeNumber: sel,
                  onRegionTap: (int n) =>
                      setState(() => _selMarker[it.id] = n),
                  onRegionDrawn: (LabelRegion r) => _edit(() {
                    final int next = it.regions.isEmpty
                        ? 1
                        : it.regions
                                  .map((LabelRegion x) => x.number)
                                  .reduce((int a, int b) => a > b ? a : b) +
                              1;
                    it.regions.add(LabelRegion(
                      number: next,
                      x: r.x,
                      y: r.y,
                      w: r.w,
                      h: r.h,
                    ));
                    _selMarker[it.id] = next;
                  }),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (it.regions.isEmpty)
            _ghost(
              it.annotationCount > 0
                  ? 'Respondents will answer '
                        '${it.annotationCount} annotation'
                        '${it.annotationCount == 1 ? '' : 's'} '
                        '(fields numbered 1-${it.annotationCount}).'
                  : 'No points yet - click the image to place one, or set the '
                        'count above if the picture already carries its own '
                        'markers.',
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final LabelRegion r in it.regions)
                  _markerChip(
                    f,
                    it,
                    r,
                    selected: sel == r.number,
                  ),
              ],
            ),
          if (it.annotationNumbers.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            _goldenLabels(f, it),
          ],
        ],
      ],
    );
  }

  /// The per-marker GOLDEN answers - the harness's solutions.json shape
  /// ({"1": "canonical description", ...}), authored here by the examiner and
  /// later handed to the LLM judge. Same chip-driven layout the respondent
  /// gets, so the two sides read identically. Never shown to respondents.
  Widget _goldenLabels(FormDef? f, FormItem it) {
    final AppTokens t = context.tokens;
    final List<int> numbers = it.annotationNumbers;
    int sel = _goldenSel[it.id] ?? numbers.first;
    if (!numbers.contains(sel)) sel = numbers.first;
    final int keyed = numbers
        .where((int n) => (it.goldenLabels[n] ?? '').trim().isNotEmpty)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Eyebrow('Golden answers (for the LLM judge)'),
            const Spacer(),
            Text(
              '$keyed / ${numbers.length} keyed',
              style: context.type.tiny.copyWith(color: t.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'The canonical description of what is wrong at each marker. '
          'Workers never see these; the judge grades their answers against '
          'them.',
          style: context.type.tiny.copyWith(height: 1.45),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final int n in numbers)
              _goldenChip(
                n,
                selected: n == sel,
                keyed: (it.goldenLabels[n] ?? '').trim().isNotEmpty,
                onTap: () => setState(() => _goldenSel[it.id] = n),
              ),
          ],
        ),
        const SizedBox(height: 8),
        FormTextInput(
          id: 'golden-ann-${it.id}-$sel',
          value: it.goldenLabels[sel] ?? '',
          hint: 'Golden answer for annotation $sel…',
          maxLines: 2,
          onChanged: (String v) => _edit(() {
            if (v.trim().isEmpty) {
              it.goldenLabels.remove(sel);
            } else {
              it.goldenLabels[sel] = v;
            }
          }),
        ),
      ],
    );
  }

  Widget _goldenChip(
    int n, {
    required bool selected,
    required bool keyed,
    required VoidCallback onTap,
  }) {
    final AppTokens t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.buttonSm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? t.primary.o(.14) : t.bgApp,
          borderRadius: Radii.buttonSm,
          border: Border.all(color: selected ? t.primary.o(.65) : t.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              keyed ? Icons.circle : Icons.circle_outlined,
              size: 8,
              color: keyed
                  ? (selected ? t.primary : t.successText)
                  : t.textMuted,
            ),
            const SizedBox(width: 5),
            Text(
              '$n',
              style: context.type.monoSmall.copyWith(
                fontWeight: FontWeight.w700,
                color: selected ? t.primary : t.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _markerChip(
    FormDef? f,
    FormItem it,
    LabelRegion r, {
    required bool selected,
  }) {
    final AppTokens t = context.tokens;
    return InkWell(
      onTap: () => setState(
        () => _selMarker[it.id] = selected ? null : r.number,
      ),
      borderRadius: Radii.buttonSm,
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
        decoration: BoxDecoration(
          color: selected ? t.primary.o(.12) : t.bgApp,
          borderRadius: Radii.buttonSm,
          border: Border.all(color: selected ? t.primary.o(.6) : t.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Point ${r.number}',
              style: context.type.small.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? t.primary : t.textSecondary,
              ),
            ),
            const SizedBox(width: 2),
            IconBtn(
              Icons.close,
              tooltip: 'Remove point ${r.number}',
              onPressed: () => _edit(() {
                it.regions
                    .removeWhere((LabelRegion x) => x.number == r.number);
                if (_selMarker[it.id] == r.number) _selMarker[it.id] = null;
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// Two media URLs, previewed the way respondents will see them: A and B
  /// side by side. Accepts image or video URLs; a video shows as a labelled
  /// tile here and in the preview.
  static const String _imgAccept = '.png,.jpg,.jpeg,.webp,.gif';
  static const String _vidAccept = '.mp4,.webm,.mov';

  /// Offered to an Audio block only (see [isAudioBlock]): a Video block gets
  /// [_vidAccept], and the A/B and prompt-writing slots still compare image or
  /// video.
  static const String _audAccept = kFormAudioAccept;

  static String _contentTypeFor(String name) => formMediaContentType(name);

  /// The one-click "take ownership of this file" action.
  ///
  /// Extracted because several surfaces need the identical button: a share-page
  /// warning, the plain offer on an importable link that raised no warning, and
  /// the retry after an automatic import failed.
  ///
  /// [label] EXISTS BECAUSE THE SAME ACTION IS NOT THE SAME OFFER. On a link
  /// nothing has been tried on, "Copy into this app" describes it. After the
  /// app already tried and failed by itself, that wording claims the copy has
  /// not been attempted - so the retry says "Try again" instead, and the text
  /// beside it names the failure.
  Widget _importBtn(
    String value,
    String busyKey,
    void Function(String) apply, {
    String label = 'Copy into this app',
  }) {
    final bool busy = widget.store.isBusy(busyKey);
    return Btn(
      label,
      size: BtnSize.sm,
      icon: Icons.cloud_download_outlined,
      busy: busy,
      tooltip: 'Download it once and store it here, so the exam does not '
          'depend on the original link.',
      onPressed: busy
          ? null
          : () async {
              final String? copied = await widget.store.withBusy(
                busyKey,
                () => widget.store.importFormMedia(value.trim()),
              );
              if (copied != null && copied.isNotEmpty && mounted) {
                _edit(() => apply(copied));
              }
            },
    );
  }

  /// Make a pasted Google Drive share link work on its own, with no second
  /// click.
  ///
  /// THE PROBLEM. A `/file/d/<id>/view` link is the VIEWER PAGE - it answers
  /// `text/html`, so nothing can decode it and the plate draws empty. The
  /// examiner pasted the url Drive gave them, which is the reasonable thing to
  /// do.
  ///
  /// WHY THIS CANNOT BE A LINK REWRITE, measured in a real browser rather than
  /// with curl - the distinction that made an earlier attempt at this look
  /// correct and fail in practice:
  ///
  ///   drive.usercontent.google.com/download   subresource -> 403, NO CORS
  ///   `lh3.googleusercontent.com/d/<id>`       subresource -> 200 image/jpeg
  ///
  /// Drive serves a browser differently from a command-line client: `curl`
  /// receives 200 with `Access-Control-Allow-Origin: *`, so every check made
  /// that way says the link is usable, while Chrome receives 403 with no CORS
  /// header at all. So the download host cannot be probed AND cannot be handed
  /// to a `<video>` element - a clip rewritten to it would never have played for
  /// a candidate either. `lh3` is the only Drive host a browser can read, and it
  /// answers `image/jpeg` for a VIDEO file because it serves the poster frame,
  /// so it cannot tell the two media apart: trusting it publishes a clip as a
  /// still, which is exactly the defect that reached a candidate as a dead 0:00
  /// player.
  ///
  /// THE SERVER HAS NO SUCH LIMIT, so the work happens there. `/forms/media/
  /// import` fetches the bytes with its own client, sees the true `video/mp4`,
  /// stores the file in this app's media bucket and reports the content type
  /// back - which is also the only trustworthy source for the item's kind. The
  /// field ends up holding our own url, so the media no longer depends on a
  /// share link an owner can move or unshare mid-sitting.
  ///
  /// WHAT CHANGED FOR THE EXAMINER: nothing to do. The import route is the same
  /// one the "Copy into this app" button called; it now runs on paste, so the
  /// button is no longer the only way to reach it.
  ///
  /// FAILS CLOSED. No id, a server refusal, or a widget disposed mid-flight all
  /// leave the field exactly as typed, and the notice with its explicit button
  /// is still there to try again. A failed import toasts the server's own words,
  /// which distinguish "not shared" from "too large" from "not a media file".
  ///
  /// GUARDED AGAINST A STALE ANSWER. The round trip is slower than typing, so
  /// the url it was asked about is compared against what the item holds when it
  /// returns, and the answer is dropped unless they still agree. Without this an
  /// import for an abandoned url lands after a newer one and overwrites it.
  ///
  /// DEBOUNCED, because this is wired to `onChanged`. A paste arrives as one
  /// change, but every subsequent keystroke would start another import. One
  /// timer per slot, restarted on each change: only the url that stops changing
  /// is fetched.
  Future<void> _resolveShareLink(
    FormItem it,
    String typed,
    void Function(String) apply, {
    required String slot,
    bool prefill = false,
  }) async {
    final String url = typed.trim();
    final String key = _slotKey(it, slot);
    // Cancel the pending import for THIS slot: the url it was going to fetch is
    // no longer what the box holds.
    _probeDebounce.remove(key)?.cancel();
    // A NEW VALUE RETIRES THE OLD VERDICT. Whatever failed before was about a
    // url that is no longer in the box, and leaving the flag set would show a
    // retry for a link the examiner has already replaced.
    _importFailed.remove(key);
    if (driveFileId(url) == null) return;

    // ALREADY REFUSED, SO DO NOT ASK AGAIN. Re-opening the form must not re-run
    // a download the server has already turned down - but the examiner must
    // still be told, so the verdict is restored rather than forgotten and the
    // retry notice is on screen from the first frame. Only the AUTOMATIC path
    // is memoised: "Try again" is a human asking for precisely this retry.
    if (prefill && _autoImportRefused.contains(url)) {
      _importFailed[key] = true;
      return;
    }

    // THE WORK GOES INSIDE THE TIMER, and this is the whole bug fix.
    //
    // This used to park on `await settled.future`, where `settled` was a
    // Completer that the timer completed. CANCELLING A TIMER DOES NOT COMPLETE
    // ITS COMPLETER - so every cancellation stranded an `await` that could
    // never resume, and the import it was waiting to start simply never ran.
    // Nothing reported it, because nothing had failed: the coroutine was still
    // sitting there.
    //
    // Two things cancel: the next keystroke on the same slot (the ordinary
    // debounce, just above) and `dispose()`. A paste is ~400ms of debounce plus
    // a ~2.4s fetch, and this form saves automatically, so a rebuild landing in
    // that window orphaned the import and left the plate reading "Copying that
    // Drive file into this app..." for good. Re-pasting appeared to fix it only
    // because it started a fresh cycle that nothing interrupted.
    //
    // Inside the callback there is no coroutine to strand: a cancelled timer
    // means the work never starts, which is what cancelling is supposed to do.
    _probeDebounce[key] = Timer(const Duration(milliseconds: 400), () {
      unawaited(
        _importShareLink(it, url, apply, slot: slot, key: key, prefill: prefill),
      );
    });
  }

  /// The round trip [_resolveShareLink] schedules, once the field has settled.
  Future<void> _importShareLink(
    FormItem it,
    String url,
    void Function(String) apply, {
    required String slot,
    required String key,
    bool prefill = false,
  }) async {
    if (!mounted) return;

    // Re-read before spending a round trip: the debounce window is long enough
    // for the field to have moved on.
    if (_slotValue(it, slot).trim() != url) return;

    final ImportedMedia? got = await _queuedMediaImport<ImportedMedia>(() {
      // IT WAITED ITS TURN, SO ASK AGAIN. The card can be gone and the field
      // can have moved on while this sat in the queue, and neither is worth a
      // round trip. A null here is indistinguishable from a refusal, which is
      // why the verdict below is only recorded once the url is re-checked.
      if (!mounted || _slotValue(it, slot).trim() != url) {
        return Future<ImportedMedia?>.value();
      }
      return widget.store.withBusy(
        'import-$slot-${it.id}',
        () => widget.store.importFormMediaDetailed(url),
      );
    });
    if (!mounted) return;
    // THE GUARD. No verdict at all on a url that is no longer in the box -
    // neither the failure flag nor the rewrite belongs to a paste the examiner
    // has already replaced.
    if (_slotValue(it, slot).trim() != url) return;

    if (got == null || got.url.isEmpty) {
      // THE OFFER COMES BACK NOW, and only now. The store has already toasted
      // the server's own words; this puts the manual control back on screen so
      // the examiner has something to act on.
      if (prefill) _autoImportRefused.add(url);
      setState(() => _importFailed[key] = true);
      return;
    }

    _edit(() {
      // A Video or Audio block keeps the kind the examiner DECLARED; the
      // server still reads the imported file for itself. An older
      // `videoBlock` with nothing declared still takes the server's answer.
      final bool declared =
          it.kind == FormItemKind.transcription ||
          (it.kind == FormItemKind.videoBlock &&
              (it.mediaKind == 'video' || it.mediaKind == 'audio'));
      if (got.kind.isNotEmpty && !declared) it.mediaKind = got.kind;
      apply(got.url);
    });
    // ONE TOAST PER DELIBERATE PASTE, AND NONE FOR A PREFILL. `Toaster` stacks
    // rather than replaces, so a form that resolves twenty prefilled links on
    // open buried itself under twenty notices of its own good news. A paste is
    // one deliberate act and still gets its acknowledgement; a prefill's
    // acknowledgement is the picture appearing where the dead share page was.
    if (!prefill) {
      widget.store.toaster.ok(
        got.kind == 'video'
            ? 'Drive video linked'
            : isAudioBlock(it)
            ? 'Drive audio linked'
            : 'Drive image linked',
      );
    }
  }

  /// What [slot] currently holds on [it].
  ///
  /// The rewrite needs to re-read the field it is about to overwrite, and the
  /// `apply` closure it was handed only WRITES.
  ///
  /// THE SLOT TAGS ARE NOT A TIDY ENUM, and guessing them is how this went
  /// wrong once already. `_promptWriting` passes `'output'`; `_mediaPair` passes
  /// its own display label, `'Side B'`, because the same string is the Eyebrow
  /// above the field. A mapping that only knew `'output'` silently compared Side
  /// B's probe answer against Side A's url, so a rewrite on the second half of a
  /// comparison was always dropped. Matched case-insensitively on the second-slot
  /// shapes rather than listing every literal, and defaulting to the primary url.
  String _slotValue(FormItem it, String slot) =>
      _isSecondSlot(slot) ? it.mediaUrlB : it.mediaUrl;

  /// Whether [slot] names the SECOND media slot, under any of its spellings.
  static bool _isSecondSlot(String slot) {
    final String s = slot.trim().toLowerCase();
    return s == 'output' || s == 'b' || s == 'side b';
  }

  /// The per-slot key for [_probeDebounce] and [_importFailed].
  ///
  /// CANONICAL, BECAUSE A TAG IS A DISPLAY STRING AND NOT AN IDENTITY - the
  /// same mistake as [_slotValue]'s, one map along. `'<itemId>:<tag>'` put the
  /// writer and the reader of these maps in different namespaces: the prefill
  /// pass recorded its failure under `'<id>:a'` while `_mediaUrlRow` and
  /// `_mediaFailed` read `'<id>:main'`, `'<id>:output'` or `'<id>:Side B'`. So
  /// a refused automatic import was INVISIBLE - the plate went on reporting
  /// "Copying that Drive file into this app...", and neither "Try again" nor
  /// "Copy into this app" ever appeared - which is the very symptom the
  /// prefill pass was added to cure, still there on its commonest failure.
  ///
  /// Keyed by which slot it IS, so every caller lands on the same entry however
  /// it spells the tag. The tag itself still names the field and the toggle,
  /// which is what it is for.
  String _slotKey(FormItem it, String slot) =>
      '${it.id}:${_isSecondSlot(slot) ? 'b' : 'a'}';

  Widget _mediaUrlRow(
    FormDef? f,
    FormItem it, {
    required String slot,
    required String value,
    required String hint,
    required String accept,
    required void Function(String) apply,
  }) {
    final AppTokens t = context.tokens;
    final String modeKey = _slotKey(it, slot);
    final String busyKey = 'formmedia:$modeKey';
    final bool busy = widget.store.isBusy(busyKey);
    // Default to Upload mode once a file-proxy URL is in the field, else Link.
    // Built from kApiPrefix, not the literal: on a bundle pointed at another
    // backend prefix an uploaded file would not be recognised as one, and the
    // field would silently open in Link mode over its own proxy URL.
    final bool uploadMode = _uploadMode[modeKey] ??
        value.startsWith('$kApiPrefix/forms/media/');

    // WHETHER TO OFFER THE MANUAL COPY AT ALL.
    //
    // THE DEFECT THIS FIXES, reported as "it misleads the end user": a Drive
    // link is imported by this app the moment it is pasted, but the notice and
    // its "Copy into this app" button were gated purely on the url's SHAPE - so
    // for the length of the debounce and the round trip they rendered on top of
    // an import already in flight, then disappeared when it landed. An offer to
    // do something that is already being done, withdrawn before it can be
    // clicked, is worse than no offer: it makes a working flow look broken and
    // invites a second, duplicate copy of the same file.
    //
    // So a link this app imports ITSELF is not offered a manual copy - unless
    // the automatic attempt failed, which is the only case where the examiner's
    // decision actually adds something. Links the importer accepts but does NOT
    // auto-import (Dropbox, OneDrive, SharePoint, and Drive's own direct `/uc?`
    // form) keep the offer exactly as before, because nothing else is going to
    // fetch them.
    final bool autoImports = driveFileId(value) != null;
    final bool offerImport =
        isImportableMediaSource(value) && (!autoImports || _importFailed[modeKey] == true);

    Future<void> pick() async {
      final PickedFile? file = await FormItemEditor.pick(accept: accept);
      if (file == null || !mounted) return;
      final String? url = await widget.store.withBusy(
        busyKey,
        () => widget.store.uploadFormMedia(
          name: file.name,
          bytes: file.bytes,
          contentType: _contentTypeFor(file.name),
        ),
      );
      if (url != null && url.isNotEmpty && mounted) {
        _edit(() => apply(url));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The two-way toggle.
        Row(
          children: <Widget>[
            Btn(
              'Link',
              tooltip: 'Paste a URL to hosted media.',
              size: BtnSize.sm,
              icon: Icons.link,
              pressed: !uploadMode,
              onPressed: () => setState(() => _uploadMode[modeKey] = false),
            ),
            const SizedBox(width: 6),
            Btn(
              'Upload',
              tooltip: 'Upload a file into the form media store.',
              size: BtnSize.sm,
              icon: Icons.upload_file_outlined,
              pressed: uploadMode,
              onPressed: () => setState(() => _uploadMode[modeKey] = true),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!uploadMode) ...<Widget>[
          FormTextInput(
            id: 'media-$slot-${it.id}',
            value: value,
            hint: hint,
            onChanged: (String v) {
              _edit(() => apply(v));
              // Rewrite a Drive share link into something that renders, in the
              // background. Not awaited: typing must never block on a network
              // probe, and if the probe never answers the field simply keeps
              // what was pasted.
              unawaited(_resolveShareLink(it, v, apply, slot: slot));
            },
          ),
          // A SHARE PAGE IS NOT A FILE, and pasting one used to fail silently:
          // the plate rendered "Could not load that image URL", which says
          // what happened but never why, so the natural next move is to
          // re-paste the same link. Naming the mistake and the fix in one line
          // is the difference between a dead end and an instruction.
          //
          // THE BUTTON IS GATED ON WHAT THE SERVER CAN FETCH, not on whether a
          // warning fired. Those are different questions, and tying them
          // together hid the action from the link that needed it most often:
          // `drive.google.com/uc?export=view&id=...` is importable and raises
          // NO warning (it really does serve bytes), so it got no button - and
          // it is also the shape a browser refuses to render cross-origin, so
          // the one URL where copying is both possible and necessary offered
          // nothing at all.
          if (mediaShareLinkWarning(value) != null) ...<Widget>[
            const SizedBox(height: 6),
            Notice(
              tone: Tone.warn,
              text: mediaShareLinkWarning(value)!,
              actions: <Widget>[
                if (offerImport) _importBtn(value, busyKey, apply),
              ],
            ),
          ] else if (autoImports && _importFailed[modeKey] == true) ...<Widget>[
            // THE AUTOMATIC IMPORT FAILED. Named as a failure rather than
            // dressed up as an opportunity: the app tried, so "this app can
            // copy that file" would be a claim the examiner has already seen
            // contradicted. The store's toast carried the server's reason;
            // this is the durable control to act on it.
            const SizedBox(height: 6),
            Notice(
              tone: Tone.warn,
              text: 'Could not copy that Drive file in automatically. Check it '
                  'is shared with "Anyone with the link", then try again - or '
                  'use Upload.',
              actions: <Widget>[
                _importBtn(value, busyKey, apply, label: 'Try again'),
              ],
            ),
          ] else if (offerImport) ...<Widget>[
            // No warning, and nothing is importing it automatically, but it is
            // still a link this app can take ownership of. Offered, not
            // insisted on - the URL may well render as it is.
            const SizedBox(height: 6),
            Notice(
              tone: Tone.info,
              text: 'This app can copy that file into its own storage, so the '
                  'exam does not depend on the link staying shared.',
              actions: <Widget>[_importBtn(value, busyKey, apply)],
            ),
          ],
        ]        else
          Row(
            children: <Widget>[
              Btn(
                value.isEmpty ? 'Choose a file' : 'Replace file',
                size: BtnSize.sm,
                icon: Icons.attach_file,
                busy: busy,
                onPressed: busy ? null : pick,
              ),
              const SizedBox(width: 10),
              if (value.isNotEmpty)
                Flexible(
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.check_circle_outline,
                          size: 15, color: t.successText),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          'File attached',
                          style: context.type.small.copyWith(color: t.textMuted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Text(
                  'Uploads to the form media store.',
                  style: context.type.small.copyWith(color: t.textMuted),
                ),
            ],
          ),
      ],
    );
  }

  Widget _mediaPair(FormDef? f, FormItem it) {
    Widget half(String tag, String url, void Function(String) set) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Eyebrow(tag),
        const SizedBox(height: 6),
        _mediaUrlRow(
          f,
          it,
          slot: tag,
          value: url,
          hint: 'Image or video URL (https://…)',
          accept: '$_imgAccept,$_vidAccept',
          apply: set,
        ),
        if (url.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          // Whatever the medium: a pair may compare two clips, or a still
          // against a clip, and either side may be a hosted embed.
          _mediaPlate(it, url: url, slot: tag),
        ],
      ],
    );

    // EQUAL split, not Cols2 (which is 125:100 for a field+hint layout) -
    // two comparison sides must be the same width, or a fixed-ratio image
    // makes the wider side taller. Stacks on a narrow card.
    final Widget a = half('Side A', it.mediaUrl, (String v) => it.mediaUrl = v);
    final Widget b =
        half('Side B', it.mediaUrlB, (String v) => it.mediaUrlB = v);
    return LayoutBuilder(
      builder: (BuildContext c, BoxConstraints bc) => bc.maxWidth < 620
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[a, const SizedBox(height: 16), b],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: a),
                const SizedBox(width: 16),
                Expanded(child: b),
              ],
            ),
    );
  }

}

/// True when [url] looks like a web PAGE rather than a media file.
///
/// WHY THIS IS WORTH SAYING OUT LOUD. The bug reported as "media urls do not
/// work" was tested with `unsplash.com/photos/a-black-and-white-photo-...`,
/// which answers `content-type: text/html`. It is the photo's PAGE, not the
/// photo - so no image code could ever render it, and the plate correctly drew
/// its failure state. What was wrong was the message: "that host will not let
/// this app show the image" blames the host for the examiner having copied the
/// address bar instead of the picture, and the advice that follows is useless.
///
/// A HEURISTIC, AND ONLY USED TO PICK WORDING. It never blocks anything: the
/// url is still attempted, and if it turns out to serve bytes after all it
/// simply renders. So a false positive costs a slightly-off message and a false
/// negative costs the old vaguer one - neither breaks a form.
///
/// The test is deliberately narrow: a url whose path carries a real image or
/// video extension is a FILE however page-like the rest of it looks, and only
/// then do the known page shapes count.
bool looksLikeWebPageUrl(String url) {
  final String u = url.trim();
  if (u.isEmpty) return false;
  final Uri? uri = Uri.tryParse(u);
  if (uri == null) return false;

  final String path = uri.path.toLowerCase();
  const List<String> fileExts = <String>[
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.avif', '.bmp', '.svg',
    '.mp4', '.webm', '.mov',
  ];
  if (fileExts.any(path.endsWith)) return false;

  // Our own proxies and data URLs carry no extension and are not pages.
  if (u.startsWith('data:') || isOurMediaOrigin(u)) return false;
  // A Drive link is handled by the rewrite, not by this.
  if (driveFileId(u) != null) return false;
  // An importable share link gets its own, more specific advice.
  if (isImportableMediaSource(u)) return false;

  // Known page shapes: a photo-site permalink, or any path with no extension at
  // all on a host that is not ours. The latter is the common case - an address
  // bar copied from a gallery.
  const List<String> pageHosts = <String>[
    'unsplash.com',
    'pexels.com',
    'pixabay.com',
    'flickr.com',
    'shutterstock.com',
    'gettyimages.com',
    'istockphoto.com',
  ];
  final String host = (uri.host).toLowerCase();
  // A SUFFIX MATCH IS WRONG HERE, and a test caught it: `images.unsplash.com`
  // ends with `unsplash.com` but is the real image CDN, not the gallery. The
  // page lives on the bare host (or its `www.`), so only those two count -
  // every other subdomain is where the FILES are.
  if (pageHosts.any((String h) => host == h || host == 'www.$h')) {
    return true;
  }
  return false;
}

/// The share-link host families the server's importer will fetch from,
/// mirroring `_IMPORT_URL_PATTERNS` in `controllers/api/forms.py`.
///
/// Used ONLY to decide whether to offer the button. The server re-checks the
/// host before it fetches anything, and re-checks every redirect hop, because a
/// client-side test is a convenience and never a security boundary.
///
/// Scheme-tolerant on purpose where the server is not: an examiner who pasted
/// `http://` or bare `drive.google.com/...` should be offered the button and let
/// the server explain itself, rather than silently getting nothing.
final List<RegExp> _importablePatterns = <RegExp>[
  // Google Drive: the two share shapes and the direct-download form.
  RegExp(r'^(?:https?://)?(?:www\.)?drive\.google\.com/(?:file/d/|open\?|uc\?)',
      caseSensitive: false),
  // Dropbox: both the old `/s/` and current `/scl/` share shapes.
  RegExp(r'^(?:https?://)?(?:www\.)?dropbox\.com/(?:s|scl)/',
      caseSensitive: false),
  // OneDrive personal, and a SharePoint image or video share.
  RegExp(r'^(?:https?://)?1drv\.ms/', caseSensitive: false),
  RegExp(r'^(?:https?://)?onedrive\.live\.com/', caseSensitive: false),
  RegExp(r'^(?:https?://)?[\w-]+\.sharepoint\.com/.*:[iv]:',
      caseSensitive: false),
  // Jumpshare share pages; the server reads the file link out of the page.
  RegExp(r'^(?:https?://)?(?:www\.)?jumpshare\.com/(?:s|v|share)/',
      caseSensitive: false),
];

/// The audio extensions the media picker offers an Audio block - the server's
/// allow-list (mp3, wav, m4a, ogg, aac, flac).
const String kFormAudioAccept = '.mp3,.wav,.m4a,.ogg,.aac,.flac';

/// Whether [it] is an Audio block: a `videoBlock` declared `media_kind:
/// 'audio'`, or an older one with no declared kind whose attached file is
/// audio. Every other `videoBlock` is a Video block (the historic meaning).
bool isAudioBlock(FormItem it) =>
    it.kind == FormItemKind.videoBlock &&
    (it.mediaKind == 'audio' ||
        (it.mediaKind != 'video' &&
            mediaKindOf(it.mediaUrl) == MediaKind.audio));

/// What the designer calls [it]: Video or Audio for a `videoBlock`, read off
/// the item, else its kind's label.
String formItemLabel(FormItem it) => isAudioBlock(it) ? 'Audio' : it.kind.label;

/// The MIME type to upload [name] as, read off its extension. Top level (not a
/// private static) so a test can pin it: the presigned policy is signed for
/// exactly this type, and a wrong one is refused by S3 with a bare 403.
String formMediaContentType(String name) {
  final String n = name.toLowerCase();
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.webp')) return 'image/webp';
  if (n.endsWith('.gif')) return 'image/gif';
  if (n.endsWith('.mp4')) return 'video/mp4';
  if (n.endsWith('.webm')) return 'video/webm';
  if (n.endsWith('.mov')) return 'video/quicktime';
  if (n.endsWith('.mp3')) return 'audio/mpeg';
  if (n.endsWith('.wav')) return 'audio/wav';
  if (n.endsWith('.m4a')) return 'audio/mp4';
  if (n.endsWith('.ogg')) return 'audio/ogg';
  if (n.endsWith('.aac')) return 'audio/aac';
  if (n.endsWith('.flac')) return 'audio/flac';
  return 'application/octet-stream';
}

/// The Google Drive file id in [url], or null when it is not a Drive file link.
///
/// Mirrors `_drive_file_id` in `controllers/api/forms.py` - the same three share
/// shapes, the same 10-character minimum on the id so a truncated paste is
/// refused rather than rewritten into a 404.
String? driveFileId(String url) {
  final String u = url.trim();
  if (u.isEmpty) return null;
  for (final RegExp p in _driveIdPatterns) {
    final RegExpMatch? m = p.firstMatch(u);
    if (m != null) return m.group(1);
  }
  return null;
}

final List<RegExp> _driveIdPatterns = <RegExp>[
  // https://drive.google.com/file/d/<id>/view?usp=sharing
  RegExp(r'^(?:https?://)?(?:www\.)?drive\.google\.com/file/d/([\w-]{10,})',
      caseSensitive: false),
  // https://drive.google.com/open?id=<id>  and  /uc?export=view&id=<id>
  RegExp(
      r'^(?:https?://)?(?:www\.)?drive\.google\.com/(?:open|uc)\?'
      r'(?:[^#]*&)?id=([\w-]{10,})',
      caseSensitive: false),
];

/// True when the server can copy [url] into this app's own media storage.
///
/// WHY THIS IS NOT `mediaShareLinkWarning != null`, which is what used to gate
/// the button. The two questions are different, and conflating them hid the
/// action from the URL that needs it least dramatically but most often:
/// `drive.google.com/uc?export=view&id=...` is importable AND raises no warning
/// (it does serve real bytes), so it got no button at all. Meanwhile a warning
/// can fire for a host the importer will not touch, where the only honest
/// advice is Upload.
bool isImportableMediaSource(String url) {
  final String u = url.trim();
  if (u.isEmpty) return false;
  return _importablePatterns.any((RegExp p) => p.hasMatch(u));
}

/// The warning for a URL that is a SHARE PAGE rather than a media file, or
/// null when the URL looks usable.
///
/// WHY THIS EXISTS. A Google Drive `/file/d/<id>/view` link answers
/// `content-type: text/html` - it is the viewer page, not the picture. Handed
/// to `Image.network` it decodes nothing, so the plate rendered "Could not
/// load that image URL": true, but it never said WHY, and the obvious next
/// move is to paste the same link again. The same trap exists for Dropbox's
/// `?dl=0` and OneDrive's share URLs.
///
/// COPYING IS THE ANSWER WE POINT AT, not a rewritten "direct" URL. A share
/// link is the wrong dependency for an exam whatever its shape: the owner can
/// move or unshare the file mid-sitting, the host rate-limits a cohort all
/// loading the same image, and a link that works for candidates is public to
/// anyone who has it. The form media store is this app's own, and its routes
/// are token-scoped.
///
/// Deliberately a WARNING and not a refusal. Some of these hosts do serve a
/// direct URL that works, and an examiner who knows their link is fine should
/// not be blocked by a heuristic.
String? mediaShareLinkWarning(String url) {
  final String u = url.trim().toLowerCase();
  if (u.isEmpty) return null;

  // NO DRIVE BRANCH ANY MORE. A Drive file link is now REWRITTEN on paste into
  // a url that displays (`_resolveShareLink`), so by the time a warning would
  // be drawn the field no longer holds the share page. Warning about a link the
  // app has already fixed would be noise; if the rewrite failed closed, the
  // plate's own failure text carries the advice instead.
  if (u.contains('drive.google.com/') && driveFileId(u) == null) {
    // A Drive url we cannot extract an id from - a folder, or a truncated
    // paste. Naming the shape is more use than a generic refusal.
    return 'That is a Google Drive link, but not to a single file - open the '
        'file itself and copy its link, or use Upload.';
  }
  // DOCS IS NOT DRIVE, and the advice differs. A `docs.google.com` link is a
  // Doc, Sheet or Slide - never a stored image file - so the importer refuses
  // it (`_import_fetch_url` matches Drive's `/file/d/`, `/open?` and `/uc?`
  // only). Naming Drive here sent the examiner to "Copy into this app", which
  // then rejected the link: worse than no advice, because it looks like the
  // button is broken.
  if (u.contains('docs.google.com/')) {
    return 'That is a Google Docs link, not a media file - it cannot be '
        'copied in. Export the image and use Upload.';
  }
  if (u.contains('dropbox.com/') && !u.contains('dl.dropboxusercontent.com')) {
    return 'That is a Dropbox share page, not a media file. Copy it into this '
        'app, or use Upload.';
  }
  if (u.contains('1drv.ms/') || u.contains('onedrive.live.com/')) {
    return 'That is a OneDrive share page, not a media file. Copy it into this '
        'app, or use Upload.';
  }
  if (u.contains('sharepoint.com/') && u.contains(':i:')) {
    return 'That is a SharePoint share page, not a media file. Copy it into '
        'this app, or use Upload.';
  }
  return null;
}
