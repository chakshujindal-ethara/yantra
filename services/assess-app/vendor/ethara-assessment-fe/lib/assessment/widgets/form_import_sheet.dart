// The Form Studio import sheet.
//
// WHY A SHEET AND NOT STRAIGHT TO THE FILE PICKER. Import used to open the OS
// dialog on the first click, which is the right shape only when the operator
// already HAS a file. Nothing in the product ever told them what one looks
// like: the parser takes almost anything (`formFromImportedJson` refuses four
// document-level shapes and silently absorbs everything else - an unknown
// `kind` becomes a short answer with no warning), so a wrong file does not fail
// at import. It fails much later, at Publish, as a list of missing answer keys.
// The sheet exists to put the template in front of that click.
//
// NOT `import_sheet.dart`. That one posts the bytes to the server, because the
// bank, generator and tag importers all run there. This import runs HERE - the
// file never reaches Odoo - so the two share an anatomy and nothing else.
// Folding them together would mean a sheet whose primary button sometimes
// uploads and sometimes parses, which is the kind of "reuse" that produces a
// third behaviour nobody wanted.
import 'package:flutter/material.dart';

import '../../services/file_pick_stub.dart'
    if (dart.library.js_interop) '../../services/file_pick_web.dart';

import '../domain/enums.dart';
import '../domain/form_models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import 'buttons.dart';
import 'controls.dart';
import 'feedback.dart';
import 'marks.dart';
import 'panel.dart';

/// Opens the import sheet and answers the file the operator chose, or null.
///
/// The PARSE stays with the caller. This sheet only decides which bytes, so the
/// screen keeps the part that has to navigate into the designer afterwards - an
/// import the author cannot see is indistinguishable from one that failed.
/// How the sheet asks for a file. Injectable ONLY so the sheet can be driven in
/// a widget test: `pickFile` is a conditional import that answers null off the
/// web, so nothing could otherwise reach the state where a file is chosen - and
/// that unreachable state is exactly where the frozen-button bug below lived.
typedef FilePicker = Future<PickedFile?> Function({String accept});

Future<PickedFile?> showFormImportSheet(
  BuildContext context,
  AppStore store, {
  FilePicker pick = pickFile,
}) async {
  // A LISTENABLE, NOT A LOCAL PLUS `setState`, and this is not a style choice.
  //
  // `showSheet` puts `actions` in a footer `Container` that is a SIBLING of
  // `body` (`controls.dart`), so a `StatefulBuilder` wrapped around the body
  // cannot reach it: its setState rebuilds the body subtree only. The footer's
  // `picked == null ? null : ...` would then be evaluated EXACTLY ONCE, when
  // the dialog is built and nothing is picked - and stay disabled forever.
  // Worse, the dropzone lives inside the body and does update, so choosing a
  // file lights up a green "Selected" badge above a primary button that can
  // never be pressed. The sheet looks like it is working.
  //
  // (Nothing forces that rebuild either: `_ModalScopeState` caches its page and
  // only drops the cache from `Navigator.didUpdateWidget`, which nothing in
  // this app triggers while a sheet is open. Hot reload marks every element
  // dirty, which is why this is invisible during `flutter run`.)
  //
  // One notifier is heard from both subtrees, so there is no second copy of
  // "which file is chosen" to fall out of step.
  final ValueNotifier<PickedFile?> picked = ValueNotifier<PickedFile?>(null);
  try {
    return await _sheet(context, store, picked, pick);
  } finally {
    picked.dispose();
  }
}

Future<PickedFile?> _sheet(
  BuildContext context,
  AppStore store,
  ValueNotifier<PickedFile?> picked,
  FilePicker pick,
) {
  return showSheet<PickedFile>(
    context,
    title: 'Import a form',
    sub: 'Build a whole form from a JSON file.',
    body: ValueListenableBuilder<PickedFile?>(
      valueListenable: picked,
      builder: (BuildContext context, PickedFile? file, _) {
        final AppTokens t = context.tokens;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Stated BEFORE the dropzone, like the bank sheet's own warning:
            // what the import does to ids and to `published` is the part an
            // operator would otherwise discover by finding two forms.
            const Notice(
              tone: Tone.warn,
              strong: 'Every id is renewed.',
              text:
                  'Importing the same file twice gives two forms rather than '
                  'overwriting one, and a file that says it is published '
                  'still arrives as a draft.',
            ),
            const SizedBox(height: 14),
            _FormDropzone(
              picked: file,
              pick: pick,
              onPick: (PickedFile f) => picked.value = f,
            ),
            const SizedBox(height: 14),
            _TemplatePanel(store: store),
            const SizedBox(height: 12),
            Text(
              'Max ${kMaxFormStructureBytes ~/ 1024} KB  ·  JSON only',
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
        builder: (BuildContext ctx, PickedFile? file, _) {
          // REFUSED HERE, NOT AFTER THE SHEET CLOSES. `AppStore.importForm`
          // checks the same ceiling and toasts an honest refusal, but by then
          // the sheet is gone and the operator has to reopen it to choose
          // another file - while this sheet already knew, and already said so
          // on the dropzone.
          final bool tooBig =
              file != null && file.bytes.length > kMaxFormStructureBytes;
          return Btn.primary(
            'Import',
            tooltip: tooBig
                ? 'That file is over the ${kMaxFormStructureBytes ~/ 1024} KB '
                      'ceiling. Choose a smaller one.'
                : 'Read the file here and open it in the designer. Nothing '
                      'is sent to candidates.',
            onPressed: file == null || tooBig
                ? null
                : () => Navigator.of(ctx).pop(file),
          );
        },
      ),
    ],
  );
}

/// The template, and the kinds it carries.
///
/// THE CHIPS COME OFF THE LOCAL ENUM, not off the downloaded file. `FormItemKind`
/// IS this importer's vocabulary - `FormItemKindX.parse` maps anything else onto
/// a short answer - so the list is already authoritative here and needs no
/// round trip. That is the one place this differs from `_TemplateColumns` in the
/// bank sheet, which must ask the server because the server owns those columns.
class _TemplatePanel extends StatelessWidget {
  const _TemplatePanel({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    const List<FormItemKind> kinds = FormItemKind.values;
    return Panel(
      title: 'Question kinds',
      note: '${kinds.length} in total',
      headActions: <Widget>[
        Btn(
          'Download template',
          icon: Icons.download_outlined,
          size: BtnSize.sm,
          tooltip:
              'A JSON file with one empty item of every kind below, and '
              'every field you have to fill in already named.',
          onPressed: store.downloadFormTemplate,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'The template is a skeleton, not a form: it carries no questions '
            'and no answer keys, so it will not publish until you write them. '
            'Publish names whatever is still blank, item by item.',
            style: context.type.bodySecondary,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 6,
            children: <Widget>[
              for (final FormItemKind k in kinds)
                StatusBadge(k.label, Tone.inert),
            ],
          ),
        ],
      ),
    );
  }
}

/// The file target. Private for the same reason the bank sheet's is: the copy
/// on it is import-specific and it is not a general-purpose control.
class _FormDropzone extends StatelessWidget {
  const _FormDropzone({
    required this.picked,
    required this.onPick,
    required this.pick,
  });

  final PickedFile? picked;
  final ValueChanged<PickedFile> onPick;
  final FilePicker pick;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (picked != null) {
      final double kb = picked!.bytes.length / 1024;
      final bool tooBig = picked!.bytes.length > kMaxFormStructureBytes;
      return Panel(
        title: picked!.name,
        note: '${kb.toStringAsFixed(1)} KB, ready to read',
        headActions: <Widget>[
          StatusBadge(
            tooBig ? 'Too large' : 'Selected',
            tooBig ? Tone.bad : Tone.ok,
          ),
        ],
        child: Text(
          tooBig
              // Said here rather than only as a toast after the click: the
              // operator can swap the file while the picker is still in reach.
              ? 'Over the ${kMaxFormStructureBytes ~/ 1024} KB ceiling, so the '
                    'import will be refused. Split the form into two, or '
                    'shorten its text.'
              : 'The file is read in this browser. Nothing is uploaded until '
                    'the form is saved as a draft.',
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
              'Drop a JSON file here',
              style: context.type.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Btn.primary(
              'Choose a File',
              icon: Icons.folder_open,
              size: BtnSize.sm,
              onPressed: () async {
                final PickedFile? f = await pick(
                  accept: '.json,application/json',
                );
                if (f != null) onPick(f);
              },
            ),
          ],
        ),
      ),
    );
  }
}
