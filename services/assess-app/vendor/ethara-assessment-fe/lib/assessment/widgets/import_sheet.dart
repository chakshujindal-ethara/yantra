// The CSV / JSON import sheet.
//
// ONE SHEET FOR THREE ENTITIES - questions, generators and tags - because the
// import is the same act each time: pick a file, send the bytes, read what
// happened. Only the wording and the route differ, and both come off
// [ImportEntity].
//
// THE FILE GOES UP UNTOUCHED, and that is the point of this rewrite. This sheet
// used to parse CSV on the client (`data/bank_payload.dart`) against a
// six-column spec, and post the result as JSON. The server's own template has
// thirty-three columns - dimensions, rubrics, images - so the file an operator
// downloaded from Odoo lost most of itself on the way in, and the import
// reported success. Now the bytes reach the same importer the back office
// uses, which is the only way "the same file gives the same result in both
// UIs" can be true rather than aspired to.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../services/file_pick_web.dart';

import '../domain/enums.dart';
import '../state/app_store.dart';
import 'buttons.dart';
import 'controls.dart';
import 'feedback.dart';
import 'marks.dart';
import 'panel.dart';
import '../theme.dart';

/// Opens the import sheet for [entity].
/// How the sheet asks for a file. Injectable ONLY so the sheet can be driven in
/// a widget test - see the typedef's twin in `form_import_sheet.dart`, and the
/// frozen-button bug both of them exist to keep fixed.
typedef FilePicker = Future<PickedFile?> Function({String accept});

Future<void> showImportSheet(
  BuildContext context,
  AppStore store, {
  required ImportEntity entity,
  FilePicker pick = pickFile,
}) async {
  // The FILE, not just its name. The sheet used to hold a filename string and
  // its Import button showed a toast, so nothing was ever read or sent.
  //
  // A LISTENABLE, NOT A LOCAL PLUS `setState`. `showSheet` puts `actions` in a
  // footer `Container` that is a SIBLING of `body` (`controls.dart`), so the
  // `StatefulBuilder` around the body cannot reach it - its setState rebuilds
  // the body subtree only, and the footer's `picked == null ? null : ...` is
  // evaluated EXACTLY ONCE, when the dialog is built and nothing is picked.
  // The dropzone (inside the body) updated and showed a green "Selected"
  // badge; the Import button next to it stayed grey and could never be
  // pressed, so all three of these importers were unreachable from this sheet.
  // Hot reload marks every element dirty, which is why it never showed up
  // during `flutter run`.
  final ValueNotifier<PickedFile?> picked = ValueNotifier<PickedFile?>(null);
  // Read once per pick, not on every footer rebuild.
  String label = 'Import';

  await showSheet<void>(
    context,
    title: entity.title,
    sub: entity.sub,
    body: ValueListenableBuilder<PickedFile?>(
      valueListenable: picked,
      builder: (BuildContext context, PickedFile? file, _) {
        final AppTokens t = context.tokens;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Stated BEFORE the dropzone: a warning that arrives after the
            // file is chosen is too late to change what the person does.
            Notice(
              tone: Tone.warn,
              strong: entity == ImportEntity.questions
                  ? 'One bad row stops the whole import.'
                  : 'A matching name updates, it does not duplicate.',
              text: entity == ImportEntity.questions
                  ? 'Nothing is written until every row validates. A partial '
                        'import would leave you guessing which questions '
                        'landed, so the file is accepted or refused as a whole.'
                  : 'A row whose name already exists overwrites the columns '
                        'that row names and leaves the rest alone - so a '
                        'corrected file can safely be re-imported.',
            ),
            const SizedBox(height: 14),
            _ImportDropzone(
              entity: entity,
              picked: file,
              pick: pick,
              onPick: (PickedFile f) {
                if (entity == ImportEntity.questions) {
                  label = _questionImportLabel(f.bytes);
                }
                picked.value = f;
              },
            ),
            const SizedBox(height: 14),
            _TemplateColumns(store: store, entity: entity),
            const SizedBox(height: 12),
            Text(
              'Max 25 MB  ·  up to 5,000 rows',
              style: context.type.small.copyWith(color: t.textMuted),
            ),
          ],
        );
      },
    ),
    actions: <Widget>[
      Btn('Cancel', onPressed: () => Navigator.of(context).pop()),
      ValueListenableBuilder<PickedFile?>(
        valueListenable: picked,
        builder: (BuildContext ctx, PickedFile? file, _) => Btn.primary(
          // Worded as Odoo's dialog words it, from the same sniff.
          label,
          tooltip:
              'Send the file to the server, which reads it with the same '
              'importer the back office uses.',
          onPressed: file == null
              ? null
              : () async {
                  Navigator.of(ctx).pop();
                  await store.importFile(entity, file.name, file.bytes);
                },
        ),
      ),
    ],
  );

  picked.dispose();
}

/// The server's sniff (`run_import` in bank_import_wizard.py): a native export
/// restores into the bank, harness JSON, a sectioned test file and anything
/// that is not JSON (read as CSV) land as drafts, and other JSON has no format
/// the server can name.
String _questionImportLabel(List<int> bytes) {
  final Object? data;
  try {
    // utf8.decode drops a leading byte-order mark, as the server's
    // utf-8-sig read does.
    data = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return 'Import as drafts';
  }
  if (_isNativeBankExport(data)) return 'Restore into the bank';
  final Object? items = data is Map ? data['questions'] : data;
  final Object? first = items is List && items.isNotEmpty ? items.first : null;
  final bool harness =
      first is Map &&
      (first.containsKey('fields') ||
          (first.containsKey('instruction') && first.containsKey('id')));
  // `sectioned_payload`: {sections: [{questions: [...]}, ...]}.
  final Object? sections = data is Map ? data['sections'] : null;
  final bool sectioned = sections is List &&
      sections.isNotEmpty &&
      sections.every((Object? s) => s is Map && s['questions'] is List);
  return harness || sectioned ? 'Import as drafts' : 'Import';
}

/// `native_payload`: an object with a truthy `assessments_be_bank` and a
/// `questions` list.
bool _isNativeBankExport(Object? data) {
  if (data is! Map || data['questions'] is! List) return false;
  final Object? mark = data['assessments_be_bank'];
  return mark != null && mark != false && mark != 0 && mark != '';
}

/// The columns the server's own template carries, fetched rather than restated.
///
/// A LIST WRITTEN HERE IS A SECOND COPY OF THE SPEC, and a second copy is how
/// the two importers came to disagree. This reads the header row off the
/// template the Download button hands out, so the sheet cannot describe a file
/// the server will not accept.
class _TemplateColumns extends StatefulWidget {
  const _TemplateColumns({required this.store, required this.entity});

  final AppStore store;
  final ImportEntity entity;

  @override
  State<_TemplateColumns> createState() => _TemplateColumnsState();
}

class _TemplateColumnsState extends State<_TemplateColumns> {
  List<String>? _columns;

  @override
  void initState() {
    super.initState();
    // Not awaited: the sheet is already on screen and the column list fills in
    // when it arrives. `importTemplateColumns` swallows its own failures, so
    // the worst case is a sheet that shows the Download button and no chips.
    unawaited(_load());
  }

  Future<void> _load() async {
    final List<String> cols = await widget.store.importTemplateColumns(
      widget.entity,
    );
    if (mounted) setState(() => _columns = cols);
  }

  @override
  Widget build(BuildContext context) {
    final List<String> cols = _columns ?? const <String>[];
    return Panel(
      title: 'Columns',
      note: cols.isEmpty ? 'From the template' : '${cols.length} in total',
      headActions: <Widget>[
        Btn(
          'Download Template',
          icon: Icons.download_outlined,
          size: BtnSize.sm,
          tooltip:
              'A CSV with the exact columns this importer reads, and an '
              'example row. The same file the back office hands out.',
          onPressed: () => widget.store.downloadImportTemplate(widget.entity),
        ),
      ],
      child: cols.isEmpty
          ? Text(
              'Download the template for the exact columns and an example row.',
              style: context.type.bodySecondary,
            )
          : Wrap(
              spacing: 7,
              runSpacing: 6,
              children: <Widget>[
                for (final String col in cols) StatusBadge(col, Tone.inert),
              ],
            ),
    );
  }
}

/// The file target. Kept private: an import dropzone carries import-specific
/// copy and is not a general-purpose control.
class _ImportDropzone extends StatelessWidget {
  final ImportEntity entity;
  final PickedFile? picked;
  final ValueChanged<PickedFile> onPick;
  final FilePicker pick;

  const _ImportDropzone({
    required this.entity,
    required this.picked,
    required this.onPick,
    required this.pick,
  });

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (picked != null) {
      return Panel(
        title: picked!.name,
        note:
            '${(picked!.bytes.length / 1024).toStringAsFixed(1)} KB, '
            'ready to send',
        headActions: <Widget>[const StatusBadge('Selected', Tone.ok)],
        child: Text(
          'The file is read by the server when you import. Rows are validated '
          'together, and the first failure reports its row number.',
          style: context.type.bodySecondary,
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.bgSubtle,
        borderRadius: Radii.panel,
        border: Border.all(color: t.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
        child: Column(
          children: <Widget>[
            Icon(Icons.upload_file, size: 26, color: t.textMuted),
            const SizedBox(height: 9),
            Text(
              entity == ImportEntity.questions
                  ? 'Drop a CSV or JSON file here'
                  : 'Drop a CSV file here',
              style: context.type.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            // A real picker, not sample filenames. The two buttons here used
            // to hand back a made-up name that nothing could read, which is
            // how the whole import path came to be a toast.
            Btn.primary(
              'Choose a File',
              icon: Icons.folder_open,
              size: BtnSize.sm,
              onPressed: () async {
                final PickedFile? f = await pick(accept: entity.accept);
                if (f != null) onPick(f);
              },
            ),
          ],
        ),
      ),
    );
  }
}
