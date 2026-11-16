// The form designer - Form Studio's editing surface.
//
// One form, two tabs: DESIGN (sections and items, edited in place) and
// PREVIEW (the respondent view, rendered by `form_preview.dart` from the same
// object, so the preview can never drift from what was designed).
//
// EDITING MODEL: the screen mutates the store's FormDef directly and calls
// setState. Text fields are TextFormFields keyed by record id - Flutter keeps
// their edit state across rebuilds, so repainting on every keystroke keeps
// the header counts live without costing any field its caret.
import 'package:flutter/material.dart';

import '../../domain/form_models.dart';
import '../../nav.dart';
import '../../state/app_store.dart';
import '../../theme.dart';
import '../../domain/enums.dart';
import '../../widgets/editable_title.dart';
import '../../widgets/buttons.dart';
import '../../widgets/controls.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
import 'form_item_editor.dart';
import 'form_preview.dart';

class FormDesignerScreen extends StatefulWidget {
  final AppStore store;
  final String formId;
  final String? tab;

  const FormDesignerScreen({
    super.key,
    required this.store,
    required this.formId,
    this.tab,
  });

  @override
  State<FormDesignerScreen> createState() => _FormDesignerScreenState();
}

class _FormDesignerScreenState extends State<FormDesignerScreen> {
  late String _tab = widget.tab == 'preview' ? 'preview' : 'design';

  // Back or Forward between Design and Preview: the route moved and this State
  // stayed, so the tab follows the route.
  @override
  void didUpdateWidget(FormDesignerScreen old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) {
      _tab = widget.tab == 'preview' ? 'preview' : 'design';
    }
  }

  /// Open tab [k], as a history entry: the address bar and Back follow it.
  void _showTab(String k) {
    setState(() => _tab = k);
    AssessmentNavScope.maybeRead(
      context,
    )?.go(FormDesigner(widget.formId, tab: k));
  }

  /// Sections the creator has collapsed (by id). View state only.
  final Set<String> _collapsed = <String>{};

  /// A deep copy of a section with FRESH ids on the section, its items and
  /// their options - so the duplicate is fully independent of the original.
  FormSection _remintSection(FormSection s) {
    final Map<String, dynamic> j = s.toJson();
    j['id'] = formNewId('sec');
    if (j['items'] is List) {
      j['items'] = (j['items'] as List).map((Object? m) {
        final Map<String, dynamic> mm = Map<String, dynamic>.from(
          m as Map<dynamic, dynamic>,
        );
        mm['id'] = formNewId('item');
        if (mm['options'] is List) {
          mm['options'] = (mm['options'] as List).map((Object? o) {
            final Map<String, dynamic> oo = Map<String, dynamic>.from(
              o as Map<dynamic, dynamic>,
            );
            oo['id'] = formNewId('opt');
            return oo;
          }).toList();
        }
        return mm;
      }).toList();
    }
    return FormSection.fromJson(j);
  }

  void _duplicateSection(FormDef f, int si) {
    _edit(f, () => f.sections.insert(si + 1, _remintSection(f.sections[si])));
    widget.store.toaster.ok('Section duplicated');
  }

  FormDef? get _form => widget.store.formById(widget.formId);

  /// A publish call in flight - the button disables so a double tap cannot
  /// mint two assessments from one form.
  bool _sending = false;

  /// Send the form to candidates: confirm, publish, surface the server's
  /// conversion notes, then land on the new assessment's Assign tab - the
  /// same doorstep `new_assessment_screen` delivers to.
  Future<void> _publish(FormDef f) async {
    final AppStore s = widget.store;
    final bool? yes = await showSheet<bool>(
      context,
      title: 'Send this form to candidates?',
      sub: 'Costs no LLM calls.',
      body: Text(
        // `displayTitle`, because this sentence is about what the OPERATOR is
        // about to go looking for: publish names the assessment and the
        // question pool from the internal name (`studio_form.display_title`),
        // so quoting the respondent heading here would name the form one thing
        // and hand them another on the next screen.
        '"${f.displayTitle}" becomes '
        '${f.questionCount} real exam question'
        '${f.questionCount == 1 ? '' : 's'} plus a draft assessment. '
        'You assign candidates and launch it next - delivery, proctoring '
        'and scoring work exactly as for a generated assessment.',
        style: context.type.body,
      ),
      actions: <Widget>[
        Btn('Cancel', onPressed: () => Navigator.of(context).pop(false)),
        // "CONFIRM PUBLISH", NOT "SEND TO CANDIDATES". This button contradicted
        // its own tooltip: it said it would send the form to candidates, and the
        // tooltip immediately below said nothing reaches them until you launch.
        // Publishing materialises bank questions and a DRAFT assessment;
        // assigning a roster and launching are two later, separate steps, and an
        // examiner who read the button literally had every reason to think a
        // half-finished form had just gone out to a cohort.
        Btn.primary(
          'Confirm Publish',
          tooltip:
              'Creates the questions and a draft assessment. '
              'Nothing reaches candidates until you launch it.',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (yes != true || !mounted) return;

    setState(() => _sending = true);
    final (String, List<String>)? res = await s.publishForm(f.id);
    if (!mounted) return;
    setState(() => _sending = false);
    if (res == null) {
      // A REFUSAL STAYS ON SCREEN UNTIL IT IS READ. The server names one item
      // per line and a form can fail on a dozen at once; a toast gave the
      // examiner 3200 ms, could not be clicked, and could not be held open - so
      // the way to keep the list was to photograph the screen. This is the same
      // sheet the succeeded-with-notes path already uses, for the same reason:
      // it is a work list, not a notification.
      if (s.publishProblems.isNotEmpty) {
        await showSheet<void>(
          context,
          title: 'Not ready to publish',
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Fix these, then publish again. Nothing has been created '
                  'and the form is unchanged.',
                  style: context.type.bodySecondary,
                ),
              ),
              for (final String p in s.publishProblems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('- $p', style: context.type.body),
                ),
            ],
          ),
          actions: <Widget>[
            Btn('Close', onPressed: () => Navigator.of(context).pop()),
          ],
        );
      }
      return;
    }
    final (String asmId, List<String> notes) = res;

    if (notes.isNotEmpty) {
      // The server converted the form but had to adapt some items; the
      // examiner sees exactly what changed before meeting the assessment.
      await showSheet<void>(
        context,
        // "Published", not "Sent": nothing has reached a candidate at this
        // point, and saying otherwise is the same misstatement the confirm
        // button was making.
        title: 'Published, with notes',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String n in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('- $n', style: context.type.body),
              ),
          ],
        ),
        actions: <Widget>[
          Btn('Close', onPressed: () => Navigator.of(context).pop()),
        ],
      );
      if (!mounted) return;
    }
    context.nav.assessment(asmId, tab: 'assign');
  }

  /// Rename the FORM - the name beside the pencil, which is the form's name
  /// everywhere an operator meets it.
  ///
  /// THIS WRITES `internalName`, NOT `title`, and the distinction is the whole
  /// requirement. There are two names and they are independent:
  ///
  ///   * the FORM NAME (this one, `internalName`) is the operators' label. It
  ///     is what Form Studio lists, what the breadcrumb reads, and what the
  ///     assessment and question pool are named on publish. `displayTitle`
  ///     resolves to it whenever it is set.
  ///   * the TITLE (`title`, edited in Settings) is candidate-facing copy - the
  ///     heading a respondent reads at the top of the form.
  ///
  /// NEITHER FOLLOWS THE OTHER. An earlier version auto-populated one from the
  /// other, which meant renaming the thing in front of you silently rewrote
  /// copy a candidate would read. They are now exactly as independent as the
  /// flag and the remark are on an attempt: two fields, two meanings, two
  /// edits.
  void _renameForm(FormDef f, String next) {
    final String name = next.trim();
    if (name.isEmpty || name == f.displayTitle) return;
    _edit(f, () => f.internalName = name);
  }

  /// Every edit: mutate, repaint, and hand the form to the store, which
  /// repaints other listeners and schedules the debounced save.
  void _edit(FormDef f, VoidCallback body) {
    setState(body);
    widget.store.persistForm(f);
  }

  @override
  Widget build(BuildContext context) {
    final FormDef? f = _form;
    if (f == null) {
      return PageBody(
        children: <Widget>[
          EmptyState(
            icon: Icons.dynamic_form_outlined,
            title: 'Form not found',
            body: 'It may have been deleted in this session.',
            action: Btn.primary(
              'Back to Form Studio',
              onPressed: () => context.nav.reset(const FormStudio()),
            ),
          ),
        ],
      );
    }

    // The designer is a capped column ANCHORED LEFT, like every other admin
    // screen: it starts where the sidebar ends instead of floating mid-window
    // with a dead gutter on both sides. The preview alone is centred at form
    // width, because that column IS the artefact being previewed.
    //
    // Panels carry no outer margin of their own, so the 16px between blocks
    // is laid explicitly here - without it the tab strip and the first panel
    // touch.
    // The inner SizedBox matters: without it a shrink-wrapping child (the
    // tab strip, mainly) takes only its natural width and its bottom hairline
    // stops mid-page instead of ruling the whole column.
    Widget capped(Widget w) => Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: SizedBox(width: double.infinity, child: w),
      ),
    );

    // PINNED HEADER over a scrolling body. The section host hands this route
    // the full viewport (no shared scroll view), so the crumbs, the title row
    // with "Add section" and the Design/Preview tabs stay put while a long
    // form scrolls beneath them - a creator at section 30 adds section 31
    // without a trip back to the top. The paddings mirror the host's shared
    // scroll view so this screen sits identically to every other.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
          child: PageBody(
            children: <Widget>[
              capped(
                Crumbs(<Crumb>[
                  Crumb(
                    'Form Studio',
                    () => context.nav.reset(const FormStudio()),
                  ),
                  // The crumb, the head below and the Form Studio row it came
                  // from are one trail, so all three read `displayTitle`.
                  Crumb(f.displayTitle),
                ]),
              ),
              // The pinned bar follows the tab. Design shows the editing
              // chrome; Preview drops it (Add section mid-preview is noise)
              // and reads as the SOP itself: the form's own title with its
              // own description, whatever this SOP says about itself.
              capped(
                _tab == 'preview'
                    ? PageHead(
                        // STILL `displayTitle`, on the Preview tab too: this
                        // pinned bar is the designer's own chrome, not part of
                        // the previewed form. The respondent heading is
                        // rendered by `FormPreview` inside the scroll area
                        // below, from `title`, which is where an examiner
                        // checks what a candidate will read.
                        f.displayTitle,
                        sub: f.description.trim().isNotEmpty
                            ? f.description.trim()
                            : 'Respondent view - try the form as a '
                                  'respondent will see it.',
                      )
                    : PageHead(
                        f.displayTitle,
                        // RENAMEABLE IN PLACE, like an assessment's name one
                        // screen over. A form was created with a default title
                        // and there was no way to change it from the designer
                        // at all - the operator's only option was to delete it
                        // and start again, which loses the sections they had
                        // just authored.
                        //
                        // Writes `title`, not `internalName`: `title` is what a
                        // CANDIDATE reads at the top of the form, so it is the
                        // one an author means when they rename the thing they
                        // are looking at. `displayTitle` falls back to it when
                        // no internal name is set, so the head, the crumb and
                        // the Form Studio row all follow in one edit.
                        //
                        // Through `_edit`, so it takes the same debounced save
                        // path as every other change on this screen rather than
                        // inventing a second write.
                        titleChild: EditableTitle(
                          // The FORM's name, which is `displayTitle` - the
                          // internal name when one is set and the title as the
                          // fallback until then. Committing always writes the
                          // internal name, so the two stop tracking the moment
                          // an operator renames the form.
                          value: f.displayTitle,
                          enabled: widget.store.can(Capability.authoring),
                          onCommit: (String next) => _renameForm(f, next),
                        ),
                        sub: widget.store.source == DataSource.seed
                            ? 'Draft - kept in this session (offline '
                                  'preview).'
                            : 'Every change saves automatically. Publish turns '
                                  'the form into a draft assessment on the '
                                  'normal exam pipeline.',
                        actions: <Widget>[
                          TagChip(
                            '${f.questionCount} question'
                            '${f.questionCount == 1 ? '' : 's'}'
                            ' · ${f.sections.length} section'
                            '${f.sections.length == 1 ? '' : 's'}',
                          ),
                          Btn(
                            'Add Section',
                            icon: Icons.playlist_add_outlined,
                            onPressed: () => _edit(
                              f,
                              () => f.sections.add(formNewSection()),
                            ),
                          ),
                          // "PUBLISH", not "Send to candidates". The button does
                          // not send anything to anybody: it turns the form into
                          // real bank questions plus a DRAFT assessment, and a
                          // separate launch step is what reaches candidates. The
                          // old label promised the last step while performing the
                          // first, which is why the tooltip had to spend two
                          // lines walking it back.
                          Btn.primary(
                            _sending ? 'Publishing...' : 'Publish',
                            icon: Icons.publish_outlined,
                            tooltip:
                                'Creates real exam questions from this '
                                'form plus a draft assessment - you assign '
                                'candidates and launch next. Costs no LLM '
                                'calls; nothing reaches candidates until '
                                'you launch.',
                            onPressed: _sending ? null : () => _publish(f),
                          ),
                        ],
                      ),
              ),
              capped(
                TabStrip(
                  active: _tab,
                  onChanged: _showTab,
                  tabs: const <TabDef>[
                    TabDef('design', 'Design'),
                    TabDef('preview', 'Preview'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 48),
            child: PageBody(
              children: <Widget>[
                if (_tab == 'preview')
                  Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: FormPreview(form: f, showKeys: true),
                    ),
                  )
                else ...<Widget>[
                  capped(_header(f)),
                  const SizedBox(height: 16),
                  // Sections drag-reorder by their handle. shrinkWrap + no
                  // physics so it lives inside this screen's scroll view.
                  capped(
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      itemCount: f.sections.length,
                      onReorderItem: (int oldI, int newI) => _edit(f, () {
                        f.sections.insert(newI, f.sections.removeAt(oldI));
                      }),
                      itemBuilder: (BuildContext ctx, int i) => Padding(
                        key: ValueKey<String>('sec-${f.sections[i].id}'),
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _section(f, i),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Design tab ───────────────────────────────────────────────────────────

  Widget _header(FormDef f) => Panel(
    title: 'Form Header',
    // The panel is no longer purely respondent-facing: "Internal name" below
    // is the one field here candidates never see, so the note says which is
    // which rather than promising all three are read by respondents.
    note:
        'What respondents read before the first question - plus the name '
        'operators see in lists.',
    headActions: <Widget>[
      // Form-level settings live behind the gear so the header stays about
      // what respondents READ; the shuffle (and anything form-wide added
      // later) opens in a sheet rather than crowding the panel.
      IconButton(
        onPressed: () => _openFormSettings(f),
        iconSize: 18,
        tooltip: 'Form Settings',
        icon: Icon(Icons.settings_outlined, color: context.tokens.textMuted),
      ),
    ],
    child: Stack16(<Widget>[
      Field(
        label: 'Title',
        help: 'The heading respondents read above the first question.',
        child: FormTextInput(
          id: 'title-${f.id}',
          value: f.title,
          hint: 'Untitled form',
          onChanged: (String v) => _edit(f, () => f.title = v),
        ),
      ),
      // NO "INTERNAL NAME" FIELD HERE, deliberately.
      //
      // It still EXISTS on the model and is still what Form Studio, the
      // published assessment and the question pool are named by - but it is
      // edited in exactly one place now, the form's name beside the pencil at
      // the top of this screen. Two inputs writing one value is how an operator
      // ends up with a form whose name in the list disagrees with the name on
      // the screen they renamed it from, and there is nothing in the second
      // field that the first cannot say.
      //
      // The TITLE above stays: it is candidate-facing copy and a genuinely
      // different sentence from the operators' label.
      Field(
        label: 'Description',
        child: FormTextInput(
          id: 'desc-${f.id}',
          value: f.description,
          hint: 'Why this form exists, and what happens with the answers',
          maxLines: 2,
          onChanged: (String v) => _edit(f, () => f.description = v),
        ),
      ),
    ]),
  );

  /// Form-WIDE settings, opened from the gear in the Form Header. A sheet
  /// rather than an inline block: it keeps the header about respondent-facing
  /// copy and gives form-level switches (today just the question shuffle) a
  /// home of their own. Rebuilt via StatefulBuilder so the switch flips live
  /// inside the sheet while the change is written straight through to the form.
  Future<void> _openFormSettings(FormDef f) => showSheet<void>(
    context,
    title: 'Form Settings',
    sub: 'Applies to the whole form.',
    body: StatefulBuilder(
      builder: (BuildContext ctx, void Function(void Function()) setSheet) =>
          SwitchRow(
            name: 'Shuffle question order',
            hint:
                'Each candidate gets the questions in a random order. '
                'Question numbers still count 1, 2, 3… in the order they see.',
            value: f.shuffleQuestions,
            last: true,
            onChanged: (bool v) {
              _edit(f, () => f.shuffleQuestions = v);
              setSheet(() {});
            },
          ),
    ),
    actions: <Widget>[
      Btn('Done', onPressed: () => Navigator.of(context).pop()),
    ],
  );

  /// What a collapsed section shows in place of its body: a one-line count,
  /// so a long form stays scannable.
  Widget _collapsedSummary(FormSection sec, int qs) {
    final AppTokens t = context.tokens;
    return Row(
      children: <Widget>[
        Icon(Icons.unfold_more, size: 15, color: t.textMuted),
        const SizedBox(width: 8),
        Text(
          sec.items.isEmpty
              ? 'Empty section'
              : '${sec.items.length} item${sec.items.length == 1 ? '' : 's'}'
                    ' · $qs question${qs == 1 ? '' : 's'} · collapsed',
          style: context.type.small.copyWith(color: t.textMuted),
        ),
      ],
    );
  }

  Widget _section(FormDef f, int si) {
    final FormSection sec = f.sections[si];
    final int n = f.sections.length;
    final bool collapsed = _collapsed.contains(sec.id);
    final int qs = sec.items.where((FormItem i) => i.isAnswerable).length;

    return Panel(
      title:
          'Section ${si + 1} of $n'
          '${sec.title.isEmpty ? '' : ' · ${sec.title}'}',
      headActions: <Widget>[
        // Collapse/expand.
        IconBtn(
          collapsed ? Icons.expand_more : Icons.expand_less,
          tooltip: collapsed ? 'Expand section' : 'Collapse section',
          onPressed: () => setState(
            () =>
                collapsed ? _collapsed.remove(sec.id) : _collapsed.add(sec.id),
          ),
        ),
        // Drag to reorder (only meaningful with >1 section).
        if (n > 1)
          ReorderableDragStartListener(
            index: si,
            child: IconBtn(
              Icons.drag_indicator,
              tooltip: 'Drag to reorder section',
              onPressed: () {},
            ),
          ),
        IconBtn(
          Icons.copy_outlined,
          tooltip: 'Duplicate section',
          onPressed: () => _duplicateSection(f, si),
        ),
        if (n > 1)
          IconBtn(
            Icons.delete_outline,
            tooltip: 'Delete section and its items',
            onPressed: () => _confirmDeleteSection(f, si),
          ),
      ],
      child: collapsed
          ? _collapsedSummary(sec, qs)
          : Stack16(<Widget>[
              Field(
                label: 'Section title',
                child: FormTextInput(
                  id: 'sec-title-${sec.id}',
                  value: sec.title,
                  hint: n > 1
                      ? 'Section ${si + 1}'
                      : 'Optional on a one-page form',
                  onChanged: (String v) => _edit(f, () => sec.title = v),
                ),
              ),
              Field(
                label: 'Section description',
                child: FormTextInput(
                  id: 'sec-desc-${sec.id}',
                  value: sec.description,
                  hint: 'Optional',
                  onChanged: (String v) => _edit(f, () => sec.description = v),
                ),
              ),
              if (sec.items.isNotEmpty)
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: sec.items.length,
                  onReorderItem: (int oldI, int newI) => _edit(f, () {
                    sec.items.insert(newI, sec.items.removeAt(oldI));
                  }),
                  itemBuilder: (BuildContext ctx, int ii) => Padding(
                    key: ValueKey<String>('item-${sec.items[ii].id}'),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: FormItemEditor(
                      store: widget.store,
                      item: sec.items[ii],
                      index: ii,
                      form: f,
                      onEdit: (VoidCallback mutate) => _edit(f, mutate),
                      onDuplicate: () => _edit(f, () {
                        sec.items.insert(
                          ii + 1,
                          FormItem.fromJson(sec.items[ii].toJson())._reminted(),
                        );
                      }),
                      onDelete: () => _edit(f, () => sec.items.removeAt(ii)),
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  Btn(
                    'Add Question',
                    size: BtnSize.sm,
                    icon: Icons.add,
                    onPressed: () => _edit(
                      f,
                      () => sec.items.add(
                        formNewItem(FormItemKind.multipleChoice),
                      ),
                    ),
                  ),
                  Btn(
                    'Title and Description',
                    tooltip:
                        'Insert a heading with body text - display only, not a question.',
                    size: BtnSize.sm,
                    icon: Icons.text_fields_outlined,
                    onPressed: () => _edit(
                      f,
                      () => sec.items.add(formNewItem(FormItemKind.textBlock)),
                    ),
                  ),
                  Btn(
                    'Image',
                    tooltip: 'Insert a display image block.',
                    size: BtnSize.sm,
                    icon: Icons.image_outlined,
                    onPressed: () => _edit(
                      f,
                      () => sec.items.add(formNewItem(FormItemKind.imageBlock)),
                    ),
                  ),
                  // TWO BUTTONS, ONE WIRE KIND. Both insert a `videoBlock`; the
                  // preset `media_kind` is what makes one of them Audio.
                  Btn(
                    'Video',
                    tooltip: 'Insert a display video block.',
                    size: BtnSize.sm,
                    icon: Icons.smart_display_outlined,
                    onPressed: () => _edit(
                      f,
                      () => sec.items.add(
                        formNewItem(FormItemKind.videoBlock)
                          ..mediaKind = 'video',
                      ),
                    ),
                  ),
                  Btn(
                    'Audio',
                    tooltip: 'Insert a display audio block.',
                    size: BtnSize.sm,
                    icon: Icons.audiotrack_outlined,
                    onPressed: () => _edit(
                      f,
                      () => sec.items.add(
                        formNewItem(FormItemKind.videoBlock)
                          ..mediaKind = 'audio',
                      ),
                    ),
                  ),
                  Btn(
                    'Transcription',
                    tooltip:
                        'Insert a clip the respondent transcribes, with its '
                        'category, sound characteristics and speakers.',
                    size: BtnSize.sm,
                    icon: Icons.closed_caption_outlined,
                    onPressed: () => _edit(
                      f,
                      () => sec.items.add(
                        formNewItem(FormItemKind.transcription),
                      ),
                    ),
                  ),
                  Btn(
                    'Comparison',
                    tooltip:
                        'Insert a side-by-side A/B media pair, optionally with a verdict question.',
                    size: BtnSize.sm,
                    icon: Icons.compare_outlined,
                    onPressed: () => _edit(
                      f,
                      () =>
                          sec.items.add(formNewItem(FormItemKind.comparePair)),
                    ),
                  ),
                  Btn(
                    'Annotation',
                    tooltip:
                        'Insert an image with numbered annotations - respondents describe each one.',
                    size: BtnSize.sm,
                    icon: Icons.format_shapes_outlined,
                    onPressed: () => _edit(
                      f,
                      () => sec.items.add(
                        formNewItem(FormItemKind.imageAnnotation),
                      ),
                    ),
                  ),
                ],
              ),
            ]),
    );
  }

  /// Deleting a section takes its questions with it, so confirm first.
  Future<void> _confirmDeleteSection(FormDef f, int si) async {
    final FormSection sec = f.sections[si];
    final int items = sec.items.length;
    final bool? yes = await showSheet<bool>(
      context,
      title: 'Delete this section?',
      sub: 'This cannot be undone.',
      body: Text(
        'Section ${si + 1}'
        '${sec.title.isEmpty ? '' : ' ("${sec.title}")'} and its '
        '$items item${items == 1 ? '' : 's'} will be permanently deleted.',
        style: context.type.body,
      ),
      actions: <Widget>[
        Btn('Cancel', onPressed: () => Navigator.of(context).pop(false)),
        Btn.danger(
          'Delete Section',
          tooltip: 'Permanently delete this section and every item on it.',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (yes == true) _deleteSection(f, si);
  }

  void _deleteSection(FormDef f, int si) {
    // NOTHING TO SCRUB. This used to walk every remaining option and reset any
    // jump that pointed at the deleted section, or the dropdown would hold a
    // value it no longer offered. Neither sections nor options carry a
    // destination any more (see `FormOption`), so a deleted section leaves no
    // dangling reference behind.
    _edit(f, () => f.sections.removeAt(si));
    widget.store.toaster.ok('Section deleted');
  }

  // ── One item card ────────────────────────────────────────────────────────
}

extension on FormItem {
  /// A duplicate needs its own ids, or the copy's text fields would share
  /// edit state with the original's through identical widget keys.
  FormItem _reminted() {
    final Map<String, dynamic> j = toJson();
    j['id'] = formNewId('item');
    if (j['options'] is List) {
      for (final Object? o in j['options'] as List) {
        if (o is Map<String, dynamic>) o['id'] = formNewId('opt');
      }
    }
    return FormItem.fromJson(j);
  }
}

/// The app's text input, shaped like every other input here, for dynamic
/// designer rows. A `TextFormField` keyed by record id: Flutter then owns the
/// edit state, so the designer can rebuild on every keystroke (live counts,
/// live preview) without controllers to allocate and dispose per row.
///
/// MOVED to `widgets/controls.dart` - it is used by three screens
/// (`form_item_editor.dart`, `form_preview.dart`, `task_template_editor.dart`)
/// besides this one, and living here made every one of them import a
/// concrete SCREEN file just to reach a shared low-level input. `FormItemEditor`
/// and `FormPreview` are meant to be standalone blocks any screen can host;
/// importing their host screen is the coupling that broke that.
