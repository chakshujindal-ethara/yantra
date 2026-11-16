"""Compare every key a serializer SENDS with every key the Dart client READS.

`contract_audit.py` audits the other direction - what the client sends against
what each route reads - and its docstring names the three bugs that justified
it. All three were client-to-server.

The next bug was server-to-client, and nothing was watching. `draft_detail`
sent `dimensions` out of `dimensions_json`, a column the generator fills for
image_ab and nothing else, so every mcq and msq went over the wire as
`dimensions: []` while its answer key sat in a different column. The client read
the key it was given, found none, rendered five options as zero and printed "no
correct option marked" over a question the server had stored correctly. There
was no error to see: a key the client reads and the server never populates is
silence in exactly the way an unread request key is.

WHAT THIS CATCHES, AND WHAT IT CANNOT. It compares NAMES. A key that is present
but computed from the wrong column looks identical to a correct one from here -
that is what `tests/test_response_contract.py` is for, and the two are meant to
be read together. This is the cheap check that runs without a database.

    FAIL  a key the client reads that no serializer in its group emits.
    WARN  a key a serializer emits that no parser reads. Often fine - the
          module sends more than any one screen needs - but it is also what a
          half-finished feature looks like.

Exit 2 when either side cannot be read - and equally when a self-test below
shows the parser has stopped recovering keys it demonstrably should - because a
check that silently compares nothing is worse than no check: `contract_audit.py`
spent its early life pointing at a directory that had never existed, reporting
OK on every run. Both cases go through `bail()`; see its docstring for why they
did not actually exit 2 for a long time.

    ETP_FE_MODELS   path to models.dart, if not the default sibling checkout
"""
import ast
import os
import pathlib
import re
import sys

BE = pathlib.Path(__file__).resolve().parent.parent
FE = pathlib.Path(os.environ.get(
    "ETP_FE_MODELS",
    BE.parents[2] / "ethara-assessment-fe"
    / "lib" / "assessment" / "domain" / "models.dart"))

SERIALIZERS = BE / "controllers" / "api" / "serializers.py"

# Which serializers can produce the payload a given Dart parser is handed.
#
# Written by hand, and it has to be: nothing in either file records the link, and
# guessing it from name similarity would produce confident nonsense. A parser is
# checked against the UNION of its group, because a client reads one shape from
# several routes - `Question.fromJson` parses a draft row, a draft detail, a bank
# row and a bank detail, and a key on any of them is a key it may legitimately
# look for.
GROUPS = {
    "Question": ["draft_row", "draft_detail",
                 "bank_question_row", "bank_question_detail"],
    "QDimension": ["draft_dimensions"],
    "Generator": ["generator_row", "generator_detail"],
    "Assessment": ["assessment_row", "assessment_detail"],
    "Attempt": ["attempt", "evaluator_admin_row"],
    "Resource": ["resource_row"],
    "Tag": ["tag_row"],
    "LedgerRow": ["usage_row"],
    "Similarity": ["similarity_row"],
}

# Keys a parser may read that no serializer is expected to send: the seed
# fixtures speak camelCase and carry their own spellings, and every parser
# accepts both so the fixtures and the live API stay interchangeable.
# Verified one by one against the parser: each is read as a FALLBACK beside a
# key the server does send (`jval(j, 'error', jval(j, 'extractionError', ...))`),
# so its absence from the wire is the design rather than a gap.
FIXTURE_ONLY = {
    # Question
    "dims", "desc", "genId", "genName", "type", "videos", "boxKey",
    "labelBoxes", "subjectiveRubric", "hasValidKey", "answerKeyValid",
    "hasSourceReference", "hasRevealingOption", "rubricReviewed",
    "denyReason", "usedIn", "approvedOn", "sourceRef", "imageError",
    "imageState", "videoState", "correctAnswer", "mergeInto", "labels",
    "questionOrder", "extractionError", "category", "n",
    # Generator / Assessment
    "meta", "owner", "plannedCount", "sopFile", "updated", "generatorId",
    "generatorName", "passThreshold", "projectId",
    # Attempt - the seed fixtures hold a whole nested attempt
    "answeredCount", "assessmentName", "autoSubmitted", "candidate",
    "employeeId", "flags", "integrityAlert", "inviteError", "inviteState",
    "isLocked", "objective", "piiAnonymized", "resp", "resultsReleased",
    "scoreOutlier", "subjective", "totalQuestions", "violationAt",
    "violationCount", "violationReason",
    # Resource / Tag
    "error", "file", "kind", "pages", "size", "uses",
}

# Findings are printed but do not fail the build yet.
#
# The Dart side reads most keys through a `??` chain of two spellings, so a
# first pass is mostly aliases rather than defects - and `contract_audit.py`
# records what happens to a checker whose output nobody trusts: its wrapper
# ended up grepping for five hardcoded names instead of reading the result.
# Set ETP_RESPONSE_AUDIT_STRICT=1 to make a finding fail, once the alias list
# above has settled.
STRICT = bool(os.environ.get("ETP_RESPONSE_AUDIT_STRICT"))


def snake(camel):
    """The same camel -> snake rule `jget` applies before its second lookup."""
    return re.sub(r"[A-Z]", lambda m: "_" + m.group(0).lower(), camel)


def bail(message):
    """Print to stderr and exit 2 - the "cannot read" status this tool promises.

    Every one of these used to be `sys.exit("2: ...")`, which does NOT exit 2.
    Passing a string to sys.exit prints it to stderr and exits 1; the "2:" was
    just the first two characters of the message, so the contract in this
    module's docstring was never actually honoured and the `2) skp` branch in
    `tools/verify.sh` step 5b - written against that contract - could never be
    reached. An unreadable side was being reported as a failed audit rather
    than a skipped one, which is the opposite of what the wrapper wanted.
    """
    print(message, file=sys.stderr)
    sys.exit(2)


# server side
#
# ast, not a regex, for the reason contract_audit.py gives: the shapes here are
# built two ways. A `*_row` returns a dict literal; a `*_detail` calls its row
# and then `data.update({...})`. Reading only the literal would report every
# detail-only key as missing.

class Serializers:
    """Every `*_row` / `*_detail` function, and the keys it emits."""

    def __init__(self, tree):
        self.functions = {}
        self.calls = {}
        for node in tree.body:
            if isinstance(node, ast.FunctionDef):
                self.functions[node.name], self.calls[node.name] = \
                    self._emitted(node)

    @staticmethod
    def _dict_keys(node):
        if not isinstance(node, ast.Dict):
            return set()
        return {k.value for k in node.keys
                if isinstance(k, ast.Constant) and isinstance(k.value, str)}

    def _emitted(self, fn):
        """Every string key of every dict literal built anywhere in ``fn``.

        DELIBERATELY BROAD. A serializer builds its shape four ways in this
        file - `return {...}`, `data.update({...})`, `rows.append({...})` and a
        dict comprehension inside a list - and an extractor that knew only the
        first two reported the keys of `draft_dimensions` and `attempt` as
        never sent, which is the loudest possible false alarm from a tool whose
        whole job is to say what is missing.

        The cost of being broad is that a lookup table inside a serializer
        contributes its keys too. That direction is the safe one: it can only
        soften a WARN, never invent a FAIL.
        """
        keys, calls = set(), set()
        for sub in ast.walk(fn):
            keys |= self._dict_keys(sub)
            # `data["x"] = ...`
            if isinstance(sub, ast.Assign):
                for target in sub.targets:
                    if isinstance(target, ast.Subscript) and \
                            isinstance(target.slice, ast.Constant) and \
                            isinstance(target.slice.value, str):
                        keys.add(target.slice.value)
            if isinstance(sub, ast.Call):
                name = getattr(sub.func, "attr", None) \
                    or getattr(sub.func, "id", None)
                if name in self.functions:
                    calls.add(name)
        return keys, calls

    def resolve(self, name, seen=None):
        """Keys a function emits, plus those of the ones it builds on."""
        seen = seen if seen is not None else set()
        if name in seen or name not in self.functions:
            return set()
        seen.add(name)
        keys = set(self.functions[name])
        for callee in self.calls[name]:
            keys |= self.resolve(callee, seen)
        return keys


# client side

def dart_reads(src):
    """Every key each `fromJson` looks for, by the entity that reads it."""
    factories = re.finditer(
        r"factory (\w+)\.fromJson\([^)]*\)"
        r"(.*?)(?=\n  (?:factory|static|Map<String)|\n\}\n)",
        src, re.S)
    reader = re.compile(r"j(?:get|val|obj|tags)\(\s*j\s*,\s*'([A-Za-z_0-9]+)'")
    out = {}
    for m in factories:
        out.setdefault(m.group(1), set()).update(
            k.group(1) for k in reader.finditer(m.group(2)))
    return out


def main():
    if not SERIALIZERS.is_file():
        bail("no serializers at %s - nothing to audit" % SERIALIZERS)
    if not FE.is_file():
        bail("no Dart models at %s - set ETP_FE_MODELS" % FE)

    server = Serializers(ast.parse(SERIALIZERS.read_text(),
                                   filename=str(SERIALIZERS)))
    if not server.functions:
        bail("parsed no functions from %s - the parser is broken" % SERIALIZERS)

    client = dart_reads(FE.read_text())
    if not client:
        bail("parsed no fromJson bodies from %s - the parser is broken" % FE)

    # SELF-TEST, because the failure this parser can have is silent. These are
    # keys both sides demonstrably handle; if they are not recovered the audit
    # is under-reading and every OK it prints is worthless.
    probe_server = server.resolve("draft_detail")
    for want in ("dimensions", "has_valid_key", "official_reasoning",
                 "answer_key"):
        if want not in probe_server:
            bail("parser self-test failed - draft_detail read as %s, "
                 "missing %r" % (sorted(probe_server), want))
    if "options" not in client.get("Question", set()):
        bail("parser self-test failed - Question.fromJson read as %s"
             % sorted(client.get("Question", set())))

    unread, missing = [], []
    for entity, fns in GROUPS.items():
        reads = client.get(entity)
        if reads is None:
            print("  ?    %s has no fromJson - renamed?" % entity)
            continue
        sends = set()
        for fn in fns:
            if fn not in server.functions:
                print("  ?    %s: no serializer named %s" % (entity, fn))
                continue
            sends |= server.resolve(fn)

        for key in sorted(reads):
            if key in FIXTURE_ONLY:
                continue
            if key not in sends and snake(key) not in sends:
                missing.append((entity, key, sorted(fns)))
        for key in sorted(sends - {snake(k) for k in reads} - reads):
            unread.append((entity, key))

    print()
    if unread:
        print("WARN  %d key(s) sent that no parser reads" % len(unread))
        for entity, key in unread:
            print("    %-12s %s" % (entity, key))
        print()

    print("=" * 72)
    if not missing:
        print("OK  every key the client reads is sent by its serializers "
              "(%d entities checked)" % len(GROUPS))
        return 0

    print("%s  %d key(s) the client reads that nothing sends"
          % ("FAIL" if STRICT else "REVIEW", len(missing)))
    for entity, key, fns in missing:
        print("\n  %s.fromJson reads %r" % (entity, key))
        print("    no serializer in %s emits it" % fns)
    if not STRICT:
        print("\n  (report-only. Each is either a fixture-only spelling to add"
              "\n   to FIXTURE_ONLY, or a real gap. Set"
              " ETP_RESPONSE_AUDIT_STRICT=1 to fail.)")
    return 1 if STRICT else 0


if __name__ == "__main__":
    sys.exit(main())
