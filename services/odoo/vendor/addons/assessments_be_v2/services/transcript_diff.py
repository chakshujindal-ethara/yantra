# -*- coding: utf-8 -*-
"""Word-by-word differences between a candidate's transcription and the correct one.

The Transcription question is graded by the LLM judge, which decides whether each mistake is critical or
minor, the way the client's auditors do. A model reading two Hindi lines can miss a one-mark difference
(है for हैं), so the judge is handed the differences first, already sorted by the client's QC rules
(QC_AGENT.md sections 4-5): what the client never counts is folded away (the sign that writes a nasal,
a nukta, ये/यह, वो/वह, a hyphen or a space in a repeated word, and any place the correct text marks
(( )) or {{ }}), a difference whose size the guide fixes carries a `rule`, and the same difference
again is one entry with `times`. Everything without a `rule` is still the judge's to weigh.

A marker with its words is one token, as the transcription guide writes it. The word alignment follows
Strix's checker (custom_addons/strix services/qc.py, difflib over tokens), cut down to one reference.
"""
import difflib
import re
import unicodedata

# (( ... )) and {{ ... }} stay one token with their words; everything else splits on spaces.
_TOKEN = re.compile(r"\(\([^)]*\)\)|\{\{[^}]*\}\}|\S+")
_MARK = re.compile(r"\(\([^)]*\)\)|\{\{[^}]*\}\}")
_REPEAT = re.compile(r"(?<!\S)([^\s(){}-]+)-\1(?!\S)")   # ना-ना == ना ना (QC section 5)
_NUKTA = re.compile("([कखगजफ])\u093c")                   # ड़ ढ़ are letters of their own: kept
_SAME = {"यह": "ये", "वह": "वो"}
_DIGIT = re.compile(r"\d")                                # 0-9 and ०-९
_LETTER = re.compile(r"[a-z]\.")
_KIND = {"insert": "missing", "delete": "added", "replace": "different"}


def tokens(text):
    return _TOKEN.findall(_REPEAT.sub(r"\1 \1", unicodedata.normalize("NFC", text or "")))


def _key(token):
    """What a token compares as: ँ reads as ं, and NFC already splits ज़ into ज + ़."""
    t = _NUKTA.sub(r"\1", token.replace("\u0901", "\u0902"))
    return _SAME.get(t, t)


def _rule(got, want):
    """The guide's own size for this difference, or "" for the judge to weigh.

    `got` is the answer's tokens at the place, `want` the correct text's.
    """
    if want and any(_MARK.fullmatch(t) for t in got) and not any(_MARK.fullmatch(t) for t in want):
        return "mark_on_clear_words"
    if _DIGIT.search(" ".join(got)) and not _DIGIT.search(" ".join(want)):
        return "digit"
    typed = "".join(got)
    if want and all(_LETTER.fullmatch(t) for t in want) and "." not in typed \
            and typed.lower() == "".join(t[0] for t in want):
        return "lone_letter" if len(want) == 1 else "letters_without_periods"
    if len(got) == len(want) == 1 and len(want[0]) > 1 and want[0].endswith("-") \
            and len(got[0]) >= len(want[0]) and got[0].startswith(want[0][:-1]):
        return "cut_off_in_full"
    if len(got) == 1 and len(want) > 1 and got[0] == "".join(want):
        return "joined_words"
    return ""


def _letters(want):
    return len(want) > 1 and all(_LETTER.fullmatch(t) for t in want)


def word_differences(answer, correct):
    """Each place the answer departs from the correct transcription, in reading order.

    `missing`: words of the correct text the answer leaves out; `added`: words the answer has that the
    correct text does not; `different`: the answer's words where the correct text has others, word for
    word when both sides have as many (a run of spoken letters stays one). `after` is the correct word
    just before the place, so a reader can find it. `rule` and `times` only when they apply.
    """
    mine, right = tokens(answer), tokens(correct)
    places = []
    ops = difflib.SequenceMatcher(
        None, [_key(t) for t in mine], [_key(t) for t in right], autojunk=False).get_opcodes()
    for op, i1, i2, j1, j2 in ops:
        if op == "equal":
            continue
        if op == "replace" and i2 - i1 == j2 - j1 > 1 and not _letters(right[j1:j2]):
            for i, j in zip(range(i1, i2), range(j1, j2)):
                # A run of spoken letters beside another difference stays one place.
                if j > j1 and places[-1][4] == j and _LETTER.fullmatch(right[j]) \
                        and _LETTER.fullmatch(right[j - 1]):
                    places[-1] = (op, places[-1][1], i + 1, places[-1][3], j + 1)
                else:
                    places.append((op, i, i + 1, j, j + 1))
        else:
            places.append((op, i1, i2, j1, j2))
    found, seen = [], {}
    for op, i1, i2, j1, j2 in places:
        got, want = mine[i1:i2], right[j1:j2]
        if [_key(t) for t in got] == [_key(t) for t in want] \
                or (want and all(_MARK.fullmatch(t) for t in want)):
            continue
        entry = {"kind": _KIND[op], "answer": " ".join(got), "correct": " ".join(want),
                 "after": right[j1 - 1] if j1 else ""}
        same = (entry["kind"], entry["answer"], entry["correct"])
        if same in seen:
            seen[same]["times"] = seen[same].get("times", 1) + 1
            continue
        rule = _rule(got, want)
        if rule:
            entry["rule"] = rule
        seen[same] = entry
        found.append(entry)
    return found


def _genders(clip):
    speakers = clip.get("speakers") if isinstance(clip.get("speakers"), list) else []
    return sorted(str((s if isinstance(s, dict) else {}).get("gender") or "unknown")
                  for s in speakers)


def clip_differences(answer, correct):
    """The clip answers that differ, as {field: {"answer": ..., "correct": ...}}; {} when none.

    A wrong category is one mistake alone: nothing that follows from it counts again. The
    characteristics compare as a set, without laughter, and without human noise when either side
    hears laughter. Speakers compare as their genders, a set: order and nativity are never compared.
    """
    answer = answer if isinstance(answer, dict) else {}
    correct = correct if isinstance(correct, dict) else {}
    category = (answer.get("category") or "none", correct.get("category") or "none")
    if category[0] != category[1]:
        return {"category": {"answer": category[0], "correct": category[1]}}
    picked = [set(c.get("characteristics") or []) for c in (answer, correct)]
    # ponytail: QC section 5 "Laughter with or without Human Noise" - a laugh ticked as
    # human noise is never a mistake.
    ignored = {"laughter", "human_noise"} if "laughter" in picked[0] | picked[1] else {"laughter"}
    found = {}
    tags = [sorted(p - ignored) for p in picked]
    if tags[0] != tags[1]:
        found["characteristics"] = {"answer": tags[0], "correct": tags[1]}
    genders = [_genders(answer), _genders(correct)]
    if genders[0] != genders[1]:
        found["speakers"] = {"answer": genders[0], "correct": genders[1]}
    return found


def demo():
    """The QC worked examples (QC_AGENT.md section 6b), with the key in the
    hearing's place: it is what was said. Stdlib only:
    `python3 services/transcript_diff.py`."""
    def found(answer, correct):
        return [(f["kind"], f["answer"], f["correct"], f.get("rule", ""))
                for f in word_differences(answer, correct)]

    assert found("तो ये देखो", "तो  ये देखो") == []
    # 1, 2: a mark on words said clearly, or a guess inside one.
    assert found("आज {{मौसम}} अच्छा है", "आज मौसम अच्छा है") == [
        ("different", "{{मौसम}}", "मौसम", "mark_on_clear_words")]
    assert found("वो ((बाज़ार)) गया था", "वो बाज़ार गया था") == [
        ("different", "((बाज़ार))", "बाज़ार", "mark_on_clear_words")]
    # 3: the key marks the place too, and speech it marks is never judged.
    assert found("((कल)) मिलते हैं", "((कल)) मिलते हैं") == []
    assert found("आज मिलते हैं", "((कल)) मिलते हैं") == []
    # 4: a repeated word typed once.
    assert found("यह बहुत अच्छा है", "यह बहुत बहुत अच्छा है") == [
        ("missing", "", "बहुत", "")]
    # 8: letters said one by one, run together (minor); one letter alone
    # without its period is critical.
    assert found("मेरा gst number", "मेरा g. s. t. number") == [
        ("different", "gst", "g. s. t.", "letters_without_periods")]
    assert found("मेरा g s t number", "मेरा g. s. t. number") == [
        ("different", "g s t", "g. s. t.", "letters_without_periods")]
    assert found("option c लो", "option c. लो") == [
        ("different", "c", "c.", "lone_letter")]
    # The same run beside another difference is still one minor, not one
    # critical per letter.
    assert found("मेरा g s t नंबर", "मेरा g. s. t. number") == [
        ("different", "g s t", "g. s. t.", "letters_without_periods"),
        ("different", "नंबर", "number", "")]
    # 9: a word said as a word stays a word.
    assert found("नया form भरना है", "नया form भरना है") == []
    # 11: a cut-off word typed in full.
    assert found("जब वो आया", "ज- वो आया") == [
        ("different", "जब", "ज-", "cut_off_in_full")]
    # 12: the nasal sign is never reported; the other-language word is left
    # to the judge, unlabelled.
    assert found("पाँच सौ रुपये", "पांच सौ rupees") == [
        ("different", "रुपये", "rupees", "")]
    # Never reported (QC section 5): ये/यह, वो/वह, a nukta, a hyphen in a repeat.
    assert found("यह अच्छा है वह गया", "ये अच्छा है वो गया") == []
    assert found("जरूर ना ना", "ज़रूर ना-ना") == []
    # Numbers are words: a digit, English or Devanagari, is critical.
    assert found("500 रुपये", "पाँच सौ रुपये") == [
        ("different", "500", "पाँच सौ", "digit")]
    assert found("५०० रुपये", "पाँच सौ रुपये")[0][3] == "digit"
    # Two words typed as one.
    assert found("उस केलिए", "उस के लिए") == [
        ("different", "केलिए", "के लिए", "joined_words")]
    # Different words are separate mistakes; the same one again is one, with
    # how often it occurs.
    assert found("उसने पानी बनाया", "उसने खाना खाया") == [
        ("different", "पानी", "खाना", ""), ("different", "बनाया", "खाया", "")]
    twice = word_differences("मै गया मै आया", "मैं गया मैं आया")
    assert [(f["answer"], f["correct"], f.get("times")) for f in twice] == [
        ("मै", "मैं", 2)], twice
    # The old line: the nasal goes, the key's ((बैंक)) place goes, the rest
    # splits word for word.
    assert found("मेरा नाम मैं दिल्ली से हूं मेरी जॉब बैंक में",
                 "मेरा नाम म्हम् मैं दिल्ली से हूँ मेरी job ((बैंक)) में") == [
        ("missing", "", "म्हम्", ""), ("different", "जॉब", "job", "")]
    # A filler the key does not have was not said.
    assert [f["kind"] for f in word_differences(
        "i uh uh think so", "i uh think so")] == ["added"]

    # The clip answers: speakers are a set of genders, the tags one mistake.
    key = {"category": "none",
           "characteristics": ["background_speech", "laughter"],
           "speakers": [{"gender": "masculine", "nativity": "native"},
                        {"gender": "feminine", "nativity": "native"}]}
    swapped = dict(key, characteristics=["background_speech", "human_noise"],
                   speakers=[{"gender": "feminine", "nativity": "non_native"},
                             {"gender": "masculine", "nativity": "unknown"}])
    assert clip_differences(swapped, key) == {}
    assert list(clip_differences(dict(key, speakers=key["speakers"][:1]),
                                 key)) == ["speakers"]
    assert list(clip_differences(
        dict(key, characteristics=["cross_talk", "audio_artifact"]),
        key)) == ["characteristics"]
    assert clip_differences(dict(key, category="no_speech"), key) == {
        "category": {"answer": "no_speech", "correct": "none"}}
    return True


if __name__ == "__main__":
    print("transcript_diff demo:", demo())
