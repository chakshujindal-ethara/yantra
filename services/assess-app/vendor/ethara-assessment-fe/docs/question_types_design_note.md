# Question types: where they stand, and what a DB-backed system would take

Status: design note only. Nothing in this document is implemented; it exists
so the DB-backed option can be picked up later without re-deriving the
tradeoffs from scratch.

## What Phase 1 + 2 already delivered (implemented, shipped)

Before this work, "add a new question type" meant finding and extending
**four separate switch statements across two files**:
`form_item_editor.dart._itemBody` (the designer's editing UI), and
`form_preview.dart._seedFromKeys` / `_answered` / `_input` (seeding the
answer key, checking "is this filled in", and drawing the respondent's
input). Each was a `switch (it.kind)` with no shared structure between the
four - easy to update three and forget the fourth.

That is now **one registry per file**, each a `Map<FormItemKind, ...>` built
once from the same methods that always drew that kind (no widget, string, or
behaviour changed - verified by the full suite passing unchanged on both the VM
and Chrome runners; that suite was 935 tests then, was 1,130 on the VM when this
note was written, and is **1,826** on the VM today - **1,276** on Chrome, where
the 74 `@TestOn('vm')` tests do not load). Adding a new kind today is:

1. Add the value to the `FormItemKind` enum (`domain/form_models.dart`).
2. Write its editor-body method and register it in `form_item_editor.dart`'s
   `_bodyRegistry`.
3. Write its seed / answered / input logic and register each in
   `form_preview.dart`'s three registries.

Four edits, all additive, none of them a search through an existing switch.
That is the ceiling of what a **code-level** registry can promise - a
developer is still required, but they can no longer break an existing kind
by mis-editing a shared switch, and nothing forces them to hunt for the
other three spots a new kind needs.

Phase 2 also confirmed and then fixed the "usable anywhere" half: both
`FormItemEditor` (the block) and `FormPreview` were already shared between
Form Studio and the Task Template editor (`TaskTemplateEditor` passes
`form: null` and every section/branch control degrades correctly). The one
real coupling - three consumers importing the shared `FormTextInput` widget
from `form_designer_screen.dart`, a concrete screen, rather than from
`widgets/`, was found and removed. Both blocks now depend only on `domain/`
(pure data), `widgets/` (shared UI), `state/app_store.dart` (app-global), and
`screens/exam/` (media players, also shared with the exam runner) - never on
a specific screen.

**What landed on top of this registry afterwards** (September 2026, shipped):
the item card's own chrome, not its body. A question card now carries the four
affordances a SECTION card always had - collapse/expand, drag to reorder,
duplicate and delete - in a section header's order, in the header rather than a
footer that scrolled out of sight, with delete behind a confirm sheet and
duplicate toasting. None of it touched `_bodyRegistry` or the three
`form_preview.dart` registries, which is the point: the registry describes what
a kind IS, and the chrome is the same for every kind. `form_item_parity_test.dart`
pins the shared contract and measures the two cards' control rows against each
other geometrically.

## What this does NOT deliver: a no-code new type

The steering ask also raised a sidebar tab where a new question type could
be defined from the UI and persisted to the database, so that adding a type
needs no redeploy. That is a materially different system from the registry
above, and was deliberately **not built** in this phase - see the
conversation's Option A / Option B split for why.

### Option A - types as data, fully generic

A new type is defined in the sidebar as a **composition of primitives**
(short text, single/multi choice, numeric scale, star rating, file, grid)
plus metadata (label, icon, category, whether it carries an answer key and
what shape that key is). The registry resolves `{primitive + config}` to the
same Flutter widgets Phase 1 already builds. No Flutter code is ever written
for a new type.

What this actually requires:

- A **schema language** for composing primitives - validation rules,
  required-ness, answer-key shape, how scoring reads that key - expressive
  enough to cover what a hand-written kind covers today (compare the
  `imageAnnotation` kind's marker-drawing UI or the grid's row/column answer
  key: these are not simple field compositions).
- A **runtime interpreter** for that schema in Flutter, replacing the
  current per-kind Dart widgets with one generic renderer driven by config.
- **Backend storage** in `assessments_be_v2` - a new Odoo model, migration,
  and API surface (`/api/v1/question_types` or similar) to store and serve
  type definitions, with versioning (a type definition used by an already-
  launched assessment cannot change retroactively under sitting candidates).
- **Every consumer of `FormItemKind` migrated** off the closed Dart enum to
  read types dynamically: Form Studio, the Task Template editor, the exam
  runner (rendering the respondent's actual input), CSV import/export, and
  the LLM grading pipeline (which needs to know a type's answer-key shape to
  grade it at all).

This is a multi-week build that reaches into the exam-taking runtime and the
scoring pipeline - production surfaces where a wrong migration is very hard
to walk back once candidates have sat exams against a dynamically-defined
type. Recommended: **not now**, and not without a dedicated design pass on
the schema language itself, which is the hard part.

### Option B - types as metadata, still hand-built

The sidebar screen registers a new type's **metadata** (key, label, icon,
category) in the database for discoverability, but a developer still writes
the Dart widget for its actual input UI and registers it in the Phase 1
registries above. The DB row makes the type *listed* everywhere; it does not
make it *render* without a code change.

This was also **not built**, on the reasoning that it adds an Odoo model,
API, and sidebar CRUD screen without removing the actual bottleneck (someone
still writes the widget) - real work for a thin slice of the stated goal.

## Recommendation

Hold both options. The Phase 1 + 2 registry is the concrete, low-risk win
that was actually asked for and can be exercised today by a developer. If
new question types turn out to be needed often enough that the *code-level*
friction Phase 1 already removed is still the bottleneck (not just the
per-file friction that existed before), that is the trigger to revisit
Option A with a proper schema-language design session - not Option B, which
would be built and then likely rebuilt once Option A's real requirements are
understood.
