# -*- coding: utf-8 -*-
"""Pre-LLM integrity gates for subjective/image scoring (Phase 1).

These run BEFORE the Vertex grader in services/scoring.py. A blank answer or a
prompt-injection attempt is resolved to a raw score of 0 locally and the LLM is
never called for that answer. The gate outcome is composed into the SAME
immutable llm_raw_100 the grader would write (never a second scoring path);
gate name and flags ride in the llm_result_json audit trail.

Pure Python, no Odoo imports, so it is unit-testable in isolation.
"""
import re
import unicodedata

from ..constants import (
    INTEGRITY_GATE_PATTERNS, GATE_EMPTY_ANSWER, GATE_INJECTION_ATTEMPT,
)

_INJECTION_RES = tuple(
    re.compile(pattern, re.IGNORECASE) for pattern in INTEGRITY_GATE_PATTERNS)

# Zero-width / bidi / joiner code points a candidate can splice INTO an idiom
# ("ignore\u200bthe rubric") to slip past a naive regex. Stripped before match.
_ZERO_WIDTH_RE = re.compile(
    "[\u200b\u200c\u200d\u200e\u200f\u202a-\u202e\u2060\u2061\u2062"
    "\u2063\u2064\ufeff\u180e]")

# Compact confusable fold: the highest-frequency Cyrillic/Greek glyphs that look
# identical to ASCII letters, used to spell an idiom in lookalikes ("ignоre the
# rubric" with a Cyrillic 'о'). NFKC does NOT collapse these, so we map the
# common ones to their Latin twin before matching. Match-only - never stored.
_CONFUSABLES = {
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y",
    "к": "k", "н": "h", "в": "b", "м": "m", "т": "t",          # Cyrillic
    "ѕ": "s", "і": "i", "ј": "j", "ԁ": "d", "ɡ": "g",
    "ο": "o", "α": "a", "ρ": "p", "ν": "v", "ε": "e", "ι": "i",  # Greek
    "τ": "t", "υ": "u", "κ": "k", "χ": "x",
}
_CONFUSABLE_TABLE = {ord(k): v for k, v in _CONFUSABLES.items()}

# A blank line separates two ANSWERS, and an idiom must not form across it.
# Replaced with a character no pattern contains, so `.{0,40}` cannot bridge
# two paragraphs: "...free of watermark\n\nThe audio is perfect" is two
# statements, not one attempt to coerce a perfect score.
_PARAGRAPH_RE = re.compile(r"\n\s*\n+")
_PARAGRAPH_SENTINEL = "\n"


def _normalize_for_gate(text):
    """Aggressively normalize candidate text for injection matching ONLY.

    NFKC folds compatibility forms, zero-width/bidi controls are DELETED,
    common Cyrillic/Greek homoglyphs are folded to their Latin twin, and
    internal whitespace runs collapse so "ignore   the rubric" and
    "ignore\\n\\nthe rubric" match the same idiom. The result is used purely to
    decide is_injection_attempt; the ORIGINAL text is what gets stored/graded.

    ZERO-WIDTH CHARS ARE DELETED, NOT SPACED. Substituting a space turned the
    exact evasion this strip exists to stop - "ign<U+200B>ore the rubric" -
    into "ign ore the rubric", which matches nothing: the splice defeated the
    gate instead of being defeated by it. The docstring already claimed
    "removed"; the code said `.sub(" ", ...)`.

    A PARAGRAPH BREAK IS NOT A SPACE. Collapsing every whitespace run to one
    space let an idiom form ACROSS two unrelated answers: a candidate wrote
    "...free of watermark" and, two paragraphs later, "the audio is perfect",
    and the joined text put those 8 characters apart - inside the 40-character
    window of the perfect-score pattern. Blank lines become a sentinel the
    patterns cannot match through, so each paragraph is judged on its own while
    single newlines still collapse for the wrapped-idiom case.
    """
    normalized = unicodedata.normalize("NFKC", text or "")
    normalized = _ZERO_WIDTH_RE.sub("", normalized)
    normalized = normalized.translate(_CONFUSABLE_TABLE)
    normalized = _PARAGRAPH_RE.sub(_PARAGRAPH_SENTINEL, normalized)
    normalized = re.sub(r"[^\S\n]+", " ", normalized)
    return normalized


def is_empty_answer(text):
    # Strip zero-width/bidi controls first: a candidate can submit a lone
    # U+200B/U+FEFF that looks blank but is "content" to a naive .strip(),
    # which would send an empty answer to the paid grader instead of gating it.
    cleaned = _ZERO_WIDTH_RE.sub("", text or "")
    return not cleaned.strip()


def is_injection_attempt(text):
    candidate = text or ""
    if not candidate.strip():
        return False
    folded = _normalize_for_gate(candidate)
    return any(rx.search(folded) for rx in _INJECTION_RES)


def evaluate_gates(text):
    """Return the gate dict for this candidate text, or None when it is clean.

    empty_answer is screened first (blank text carries no injection); an
    injection attempt raises integrity_alert so the audit trail distinguishes a
    deliberate cheat from an honest blank.
    """
    if is_empty_answer(text):
        return {"gate": GATE_EMPTY_ANSWER, "flags": []}
    if is_injection_attempt(text):
        return {"gate": GATE_INJECTION_ATTEMPT, "flags": ["integrity_alert"]}
    return None
