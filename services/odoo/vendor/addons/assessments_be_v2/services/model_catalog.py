"""Model pricing, capability and thinking-config catalog.

Single source of truth for the three questions that all key off the same model
string, and that used to be answered in three unrelated places:

  1. WHAT DOES IT COST -- feeds `assessments.be.llm.usage` and therefore the
     `daily_llm_cap_usd` / `per_evaluator_llm_cap_usd` gates. A model missing
     from the table used to bill at a flat default with `image: 0.0`, so
     switching the image model silently recorded every render as $0.00 and the
     $100/day cap stopped seeing image spend at all.
  2. WHAT CAN IT DO -- a picture generator cannot grade an answer or parse a
     PDF. Three docstrings in `vertex.py` already said so in prose; this makes
     it enforceable.
  3. HOW DO I ASK IT TO THINK -- Gemini 2.5 takes `thinkingBudget` (an int),
     Gemini 3.x takes `thinkingLevel` (an enum), and Google rejects a request
     carrying both. Sending 2.5's parameter to a 3.x model is wrong today.

BUILT FOR A MODEL SWAP, NOT FOR A FIXED LIST
--------------------------------------------
Every lookup normalises the ID and then falls back to the longest matching
family prefix, so `gemini-3.1-flash-lite-preview-11-2026` and
`publishers/google/models/gemini-3.1-flash-lite` both price as
`gemini-3.1-flash-lite` with nobody editing this file. Capability and thinking
style are derived from NAMING RULES rather than membership in a table, for the
same reason: a model released next month must behave correctly on arrival.

An ID that matches nothing at all is logged ONCE at WARNING and priced at a
deliberately PESSIMISTIC default. Over-billing an unknown model is a visible
annoyance; under-billing it disables the spend cap, which is the failure we are
actually guarding against.

PRICE PROVENANCE
----------------
`in`/`out` are USD per 1,000,000 tokens; `image` is USD per generated image at
the 1K/2K tier, which is what this module renders (no resolution is sent, and
Google bills 1K and 2K identically). 4K roughly doubles the image figure -- if
a resolution parameter is ever added, `image` has to become a per-tier dict.

Rates marked VERIFIED were read off Google's own pricing/model pages or launch
posts. Rates marked INFERRED are derived from a documented relative statement
(e.g. "half the cost of 3 Flash") and are the ones to re-check first when a
bill looks wrong. Thinking tokens bill at the OUTPUT rate on every Gemini
model, which is why `_estimate_cost` adds `thoughtsTokenCount` to output.
"""

import logging

_logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Pricing
# ---------------------------------------------------------------------------
# `long_in` / `long_out` are the LONG-CONTEXT tier. Gemini 3.x Pro doubles its
# rate once the prompt crosses `LONG_CONTEXT_THRESHOLD_TOKENS` input tokens,
# and the higher rate applies to the WHOLE request, not just the excess. The
# question-authoring call ships a multi-megabyte SOP PDF, so this tier is not
# hypothetical for us -- omitting it under-reports authoring cost.
LONG_CONTEXT_THRESHOLD_TOKENS = 200_000

# Share of the input rate a cached input token bills at: "On Gemini 2.5 or
# later models, this discount is 90%" (Vertex context-cache overview,
# checked 2026-09-22). A price row may pin its own `cached_in` instead.
CACHED_INPUT_SHARE = 0.10

TEXT_PRICING = {
    # -- Gemini 3.x, reasoning / multimodal text -----------------------------
    # VERIFIED: $2.00/$12.00 under 200K, $4.00/$18.00 over.
    "gemini-3.1-pro": {"in": 2.00, "out": 12.00, "image": 0.0,
                       "long_in": 4.00, "long_out": 18.00,
                       "max_out": 65536, "cache_min": 4096,
                       "cache_storage": 4.50},
    # VERIFIED: GA 2026-09-02 at 3.7 Flash's rate. Supported thinkingLevel
    # values are LOW / MEDIUM / HIGH -- MINIMAL is an API validation error.
    "gemini-3.8-flash": {"in": 0.75, "out": 3.75, "image": 0.0,
                         "max_out": 65536, "cache_min": 4096},
    "gemini-3.7-flash": {"in": 0.75, "out": 3.75, "image": 0.0,
                         "max_out": 65536, "cache_min": 4096},
    # INFERRED: 3.1 Flash-Lite is documented as half of 3 Flash, and Flash-Lite
    # is a VERIFIED $0.25/$1.50, which puts Flash at $0.50/$3.00.
    "gemini-3.1-flash": {"in": 0.50, "out": 3.00, "image": 0.0,
                         "max_out": 65536, "cache_min": 4096},
    "gemini-3-flash": {"in": 0.50, "out": 3.00, "image": 0.0,
                       "max_out": 65536, "cache_min": 4096},
    # VERIFIED off Google's Flash-Lite launch post. Exactly 8x cheaper than
    # 3.1 Pro on BOTH input and output, which is the only reason an 8x saving
    # holds for any token mix. 1M context, reads text/image/video/audio/PDF.
    "gemini-3.1-flash-lite": {"in": 0.25, "out": 1.50, "image": 0.0,
                              "max_out": 65536, "cache_min": 4096},
    # -- Gemini 3.x, image GENERATION (Nano Banana family) -------------------
    # Token rates bill the prompt and any reference image; `image` bills the
    # render on top. These emit pictures -- never route grading here.
    # VERIFIED: Nano Banana Pro, $0.134 at 1K/2K, $0.24 at 4K.
    "gemini-3-pro-image": {"in": 2.00, "out": 12.00, "image": 0.134},
    # VERIFIED: Nano Banana 2. $0.045 at 512px, $0.067 at 1K, $0.101 at 2K,
    # $0.151 at 4K.
    "gemini-3.1-flash-image": {"in": 0.50, "out": 3.00, "image": 0.067},
    # VERIFIED: Nano Banana 2 Lite, $0.0336 at 1K -- exactly half of Nano
    # Banana 2 at every tier, and 4x under Nano Banana Pro. This is the model
    # a "$0.034 per image" target actually refers to; reaching $0.034 on
    # `gemini-3.1-flash-image` needs the async Batch API instead.
    "gemini-3.1-flash-lite-image": {"in": 0.25, "out": 1.50, "image": 0.0336},
    # -- Gemini 2.5, what stage/prod is entitled to today -------------------
    # Keep these EXACTLY as they were. The current deployment is pointed here
    # by config override, so changing a number changes a live bill.
    "gemini-2.5-pro": {"in": 1.25, "out": 10.00, "image": 0.0,
                       "max_out": 65536, "cache_min": 2048},
    "gemini-2.5-flash": {"in": 0.30, "out": 2.50, "image": 0.0,
                         "max_out": 65536, "cache_min": 2048},
    "gemini-2.5-flash-lite": {"in": 0.10, "out": 0.40, "image": 0.0,
                              "max_out": 65536, "cache_min": 2048},
    "gemini-2.5-flash-image": {"in": 0.30, "out": 2.50, "image": 0.039},
    "gemini-2.0-flash": {"in": 0.15, "out": 0.60, "image": 0.0,
                         "max_out": 8192, "cache_min": 2048},
    "gemini-2.0-flash-lite": {"in": 0.075, "out": 0.30, "image": 0.0,
                              "max_out": 8192, "cache_min": 2048},
    "gemini-1.5-pro": {"in": 1.25, "out": 5.00, "image": 0.0,
                       "max_out": 8192},
    "gemini-1.5-flash": {"in": 0.075, "out": 0.30, "image": 0.0,
                         "max_out": 8192},
}

# CAPABILITY columns on a text row, for a scoring-model swap (W14):
#   max_out        the model's own output ceiling; a request above it is refused,
#                  so `vertex` clamps to it. Absent = unknown, not clamped.
#                  INFERRED from the 3.x family for 3.7 / 3.8 Flash.
#   cache_min      the smallest explicit context cache the model accepts, in
#                  tokens (Gemini 3: 4,096; Gemini 2: 2,048). Absent = never
#                  cache on this model.
#   cache_storage  USD per 1M cached tokens per hour. VERIFIED for 3.1 Pro; a
#                  caching row without one bills at CACHE_STORAGE_DEFAULT.
# An unknown model gets none of these: priced pessimistically, never cached.
CACHE_STORAGE_DEFAULT = 4.50

# Deliberately pessimistic: pricier than every model above except 3.x Pro, and
# it CHARGES for images. An unknown model that renders pictures used to record
# $0.00 and take the daily cap offline; now it over-reports until someone adds
# a row, which is a bug you can see on the LLM Budget screen.
DEFAULT_TEXT_PRICE = {"in": 2.00, "out": 12.00, "image": 0.134}

# Veo bills PER SECOND of output clip, never per token. `_ledger_values` picks
# video pricing OR token pricing, so a Veo row carries no token cost at all.
VIDEO_PRICING = {
    "veo-3.1-generate": 0.40,        # VERIFIED, 720p/1080p with audio
    "veo-3.1-fast-generate": 0.15,   # VERIFIED, same durations, ~2.7x cheaper
    "veo-3.1-lite-generate": 0.05,   # VERIFIED, PREVIEW -- confirm GA before prod
    "veo-3.1-lite": 0.05,
    "veo-3.0-generate": 0.40,
    "veo-3.0-fast-generate": 0.15,
    "veo-2.0-generate": 0.35,
    # Family catch-alls, matched only when nothing longer does. A date-stamped
    # alias like `veo-3.1-20260320` normalises to `veo-3.1` and would otherwise
    # miss every row above and land on the default.
    "veo-3.1": 0.40,
    "veo-3.0": 0.40,
    "veo-2.0": 0.35,
}
# Highest real Veo rate, for the same reason as DEFAULT_TEXT_PRICE: an unknown
# video model must never look cheaper than it is to the spend cap.
DEFAULT_VIDEO_RATE = 0.40


# ---------------------------------------------------------------------------
# Model-ID normalisation
# ---------------------------------------------------------------------------
# Release-channel markers Google inserts without changing the price. Removed as
# SEGMENTS rather than as a trailing suffix, because they are not always last:
# `gemini-2.0-flash-preview-image-generation` carries `preview` in the middle,
# and stripping from the end would eat `-image-generation` with it -- destroying
# the one token that says this model returns a picture.
_STRIP_SEGMENTS = frozenset(("preview", "latest", "exp", "experimental"))

# `publishers/google/models/<id>` is how the Vertex REST path names a model and
# how a copy-pasted setting sometimes arrives.
_STRIP_PREFIXES = (
    "publishers/google/models/", "models/", "google/", "vertex_ai/",
)

_warned_unknown = set()


def normalize_model_id(model):
    """Reduce a model string to the family key used by the pricing tables.

    Idempotent and total: any input returns a string, never raises. Trailing
    build/date stamps are dropped (``-001``, ``-002``, ``-11-2026``,
    ``-20260320``) because Google reprices a family, not a build.
    """
    name = (model or "").strip().lower()
    if not name:
        return ""
    for prefix in _STRIP_PREFIXES:
        if name.startswith(prefix):
            name = name[len(prefix):]
    parts = [p for p in name.split("-") if p and p not in _STRIP_SEGMENTS]
    # Drop trailing numeric build/date stamps, but STOP at three parts so the
    # version is never mistaken for one: `gemini-3` must not become `gemini`,
    # and `veo-3.1-20260320` must stop at `veo-3.1`. A version segment sits at
    # index 1; a build stamp only ever appears after a named segment.
    while len(parts) > 2 and parts[-1].isdigit():
        parts.pop()
    return "-".join(parts).strip("-")


def _lookup(table, model, default):
    """Exact match, else the LONGEST family prefix, else `default`.

    Longest-prefix rather than first-match matters:
    `gemini-3.1-flash-lite-image` must not be priced as `gemini-3.1-flash`.
    """
    key = normalize_model_id(model)
    if not key:
        return default, False
    if key in table:
        return table[key], True
    matches = [c for c in table if key.startswith(c)]
    if matches:
        return table[max(matches, key=len)], True
    return default, False


def _warn_once(model, kind):
    key = "%s:%s" % (kind, normalize_model_id(model))
    if key in _warned_unknown:
        return
    _warned_unknown.add(key)
    _logger.warning(
        "etp_assessment: no %s price for model %r - billing it at the "
        "pessimistic default. Add a row to services/model_catalog.py so the "
        "cost ledger and the daily spend cap stay accurate.", kind, model)


def price_for(model):
    """Token/image rates for `model`. Never returns None."""
    price, found = _lookup(TEXT_PRICING, model, DEFAULT_TEXT_PRICE)
    if not found:
        _warn_once(model, "token")
    return price


def video_rate_for(model):
    """USD per second of generated clip. Never returns None."""
    rate, found = _lookup(VIDEO_PRICING, model, DEFAULT_VIDEO_RATE)
    if not found:
        _warn_once(model, "video")
    return rate


# The pessimistic defaults are deliberately set at real Nano Banana Pro rates,
# which means a fallen-through price is NUMERICALLY INDISTINGUISHABLE from a
# correctly priced one. Comparing `price_for(x)` against the default is
# therefore not a valid way to ask "do we know this model" - these two are.
# `vertex_setup` uses them to report coverage before anything is billed.

def price_is_known(model):
    """Whether `model` has a real token/image price rather than the default."""
    return _lookup(TEXT_PRICING, model, None)[1]


def video_rate_is_known(model):
    """Whether `model` has a real per-second rate rather than the default."""
    return _lookup(VIDEO_PRICING, model, None)[1]


def _capabilities(model):
    return _lookup(TEXT_PRICING, model, {})[0]


def max_output_tokens(model):
    """The model's output ceiling, or None when the catalog does not know it."""
    return _capabilities(model).get("max_out")


def clamp_output_tokens(model, wanted):
    """`wanted`, lowered to what `model` can return. Unknown model: unchanged."""
    ceiling = max_output_tokens(model)
    return min(wanted, ceiling) if ceiling else wanted


def cache_min_tokens(model):
    """Smallest explicit cache `model` accepts, or None: never cache it."""
    return _capabilities(model).get("cache_min")


def cache_storage_rate(model):
    """USD per 1M cached tokens per hour, or None when it is never cached."""
    row = _capabilities(model)
    if not row.get("cache_min"):
        return None
    return row.get("cache_storage", CACHE_STORAGE_DEFAULT)


def cache_storage_cost(model, tokens, seconds):
    """USD to keep ``tokens`` cached on ``model`` for ``seconds``."""
    rate = cache_storage_rate(model) or 0.0
    return (max(0, int(tokens or 0)) * rate
            * max(0.0, float(seconds or 0)) / 3600.0 / 1_000_000.0)


def describe(model):
    """What the catalog knows about `model`, for the settings screen."""
    return {
        "model": model or "",
        "price_known": price_is_known(model),
        "capabilities_known": max_output_tokens(model) is not None,
        "max_output_tokens": max_output_tokens(model),
        "cache_min_tokens": cache_min_tokens(model),
        "cache_storage_per_mtok_hour": cache_storage_rate(model),
    }


def estimate_cost(model, tokens_in, tokens_out, thoughts, image_count, cached=0):
    """USD for one generateContent call.

    Thinking tokens bill at the OUTPUT rate on every Gemini model, so they are
    folded into output rather than tracked separately. Image renders are
    ADDITIVE on top of tokens, not instead of them.

    The long-context tier is selected by prompt size and then applies to the
    whole request -- that is how Google bills it, and it is why a call that
    ships a large SOP costs more per token than the headline rate.
    """
    # NOTHING BILLED, NOTHING TO PRICE: a Veo `fetch_video_op` poll logs a row
    # with zero tokens and no images (the clip is billed per second on its
    # submit row), and looking its model up in the TOKEN table only warned
    # "no token price" about a call that costs nothing.
    if not (tokens_in or tokens_out or thoughts or image_count):
        return 0.0
    price = price_for(model)
    # Clamped at zero because this figure is SUMMED by the daily and
    # per-evaluator spend caps. A negative row would not merely misreport - it
    # would subtract from the day's total and buy back headroom the caps exist
    # to deny. Counts come straight from Google's `usageMetadata`, so a negative
    # should be impossible; that is exactly why it is worth one line to make it
    # harmless rather than load-bearing on an external field staying sane.
    tokens_in = max(0, int(tokens_in or 0))
    out_tokens = max(0, int(tokens_out or 0)) + max(0, int(thoughts or 0))
    if tokens_in > LONG_CONTEXT_THRESHOLD_TOKENS and "long_in" in price:
        rate_in = price["long_in"]
        rate_out = price.get("long_out", price["out"])
    else:
        rate_in = price["in"]
        rate_out = price["out"]
    # CACHED INPUT is part of `tokens_in` (promptTokenCount includes it) and
    # bills at a 90% discount on Gemini 2.5 and later, implicit or explicit.
    cached = min(tokens_in, max(0, int(cached or 0)))
    rate_cached = price.get("cached_in", rate_in * CACHED_INPUT_SHARE)
    token_cost = ((tokens_in - cached) * rate_in + cached * rate_cached
                  + out_tokens * rate_out) / 1_000_000.0
    return token_cost + int(image_count or 0) * price.get("image", 0.0)


def estimate_video_cost(model, video_seconds):
    """USD for one clip. Clamped for the same reason as `estimate_cost`."""
    return max(0.0, float(video_seconds or 0.0)) * video_rate_for(model)


# ---------------------------------------------------------------------------
# Capabilities
# ---------------------------------------------------------------------------
# Derived from naming rules, NOT from a membership list, so a model released
# after this file was written is classified correctly on arrival.
#
#   * `-image` in a Gemini ID means the model RETURNS a picture. It is not a
#     model that reads pictures -- every Gemini text model already does that.
#     Routing a text or JSON task here produces "Multi-modal output is not
#     supported" or a picture where JSON was expected.
#   * `veo-` / `imagen-` are separate families with their own request shape.

def is_image_generation_model(model):
    """True when the model's OUTPUT is a picture."""
    key = normalize_model_id(model)
    if not key:
        return False
    if key.startswith("imagen"):
        return True
    return "image" in key.split("-") or key.endswith("-image-generation")


def is_video_model(model):
    return normalize_model_id(model).startswith("veo")


def is_text_capable(model):
    """True when the model can be asked for text or JSON.

    Non-Google IDs return True: this module cannot know a third-party model's
    shape, and the guards that call this must fail OPEN so an unrecognised but
    correctly configured model is never silently ignored.
    """
    return not (is_image_generation_model(model) or is_video_model(model))


# ---------------------------------------------------------------------------
# Thinking configuration
# ---------------------------------------------------------------------------
# Gemini 2.5 accepts `thinkingConfig.thinkingBudget` (int, 0 disables).
# Gemini 3.x replaced it with `thinkingConfig.thinkingLevel` (enum) and REJECTS
# a request carrying both. `gemini-2.5-pro` accepts neither: it cannot have
# thinking disabled and 400s on budget 0.
#
# WHY 3.x DEFAULTS TO SENDING NOTHING
# -----------------------------------
# The old code sent `thinkingBudget: 0` to every model except `gemini-2.5-pro`,
# including `gemini-3.1-pro-preview` - which is what production actually runs.
# Google's own 3.x migration note ("if you used a thinking budget of 0 ... set
# your thinking level instead") only makes sense if the deprecated parameter is
# IGNORED on 3.x rather than honoured, and production has been calling
# successfully with it for months, so it cannot be an error either. The
# conclusion is that live traffic has been running 3.1 Pro at its DEFAULT
# reasoning depth all along.
#
# Which makes "translate budget 0 into level LOW" a silent quality reduction on
# live grading rather than a bug fix. So the translation is OPT-IN: with no
# level configured we send no thinking field at all for 3.x, which reproduces
# today's effective behaviour exactly and cannot be rejected. Setting
# `assessments_be_v2.thinking_level` to LOW is then a deliberate, reversible
# cost decision instead of a side effect of a refactor.
#
# LOW, not MINIMAL, is the recommended floor: MINIMAL is the documented budget-0
# equivalent on some 3.x models but an explicit validation error on 3.8 Flash,
# so LOW is the only value valid across the whole range.
THINKING_STYLE_NONE = "none"
THINKING_STYLE_BUDGET = "budget"
THINKING_STYLE_LEVEL = "level"

# The cheapest level that is valid on every 3.x model, and so the one to reach
# for when trading quality for cost. Not a default - see the note above.
MINIMAL_THINKING_LEVEL = "LOW"

# Accepted `thinkingLevel` values. MINIMAL is deliberately absent - see above.
THINKING_LEVELS = ("LOW", "MEDIUM", "HIGH")

# Families that reject every attempt to turn thinking down. Prefix-matched.
_THINKING_NOT_CONFIGURABLE = ("gemini-2.5-pro",)


def thinking_style(model):
    key = normalize_model_id(model)
    if not key:
        return THINKING_STYLE_NONE
    if any(key.startswith(x) for x in _THINKING_NOT_CONFIGURABLE):
        return THINKING_STYLE_NONE
    if key.startswith("gemini-2.") or key.startswith("gemini-1."):
        return THINKING_STYLE_BUDGET
    if key.startswith("gemini-3") or key.startswith("gemini-4"):
        return THINKING_STYLE_LEVEL
    # Unknown or third-party: send nothing. An unrecognised generationConfig
    # key is a 400 on most providers, and a silent 400 here would look like a
    # model outage rather than a config problem.
    return THINKING_STYLE_NONE


def normalize_thinking_level(level):
    """Validate a configured level. Returns "" for anything unusable.

    An unrecognised string must NOT be forwarded to Google - it would 400 the
    call, and a 400 on every request reads as a model outage rather than as a
    typo in a settings field.
    """
    value = (level or "").strip().upper()
    return value if value in THINKING_LEVELS else ""


def apply_thinking(gen_config, model, level=None):
    """Set the thinking field `model`'s generation actually accepts.

    Mutates `gen_config` in place and returns it.

      * Gemini 2.5 (except 2.5 Pro) -> `thinkingBudget: 0`, unchanged behaviour.
      * Gemini 3.x -> `thinkingLevel` ONLY when `level` is a configured, valid
        value. With no level, nothing is sent and the model keeps its default
        depth, which is what production has effectively been getting.
      * 2.5 Pro, Veo, and anything unrecognised -> nothing. 2.5 Pro 400s on
        budget 0, and a non-Google provider would 400 on a Google-shaped key.
    """
    style = thinking_style(model)
    if style == THINKING_STYLE_BUDGET:
        gen_config["thinkingConfig"] = {"thinkingBudget": 0}
    elif style == THINKING_STYLE_LEVEL:
        wanted = normalize_thinking_level(level)
        if wanted:
            gen_config["thinkingConfig"] = {"thinkingLevel": wanted}
    return gen_config
