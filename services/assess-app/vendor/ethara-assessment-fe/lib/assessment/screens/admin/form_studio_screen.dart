// Form Studio - the forms an operator has designed, and the door to designing
// one.
//
// A list, not a dashboard: a form's interesting surface is the designer, so
// this screen only has to answer "which forms exist, how big are they, and
// which one do I open". Same shape as the question bank for that reason.
import 'package:flutter/material.dart';

import '../../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../../services/file_pick_web.dart';

import '../../../services/json_export.dart';
import '../../domain/enums.dart';
import '../../domain/form_models.dart';
import '../../domain/models.dart';
import '../../nav.dart';
import '../../state/app_store.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/controls.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/feedback.dart';
import '../../widgets/form_import_sheet.dart';
import '../../widgets/marks.dart';
import '../../widgets/panel.dart';
// The respondent preview and the template designer, both shared with the Forms
// tab and the generator screen so this tab cannot drift from either.
import 'form_preview.dart';
import 'task_template_editor.dart';

class FormStudioScreen extends StatefulWidget {
  final AppStore store;

  const FormStudioScreen({super.key, required this.store});

  @override
  State<FormStudioScreen> createState() => _FormStudioScreenState();
}

class _FormStudioScreenState extends State<FormStudioScreen> {
  String _search = '';

  @override
  void initState() {
    super.initState();
    // LOAD THE TEMPLATE LIBRARY.
    //
    // `taskTemplates` was only ever fetched by the generator detail screen, so
    // arriving at Form Studio directly left the Question Types tab listing the
    // seven built-in shapes and none of the twelve templates that exist - the
    // API had them, the store did not. Post-frame because the loader ends in
    // notifyListeners, which throws if called during build.
    //
    // NOT FOR A READ-ONLY MANAGER. `/api/v1/task_templates` is Admin-only, and
    // `loadTaskTemplates` is quiet-by-default: the 403 would land as
    // `taskTemplatesFailed`, and the Question Types tab would tell a Manager
    // "we could not load these" - reporting a permission as an outage. The tab
    // is hidden for them instead, so the call has nothing to feed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.store.can(Capability.authoring)) {
        widget.store.loadTaskTemplates();
      }
    });
  }

  /// Which list is showing: the forms someone designed, or every question shape
  /// a generator may author.
  ///
  /// WHY BOTH LIVE HERE. A Form Studio template and a built-in question type
  /// are the same thing to an operator planning a run - "what shape can this
  /// produce?" - but a template was only visible inside the generator's picker,
  /// so there was nowhere to see the full catalogue, compare two templates, or
  /// tell which ones would actually generate. The types tab answers that on the
  /// screen where the shapes are authored.
  String _tab = 'forms';

  void _create() {
    final FormDef f = widget.store.createForm();
    context.nav.go(FormDesigner(f.id));
  }

  /// A file-picker round trip is in flight, so the button cannot be pressed
  /// twice and mint two forms from one file.
  bool _importing = false;

  /// Build a whole form from a JSON file and open it.
  ///
  /// THROUGH A SHEET, NOT STRAIGHT TO THE PICKER. Going straight to the OS
  /// dialog was right only for an operator who already had a file, and nothing
  /// in the product ever showed them what one looks like. The sheet carries the
  /// template download, so the first click can produce a starting file instead
  /// of a dead end. It answers the bytes and nothing else; the parse and the
  /// navigation stay here.
  ///
  /// The picker is restricted to `.json`, but the parse is what actually
  /// decides: an operator can rename anything.
  Future<void> _import() async {
    final PickedFile? file = await showFormImportSheet(context, widget.store);
    if (file == null || !mounted) return;
    setState(() => _importing = true);
    final FormDef? form = await widget.store.importForm(
      bytes: file.bytes,
      filename: file.name,
    );
    if (!mounted) return;
    setState(() => _importing = false);
    // Straight into the designer: an import the author cannot see is
    // indistinguishable from one that failed.
    if (form != null) context.nav.go(FormDesigner(form.id));
  }

  /// Write one form to a JSON file the Import button can read back.
  ///
  /// EXPORTS THE SAVED RECORD, not a re-derived shape: `FormDef.toJson()` is
  /// the same serialisation `formFromImportedJson` parses, and there is a test
  /// pinning that round trip. So the file is not a report about a form - it IS
  /// the form, and importing it elsewhere rebuilds it.
  ///
  /// `published` RIDES ALONG BUT DOES NOT SURVIVE. The importer forces every
  /// import to a draft, because publishing puts questions in front of
  /// candidates and that is a decision someone makes on purpose, not a
  /// property a file carries in.
  void _export(AppStore s, FormDef f) {
    // NAMED FOR THE OPERATOR, like the row it was exported from: the file
    // lands in a downloads folder next to twenty others and the person who has
    // to recognise it there is the one who typed the internal name. The
    // document inside still carries both names, so the import is lossless.
    final String name = f.displayTitle.trim();
    final String file = jsonFileName(name, fallback: 'form');
    downloadJson(file, f.toJson());
    s.toaster.ok(
      '$file downloaded - ${f.sections.length} section(s), '
      '${f.questionCount} question(s). Import brings it back.',
    );
  }

  /// A read-only Manager's way into a form: the respondent view, no editor.
  ///
  /// THE DESIGNER IS NOT A VIEWER. `FormDesignerScreen` autosaves - the first
  /// keystroke or reorder posts - so a Manager cannot be let in by hiding a
  /// Save button, and the route guard turns them away from `FormDesigner`
  /// outright. That left this tab on a Manager's rail with rows that led
  /// nowhere: a list of forms whose one interesting surface was blocked, which
  /// reads as a broken screen rather than a limited one.
  ///
  /// So the row opens what the designer's own Preview tab renders, from the
  /// same widget and the same `showKeys: true`. That is the whole design a
  /// Manager has to read - every control as it was drawn, its options, its
  /// scale points, its media and its answer key. It just cannot write.
  ///
  /// NO EDIT ACTION, unlike the template preview further down this file. An
  /// affordance whose destination bounces the same user is worse than no
  /// affordance: it reads as a bug in the console instead of a permission they
  /// were never given.
  void _previewForm(FormDef f) {
    showSheet<void>(
      context,
      title: f.displayTitle,
      sub:
          '${f.published ? 'Published' : 'Draft'} · '
          '${f.sections.length} section${f.sections.length == 1 ? '' : 's'} · '
          '${f.questionCount} question${f.questionCount == 1 ? '' : 's'}',
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: FormPreview(form: f, showKeys: true),
      ),
      actions: <Widget>[
        Btn('Close', onPressed: () => Navigator.of(context).pop()),
      ],
    );
  }

  /// Deleting a form is irreversible, so ask first. Returns via the sheet's
  /// own Delete/Cancel actions; only a confirmed Delete removes the row.
  Future<void> _confirmDelete(AppStore s, FormDef f) async {
    // The confirmation must quote the form back in the SAME words as the row
    // that was clicked, or an operator with an internal name set is asked to
    // approve deleting something they do not recognise.
    final String name = f.displayTitle;
    final bool? yes = await showSheet<bool>(
      context,
      title: 'Delete this form?',
      sub: 'This cannot be undone.',
      body: Text(
        '"$name" and its ${f.sections.length} section'
        '${f.sections.length == 1 ? '' : 's'} '
        '(${f.questionCount} question${f.questionCount == 1 ? '' : 's'}) '
        'will be permanently deleted.',
        style: context.type.body,
      ),
      actions: <Widget>[
        Btn('Cancel', onPressed: () => Navigator.of(context).pop(false)),
        Btn.danger(
          'Delete Form',
          tooltip: 'Permanently delete this form and its design.',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (yes == true) {
      s.deleteForm(f.id);
      s.toaster.ok('Form deleted');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;

    return ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final List<FormDef> all = s.forms;
        final String q = _search.trim().toLowerCase();
        final List<FormDef> shown = q.isEmpty
            ? all
            // SEARCHES WHAT THE LIST SHOWS. Filtering on `title` while the
            // rows render `displayTitle` is the worst of both: an operator
            // types the name they can see in front of them and the row
            // disappears.
            : all
                  .where(
                    (FormDef f) => f.displayTitle.toLowerCase().contains(q),
                  )
                  .toList();

        return PageBody(
          children: <Widget>[
            // No breadcrumbs: this is a root destination, the rail already
            // says where we are.
            PageHead(
              'Form Studio',
              sub:
                  'Design a form, preview it as a respondent, publish it '
                  'when the collection phase ships.',
              actions: <Widget>[
                // Form Studio is on a read-only Manager's rail so they can
                // READ a published form's design. Authoring it - import, create,
                // duplicate, export, delete - is Admin-only server-side.
                if (_tab == 'forms' && s.can(Capability.authoring)) ...<Widget>[
                  Btn(
                    _importing ? 'Importing...' : 'Import',
                    icon: Icons.upload_file_outlined,
                    tooltip:
                        'Build a whole form from a JSON file, or download '
                        'a template to start from. Every id is renewed, so '
                        'importing twice gives two forms rather than '
                        'overwriting one.',
                    onPressed: _importing ? null : _import,
                  ),
                  Btn.primary('New Form', icon: Icons.add, onPressed: _create),
                ],
              ],
            ),
            TabStrip(
              active: _tab,
              onChanged: (String k) => setState(() {
                _tab = k;
                // The two lists search different things, so a query carried
                // across would silently filter the new list by the old term.
                _search = '';
              }),
              tabs: <TabDef>[
                const TabDef('forms', 'Forms'),
                // The catalogue lists Admin-only data, so a Manager gets a
                // single-tab Form Studio rather than a tab that cannot fill.
                if (s.can(Capability.authoring))
                  const TabDef('types', 'Question Types'),
              ],
            ),
            if (_tab == 'types' && s.can(Capability.authoring))
              _TypeCatalogue(store: s)
            else
              Panel(
                flush: true,
                toolbar: Toolbar(<Widget>[
                  SearchField(
                    value: _search,
                    hint: 'Search forms',
                    onChanged: (String v) => setState(() => _search = v),
                  ),
                  const Spacer(),
                  TagChip('${shown.length} of ${all.length}'),
                ]),
                child: DataGrid(
                  minWidth: 760,
                  emptyMessage: q.isEmpty
                      // "Design the first one" is an instruction, and a
                      // read-only Manager cannot follow it - the New Form
                      // button is not theirs and the empty state carries none.
                      // An empty state that asks for something impossible reads
                      // as a missing button rather than as an empty list.
                      ? (s.can(Capability.authoring)
                            ? 'No forms yet. Design the first one.'
                            : 'No forms have been designed yet.')
                      // "No form", not "No form title": the filter above
                      // matches the name shown in the list, which is the
                      // internal name whenever one is set.
                      : 'No form matches "$_search".',
                  emptyIcon: Icons.dynamic_form_outlined,
                  emptyAction: q.isEmpty && s.can(Capability.authoring)
                      ? Btn.primary(
                          'New Form',
                          icon: Icons.add,
                          onPressed: _create,
                        )
                      : null,
                  cols: const <Col>[
                    Col('Form', flex: 3),
                    Col('Sections', width: 90, numeric: true),
                    Col('Questions', width: 100, numeric: true),
                    Col('Updated', width: 110),
                    Col('Status', width: 100),
                    Col('', width: 128),
                  ],
                  rows: shown
                      .map(
                        (FormDef f) => GridRow(
                          <Widget>[
                            GridLink(f.displayTitle),
                            Text(
                              '${f.sections.length}',
                              style: context.type.tableCell,
                            ),
                            Text(
                              '${f.questionCount}',
                              style: context.type.tableCell,
                            ),
                            Mono(_day(f.updatedAt)),
                            Pill(
                              f.published ? 'Published' : 'Draft',
                              f.published ? Tone.ok : Tone.inert,
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: <Widget>[
                                if (!s.can(Capability.authoring))
                                  // Nothing in this cell for a Manager: every
                                  // one of these writes. The row still opens -
                                  // into the read-only preview, see the tap
                                  // handler at the bottom of the row.
                                  const SizedBox.shrink()
                                else ...<Widget>[
                                  // The row itself opens the designer too; the
                                  // pencil exists so editing is discoverable
                                  // without knowing that.
                                  IconBtn(
                                    Icons.edit_outlined,
                                    tooltip: 'Edit',
                                    onPressed: () =>
                                        context.nav.go(FormDesigner(f.id)),
                                  ),
                                  IconBtn(
                                    Icons.copy_outlined,
                                    tooltip: 'Duplicate',
                                    onPressed: () {
                                      s.duplicateForm(f.id);
                                      s.toaster.ok('Form duplicated');
                                    },
                                  ),
                                  // THE COUNTERPART TO IMPORT, on every row.
                                  //
                                  // Import could build a form from JSON but nothing
                                  // could produce that JSON, so the feature was
                                  // half a round trip: the only way to get a file
                                  // was to hand-write one. This writes exactly what
                                  // `formFromImportedJson` reads, which is what
                                  // makes a form portable between environments -
                                  // author on local, import on stage.
                                  IconBtn(
                                    Icons.file_download_outlined,
                                    tooltip:
                                        'Export as JSON. The file imports '
                                        'back with the Import button, so a form '
                                        'can move between environments.',
                                    onPressed: () => _export(s, f),
                                  ),
                                  IconBtn(
                                    Icons.delete_outline,
                                    tooltip: 'Delete',
                                    onPressed: () => _confirmDelete(s, f),
                                  ),
                                ],
                              ],
                            ),
                            // ONE ROW, TWO DESTINATIONS, decided by what the
                            // user may do rather than by which portal they are
                            // in - `Portal` reports admin for a Manager, so
                            // branching on it is what sent them to the designer
                            // in the first place. An Admin gets the editor; a
                            // Manager gets the preview, because the designer
                            // autosaves and the route guard rejects them.
                          ],
                          onTap: () => s.can(Capability.authoring)
                              ? context.nav.go(FormDesigner(f.id))
                              : _previewForm(f),
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Every question shape a generator may author: the built-in types and the
/// Form Studio templates, in one searchable list.
///
/// Same grid, toolbar and search as the Forms tab, because it answers the same
/// kind of question and an operator should not have to learn a second layout.
/// A template row opens its designer; a built-in type has no designer, so its
/// row opens a preview of what the shape asks instead.
class _TypeCatalogue extends StatefulWidget {
  const _TypeCatalogue({required this.store});

  final AppStore store;

  @override
  State<_TypeCatalogue> createState() => _TypeCatalogueState();
}

class _TypeCatalogueState extends State<_TypeCatalogue> {
  String _search = '';

  /// What a built-in type asks a candidate to do, in the operator's words.
  ///
  /// Data-driven off the enum rather than a parallel list, so a type added to
  /// `QType` appears here without another edit; only the sentence is per-type.
  static const Map<QType, String> _whatItAsks = <QType, String>{
    QType.mcq: 'Pick exactly one option from a list.',
    QType.msq: 'Pick every option that applies.',
    QType.subjectiveRubric:
        'Judge a submission against the axes and checks you author, and write '
        'up anything that failed.',
    QType.imageAb:
        'Compare two images and say which is better on each axis you author.',
    QType.imagePrompt: 'Write the prompt that would produce a target image.',
    QType.imageLabel:
        'Categorise or annotate each numbered region on an image.',
    QType.videoPrompt: 'Write the prompt that would produce a target clip.',
  };

  void _previewType(QType q) {
    showSheet<void>(
      context,
      title: q.label,
      sub: 'A built-in shape. Every generator can author it.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            _whatItAsks[q] ?? 'A built-in question shape.',
            style: context.type.body,
          ),
          const SizedBox(height: 14),
          Text(
            q.isObjective
                ? 'Marked by matching the candidate\'s choice against the '
                      'answer key, so it scores the moment they submit.'
                : 'Marked by the grader, so its result is held until scoring '
                      'has run.',
            style: context.type.small,
          ),
        ],
      ),
      actions: <Widget>[
        Btn('Close', onPressed: () => Navigator.of(context).pop()),
      ],
    );
  }

  /// A template's document as a [FormDef], so the REAL respondent preview can
  /// render it.
  ///
  /// The only mismatch between the two families is the wrapper key: a
  /// `FormDef` reads `j['sections']`, and `TaskTemplate.structure` IS that bare
  /// list ("Form Studio `sections`, verbatim" - see the model). Every item
  /// underneath is already the designer's own shape, which is what lets the
  /// server borrow `studio_form._item_spec` for both. So this is a rename, not a
  /// conversion, and nothing here can drift from what the designer produces.
  ///
  /// The synthesized id is never persisted - [FormPreview] takes a typed
  /// `FormDef` and no store, so it renders a form that was never saved.
  static FormDef _asFormDef(TaskTemplate tpl) =>
      FormDef.fromJson(<String, dynamic>{
        'id': 'tpl-${tpl.id}',
        'title': tpl.name,
        'description': tpl.instructions,
        'sections': tpl.structure,
      });

  /// The respondent view of a template, plus a way into the editor.
  ///
  /// WAS A FLAT TEXT LIST of `title · kind` strings, which is the one thing a
  /// preview must not be: an examiner could not see the control they had drawn,
  /// the options, the scale points or the media - only that an item existed. The
  /// Forms tab has had a real preview all along, so the two halves of the same
  /// screen disagreed about what "preview" means.
  ///
  /// `showKeys: true` matches the Forms tab: the answer key is pre-filled so the
  /// author can check it, and the preview's own banner says respondents start
  /// blank.
  void _previewTemplate(TaskTemplate tpl) {
    showSheet<void>(
      context,
      title: tpl.name.isEmpty ? 'Untitled template' : tpl.name,
      sub:
          'Designed in Form Studio · '
          '${tpl.itemCount} item${tpl.itemCount == 1 ? '' : 's'}'
          '${tpl.isPartlyBroken ? " · ${tpl.usableCount} would generate" : ""}',
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: FormPreview(form: _asFormDef(tpl), showKeys: true),
      ),
      actions: <Widget>[
        Btn('Close', onPressed: () => Navigator.of(context).pop()),
        Btn(
          'Edit',
          variant: BtnVariant.primary,
          tooltip:
              'Open this question type in the designer - its questions, '
              'options and answer key',
          onPressed: () {
            Navigator.of(context).pop();
            _editTemplate(tpl);
          },
        ),
      ],
    );
  }

  /// Open a template in the designer it was authored in.
  ///
  /// REUSES `TaskTemplateEditor`, the same dialog the generator screen opens, so
  /// there is one template designer rather than two that can drift. It was
  /// reachable ONLY from a generator, which is why this tab could list a
  /// template and then offer no way to change it - the capability existed and
  /// had no entry point.
  ///
  /// `generatorId` is empty on purpose: that argument exists so the editor can
  /// offer "draft this from the SOP", which needs a generator to read the SOP
  /// from. Reached from here there is no generator in scope, and the editor
  /// hides that affordance rather than guessing one.
  void _editTemplate(TaskTemplate tpl) {
    showToastedDialog<void>(
      context,
      barrierDismissible: false,
      builder: (BuildContext _) => TaskTemplateEditor(
        store: widget.store,
        generatorId: '',
        template: tpl,
      ),
    ).then((_) {
      if (mounted) widget.store.loadTaskTemplates(quiet: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppStore s = widget.store;
    final String q = _search.trim().toLowerCase();

    final List<QType> types = QType.generatable
        .where(
          (QType t) =>
              q.isEmpty ||
              t.label.toLowerCase().contains(q) ||
              (_whatItAsks[t] ?? '').toLowerCase().contains(q),
        )
        .toList();
    final List<TaskTemplate> templates = s.taskTemplates
        .where(
          (TaskTemplate t) =>
              q.isEmpty ||
              t.name.toLowerCase().contains(q) ||
              t.shapeSummary.toLowerCase().contains(q),
        )
        .toList();
    final int total = QType.generatable.length + s.taskTemplates.length;
    final int shownCount = types.length + templates.length;

    return Panel(
      flush: true,
      toolbar: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Toolbar(<Widget>[
            SearchField(
              value: _search,
              hint: 'Search question types',
              onChanged: (String v) => setState(() => _search = v),
            ),
            const Spacer(),
            // The count says WHICH READING APPLIES. On a failed load it counts
            // only what is really here rather than "7 of 7", which an operator
            // reads as "my designed types were deleted".
            TagChip(
              s.taskTemplatesFailed
                  ? '$shownCount built-in'
                  : '$shownCount of $total',
            ),
          ]),
          // SAY SO WHEN THE LIBRARY DID NOT LOAD. `loadTaskTemplates` is quiet
          // by default and swallows its exception, so a 500 left `taskTemplates`
          // empty and this tab presented a short list as the whole catalogue.
          if (s.taskTemplatesFailed)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Notice(
                tone: Tone.warn,
                strong: 'Designed question types could not be loaded.',
                text:
                    'Only the built-in ones are listed. Nothing has been '
                    'deleted - reload to try again.',
              ),
            ),
        ],
      ),
      child: DataGrid(
        minWidth: 760,
        emptyMessage: 'No question type matches "$_search".',
        emptyIcon: Icons.category_outlined,
        cols: const <Col>[
          Col('Question type', flex: 3),
          Col('Source', width: 130),
          Col('Items', width: 80, numeric: true),
          Col('Scoring', width: 130),
          Col('Status', width: 110),
          Col('', width: 64),
        ],
        rows: <GridRow>[
          for (final QType t in types)
            GridRow(<Widget>[
              GridLink(t.label),
              Pill('Built-in', Tone.inert),
              Text('-', style: context.type.tableCell),
              Text(
                t.isObjective ? 'Answer Key' : 'Grader',
                style: context.type.tableCell,
              ),
              Pill('Ready', Tone.ok),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  IconBtn(
                    Icons.visibility_outlined,
                    tooltip: 'Preview',
                    onPressed: () => _previewType(t),
                  ),
                ],
              ),
            ], onTap: () => _previewType(t)),
          for (final TaskTemplate tpl in templates)
            GridRow(<Widget>[
              GridLink(tpl.name.isEmpty ? 'Untitled template' : tpl.name),
              Pill('Form Studio', Tone.info),
              Text('${tpl.itemCount}', style: context.type.tableCell),
              Text(
                QType.parse(tpl.questionType).short,
                style: context.type.tableCell,
              ),
              // An unusable template spends money and returns nothing, so it
              // says so here rather than only inside the generator's picker.
              Pill(
                tpl.isUnusable
                    ? 'Unusable'
                    : tpl.isPartlyBroken
                    ? '${tpl.usableCount}/${tpl.itemCount} usable'
                    : 'Ready',
                tpl.isUnusable
                    ? Tone.bad
                    : tpl.isPartlyBroken
                    ? Tone.warn
                    : Tone.ok,
              ),
              // PREVIEW AND EDIT, the same pair the Forms tab offers. A row that
              // could only be looked at was the whole complaint about this tab:
              // the editor existed, reachable from a generator, and nothing here
              // led to it.
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  IconBtn(
                    Icons.edit_outlined,
                    tooltip: 'Edit this question type',
                    onPressed: () => _editTemplate(tpl),
                  ),
                  IconBtn(
                    Icons.visibility_outlined,
                    tooltip: 'Preview as a respondent',
                    onPressed: () => _previewTemplate(tpl),
                  ),
                ],
              ),
            ], onTap: () => _previewTemplate(tpl)),
        ],
      ),
    );
  }
}

/// The India date, like every other date on screen - not the browser's.
String _day(DateTime at) {
  final DateTime d = inIst(at);
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
