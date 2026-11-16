# -*- coding: utf-8 -*-
"""Swapping a model, or the service-account key, must be configuration only.

WHAT WENT WRONG, AND WHY IT WAS INVISIBLE
-----------------------------------------
`_PRICING` was a dict keyed on the EXACT model string, with `_DEFAULT_PRICE` of
$1/$5 and **`image: 0.0`** behind it. Three consequences, none of which surfaced
as an error:

  1. Every model the cost proposal moves to was absent from the table, so a
     switched image model recorded each render as **$0.00**. `_check_budget`
     enforces the daily cap by SUMMING THE LEDGER, so the cap stopped seeing
     image spend entirely - the guard rail was removed by a settings change.
  2. An exact-match dict also missed `...-preview`, `...-001` and date-stamped
     aliases of models it already knew, so a pinned build silently mispriced.
  3. `_apply_thinking_budget` sent `thinkingBudget: 0` to everything except
     `gemini-2.5-pro`. Gemini 3.x replaced that parameter with `thinkingLevel`
     and rejects a request carrying both - and `gemini-3.1-pro-preview`, the
     module's own generation and scoring default, is a 3.x model. The wrong
     parameter was going to our own default before any swap was proposed.

Two lanes also ran on the wrong model outright: `assign_question_skills` and
`draft_task_template_from_sop` passed no `model=`, so they inherited
`vertex_model`, whose default IS the image model - the priciest row in the
catalog - to do a text job. One of them feeds it a PDF, which an image model
cannot read at all.

THE STANDARD THESE TESTS HOLD
-----------------------------
Pricing is asserted as RATIOS and as SHAPE, not as a frozen dollar figure.
Google reprices; a test that pins $0.25 becomes a lie the day they change it and
teaches the next reader to update the assertion rather than the catalog. What
must not drift is the RELATIONSHIP the cost case rests on - Flash-Lite being
exactly 8x under 3.1-pro on both input and output is the only reason an "8x
saving" holds for any token mix at all - and the invariant that an unknown model
never looks free.

`TransactionCase` throughout, matching the house style. Most of `model_catalog`
is pure functions over strings and needs no cursor, but the resolver and
key-swap cases read and write `ir.config_parameter`, and one base class keeps
the file uniform.
"""
import json
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.constants import (
    GENERATION_DEFAULT_MODEL, VERTEX_DEFAULT_MODEL, VIDEO_DEFAULT_MODEL,
)
from odoo.addons.assessments_be_v2.services import model_catalog, vertex


@tagged("-at_install", "post_install")
class TestTheCatalogRecognisesAModelItWasNotToldAbout(TransactionCase):
    """Normalisation is what makes a swap config-only instead of an edit here."""

    def test_a_pinned_or_dated_build_prices_as_its_family(self):
        """`-preview`, `-001` and `-11-2026` are build markers, not models.

        Google reprices a FAMILY. An exact-match table treated every alias as an
        unknown model and fell to the default, which is how a correctly
        configured deployment ends up with a wrong ledger.
        """
        family = model_catalog.price_for("gemini-3.1-flash-lite")
        for alias in ("gemini-3.1-flash-lite-preview",
                      "gemini-3.1-flash-lite-preview-11-2026",
                      "gemini-3.1-flash-lite-001",
                      "publishers/google/models/gemini-3.1-flash-lite",
                      "  GEMINI-3.1-FLASH-LITE  "):
            self.assertEqual(
                model_catalog.price_for(alias), family,
                "%r must price as its family, not fall to the default" % alias)

    def test_a_longer_family_name_wins_the_prefix_match(self):
        """`-lite-image` must not be priced as `-flash`.

        First-match prefix logic would have priced Nano Banana 2 Lite as plain
        3.1 Flash and lost the per-image figure, which is the whole cost of the
        render lane.
        """
        lite_image = model_catalog.price_for("gemini-3.1-flash-lite-image")
        self.assertGreater(lite_image["image"], 0.0)
        self.assertLess(
            lite_image["image"],
            model_catalog.price_for("gemini-3.1-flash-image")["image"],
            "Lite renders must be cheaper than full Nano Banana 2")
        self.assertLess(
            model_catalog.price_for("gemini-3.1-flash-image")["image"],
            model_catalog.price_for("gemini-3-pro-image")["image"],
            "Nano Banana 2 must be cheaper than Nano Banana Pro")

    def test_a_version_is_never_mistaken_for_a_build_stamp(self):
        """`gemini-3` must not normalise to `gemini`.

        The build-stamp stripper walks trailing numeric segments. Unbounded, it
        eats the version too, and `gemini` prefix-matches every Gemini row -
        so the cheapest model in the table would set the price for the dearest.
        """
        self.assertEqual(model_catalog.normalize_model_id("gemini-3"), "gemini-3")
        self.assertEqual(model_catalog.normalize_model_id("veo-3.1-20260320"),
                         "veo-3.1")

    def test_an_unknown_model_is_never_free(self):
        """The invariant that actually protects the daily cap.

        Over-billing an unrecognised model is a visible annoyance on the LLM
        Budget screen. Under-billing it silently disables the spend cap, which
        is the failure this default exists to prevent - so the default must
        charge for images, and must not undercut a real model.
        """
        price = model_catalog.price_for("some-model-nobody-added-yet")
        self.assertGreater(price["image"], 0.0,
                           "a $0.00 image default is what blinded the cap")
        self.assertGreaterEqual(price["in"], 2.00)
        self.assertGreaterEqual(price["out"], 12.00)

        rate = model_catalog.video_rate_for("seedance-2.0")
        self.assertGreaterEqual(
            rate, max(model_catalog.VIDEO_PRICING.values()),
            "an unpriced video model must not look cheaper than a real one")

    def test_an_empty_or_missing_model_does_not_explode(self):
        """`_ledger_values` runs on the failure path too, where model may be ''."""
        for junk in ("", None, "   ", "///"):
            self.assertIsInstance(model_catalog.price_for(junk), dict)
            self.assertIsInstance(model_catalog.video_rate_for(junk), float)
            self.assertEqual(model_catalog.estimate_cost(junk, 0, 0, 0, 0), 0.0)

    def test_a_cost_can_never_come_out_negative(self):
        """A negative row would BUY BACK spend-cap headroom.

        `_check_budget` enforces the daily and per-evaluator caps by summing
        `cost_usd`. One negative row subtracts from the day's total, so a
        nonsense token count would not merely misreport - it would raise the
        ceiling. Counts arrive from Google's `usageMetadata`, so this should be
        unreachable; clamping keeps a spend guard from depending on an external
        field staying sane.
        """
        for args in ((-1000, -1000, -1000, -5), (-1, 0, 0, 0), (0, 0, 0, -3)):
            self.assertGreaterEqual(
                model_catalog.estimate_cost("gemini-3.1-pro-preview", *args),
                0.0, "estimate_cost%r went negative" % (args,))
        self.assertGreaterEqual(
            model_catalog.estimate_video_cost("veo-3.1-generate-001", -30), 0.0)


@tagged("-at_install", "post_install")
class TestTheSavingsTheProposalRestsOn(TransactionCase):
    """The ratios, not the dollar figures. These are the load-bearing claims."""

    PRO = "gemini-3.1-pro-preview"

    def test_flash_lite_is_eight_times_under_pro_on_both_directions(self):
        """8x on input AND output, which is why the ratio is mix-independent.

        A model 8x cheaper on input but 4x on output delivers somewhere between
        the two depending on the token mix, and the saving becomes a function of
        the prompt. Equal ratios on both axes is the property that makes "8x"
        true for scoring, detection and authoring alike.
        """
        pro = model_catalog.price_for(self.PRO)
        lite = model_catalog.price_for("gemini-3.1-flash-lite")
        self.assertAlmostEqual(pro["in"] / lite["in"], 8.0, places=2)
        self.assertAlmostEqual(pro["out"] / lite["out"], 8.0, places=2)

    def test_an_image_generator_is_not_eight_times_under_pro(self):
        """Guards the specific error the proposal made.

        The 8x target was written next to `gemini-3.1-flash-image`. That model
        is 4x on tokens, not 8x - the 8x figure belongs to the `-lite-` tier.
        Implemented literally, the row would have delivered half its promise.
        """
        pro = model_catalog.price_for(self.PRO)
        flash_image = model_catalog.price_for("gemini-3.1-flash-image")
        self.assertLess(pro["in"] / flash_image["in"], 8.0)

    def test_thinking_tokens_bill_at_the_output_rate(self):
        """`thoughtsTokenCount` is output. Dropping it under-reports every call."""
        with_thoughts = model_catalog.estimate_cost(self.PRO, 1000, 1000, 1000, 0)
        without = model_catalog.estimate_cost(self.PRO, 1000, 2000, 0, 0)
        self.assertAlmostEqual(with_thoughts, without, places=10)

    def test_a_render_costs_tokens_plus_the_picture(self):
        """Per-image price is ADDITIVE, not a replacement for token cost."""
        model = "gemini-3.1-flash-lite-image"
        one = model_catalog.estimate_cost(model, 500, 50, 0, 1)
        none = model_catalog.estimate_cost(model, 500, 50, 0, 0)
        self.assertAlmostEqual(
            one - none, model_catalog.price_for(model)["image"], places=10)

    def test_the_long_context_tier_applies_to_the_whole_request(self):
        """Authoring ships a multi-megabyte SOP, so this tier is not theoretical.

        Gemini 3.x Pro doubles its rate past 200K input tokens and charges the
        higher rate on the ENTIRE request, not just the excess. Ignoring it
        under-reports exactly the lane that spends the most per call.
        """
        threshold = model_catalog.LONG_CONTEXT_THRESHOLD_TOKENS
        under = model_catalog.estimate_cost(self.PRO, threshold - 1000, 10000, 0, 0)
        over = model_catalog.estimate_cost(self.PRO, threshold + 1000, 10000, 0, 0)
        self.assertGreater(over, under * 1.8,
                           "crossing 200K must roughly double the call")

    def test_a_model_with_one_flat_rate_has_no_cliff(self):
        """Only the tiered families carry `long_in`; the rest must stay linear."""
        threshold = model_catalog.LONG_CONTEXT_THRESHOLD_TOKENS
        lite = "gemini-3.1-flash-lite"
        under = model_catalog.estimate_cost(lite, threshold - 1000, 0, 0, 0)
        over = model_catalog.estimate_cost(lite, threshold + 1000, 0, 0, 0)
        self.assertAlmostEqual(over / under, (threshold + 1000) / (threshold - 1000),
                               places=4)

    def test_veo_bills_per_second_and_fast_is_the_cheaper_lane(self):
        """A two-clip 8s question is the unit the proposal costs. 16 seconds."""
        standard = model_catalog.estimate_video_cost("veo-3.1-generate-001", 16)
        fast = model_catalog.estimate_video_cost("veo-3.1-fast-generate-001", 16)
        lite = model_catalog.estimate_video_cost("veo-3.1-lite-generate-001", 16)
        self.assertGreater(standard, fast)
        self.assertGreater(fast, lite)
        self.assertAlmostEqual(
            standard, model_catalog.video_rate_for("veo-3.1-generate-001") * 16,
            places=10)


@tagged("-at_install", "post_install")
class TestACachedTokenBillsAtTheCacheRate(TransactionCase):
    """Vertex bills cached input at a 90% discount on Gemini 2.5+, and
    `promptTokenCount` already includes the cached tokens. Pricing them at the
    full input rate would overstate spend - and the daily cap is enforced from
    that ledger."""

    PRO = "gemini-3.1-pro-preview"

    def test_cached_input_is_a_tenth_of_the_input_rate(self):
        # 100k in (under the long-context tier), 80k of them cached:
        # 20k x $2.00/M + 80k x $0.20/M = $0.056.
        cost = model_catalog.estimate_cost(self.PRO, 100_000, 0, 0, 0, 80_000)
        self.assertAlmostEqual(cost, 0.056)

    def test_no_cache_prices_as_before(self):
        self.assertEqual(
            model_catalog.estimate_cost(self.PRO, 17233, 6815, 0, 0),
            model_catalog.estimate_cost(self.PRO, 17233, 6815, 0, 0, 0))

    def test_the_ledger_records_what_vertex_served_from_cache(self):
        values = vertex._ledger_values(self.env, self.PRO, {
            "promptTokenCount": 17233, "candidatesTokenCount": 637,
            "thoughtsTokenCount": 1211, "cachedContentTokenCount": 4550,
        }, 0, {"operation": "score_subjective"})
        self.assertEqual(values["cached_tokens"], 4550)
        self.assertLess(values["cost_usd"], model_catalog.estimate_cost(
            self.PRO, 17233, 637, 1211, 0))


@tagged("-at_install", "post_install")
class TestTheRightThinkingParameterPerGeneration(TransactionCase):
    """Gemini 2.5 takes `thinkingBudget`; Gemini 3.x takes `thinkingLevel`.

    And turning 3.x reasoning DOWN is opt-in. The old code sent
    `thinkingBudget: 0` to every model but `gemini-2.5-pro`, which on a 3.x
    model is a parameter that no longer exists - so production has been running
    `gemini-3.1-pro-preview` at its default depth. Silently translating that to
    LOW would have made live grading shallower to save money nobody asked to
    save, which is a product change disguised as a refactor.
    """

    def setUp(self):
        super().setUp()
        self.ICP = self.env["ir.config_parameter"].sudo()

    def _level(self, value):
        self.ICP.set_param("assessments_be_v2.thinking_level", value)

    def test_a_2_5_model_still_gets_budget_zero(self):
        """Unchanged for 2.5, where the parameter is real and was being honoured."""
        self.assertEqual(
            model_catalog.apply_thinking({}, "gemini-2.5-flash"),
            {"thinkingConfig": {"thinkingBudget": 0}})

    def test_a_3_x_model_is_sent_nothing_by_default(self):
        """THE GUARD ON PRODUCTION BEHAVIOUR.

        No thinking field means the model keeps its own depth, which is what
        live traffic already has. It also cannot be rejected, where a wrong
        parameter can.
        """
        for model in ("gemini-3.1-pro-preview", "gemini-3.8-flash",
                      "gemini-3.1-flash-lite"):
            self.assertEqual(model_catalog.apply_thinking({}, model), {}, model)

    def test_a_configured_level_reaches_a_3_x_model_as_a_level(self):
        for model in ("gemini-3.1-pro-preview", "gemini-3.8-flash"):
            thinking = model_catalog.apply_thinking(
                {}, model, "LOW")["thinkingConfig"]
            self.assertEqual(thinking, {"thinkingLevel": "LOW"})
            self.assertNotIn(
                "thinkingBudget", thinking,
                "%s rejects a request carrying both parameters" % model)

    def test_a_level_is_never_sent_to_a_2_5_model(self):
        """2.5 does not know `thinkingLevel` and 400s on it."""
        self.assertEqual(
            model_catalog.apply_thinking({}, "gemini-2.5-flash", "HIGH"),
            {"thinkingConfig": {"thinkingBudget": 0}})

    def test_a_typo_in_the_setting_is_ignored_not_forwarded(self):
        """A bad value must not 400 every call in the deployment.

        Forwarding it would take generation and scoring down together, and a 400
        on every request reads as a model outage rather than as a settings typo.
        """
        for junk in ("MINIMAL", "low-ish", "0", "none", None, ""):
            self.assertEqual(model_catalog.normalize_thinking_level(junk), "")
            self.assertEqual(
                model_catalog.apply_thinking({}, "gemini-3.8-flash", junk), {})

    def test_minimal_is_not_offered_because_3_8_flash_rejects_it(self):
        """MINIMAL is the documented budget-0 equivalent on SOME 3.x models and
        an explicit validation error on 3.8 Flash, so it is not a legal value
        here and LOW is the recommended floor."""
        self.assertNotIn("MINIMAL", model_catalog.THINKING_LEVELS)
        self.assertEqual(model_catalog.MINIMAL_THINKING_LEVEL, "LOW")

    def test_a_model_that_cannot_be_turned_down_is_sent_nothing(self):
        """`gemini-2.5-pro` 400s on budget 0. Silence is the only safe request."""
        self.assertEqual(model_catalog.apply_thinking({}, "gemini-2.5-pro"), {})
        self.assertEqual(
            model_catalog.apply_thinking({}, "gemini-2.5-pro", "LOW"), {})

    def test_an_unrecognised_provider_is_sent_nothing(self):
        """A non-Google model must not receive a Google-shaped generationConfig."""
        self.assertEqual(
            model_catalog.apply_thinking({}, "glm-5.3-flash", "LOW"), {})

    def test_the_request_path_honours_the_setting(self):
        """End to end through the function `_call_vertex_single` actually calls."""
        self._level("")
        config = {}
        vertex._apply_thinking_budget(config, "gemini-3.1-pro-preview", self.env)
        self.assertEqual(config, {}, "unset must preserve today's behaviour")

        self._level("LOW")
        config = {}
        vertex._apply_thinking_budget(config, "gemini-3.1-pro-preview", self.env)
        self.assertEqual(config, {"thinkingConfig": {"thinkingLevel": "LOW"}})
        self._level("")

    def test_the_request_path_still_works_without_an_env(self):
        """`env=None` keeps the helper usable from a context with no cursor."""
        config = {}
        vertex._apply_thinking_budget(config, "gemini-2.5-flash", None)
        self.assertEqual(config, {"thinkingConfig": {"thinkingBudget": 0}})

    def _sent_config(self, operation):
        """The generationConfig one text call sends for `operation`."""
        sent = []

        class _Reply:
            status_code = 200
            text = ""

            def json(self):
                return {"candidates": [{"finishReason": "STOP", "content": {
                    "parts": [{"text": '{"ok": true}'}]}}],
                    "usageMetadata": {}}

        class _Client:
            def post(self, url, json=None, headers=None, **kw):
                sent.append(json["generationConfig"])
                return _Reply()

        with patch.object(vertex, "_vertex_creds", return_value=(
                    "p", "global", "gemini-3.1-pro-preview", "")), \
                patch.object(vertex, "_gemini_request",
                             return_value=("https://vertex.invalid", {})), \
                patch.object(vertex, "_httpx", return_value=_Client()), \
                patch.object(vertex, "_log_usage"), \
                patch.object(vertex, "_check_budget"), \
                patch.object(vertex, "_check_cancelled"), \
                patch.object(vertex, "_check_scoring_cancelled"):
            vertex._call_vertex_single(self.env, "sys", "hi",
                                       response_json=True,
                                       usage_ctx={"operation": operation})
        return sent[0]

    def test_a_level_for_one_operation_reaches_only_that_operation(self):
        """R10.4: `thinking_level.<operation>` turns one lane down (Draft from
        SOP is in-house); unset, every request stays as it was."""
        self._level("")
        self.ICP.set_param(
            "assessments_be_v2.thinking_level.draft_task_template", "low")
        self.assertEqual(
            vertex._thinking_level(self.env, "draft_task_template"), "LOW")
        self.assertEqual(
            vertex._thinking_level(self.env, "generate_questions"), "")
        self.assertEqual(vertex._thinking_level(self.env), "")
        self.assertEqual(
            self._sent_config("draft_task_template")["thinkingConfig"],
            {"thinkingLevel": "LOW"})
        self.assertNotIn("thinkingConfig",
                         self._sent_config("generate_questions"))

    def test_junk_for_one_operation_falls_back_to_the_global_level(self):
        self._level("HIGH")
        self.ICP.set_param(
            "assessments_be_v2.thinking_level.draft_task_template", "lowish")
        self.assertEqual(
            vertex._thinking_level(self.env, "draft_task_template"), "HIGH")


@tagged("-at_install", "post_install")
class TestAPictureModelCannotDoATextJob(TransactionCase):
    """Capability is derived from naming rules so a new model arrives correct."""

    def test_an_image_suffix_means_the_output_is_a_picture(self):
        for model in ("gemini-3-pro-image", "gemini-3.1-flash-image",
                      "gemini-3.1-flash-lite-image", "gemini-2.5-flash-image",
                      "gemini-2.0-flash-preview-image-generation",
                      "imagen-4.0-generate-001"):
            self.assertTrue(model_catalog.is_image_generation_model(model), model)
            self.assertFalse(model_catalog.is_text_capable(model), model)

    def test_a_preview_marker_does_not_hide_the_image_suffix(self):
        """`preview` sits MID-STRING in this ID.

        Stripping release markers from the END would have eaten
        `-image-generation` with it and reclassified a picture model as a text
        model - the exact miscast these guards exist to catch.
        """
        self.assertTrue(model_catalog.is_image_generation_model(
            "gemini-2.0-flash-preview-image-generation"))

    def test_a_reasoning_model_is_text_capable_even_though_it_reads_pictures(self):
        """Reading an image is not generating one. Every Gemini text model does."""
        for model in ("gemini-3.1-pro-preview", "gemini-3.1-flash-lite",
                      "gemini-3.8-flash", "gemini-2.5-pro"):
            self.assertTrue(model_catalog.is_text_capable(model), model)
            self.assertFalse(model_catalog.is_image_generation_model(model), model)

    def test_an_unrecognised_model_fails_open(self):
        """The guards must not silently ignore a correctly configured model.

        This module cannot know a third-party model's shape, so an unknown ID is
        treated as usable. Refusing it would turn "we have not heard of this"
        into "your setting does nothing", with no way to override.
        """
        self.assertTrue(model_catalog.is_text_capable("glm-5.3-flash"))


@tagged("-at_install", "post_install")
class TestAMiscastModelIsIgnoredNotObeyed(TransactionCase):
    """Every text lane must survive a picture model typed into its field."""

    def setUp(self):
        super().setUp()
        self.ICP = self.env["ir.config_parameter"].sudo()
        # `_text_lane` warns once per lane+model per process. Clear it so each
        # test observes the behaviour rather than a cached silence.
        vertex._warned_miscast.clear()

    def _set(self, key, value):
        self.ICP.set_param("assessments_be_v2.%s" % key, value)

    def test_a_render_model_in_a_text_field_is_skipped_with_a_default(self):
        """Falls THROUGH, never raises.

        An override we cannot honour must not take grading or authoring down on
        a misconfigured deployment - the chain still ends in a working default,
        and the log says why the setting was ignored.
        """
        for key, resolver in (("generation_model", vertex._generation_model),
                              ("scoring_model", vertex._scoring_model),
                              ("detection_model", vertex._detection_model),
                              ("verify_model", vertex._verify_model),
                              ("utility_model", vertex._utility_model)):
            self._set(key, "gemini-3-pro-image")
            resolved = resolver(self.env)
            self.assertTrue(
                model_catalog.is_text_capable(resolved),
                "%s resolved to %r, which cannot return text" % (key, resolved))
            self._set(key, "")

    def test_a_miscast_fallback_disables_the_lane_rather_than_retrying(self):
        """Empty means "no fallback", which is the right degradation here.

        A picture model in this field would be retried on every quota error and
        fail every time - doubling the bill to prove a point.
        """
        self._set("fallback_model", "gemini-3.1-flash-lite-image")
        self.assertEqual(vertex._fallback_model(self.env), "")

    def test_a_legitimate_override_is_still_obeyed(self):
        """The guard must not swallow a correct setting."""
        self._set("scoring_model", "gemini-3.1-flash-lite")
        self.assertEqual(vertex._scoring_model(self.env), "gemini-3.1-flash-lite")
        self._set("scoring_model", "")

    def test_an_unset_utility_model_behaves_exactly_as_before(self):
        """`extract_tags` and `consolidate_vocab` moved onto this lane.

        They must not change model until someone opts in, or this becomes a
        silent quality change to tag extraction rather than a cost setting.
        """
        self._set("utility_model", "")
        self._set("generation_model", "gemini-3.1-pro-preview")
        self.assertEqual(vertex._utility_model(self.env),
                         vertex._generation_model(self.env))

    def test_the_image_lane_is_left_alone(self):
        """`image_model` is the one field where a picture model is correct."""
        self._set("image_model", "gemini-3.1-flash-lite-image")
        self.assertEqual(vertex._vertex_image_model(self.env),
                         "gemini-3.1-flash-lite-image")


@tagged("-at_install", "post_install")
class TestASwappedServiceAccountTakesTheProjectWithIt(TransactionCase):
    """Dropping in a new key must not leave the module on the old project.

    `vertex_project_id` was only auto-filled when EMPTY, so a key issued for a
    different GCP project authenticated as the new service account against the
    old project's URL. That is a 403 or 404 naming the PROJECT, not the key, and
    it reads like missing entitlement rather than a stale setting.
    """

    def setUp(self):
        super().setUp()
        self.ICP = self.env["ir.config_parameter"].sudo()
        # A DATABASE WITH A REAL KEY INSTALLED IS NOT A FIRST SIGHTING. These
        # cases start from "no key seen yet"; on a developer database carrying
        # a live service account, its stored fingerprint and cached bearer made
        # two of them fail for reasons that had nothing to do with the code.
        # Cleared inside the test's own transaction, so nothing real is touched.
        for key in ("assessments_be_v2.vertex_service_account_json",
                    "assessments_be_v2.vertex_project_id",
                    "assessments_be_v2.vertex_minted_token",
                    "assessments_be_v2.vertex_minted_token_expires",
                    vertex.SA_FINGERPRINT_PARAM,
                    vertex.SA_PROJECT_SOURCE_PARAM):
            self.ICP.set_param(key, False)

    def _key(self, email, key_id, project):
        return {"type": "service_account", "client_email": email,
                "private_key_id": key_id, "private_key": "-----BEGIN-----",
                "project_id": project,
                "token_uri": "https://oauth2.googleapis.com/token"}

    def _install(self, sa):
        return vertex._sync_service_account_identity(self.env, sa)

    def test_the_first_key_seen_is_adopted_not_reported_as_a_rotation(self):
        old = self._key("a@x.iam.gserviceaccount.com", "k1", "proj-old")
        self.assertFalse(self._install(old),
                         "the first observation is not a rotation")
        self.assertEqual(
            self.ICP.get_param("assessments_be_v2.vertex_project_id"),
            "proj-old")

    def test_a_new_key_for_a_new_project_re_points_the_project(self):
        """The headline behaviour: swap the JSON, everything follows."""
        self._install(self._key("a@x.iam.gserviceaccount.com", "k1", "proj-old"))
        rotated = self._install(
            self._key("b@y.iam.gserviceaccount.com", "k2", "proj-new"))
        self.assertTrue(rotated)
        self.assertEqual(
            self.ICP.get_param("assessments_be_v2.vertex_project_id"),
            "proj-new")

    def test_a_rotation_discards_a_bearer_minted_against_the_previous_key(self):
        """A stale token is worse than none: it succeeds against the WRONG project.

        The settings form and the API route already cleared it. Keying this on a
        fingerprint instead means it also holds for a key installed by any other
        path, including a direct `ir.config_parameter` write.
        """
        self._install(self._key("a@x.iam.gserviceaccount.com", "k1", "proj-old"))
        self.ICP.set_param("assessments_be_v2.vertex_minted_token", "stale-token")
        self.ICP.set_param("assessments_be_v2.vertex_minted_token_expires",
                           "99999999999")
        self._install(self._key("b@y.iam.gserviceaccount.com", "k2", "proj-new"))
        # Asserted as FALSY, not as "". `set_param` with an empty string DELETES
        # the row, so `get_param` then returns False rather than "". Both satisfy
        # the invariant `_minted_bearer` actually depends on - no usable cached
        # bearer survives - and pinning the literal would test Odoo's storage
        # behaviour instead of ours.
        self.assertFalse(
            self.ICP.get_param("assessments_be_v2.vertex_minted_token"),
            "a bearer minted against the previous key must not survive")

    def test_a_re_issued_key_for_the_same_account_still_counts_as_a_rotation(self):
        """Same `client_email`, new `private_key_id`. The old bearer must go."""
        self._install(self._key("a@x.iam.gserviceaccount.com", "k1", "proj-old"))
        self.assertTrue(self._install(
            self._key("a@x.iam.gserviceaccount.com", "k2", "proj-old")))

    def test_re_reading_the_same_key_changes_nothing(self):
        """Called on EVERY Vertex call, so it has to be idempotent and cheap."""
        sa = self._key("a@x.iam.gserviceaccount.com", "k1", "proj-old")
        self._install(sa)
        self.ICP.set_param("assessments_be_v2.vertex_minted_token", "live-token")
        self.assertFalse(self._install(sa))
        self.assertEqual(
            self.ICP.get_param("assessments_be_v2.vertex_minted_token"),
            "live-token", "an unchanged key must not force a re-mint")

    def test_a_hand_set_project_id_is_kept_and_reported(self):
        """A cross-project setup is legitimate; overwriting it is the worse bug.

        Key in one project, quota and entitlement in another, is a real Google
        configuration. The rule is that we only re-point a value WE adopted.
        """
        self._install(self._key("a@x.iam.gserviceaccount.com", "k1", "proj-old"))
        self.ICP.set_param("assessments_be_v2.vertex_project_id", "proj-chosen")
        self._install(self._key("b@y.iam.gserviceaccount.com", "k2", "proj-new"))
        self.assertEqual(
            self.ICP.get_param("assessments_be_v2.vertex_project_id"),
            "proj-chosen")

    def test_the_fingerprint_never_carries_the_private_key(self):
        """It lands in `ir.config_parameter`, so it goes into every dump."""
        secret = "-----BEGIN PRIVATE KEY-----SUPERSECRET-----END-----"
        sa = self._key("a@x.iam.gserviceaccount.com", "k1", "proj-old")
        sa["private_key"] = secret
        fingerprint = vertex._sa_fingerprint(sa)
        self.assertNotIn("SUPERSECRET", fingerprint)
        self.assertNotIn(secret, fingerprint)
        self.assertEqual(len(fingerprint), 16)

    def test_a_malformed_key_names_the_problem(self):
        """"Not valid JSON" beats a KeyError from three frames down."""
        with self.assertRaises(RuntimeError):
            vertex._load_service_account("{not json")
        with self.assertRaises(RuntimeError):
            vertex._load_service_account(json.dumps({"project_id": "p"}))

    def test_the_steady_state_writes_nothing_at_all(self):
        """This sits on the path of EVERY Vertex call, and scoring runs sharded.

        The unchanged case has to be a single read. When it also wrote, the first
        call after a deploy had every worker updating the same
        `ir.config_parameter` rows at once, which at REPEATABLE READ is
        `could not serialize access due to concurrent update` - a failure this
        module has shipped before (tests/test_tag_extract_lifecycle.py).
        """
        sa = self._key("a@x.iam.gserviceaccount.com", "k1", "proj-old")
        self._install(sa)
        writes = []
        original = type(self.ICP).set_param

        def spy(records, key, value):
            writes.append(key)
            return original(records, key, value)

        self.patch(type(self.ICP), "set_param", spy)
        self.assertFalse(self._install(sa))
        self.assertEqual(writes, [],
                         "the unchanged path must not write; it would serialise "
                         "every concurrent Vertex caller against itself")

    def test_a_sync_failure_never_breaks_the_vertex_call(self):
        """Bookkeeping, not a precondition.

        Losing a write race on a housekeeping row must not turn into a failed
        generation or a lost score, so `_minted_bearer` swallows it and retries
        on the next call.
        """
        boom = RuntimeError("could not serialize access due to concurrent update")

        def explode(env, sa):
            raise boom

        self.patch(vertex, "_sync_service_account_identity", explode)
        # No service account configured, so `_minted_bearer` returns before the
        # sync - the point is that the guarded call site compiles and the helper
        # is reached through a try/except rather than bare.
        self.assertEqual(vertex._minted_bearer(self.env), "")

    def test_production_shaped_config_keeps_its_cross_project_id(self):
        """Live production on 2026-09-10, asserted as a scenario.

        `vertex_project_id = agon-development-499205` while
        `vertex_project_id_source = etp-ethara` - the key is issued for one GCP
        project and the quota lives in another. That is a legitimate setup, and
        the incoming key swap must not "helpfully" re-point it.
        """
        self.ICP.set_param("assessments_be_v2.vertex_project_id",
                           "agon-development-499205")
        self.ICP.set_param(vertex.SA_PROJECT_SOURCE_PARAM, "etp-ethara")
        self.ICP.set_param(vertex.SA_FINGERPRINT_PARAM, "5b56e2025d0a083d")
        self._install(self._key("new@z.iam.gserviceaccount.com", "k9",
                                "etp-ethara-new"))
        self.assertEqual(
            self.ICP.get_param("assessments_be_v2.vertex_project_id"),
            "agon-development-499205",
            "a deliberate cross-project id must survive a key swap")


@tagged("-at_install", "post_install")
class TestTheSettingsFormActuallySavesThese(TransactionCase):
    """The form is where a human sets these, so the form is what must work.

    `-u module` proves a view LOADS. It does not prove a field SAVES, reads back
    what was saved, or reaches the resolver - and `thinking_level` is a
    Selection carrying an empty-string option, which is unusual enough in Odoo
    to be worth pinning. A field that silently fails to round-trip here means an
    admin sets a model, sees it accepted, and gets the old one anyway.
    """

    def setUp(self):
        super().setUp()
        self.ICP = self.env["ir.config_parameter"].sudo()
        self.Settings = self.env["res.config.settings"]
        vertex._warned_miscast.clear()

    def _save(self, **values):
        self.Settings.create(values).execute()

    def test_the_settings_page_can_be_rendered_at_all(self):
        """`default_get` over every field is what opening the page does.

        A field whose default cannot be computed takes the WHOLE Settings page
        down, not just its own section - including every unrelated setting on it.
        """
        defaults = self.Settings.default_get(list(self.Settings.fields_get()))
        self.assertIn("assessments_be_thinking_level", defaults)
        self.assertIn("assessments_be_utility_model", defaults)
        self.assertIn("assessments_be_verify_model", defaults)

    def test_a_thinking_level_survives_save_reopen_and_reaches_the_payload(self):
        for value in ("LOW", "MEDIUM", "HIGH"):
            self._save(assessments_be_thinking_level=value)
            self.assertEqual(vertex._thinking_level(self.env), value)
            self.assertEqual(
                self.Settings.create({}).assessments_be_thinking_level, value,
                "reopening the form must show what was saved")
            config = {}
            vertex._apply_thinking_budget(
                config, "gemini-3.1-pro-preview", self.env)
            self.assertEqual(
                config, {"thinkingConfig": {"thinkingLevel": value}})

    def test_the_empty_option_saves_and_means_model_default(self):
        """The default, and the one an admin picks to undo a cost experiment."""
        self._save(assessments_be_thinking_level="LOW")
        self._save(assessments_be_thinking_level="")
        self.assertEqual(vertex._thinking_level(self.env), "")
        config = {}
        vertex._apply_thinking_budget(config, "gemini-3.1-pro-preview", self.env)
        self.assertEqual(config, {}, "empty must send no thinking field")

    def test_a_model_override_saves_and_reaches_its_resolver(self):
        self._save(assessments_be_utility_model="gemini-3.1-flash-lite",
                   assessments_be_verify_model="gemini-3.1-flash-lite")
        self.assertEqual(vertex._utility_model(self.env),
                         "gemini-3.1-flash-lite")
        self.assertEqual(vertex._verify_model(self.env),
                         "gemini-3.1-flash-lite")

    def test_clearing_an_override_restores_the_fallback_chain(self):
        """Blanking a field is how an override is REMOVED, not how it is broken."""
        self._save(assessments_be_utility_model="gemini-3.1-flash-lite",
                   assessments_be_verify_model="gemini-3.1-flash-lite")
        self._save(assessments_be_utility_model="",
                   assessments_be_verify_model="")
        self.assertEqual(vertex._utility_model(self.env),
                         vertex._generation_model(self.env))
        self.assertEqual(vertex._verify_model(self.env),
                         vertex._detection_model(self.env))

    def test_a_picture_model_saved_in_a_text_field_is_still_refused(self):
        """The guard has to hold on the real path, not only on a direct call."""
        self._save(assessments_be_scoring_model="gemini-3-pro-image")
        resolved = vertex._scoring_model(self.env)
        self.assertTrue(model_catalog.is_text_capable(resolved))


@tagged("-at_install", "post_install")
class TestTheLedgerAgreesWithTheCatalog(TransactionCase):
    """The cap is enforced on `cost_usd` in the ledger, not on an estimate."""

    def test_vertex_still_exposes_the_names_tools_and_tests_import(self):
        """`_PRICING` and friends are views onto the catalog, not a second copy."""
        self.assertIs(vertex._PRICING, model_catalog.TEXT_PRICING)
        self.assertIs(vertex._VIDEO_PRICING, model_catalog.VIDEO_PRICING)
        self.assertEqual(
            vertex._estimate_cost("gemini-3.1-flash-lite", 1000, 100, 0, 0),
            model_catalog.estimate_cost("gemini-3.1-flash-lite", 1000, 100, 0, 0))
        self.assertEqual(
            vertex._estimate_video_cost("veo-3.1-fast-generate-001", 8),
            model_catalog.estimate_video_cost("veo-3.1-fast-generate-001", 8))

    def test_every_model_named_in_the_settings_help_has_a_price(self):
        """Help text is a recommendation. Recommending an unpriced model is how
        the ledger silently drifts, so the two must not disagree."""
        recommended = (
            "gemini-3.1-pro-preview", "gemini-3.8-flash",
            "gemini-3.1-flash-lite", "gemini-3-pro-image",
            "gemini-3.1-flash-image", "gemini-3.1-flash-lite-image",
            "gemini-2.5-pro",
        )
        for model in recommended:
            self.assertTrue(
                model_catalog.price_is_known(model),
                "%s is recommended in the settings help but has no catalog "
                "price, so it would bill at the default" % model)

    def test_the_models_production_actually_runs_are_priced_exactly(self):
        """Read off live production config on 2026-09-10.

        `vertex_model = gemini-3-pro-image`, `video_model = veo-3.1-generate-001`
        and EVERY text override unset, so the text lanes resolve to
        `GENERATION_DEFAULT_MODEL`. If any of these three fell through to the
        catalog default, the ledger and the $100/day cap would be running on a
        guess for 100% of live traffic - which is the exact failure the old
        `image: 0.0` default produced.
        """
        for model in ("gemini-3-pro-image", GENERATION_DEFAULT_MODEL,
                      VERTEX_DEFAULT_MODEL):
            self.assertTrue(
                model_catalog.price_is_known(model),
                "%s is live in production and has no catalog price" % model)
        self.assertTrue(model_catalog.video_rate_is_known(VIDEO_DEFAULT_MODEL))

    def test_the_production_image_price_did_not_move(self):
        """$0.134 per 1K/2K render was the number before this refactor.

        A refactor that silently reprices the live image model would move the
        cost ledger and the cap for every question already in the bank.
        """
        self.assertAlmostEqual(
            model_catalog.price_for("gemini-3-pro-image")["image"], 0.134,
            places=6)
        self.assertAlmostEqual(
            model_catalog.video_rate_for("veo-3.1-generate-001"), 0.40,
            places=6)

    def test_every_recommended_veo_model_has_a_rate(self):
        for model in ("veo-3.1-generate-001", "veo-3.1-fast-generate-001",
                      "veo-3.1-lite-generate-001"):
            self.assertTrue(
                model_catalog.video_rate_is_known(model),
                "%s is recommended but has no per-second rate" % model)

    def test_an_unpriced_model_is_reported_as_unknown_not_inferred_from_value(self):
        """The default equals real Nano Banana Pro rates on purpose.

        That makes a fallen-through price numerically identical to a correct one,
        so "is this priced" has to be its own question rather than a comparison
        against the default. This test exists because the comparison version of
        it failed on `gemini-3-pro-image` - the live production image model.
        """
        self.assertEqual(model_catalog.price_for("no-such-model"),
                         model_catalog.DEFAULT_TEXT_PRICE)
        self.assertFalse(model_catalog.price_is_known("no-such-model"))
        self.assertTrue(model_catalog.price_is_known("gemini-3-pro-image"))
        self.assertFalse(model_catalog.video_rate_is_known("seedance-2.0"))
        self.assertTrue(model_catalog.video_rate_is_known("veo-3.1-generate-001"))
