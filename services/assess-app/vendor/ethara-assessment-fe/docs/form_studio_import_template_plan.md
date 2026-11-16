# Form Studio: a JSON template on the Import button

2026-09-16. Analysis and plan. **IMPLEMENTED** - see the status block below;
everything is in the working tree and uncommitted.

## Status

All five phases landed on 2026-09-16. The full contract now lives in
`assessments_be_v2/docs/ETP_KNOWLEDGE_BASE.md` §4.1a, which is the document to
read; this note is kept for the reasoning and the options that were rejected.

| Phase | What landed |
|---|---|
| 1 renderer | `assessments_be_v2/services/form_json_template.py` |
| 2 route | `GET /api/v1/forms/template/json` in `controllers/api/forms.py` |
| 3 sheet | `lib/assessment/widgets/form_import_sheet.dart`, wired at `form_studio_screen.dart:_import`; `ApiClient.formTemplate`, `AppStore.downloadFormTemplate`, `downloadJsonText` in `lib/services/json_export.dart` |
| 4 tests | `assessments_be_v2/tests/test_form_template.py` (23 tests), `test/assessment/form_template_test.dart` (10 tests), fixture `test/assessment/payloads/form_template.json` captured over real HTTP, capture wired into `tool/capture_payloads.py` |
| 5 doc | knowledge base §4.1a, and its entry in the Contents list |

### After the review round

An adversarial audit plus a real-browser pass over the running stack turned up
five more things, all now fixed:

1. **The sheet's Import button could never be pressed.** `showSheet` puts
   `actions` in a footer that is a SIBLING of `body`, so the `StatefulBuilder`
   around the body never rebuilt it and `picked == null` was evaluated once, at
   open. Choosing a file lit a green "Selected" badge above a dead button. The
   SAME bug was already shipping in `import_sheet.dart`, so bank, generator and
   tag import were dead too - fixed in both with a `ValueNotifier`, and pinned
   by `test/assessment/import_sheets_enable_their_button_test.dart`, which was
   confirmed to fail (2 failures) against the old construction. It survived
   because hot reload marks every element dirty, so it is invisible under
   `flutter run` and only real in a release build.
2. **The template leaked authoring guidance to candidates.** Each kind's `hint`
   went into `help`, and `help` becomes the published question's candidate-facing
   `description` - and for a `textBlock`, the next question's lead text. Publish
   never inspects `help`, so nothing would have said so. The guidance moved to
   `_note`, which both parsers drop; `help` is now blank like every other slot.
3. **A blank-titled item could not be identified in the refusal.** Found by
   importing the template in a browser and pressing Publish: four lines all read
   `"Untitled question" (section "2. Choices, grids and scales")` against seven
   blank items. `_where` now falls back to the item's position in its section,
   threaded through `validate_structure`'s one-item re-walk so per-item
   attribution still matches what publish emits. Ten distinct lines now.
4. `kFormImportMaxBytes` was a second copy of `kMaxFormStructureBytes`. Deleted.
5. An oversized file now disables Import in the sheet rather than closing it and
   toasting the refusal afterwards.

Plus: a non-Admin 403 test on the route, a flags-coverage test, and the
documentation counts this change made stale across both repos.

### Verified

Backend `0 failed, 0 error(s) of 1671 tests`; client `1639 tests, all passed`;
`flutter analyze` clean - the numbers AT THE TIME OF THIS CHANGE. The suites have
grown since: as of 2026-09-18 the backend is `0 failed, 0 error(s) of 1869
tests`, the client is 1,826 passed on the VM and 1,276 on Chrome, and
`dart analyze lib/ test/` is clean. End-to-end in headless Chrome against the running
stack: sign in, Form Studio, Import, Download template (7,477 bytes on disk, 15
kinds, `help` empty, `_note` on every item), choose that file through the real
picker, Import, designer shows 14 questions across 3 sections, Publish returns
422 with one line per gap. Zero console errors, zero failed requests.

### Known, not fixed

`showSheet`'s footer emits no accessibility nodes on Flutter web - the
framework's own semantics tree has them in a widget test, so it is in the
engine's DOM projection rather than the widget code. It affects EVERY sheet in
the app (confirmed on the Question Bank sheet: 49 semantics nodes, only "Choose
a File"), predates this change, and wants its own investigation.

**Deviation from the plan as written, found while building.** The plan's Phase 4
listed "every question item reports a problem". That is not true, and the test
asserts the truth instead: `textBlock`, `imageBlock` and `videoBlock` correctly
report NOTHING - the first is informational, and a blank media block is a plate
with no option label, so it is not yet a question to complain about. Twelve of
the fifteen kinds name their own gap; the three that stay quiet are named in the
test with the reason, so a change to either side fails rather than drifts.

The manifest version was deliberately NOT bumped: that happens on a push to
stage, not during local work.

---


**The ask**: when an operator clicks **Import** in Form Studio, offer them a JSON
template, along the lines of `form-studio-every-permutation.json`.

**Decided with Chakshu, 2026-09-16**: the template is a **structure**, not a set
of questions. It carries one empty item of every element kind, with every slot
that kind can fill present and blank. The author writes the question text, the
golden answers and the mandatory fields themselves. It is therefore NOT expected
to publish as-is.

**The answer in three lines.** Generate the skeleton on the backend from
`constants.FORM_ITEM_KINDS` - the catalogue that already declares, per kind, both
the slots it needs (`needs`) and a sentence of authored guidance (`hint`) - serve
it at `GET /api/v1/forms/template/json`, and have the Form Studio Import sheet
download it. Nothing is hand-authored, so nothing can rot: a kind added to the
catalogue appears in the template with no edit, and the suite fails if it does
not.

---

## 1. What clicking Import does today

| Step | Where |
|---|---|
| Button, tooltip, `Importing...` label | `lib/assessment/screens/admin/form_studio_screen.dart:232-239` |
| Opens the OS file picker immediately, `.json,application/json` | `form_studio_screen.dart:89-90`, `lib/services/file_pick_web.dart:21-70` |
| Parses on the client | `AppStore.importForm` `lib/assessment/state/app_store.dart:1573-1618` -> `formFromImportedJson` `lib/assessment/domain/form_models.dart:806-872` |
| Persists the resulting draft | debounced POST to `/api/v1/forms/save` (`app_store.dart:1440-1452`) |
| Navigates into the designer | `form_studio_screen.dart:101` |

**There is no sample, no template, no schema help anywhere in Form Studio.** The
only copy near the button is the page subtitle and the empty state.

**The file never reaches Odoo.** There is no `/api/v1/forms/import` and no
`/api/v1/forms/export` route - the seven `/forms/*` routes are `save`, `delete`,
`publish`, `media`, `media/import`, the public `media/<key>` reader and the list.
Form Studio's import is entirely client-side.

An **Export** already exists per row (`form_studio_screen.dart:115-127`), and
`import(export(x))` is pinned by `test/assessment/form_import_test.dart:185-275`.
So the format is already a real, round-tripping interchange format. What is
missing is a way to get a **first** file without owning a form already.

---

## 2. The two contracts, and which one a structure template answers to

**Contract A - the Dart parser** (`form_models.dart:806-872`). Extremely
permissive. It refuses exactly four things:

* not an object or a list -> `That file is not a form: expected a JSON object with a "sections" list, or a bare list of sections.`
* no `sections` list -> `That file has no "sections" list, so there is no form in it.`
* `sections: []` -> `That form has no sections, so there would be nothing to edit.`
* `sections` with no object in it -> `The "sections" list does not contain any sections.`

plus a 512 KB cap checked before decode (`app_store.dart:1577-1583`). Everything
else is absorbed: an unknown `kind` becomes `shortAnswer` **with no warning**
(`form_models.dart:135-140`), malformed sub-objects are dropped by `whereType`,
missing keys take defaults.

**Contract B - the Python publish gate** (`models/studio_form.py:493-528`,
`_item_spec`). Strict. Every question needs an answer key of the right shape:

| Kind | Key it demands | Refusal if missing |
|---|---|---|
| `multipleChoice` / `dropdown` / `checkboxes` | >=2 labelled options, >=1 `correct`, exactly one unless checkboxes | `no option is marked correct - set the answer key in the designer.` (`:686`) |
| `choiceGrid` / `checkboxGrid` | every row keyed in `grid_key`; one column per row for `choiceGrid` | `rows without an answer key: %s.` (`:734`) |
| `linearScale` / `rating` | `golden_answer` a digit string inside range | `set the correct value (%s-%s) as the golden answer...` (`:771`) |
| `shortAnswer` / `paragraph` | non-empty `golden_answer`, **mandatory** | `write the golden answer - the model answer the judge marks against.` (`:795`) |
| `imageBlock` / `videoBlock` with options | `media_url` + the choice rules | `the question has no media.` (`:812`) |
| `comparePair` | `media_url` + `media_url_b` + one correct verdict; `golden_answer` when `require_justification` | `an A/B comparison needs both images.` (`:838`) |
| `imageAnnotation` | `media_url` + points + a `golden_labels` entry for **every** point | `every point needs a golden answer... Missing: %s.` (`:948`) |
| `promptWriting` | `media_url` + `golden_answer`; axes optional but >=2 options and one correct if present | `write the golden prompt...` (`:1006`) |
| `fileUpload` | never publishable | `file-upload questions cannot be delivered in the exam pipeline` (`:601`) |

`/api/v1/forms/save` validates nothing beyond "is a list" and the size cap
(`controllers/api/forms.py:94-121`). Publish is the only gate.

**A structure template answers to Contract A, and turns Contract B into a
checklist.** It must import without a single kind silently degrading. It will
NOT publish - and that is the designed behaviour, because publish already
answers 422 with a `problems` array naming every gap
(`controllers/api/forms.py:148-177`). So: import the template, hit Publish, and
the product itself tells the author exactly which slots are still blank. That
feedback loop already exists; the template plugs into it rather than duplicating
it.

---

## 3. Why the permutation fixture is not the template

`/Users/cj/Developer/form-studio-every-permutation.json` - 5 sections, 31 items,
15 kinds, 25 distinct item keys, 20 KB. A good QA fixture, the wrong artifact to
hand an author - and doubly wrong now that the template is a structure:

1. **It is full of authored content**, which is precisely what the author is
   meant to supply. Three items are titled `ADVERSARIAL: ...`, two
   `SUBSTITUTE ME - ...`, and their `help` is commentary aimed at whoever is
   verifying the media classifier. `help` is candidate-facing.
2. **It only publishes if it passes through the Flutter app first.** Its
   `linearScale` carries `scale_golden: 5` and its `rating` carries
   `rating_golden: 5`, with no `golden_answer`. Verified: neither name appears
   anywhere in `models/studio_form.py`; the scale branch reads `golden_answer`
   only (`studio_form.py:770-773`). The Flutter exporter papers over it -
   `_wireGoldenAnswer` (`form_models.dart:391-395`) maps the typed field back
   onto `golden_answer` at `toJson` time. See D-a in §7.
3. **`"required": true` on all 31 items.** Read by Dart, drawn in the designer,
   never read by `studio_form.py`.
4. **Six third-party image URLs.** Images are fetched at publish -
   `_fetch_media_b64`, `requests.get(timeout=20)` behind the SSRF gate, with a
   content-type check (`studio_form.py:1270-1376`). A skeleton with empty
   `media_url` makes no outbound request at all.
5. **It cannot cover three backend kinds.** `constants.py:289-387` defines 18;
   the Flutter enum has 15. `date`, `time` and `fileUpload` were retired on the
   client (`form_models.dart:129-133`) and silently degrade to `shortAnswer`.

What it gets **right**, and the skeleton should copy: `grid_key` uses **0-based
row indices as strings**, exactly what `studio_form.py:731` reads (`key.get(str(i))`
over `enumerate(rows)`); and `regions` use the `{n, x, y, w, h}` fractional shape
both sides accept.

Keep the fixture as a fixture - a QA artifact for the media classifier and the
carry rules.

---

## 4. What the template contains

**One item per element kind, empty, with every slot that kind can carry present
and blank.** Three sections grouped by family. No answer keys, no question text,
no media URLs.

Each kind's `needs` tuple in `constants.FORM_ITEM_KINDS` already says which slots
to seed, and `form_item_editor.js:571-611` (`newItem`) already implements exactly
that seeding for the Odoo editor's **Add question** button. The template is that
same function, rendered to a file. An imported template item is then indistinguishable
from what the designer produces when you add a question of that kind - which is
the property that makes it a template rather than a second opinion.

Document level:

```json
{
  "title": "Form import template",
  "internal_name": "Template - every question kind",
  "description": "One empty item of every kind Form Studio can author. Fill in the titles, the options and the golden answers, delete what you do not need, then import it.",
  "shuffle_questions": false,
  "sections": [ ... ]
}
```

`id`, `published` and `updated_at` are omitted: the importer re-mints every `id`
(`form_models.dart:755-781`), forces `published: false` (`:861`) and resets
`updated_at` on save. Keys the file cannot influence do not belong in a document
that teaches the format.

### The `needs` token -> seeded keys mapping

| Token | Kinds carrying it | Seeded into the template item |
|---|---|---|
| `options` | the 3 choice kinds, `imageBlock`, `videoBlock`, `comparePair` | `"options": [{"label": "", "correct": false}, {"label": "", "correct": false}]` - two, because one option is not a choice and publish says so |
| `options_optional` | `promptWriting` | same two blanks, with a `help` line saying the axes are optional |
| `grid` | `choiceGrid`, `checkboxGrid` | `"rows": ["", ""]`, `"columns": ["", ""]`, `"grid_key": {}` - **plain strings**, because `_item_spec` coerces with `str(...)` and a dict would become a column labelled with its own source code |
| `multi_key` | `checkboxes`, `checkboxGrid` | nothing extra; it is what makes several `correct` flags legal |
| `scale` | `linearScale` | `"scale_min": 1, "scale_max": 5, "scale_min_label": "", "scale_max_label": ""` |
| `rating` | `rating` | `"rating_max": 5` |
| `golden` / `golden_optional` / `golden_point` | written kinds, `comparePair`, `promptWriting`, both scales | `"golden_answer": ""` - note this covers the two scale kinds, which is what sidesteps D-a on this path |
| `media` | 5 media kinds | `"media_url": ""` |
| `media_b` / `media_b_optional` | `comparePair` / `promptWriting` | `"media_url_b": ""` |
| `regions` | `imageAnnotation` | `"annotation_count": 1`, `"golden_labels": {}` |
| flags | `multi_select` (`imageBlock`/`videoBlock`), `require_justification` (`comparePair`) | seeded `false` |

**Two deliberate divergences from `newItem`,** both to be named in code with the
reason:

* **Optional slots are seeded here and not there.** `newItem` skips
  `media_b_optional` and `options_optional`, so the Odoo editor's blank
  `promptWriting` has no `media_url_b`. A template that hides that slot cannot
  teach the reference-then-output transform shape, which is one of the least
  guessable parts of the format.
* **`allow_other` is not seeded**, although it is a declared flag on the three
  choice kinds. Publish drops it with a warning (`studio_form.py:693-695`), so
  seeding it would teach a dead field.

**`help` carries the catalogue's own `hint`.** Every entry in `FORM_ITEM_KINDS`
already has a sentence of authored guidance - `"Every row needs exactly one
correct column - a row with two is refused, because a radio row can never match
that key."` and so on. Putting it in the item's `help` makes the template
self-documenting inside the designer, and means the guidance has exactly one
home. The author overwrites it along with the title.

**Excluded kinds**: `date` and `time` (Flutter retired them; they would import as
`shortAnswer` with no warning) and `fileUpload` (role `refused` - one of them
refuses the whole form). Named in an explicit skip list so the exclusion is a
decision on the record, not an omission.

---

## 5. Three ways to build it

| | A. Bundle a static asset | B. Build it in Dart | C. Generate it on the backend |
|---|---|---|---|
| Where it lives | `assets/form_template.json` | a `formImportTemplate()` beside `formSample()` (`form_models.dart:893`) | `services/form_json_template.py`, rendered from `constants.FORM_ITEM_KINDS` |
| How the button gets it | `rootBundle.loadString` | `downloadJson(...)`, already in `lib/services/json_export.dart` | `GET /api/v1/forms/template/json` -> `downloadJson` |
| Works offline | yes | yes | no (`downloadImportTemplate` already answers "Templates come from the server") |
| Cost | ~15 lines | ~80 lines Dart | ~90 lines Python + ~60 lines Dart |
| Source of the kind list | a copy | a second copy (the Dart enum) | **the catalogue itself** |
| A kind added to `constants.py` | silently missing | silently missing | appears automatically; the coverage test fails if it cannot be seeded |

**C, as chosen.** The deciding row is the last one. `constants.FORM_ITEM_KINDS` is
already the single declaration this module is built around - `form_item_kinds_of()`
derives the family tuples `_item_spec` branches on, precisely so "a kind ends up
in an editor's picker and in no branch of publish" cannot happen. A template is
one more consumer of that catalogue, and any template built anywhere else is a
second copy of it.

> Correction to the first draft of this note, which argued no renderer was needed
> because the template could be authored in Form Studio and exported. That held
> when the template was going to carry real questions. For a structure skeleton
> there is no content to author - the file is a pure function of the catalogue -
> so the renderer is the smaller artifact, not the larger one.

---

## 6. The plan

**Phase 1 - the renderer.** `services/form_json_template.py`, modelled on
`services/bank_json_template.py`:

* `_blank_item(kind_def)` - the `needs` -> keys mapping in §4, one branch per
  token, each naming why. Unknown token raises rather than silently seeding
  nothing, so adding a token to the catalogue cannot half-land.
* `SKIPPED_KINDS = ("date", "time", "fileUpload")` with the reason in the comment.
* `SECTIONS` - the family grouping and a one-line description each.
* `template_payload()` -> the document; `template_json()` -> `(filename, bytes)`
  through one `_dump` so the route and any future button emit the same bytes.
* Module-constant cost: no env, no ORM, no I/O.

**Phase 2 - serve it.** One route in `controllers/api/forms.py`, modelled on
`write.py:2169-2213`:

* `GET /api/v1/forms/template/json`, `auth="user"`, `@require_manager` - the same
  rung as every other template route and as `/forms/save`.
* Returns `{filename, mimetype, content}` with `content` base64, matching
  `/api/v1/bank/template/json` and `/api/v1/candidates/template`.

**Phase 3 - the Import sheet.** Replace straight-to-file-picker with a sheet,
modelled on `lib/assessment/widgets/import_sheet.dart:33-101` but client-side
(that sheet posts bytes to the server; this one must not):

* `Notice(tone: warn)` above the dropzone saying what the tooltip already says -
  every id is renewed so importing twice gives two forms, and a file claiming
  `"published": true` still arrives as a draft.
* the dropzone, `.json,application/json`
* a `Panel` titled **Question kinds** carrying `Btn('Download template', icon: Icons.download_outlined)`
  and one chip per `FormItemKind.label`, read off the local enum - which *is* the
  parser's vocabulary, so unlike `_TemplateColumns` it needs no server round trip.
* a line stating plainly that the template is a skeleton: fill in the titles,
  options and golden answers, then Publish will name anything still missing.
* `Max 512 KB` as the footnote.

New plumbing: `ApiClient.formTemplate()` (one line beside `importTemplate`,
`api_client.dart:1325`) and `AppStore.downloadFormTemplate()` - a JSON sibling of
`downloadImportTemplate` (`app_store.dart:6063`), which is CSV-hardcoded down to
its `.csv` fallback filename and cannot be reused as-is.

**Phase 4 - the tests.**

* **Coverage, backend.** Every kind in `FORM_ITEM_KINDS` is either in the
  template exactly once or in `SKIPPED_KINDS`. Adding a kind without an example
  fails the suite.
* **Seeding, backend.** For every templated kind, every token in its `needs`
  produced at least one key on the item. This is the guard that a new `needs`
  token cannot land unseeded.
* **The checklist property, backend.** `validate_structure(template_sections)`
  returns one entry per question item, each with at least one problem, and each
  problem is the kind's own "fill this in" refusal - not a crash, not a silent
  pass. This pins the designed behaviour from §2 rather than leaving it as an
  accident.
* **Parity with the Odoo editor, backend.** The template's blank item for a kind
  matches `newItem(kind)`'s seeding except for the two divergences named in §4.
  There is an AST-walking precedent for reaching into that JS:
  `tests/test_the_form_editor_speaks_the_same_kinds.py:44-99`.
* **Import, frontend.** Capture the template into `test/assessment/payloads/`
  through the existing `tool/capture_payloads.py` (`make fixtures`), then assert
  `formFromImportedJson` parses it to 15 items with every `FormItemKind` present
  and **none silently degraded to `shortAnswer`** - the one failure mode Contract
  A will not report.

**Phase 5 - the doc.** A section in `docs/ETP_KNOWLEDGE_BASE.md` beside §4.1.
Because the `hint` strings and the `needs` tokens both live in the catalogue, a
`schema_doc_markdown()` equivalent is close to free here and worth having on the
same terms §4.1 already sets: the prose is a render of the payload, and
`test_import_parity` style equality keeps it honest.

Rough size: ~90 lines Python + ~30 for the route + 2 test files; ~150 lines Dart
+ 1 test file. No migration - `etp.studio.form` has never been migrated and this
adds no field.

---

## 7. Two defects found on the way

Both deferred by Chakshu on 2026-09-16 - recorded here, not scheduled.

**D-a. `scale_golden` and `rating_golden` are invisible to publish.** The Flutter
designer writes them, `task_template._authored_key` reads them
(`models/task_template.py:415-427`), and `studio_form._item_spec` does not - a
grep for either name across `models/studio_form.py` returns nothing. A form
authored **outside** the Flutter app - by a script, by a model, or by someone
copying the permutation fixture - is refused with *"set the correct value (1-5)
as the golden answer"* while the file plainly contains the value.

This plan does not trip over it: the skeleton seeds `golden_answer: ""` on the
two scale kinds, because their `needs` carry `golden_point` and
`wantsGolden` (`form_item_editor.js:385-391`) covers it. So the template puts the
key where publish reads it. The defect still bites anything authoring a form from
the fixture's shape. The fix, when it is wanted, is a fallback to the typed field
in the scale branch when `golden_answer` is empty.

**D-b. The two designers disagree on three kinds.** `constants.py` defines 18
kinds and `form_item_kinds()` serves all 18 to the Odoo OWL editor; the Flutter
enum has 15 and maps `date`, `time` and `fileUpload` onto `shortAnswer` **with no
warning** (`form_models.dart:129-140`). A form authored in the back office with a
`date` question opens in Form Studio as a short answer and nobody is told. The
template's skip list documents the disagreement without resolving it.

---

## 8. What "done" looks like

* A Form Studio Import sheet that offers a template before it offers a file box.
* One downloaded JSON document a human can read top to bottom, fill in, and
  import - with every slot visible and empty.
* A kind added to `constants.FORM_ITEM_KINDS` cannot ship without appearing in
  the template or being named in the skip list.
* Importing the template degrades no kind, and publishing it names every gap.
