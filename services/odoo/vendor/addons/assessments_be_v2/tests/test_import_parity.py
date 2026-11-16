# -*- coding: utf-8 -*-
"""One import spec, whichever UI you drop the file in.

THE DEFECT. Questions could be imported from both surfaces and the two did not
agree. Odoo's wizard reads a THIRTY-THREE column CSV - title, question_type,
dim1..dim4_{label,options,correct}, rubric_json, official_reasoning,
img1..img3_{slot,label,url} - while the Flutter client converted CSV itself with
a SIX column Dart parser and posted JSON. Feed the template Odoo hands you to
the app and the dimensions, the rubric and the images were dropped in silence:
the import reported success and the questions arrived hollow.

Tags and generators had it worse. Odoo offered stock `base_import` (free-form
field mapping, which nothing outside Odoo can replicate) and the app offered
nothing, so "the same file gives the same result" was not even expressible.

What is asserted here:

  * the Odoo template round-trips through the importer with every column
    intact - dimensions, answer key, rubric and images;
  * the API's file lane and the back-office button are the SAME code, so they
    cannot drift;
  * tags and generators upsert rather than duplicate, which is what makes a
    corrected re-run safe.
"""
import base64
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase

from ..models import bank_import_wizard as wizard_module
from ..models import simple_import
from ..services import bank_json_template as json_template


def _b64(text):
    return base64.b64encode(text.encode("utf-8")).decode()


#: Which draft field each documented harness path has to land in. Read by
#: `_assert_every_demonstrated_field_landed`, which walks the TEMPLATE and looks
#: each path up here - so a path the template demonstrates with no entry here is
#: a KeyError rather than a silent pass.
_HARNESS_PATH_TO_DRAFT_FIELD = {
    "questions[].id": "gen_batch",
    "questions[].instruction": "question_prompt",
    "questions[].covers_elements": "covers_elements_json",
    "questions[].fields.question_type": "question_type",
    "questions[].fields.difficulty": "difficulty",
    "questions[].fields.options": "options_json",
    "questions[].fields.correct_answer": "correct_answer_json",
    "questions[].fields.rubric": "rubric_json",
    "questions[].fields.official_reasoning": "official_reasoning",
    "questions[].assets": "images_json",
    "solutions.<id>.answers": "solution_json",
    "solutions.<id>.rationale": "solution_rationale",
}

#: Same idea for the native export's keys. `generator`, `dimensions` and
#: `images` land as relations rather than as a scalar of the same name.
_NATIVE_KEY_TO_QUESTION_FIELD = {
    "name": "name",
    "prompt": "prompt",
    "description": "description",
    "question_type": "question_type",
    "difficulty": "difficulty",
    "time_minutes": "time_minutes",
    "sequence": "sequence",
    "source_ref": "source_ref",
    "official_reasoning": "official_reasoning",
    "subjective_rubric_json": "subjective_rubric_json",
    "grading_json": "grading_json",
    "meta_json": "meta_json",
    "generator": "generator_id",
    "dimensions": "question_dimension_ids",
    "images": "image_ids",
}


def _harness_paths(template):
    """The paths the template ACTUALLY demonstrates, in `HARNESS_FIELDS` notation."""
    paths = set()
    for question in template["questions"]:
        for key, value in question.items():
            if key == "fields":
                paths.update("questions[].fields.%s" % f for f in value)
            else:
                paths.add("questions[].%s" % key)
    for solution in template["solutions"].values():
        paths.update("solutions.<id>.%s" % key for key in solution)
    return paths


class TestTheQuestionImportSpecIsShared(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Wizard = self.env["assessments.be.bank.import.wizard"]

    def _import(self, csv_text, name=None):
        return self.Wizard.create({
            "data_file": _b64(csv_text),
            "data_filename": "bank.csv",
            "generator_name": name or "Import %s" % uuid4().hex[:6],
        }).run_import()

    def test_the_template_odoo_hands_out_imports_without_losing_a_column(self):
        """THE regression, driven through the exact file an operator downloads.

        `build_template_csv` is what the Download Template button emits, so a
        change that added a column the importer cannot read would fail here
        rather than at somebody's desk.
        """
        result = self._import(wizard_module.build_template_csv())

        self.assertEqual(result["format"], "csv")
        self.assertGreater(result["questions_created"], 0)

        # W9: every row waits in Pending Approvals; the reviewer's approval is
        # what puts it in the bank, and the key has to survive that.
        generator = self.env["assessments.be.prompt"].browse(
            result["generator_id"])
        generator.question_ids.action_approve()
        questions = self.env["assessments.be.question"].search(
            [("generator_id", "=", generator.id)])
        self.assertTrue(questions, "the template produced no questions at all")

        # The columns the six-column client parser had no way to carry.
        self.assertTrue(
            questions.mapped("question_dimension_ids"),
            "no question kept a dimension - the answer key was dropped")
        self.assertTrue(
            questions.question_dimension_ids.option_line_ids.filtered(
                "is_correct"),
            "no option came back marked correct - the key is gone")

    def test_multi_dimension_and_image_columns_survive(self):
        """The two column families that only exist in the wide spec."""
        header = ",".join(wizard_module.import_columns())
        row = {
            "title": "Two part question",
            "question_type": "mcq",
            "prompt": "Answer both parts.",
            "difficulty": "easy",
            "dim1_label": "Part one",
            "dim1_options": "Alpha|Bravo",
            "dim1_correct": "Alpha",
            "dim2_label": "Part two",
            "dim2_options": "Charlie|Delta",
            "dim2_correct": "Delta",
            "img1_slot": "a",
            "img1_label": "The frame",
            "img1_url": "https://example.invalid/frame.png",
        }
        line = ",".join(
            '"%s"' % row.get(column, "").replace('"', '""')
            for column in wizard_module.import_columns())

        result = self._import("%s\n%s\n" % (header, line))

        self.env["assessments.be.prompt"].browse(
            result["generator_id"]).question_ids.action_approve()
        question = self.env["assessments.be.question"].search(
            [("generator_id", "=", result["generator_id"])], limit=1)
        self.assertTrue(question)
        dims = question.question_dimension_ids
        self.assertEqual(
            len(dims), 2,
            "an indexed dim2_* column was dropped, so a two-part question "
            "arrived worth one mark")
        self.assertEqual(
            sorted(dims.mapped("name")), ["Part one", "Part two"])
        self.assertEqual(
            sorted(dims.option_line_ids.filtered("is_correct").mapped("name")),
            ["Alpha", "Delta"],
            "the answer key did not survive the indexed columns")
        # The picture arrives as the draft's `images_json`; turning that into
        # `question.image_ids` happens on approval and only for the types that
        # carry pictures, which is not what this test is about. What IS is that
        # the img1_* columns were read at all - the six-column client parser
        # had no idea they existed.
        draft = self.env["assessments.be.prompt.question"].search(
            [("prompt_id", "=", result["generator_id"])], limit=1)
        self.assertIn(
            "frame.png", draft.images_json or "",
            "an img1_* column was dropped, so the picture never arrived")

    def test_the_api_and_the_button_run_the_same_importer(self):
        """A SOURCE assertion, and the cheapest guard against the whole bug.

        The defect was never a wrong column list - it was that there were TWO
        implementations, so any change to one silently un-matched the other.
        `action_import` renders; `run_import` does the work; the route calls
        `run_import`. If a future edit gives the route its own parsing, this is
        what says so.
        """
        import inspect

        from ..controllers.api import write as write_api

        route = inspect.getsource(write_api.EtpAssessmentApiWrite._bank_import_file)
        self.assertIn("assessments.be.bank.import.wizard", route)
        self.assertIn("run_import()", route)

        button = inspect.getsource(
            self.Wizard.__class__.action_import)
        self.assertIn("run_import()", button)
        self.assertNotIn(
            "_parse_rows", button,
            "the button must not parse on its own - that is what run_import "
            "is for, and a second parser is the bug this file is about")

    def test_a_bad_row_names_itself(self):
        """The importer's row-numbered refusal is the only part an operator can
        act on, so it has to reach them rather than being replaced by a generic
        failure."""
        # `title` OR `prompt` makes the file recognisable, so a wrong file has
        # to be missing both - one of them alone is a valid, if sparse, import.
        with self.assertRaises(UserError) as caught:
            self._import("colour,size\nred,large\n")

        self.assertIn("title", str(caught.exception))

    # ── D4: the same guarantee for the two JSON paths ────────────────────
    #
    # The CSV template above is round-tripped through the real importer, which
    # is what has kept it honest. JSON had no template at all, so there was
    # nothing to round-trip and the format had to be guessed from the parser.
    # These do for JSON exactly what `test_the_template_odoo_hands_out...` does
    # for CSV: a parser change that breaks the template fails the suite here
    # rather than at somebody's desk.

    def _wizard(self, payload_bytes, filename, name=None):
        return self.Wizard.create({
            "data_file": base64.b64encode(payload_bytes).decode(),
            "data_filename": filename,
            "generator_name": name or "JSON Import %s" % uuid4().hex[:6],
        })

    def _attachment_bytes(self, action):
        """The bytes behind an `ir.actions.act_url` download action."""
        self.assertEqual(action["type"], "ir.actions.act_url")
        att_id = int(action["url"].split("/web/content/")[1].split("?")[0])
        return self.env["ir.attachment"].browse(att_id).raw

    def _assert_landed(self, record, field, path, qid):
        value = record[field]
        self.assertTrue(
            value,
            "%s demonstrates %s but %s.%s came back empty - the template and "
            "the parser have drifted apart"
            % (qid, path, record._name, field))

    def test_the_harness_json_template_imports_itself(self):
        """THE D4 regression. The harness path has no exporter, so its template
        is hand-authored - which is exactly the kind of file that rots. Driven
        through the wizard, so the fingerprint, the parser and the field mapping
        are all the real ones."""
        _fname, payload = json_template.harness_template_json()
        result = self._wizard(payload, "questions.json").run_import()

        self.assertEqual(
            result["format"], "harness",
            "the harness template was not recognised as harness - "
            "_try_harness_payload's fingerprint no longer matches it")
        template = json_template.HARNESS_TEMPLATE
        self.assertEqual(result["questions_created"], len(template["questions"]))

        drafts = self.env["assessments.be.prompt.question"].search(
            [("prompt_id", "=", result["generator_id"])])
        self.assertEqual(len(drafts), len(template["questions"]))

        # Walk the TEMPLATE, not a hand-written list of expectations: every
        # field it demonstrates has to land somewhere non-empty.
        for question in template["questions"]:
            qid = question["id"]
            draft = drafts.filtered(
                lambda d, q=qid: d.gen_batch == "harness:%s" % q)
            self.assertEqual(
                len(draft), 1,
                "no draft carries gen_batch harness:%s - the id did not survive"
                % qid)
            paths = {"questions[].%s" % k for k in question if k != "fields"}
            paths |= {"questions[].fields.%s" % k
                      for k in question.get("fields") or {}}
            paths |= {"solutions.<id>.%s" % k
                      for k in template["solutions"].get(qid) or {}}
            for path in sorted(paths):
                self._assert_landed(
                    draft, _HARNESS_PATH_TO_DRAFT_FIELD[path], path, qid)

        # The asset is an http(s) URL on purpose: `_apply_harness_assets` only
        # auto-attaches those, and a local path would have demonstrated the
        # warning path instead of the working one.
        self.assertFalse(
            [w for w in result["warnings"] if "not auto-attached" in w],
            "the template's own asset was refused: %s" % result["warnings"])

    def test_the_native_json_template_imports_itself(self):
        """The native template is EXPORTED rather than authored, so this asserts
        the round trip closes: `_export_native` -> `import_bank_native` -> the
        same values back on a live question."""
        _fname, payload = json_template.native_template_json(self.env)
        # The flag the back office's Restore into the bank button sends.
        result = self._wizard(payload, "bank.json").with_context(
            confirm_native_restore=True).run_import()

        self.assertEqual(
            result["format"], "native",
            "the native template lost its `assessments_be_bank` sentinel")
        self.assertEqual(result["questions_created"], 1)
        self.assertFalse(result["warnings"], result["warnings"])

        exported = json_template.native_template_payload(
            self.env)["questions"][0]
        question = self.env["assessments.be.question"].search(
            [("source_ref", "=", exported["source_ref"])], limit=1)
        self.assertTrue(question, "the native import created nothing findable")

        for key, value in exported.items():
            if not value:
                continue
            self._assert_landed(
                question, _NATIVE_KEY_TO_QUESTION_FIELD[key], key, "native")

        # The two relations are the lossy part of any bank move, so they get
        # their own assertions rather than a truthiness check.
        self.assertEqual(
            question.generator_id.name, exported["generator"],
            "`generator` did not create or match a generator by name")
        self.assertEqual(
            question.question_dimension_ids.option_line_ids.filtered(
                "is_correct").mapped("name"),
            [o["name"] for o in exported["dimensions"][0]["options"]
             if o["is_correct"]],
            "the answer key did not survive the native round trip")
        self.assertEqual(
            question.image_ids.mapped("image_url"),
            [i["image_url"] for i in exported["images"]])

    def test_each_json_template_goes_to_its_own_parser_and_not_to_csv(self):
        """The fingerprints are load-bearing. A template that falls through to
        the CSV path is refused for having no header row, so 'the wrong parser'
        and 'a broken template' look identical to an operator."""
        harness = self._wizard(
            json_template.harness_template_json()[1], "questions.json")
        native = self._wizard(
            json_template.native_template_json(self.env)[1], "bank.json")

        self.assertIsNotNone(
            harness._try_harness_payload(),
            "the harness template is not recognised as harness")
        self.assertIsNone(
            harness._try_native_payload(),
            "the harness template also matches the NATIVE fingerprint - the "
            "two are no longer distinguishable")
        self.assertIsNotNone(
            native._try_native_payload(),
            "the native template is not recognised as native")
        self.assertIsNone(
            native._try_harness_payload(),
            "the native template also matches the HARNESS fingerprint, and "
            "harness is sniffed FIRST - it would import as drafts")

        # And the CSV template must not have become JSON-shaped, which would
        # silently move it off the parser that has always read it.
        csv_wizard = self.Wizard.create({
            "data_file": _b64(wizard_module.build_template_csv()),
            "data_filename": "bank.csv",
        })
        self.assertIsNone(csv_wizard._try_harness_payload())
        self.assertIsNone(csv_wizard._try_native_payload())

    def test_the_api_and_the_button_hand_out_the_same_json_bytes(self):
        """Two surfaces, one file. The CSV template's equivalent guard is
        `test_the_api_and_the_button_run_the_same_importer`; this is the
        download half of it."""
        import inspect

        from ..controllers.api import write as write_api

        for flavor in json_template.FLAVORS:
            wizard = self._wizard(b"[]", "unused.json")
            button = self._attachment_bytes(
                wizard.with_context(json_flavor=flavor)
                .action_download_json_template())
            route = base64.b64decode(
                json_template.template_api_payload(
                    flavor, env=self.env)["content"])
            self.assertEqual(
                button, route,
                "the %s template differs between the wizard button and the "
                "API payload" % flavor)

        # A SOURCE assertion, for the same reason the importer has one: the
        # bytes above can only be equal while both surfaces call the one
        # builder, and this is what says so if a future edit gives the route its
        # own rendering.
        source = inspect.getsource(
            write_api.EtpAssessmentApiWrite.bank_template_json)
        self.assertIn("template_api_payload", source)
        button_source = inspect.getsource(
            self.Wizard.__class__.action_download_json_template)
        self.assertIn("bank_json_template.template_json", button_source)

        # `json2` merges the JSON body with the PATH parameters and NOTHING
        # else, so `?flavor=` has to be read off `httprequest.args` explicitly.
        # Without this line the route answers every request with the harness
        # template, at 200, with no error - which is what it did on its first
        # pass. `test_bank_json_template_route.py` proves the behaviour over real
        # HTTP; this is the cheap guard that names the missing line.
        self.assertIn("httprequest.args", source)

    def test_an_unknown_json_flavour_is_refused_by_name(self):
        with self.assertRaises(UserError) as caught:
            self._wizard(b"[]", "unused.json").with_context(
                json_flavor="csv").action_download_json_template()

        self.assertIn("csv", str(caught.exception))

    def test_the_schema_doc_is_a_render_of_the_templates(self):
        """The prose cannot drift from the payload, because the prose IS the
        payload.

        The schema used to be its own file, so the check was a whole-file
        equality. The docs are now consolidated into ONE knowledge base, so the
        generator owns a delimited REGION of it instead - and the identical
        guarantee holds over that region. Everything outside the markers is
        hand-written and deliberately not compared.
        """
        self.assertEqual(
            json_template.committed_schema_doc().strip(),
            json_template.schema_doc_markdown().strip(),
            "the knowledge base's generated schema region is stale - "
            "regenerate it with "
            "services/bank_json_template.write_schema_doc()")

    def test_the_managed_region_markers_still_exist(self):
        """Without them a regeneration cannot find where to write, and the
        equality above would be comparing nothing to nothing."""
        with open(json_template.doc_path(), encoding="utf-8") as handle:
            kb = handle.read()
        self.assertIn(json_template.DOC_BEGIN, kb)
        self.assertIn(json_template.DOC_END, kb)
        self.assertLess(
            kb.index(json_template.DOC_BEGIN),
            kb.index(json_template.DOC_END),
            "the markers are inverted, so the region is empty")

        self.assertEqual(
            {f.path for f in json_template.HARNESS_FIELDS},
            _harness_paths(json_template.HARNESS_TEMPLATE),
            "the documented harness field list and the harness template "
            "demonstrate different fields")
        self.assertEqual(
            {f.path for f in json_template.NATIVE_FIELDS},
            set(json_template.native_template_payload(
                self.env)["questions"][0]),
            "the documented native field list and what `_export_native` "
            "actually emits have diverged")
        # Every documented path is also asserted to LAND somewhere, so a new
        # field cannot be documented without being round-tripped.
        self.assertEqual(
            {f.path for f in json_template.HARNESS_FIELDS},
            set(_HARNESS_PATH_TO_DRAFT_FIELD))
        self.assertEqual(
            {f.path for f in json_template.NATIVE_FIELDS},
            set(_NATIVE_KEY_TO_QUESTION_FIELD))


class TestTagImport(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Import = self.env["assessments.be.simple.import"]
        self.Tag = self.env["assessments.be.tag"]

    def _csv(self, *rows):
        header = ",".join(simple_import.TAG_COLUMNS)
        lines = [",".join(r.get(c, "") for c in simple_import.TAG_COLUMNS)
                 for r in rows]
        return _b64("\n".join([header] + lines) + "\n")

    def test_the_template_imports_itself(self):
        result = self.Import.import_tags_csv(
            _b64(self.Import.tag_template_csv()))

        self.assertGreater(result["created"], 0)
        self.assertFalse(result["warnings"])

    def test_a_second_run_updates_rather_than_duplicates(self):
        """UPSERT IS THE POINT. A vocabulary is re-typed and re-imported, and
        an importer that appended would turn a corrected re-run into a second
        copy of every tag the ranker then treats as a distinct concept."""
        name = "domain:import-test-%s" % uuid4().hex[:6]
        first = self.Import.import_tags_csv(
            self._csv({"name": name, "display": "First"}))
        second = self.Import.import_tags_csv(
            self._csv({"name": name, "display": "Second"}))

        self.assertEqual(first["created"], 1)
        self.assertEqual(second["created"], 0)
        self.assertEqual(second["updated"], 1)
        self.assertEqual(
            len(self.Tag.search([("name", "=ilike", name)])), 1,
            "the same tag was imported twice")

    def test_an_unusable_key_is_named_rather_than_swallowed(self):
        """A name made only of separators canonicalises to nothing.

        Not a blank row - one of those is skipped as empty, which is correct
        and is a different case. This is a row somebody typed something into
        that cannot become a tag, and it has to be reported rather than
        vanishing into a count that looks like a success.
        """
        result = self.Import.import_tags_csv(
            self._csv({"name": ":::", "display": "Nothing"}))

        self.assertEqual(result["created"], 0)
        self.assertTrue(
            result["warnings"],
            "an unusable key was dropped without a word")

    def test_the_wrong_file_says_so(self):
        with self.assertRaises(UserError) as caught:
            self.Import.import_tags_csv(_b64("colour,size\nred,large\n"))

        self.assertIn("name", str(caught.exception))


class TestGeneratorImport(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Import = self.env["assessments.be.simple.import"]
        self.Prompt = self.env["assessments.be.prompt"]

    def _csv(self, *rows):
        cols = simple_import.GENERATOR_COLUMNS
        header = ",".join(cols)
        lines = [",".join('"%s"' % r.get(c, "") for c in cols) for r in rows]
        return _b64("\n".join([header] + lines) + "\n")

    def test_the_template_imports_itself(self):
        result = self.Import.import_generators_csv(
            _b64(self.Import.generator_template_csv()))

        self.assertEqual(result["created"], 1)
        self.assertFalse(result["warnings"])

    def test_settings_and_allowed_types_arrive(self):
        name = "Imported gen %s" % uuid4().hex[:6]
        result = self.Import.import_generators_csv(self._csv({
            "name": name,
            "sop_title": "A title",
            "sop_question_count": "7",
            "allowed_question_types": "mcq|msq",
        }))

        generator = self.Prompt.browse(result["generator_ids"][0])
        self.assertEqual(generator.name, name)
        self.assertEqual(generator.sop_title, "A title")
        self.assertEqual(generator.sop_question_count, 7)
        self.assertEqual(
            sorted(generator.allowed_question_type_ids.mapped("code")),
            ["mcq", "msq"])

    def test_a_second_run_updates_in_place(self):
        name = "Imported gen %s" % uuid4().hex[:6]
        self.Import.import_generators_csv(
            self._csv({"name": name, "sop_title": "First"}))
        second = self.Import.import_generators_csv(
            self._csv({"name": name, "sop_title": "Second"}))

        self.assertEqual(second["created"], 0)
        self.assertEqual(second["updated"], 1)
        found = self.Prompt.search([("name", "=", name)])
        self.assertEqual(len(found), 1)
        self.assertEqual(found.sop_title, "Second")

    def test_a_partial_row_does_not_blank_what_it_omits(self):
        """A file that names three columns must not clear the other four.

        This is what makes an import safe to re-run against records somebody
        has since edited in the UI.
        """
        name = "Imported gen %s" % uuid4().hex[:6]
        self.Import.import_generators_csv(self._csv({
            "name": name, "sop_title": "Keep me", "sop_question_count": "9",
        }))
        self.Import.import_generators_csv(
            self._csv({"name": name, "sop_summary": "Added later"}))

        found = self.Prompt.search([("name", "=", name)])
        self.assertEqual(found.sop_title, "Keep me")
        self.assertEqual(found.sop_question_count, 9)
        self.assertEqual(found.sop_summary, "Added later")

    def test_an_unknown_question_type_is_reported_not_fatal(self):
        name = "Imported gen %s" % uuid4().hex[:6]
        result = self.Import.import_generators_csv(self._csv({
            "name": name, "allowed_question_types": "mcq|not_a_type",
        }))

        self.assertEqual(result["created"], 1)
        self.assertTrue(
            any("not_a_type" in w for w in result["warnings"]),
            "an unknown type must be named, not silently dropped")

    def test_an_out_of_range_label_count_is_reported_not_fatal(self):
        """`_check_image_label_count` refuses anything under 1, and a
        ValidationError mid-file would abort the whole import over one typo."""
        name = "Imported gen %s" % uuid4().hex[:6]
        result = self.Import.import_generators_csv(self._csv({
            "name": name, "image_label_count": "0",
        }))

        self.assertEqual(result["created"], 1)
        self.assertTrue(result["warnings"])
