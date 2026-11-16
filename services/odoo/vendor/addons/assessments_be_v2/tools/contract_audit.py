"""Compare every key the Dart client SENDS with every key each route READS.

Three bugs of this exact class shipped before this existed:
  person_ids   vs applicant_ids       - nobody could be assigned
  dry_run      vs confirm             - no assessment could be launched
  option_ids   vs selected_option_ids - every MCQ answer was discarded

None produced an error. The server reads what it asks for, sees nothing, and
carries on: an unread key is silence, not a 400. Only a diff of the two sides
finds them.

NOT WIRED INTO CI - run it yourself, or through `tools/verify.sh` (gate 5). This
docstring used to claim it ran in CI. It does not: the repo's only workflow is
`.github/workflows/security-scan.yaml`, which never invokes this script, has no
`pull_request` trigger, and is gated on a `prod:` commit-message prefix.

Exit 1 on any key the client sends that no handler for that path reads.
Exit 2 when either side cannot be read, because a check that silently finds
nothing to compare is worse than no check: this script previously pointed at
`assessments_be_v2/controllers/api/`, a directory that has never existed - the
API lives in this addon. The server side came back empty, every client path
reported "no matching route found" (a warning, not a failure), and the audit
exited 0 having compared nothing.

    ETP_FE_CLIENT   path to api_client.dart, if not the default sibling checkout
"""
import ast
import os
import pathlib
import re
import sys

BE = pathlib.Path(__file__).resolve().parent.parent
FE = pathlib.Path(os.environ.get(
    "ETP_FE_CLIENT",
    BE.parents[2] / "ethara-assessment-fe"
    / "lib" / "assessment" / "data" / "api_client.dart"))

# Keys every route accepts for free, or that the transport adds.
UNIVERSAL = {"limit", "offset", "db", "context", "search", "order"}

# The param readers. `arg` is the raw one; the rest coerce.
READERS = {"arg", "str_arg", "int_arg", "bool_arg", "float_arg", "id_list_arg"}


# The client builds every path from a compile-time prefix constant rather than
# a literal - `_call('$kApiPrefix/assessments/...')` - so these have to be
# resolved BEFORE the generic `$ident -> *` collapse below. Without them
# `$kApiPrefix/...` normalised to `*/assessments/*/assign` while the server form
# normalised to `/api/v1/assessments/*/assign`: the two never compared equal, so
# EVERY client call fell into the "no matching route found" report-only branch
# and the audit printed OK having compared nothing at all. Its own self-test is
# what refused to let that pass silently.
#
# The values match the build defaults in the frontend Makefile (API_PREFIX,
# GATEWAY_PREFIX, MEDIA_PREFIX).
CLIENT_PREFIXES = {
    "kApiPrefix": "/api/v1",
    "kGatewayPrefix": "/api/v1",
    "kMediaPrefix": "/assessments_be",
}


def route_key(path):
    """Normalise a path so client and server forms compare equal."""
    p = path.split("?", 1)[0]
    p = re.sub(r"<[^>]+>", "*", p)
    for name, value in CLIENT_PREFIXES.items():
        p = p.replace("${%s}" % name, value).replace("$%s" % name, value)
    p = re.sub(r"\$\{?[A-Za-z_][A-Za-z0-9_.]*\}?", "*", p)
    return p.rstrip("/")


# server side
#
# WHY ast AND NOT A REGEX. A regex sees only literal `str_arg("name")` calls in
# the route body, and this API reads most of its input two other ways:
#
#   * field allow-lists - `_picked(ASSESSMENT_FIELDS)`, where the accepted keys
#     are a module-level dict, not call arguments;
#   * shared helpers - `/exam/<t>/answer` reads justification, label_answers and
#     selected_option_ids inside `self._record_response`, not in the handler.
#
# The regex version reported all of those as ignored. Nine of its twelve
# findings were false, which is why the shell wrapper around it ended up
# grepping for five hardcoded names instead of trusting the output - a check
# that cannot fail. Resolving constants and following same-file helpers is what
# makes the exit code worth acting on.

def _string_keys(node):
    """Literal string keys of a dict/set/list/tuple constant."""
    if isinstance(node, ast.Dict):
        return {k.value for k in node.keys
                if isinstance(k, ast.Constant) and isinstance(k.value, str)}
    if isinstance(node, (ast.Set, ast.List, ast.Tuple)):
        return {e.value for e in node.elts
                if isinstance(e, ast.Constant) and isinstance(e.value, str)}
    return set()


class FileIndex:
    """Every function in one file, with what it reads and whom it calls."""

    # `kw.get("body")` is a fourth read pattern, alongside the arg() helpers.
    # Scoped to these receivers so an unrelated dict lookup is not mistaken for
    # a payload read.
    PAYLOAD_NAMES = {"kw", "kwargs", "params", "payload", "vals", "body"}

    def __init__(self, tree):
        self.consts = {}        # NAME -> {"key", ...}
        self._aliases = set()   # locals bound to the request payload
        self.reads = {}         # func name -> {"key", ...}
        self.calls = {}         # func name -> {func name, ...}
        self.routes = []        # (path, func name)
        # Two passes: an allow-list defined further down the class body than
        # the handler that uses it must still resolve.
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        keys = _string_keys(node.value)
                        if keys:
                            self.consts[target.id] = keys
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef):
                self._index_function(node)

    def _const_keys(self, node):
        """Keys of an allow-list referenced as NAME or self.NAME."""
        if isinstance(node, ast.Name):
            return self.consts.get(node.id, set())
        if isinstance(node, ast.Attribute):
            return self.consts.get(node.attr, set())
        return set()

    def _is_payload_get(self, call):
        """True for `kw.get("x")` / `body().get("x")` and friends."""
        func = call.func
        if not (isinstance(func, ast.Attribute) and func.attr == "get"):
            return False
        recv = func.value
        if isinstance(recv, ast.Name):
            # A LOCAL ALIAS COUNTS TOO. `payload = body()` then
            # `payload.get("remark")` is the same read as `body().get(...)`,
            # but matching on the receiver NAME alone missed it whenever the
            # local was called something outside PAYLOAD_NAMES. That is not
            # hypothetical: a route that read its remark through a local called
            # `raw` was reported here as IGNORING the key, a reviewer believed
            # the report, and chased a bug that did not exist. The aliases are
            # collected per function in `_index_function` below.
            return recv.id in self.PAYLOAD_NAMES or recv.id in self._aliases
        # body().get("x")
        return (isinstance(recv, ast.Call) and isinstance(recv.func, ast.Name)
                and recv.func.id in self.PAYLOAD_NAMES)

    def _index_function(self, fn):
        reads, calls = set(), set()
        # Locals bound to a payload call - `payload = body()`, `p = kw` - so a
        # read through the alias is still recognised as a read.
        self._aliases = set()
        for sub in ast.walk(fn):
            if isinstance(sub, ast.Assign) and len(sub.targets) == 1 and \
                    isinstance(sub.targets[0], ast.Name):
                val = sub.value
                if isinstance(val, ast.Call) and isinstance(val.func, ast.Name) \
                        and val.func.id in self.PAYLOAD_NAMES:
                    self._aliases.add(sub.targets[0].id)
                elif isinstance(val, ast.Name) and val.id in self.PAYLOAD_NAMES:
                    self._aliases.add(sub.targets[0].id)
        for sub in ast.walk(fn):
            if isinstance(sub, (ast.Name, ast.Attribute)):
                reads |= self._const_keys(sub)
            if not isinstance(sub, ast.Call):
                continue
            first = sub.args[0] if sub.args else None
            literal = (first.value if isinstance(first, ast.Constant)
                       and isinstance(first.value, str) else None)
            name = None
            if isinstance(sub.func, ast.Name):
                name = sub.func.id
            elif isinstance(sub.func, ast.Attribute):
                name = sub.func.attr          # self._helper(...) -> _helper
            if self._is_payload_get(sub):
                if literal:
                    reads.add(literal)
            elif name in READERS:
                if literal:
                    reads.add(literal)
            elif name:
                calls.add(name)
        self.reads[fn.name] = reads
        self.calls[fn.name] = calls
        for dec in fn.decorator_list:
            if not (isinstance(dec, ast.Call)
                    and getattr(dec.func, "attr", "") == "route"):
                continue
            for arg in dec.args:
                for path in ([arg] if isinstance(arg, ast.Constant)
                             else getattr(arg, "elts", [])):
                    if isinstance(path, ast.Constant) and \
                            isinstance(path.value, str):
                        self.routes.append((path.value, fn.name))

    def resolve(self, fn_name, seen=None):
        """Keys read by a function, plus every same-file function it calls."""
        seen = seen if seen is not None else set()
        if fn_name in seen or fn_name not in self.reads:
            return set()
        seen.add(fn_name)
        keys = set(self.reads[fn_name])
        for callee in self.calls[fn_name]:
            keys |= self.resolve(callee, seen)
        return keys


api_dir = BE / "controllers" / "api"
if not api_dir.is_dir():
    sys.exit(f"2: no controllers at {api_dir} - nothing to audit")
if not FE.is_file():
    sys.exit(f"2: no Dart client at {FE} - set ETP_FE_CLIENT")

server = {}
for py in sorted(api_dir.glob("*.py")):
    index = FileIndex(ast.parse(py.read_text(), filename=str(py)))
    for path, fn_name in index.routes:
        server.setdefault(route_key(path), set()).update(index.resolve(fn_name))

# The client signs in at /api/v1/auth_token and /api/v1/refresh_token, which
# belong to api_auth_gateway - the reason it is a hard dependency in the
# manifest. Their paths are collected so they do not show up as "no matching
# route", but their KEYS are not audited: that is another module's contract,
# and its controllers are one large file where following every helper unions
# most of the codebase into one meaningless read-set.
foreign = set()
gateway = BE.parent / "api_auth_gateway" / "controllers"
if gateway.is_dir():
    for py in sorted(gateway.glob("*.py")):
        index = FileIndex(ast.parse(py.read_text(), filename=str(py)))
        foreign |= {route_key(p) for p, _ in index.routes}
foreign -= set(server)

if not server:
    sys.exit(f"2: found no @http.route in {api_dir} - the parser is broken")

# client side
dart = FE.read_text()
client = {}
# Each `_call('<path>', <body>)`; the body runs to the closing `});`.
# `,?` before the closing paren: `dart format` writes multi-line calls with a
# TRAILING COMMA - `<String, dynamic>{...},\n);` - and without tolerating it the
# optional group could not close, so the engine backtracked `(.*?)` across the
# newline (re.S) into the NEXT method's map and attributed its keys to THIS
# path. That produced a confident, wrong FAIL naming a route the client never
# sent those keys to.
#
# THE CLOSING BRACE IS FOUND BY COUNTING, NOT BY MATCHING. A non-greedy
# `(.*?)\}` closes at the FIRST `}` that satisfies the terminator, and a Dart 3
# record type inside the body - `for (final ({String name, String email}) i in
# invites)` - offers one: its `})` matched, so the capture stopped mid-token and
# every key after it was invisible.
#
# That blind spot is why `remove` shipped on the assign body, read by nothing on
# the server, with this audit reporting OK on every run. An audit that cannot
# see a key is worse than no audit, because it is trusted.
def _top_level_keys(text, start):
    """The `'key':` names written DIRECTLY in the map opening at ``start``.

    Returns ``(keys, end)`` where ``end`` indexes the map's closing brace, or
    ``(None, -1)`` if the braces never balance.

    Depth is tracked over `{}` and `[]` together, and only keys at the map's
    own level are collected. A nested `candidates: [{'name': ..}]` describes
    the shape of a LIST ELEMENT, not a key of the request body, and counting
    its keys as body keys made the audit fail on routes that were correct.

    String literals are skipped so a brace inside `'...'` or `"..."` cannot
    move the depth, and `\\` escapes are honoured inside them.

    COMMENTS ARE SKIPPED TOO, and that is not a nicety. This codebase documents
    every wire key in prose directly above it, and that prose contains
    apostrophes - "it to that user's applicant" sits inside the `/assign` body.
    With `//` runs treated as code, that lone `'` opened a string literal that
    then ran on until the NEXT quote in the file, which was the opening quote of
    `'user_ids'`. Every key after the first comment therefore became invisible:
    the audit read `/assign` as one key instead of four and was one apostrophe
    away from silently approving any contract at all.
    """
    keys, depth, i, quote, lit = set(), 0, start, "", ""
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                # A closing quote at the map's own level may be a key: it is
                # one exactly when the next non-space character is a colon
                # that is not part of `::` or `?:`.
                rest = text[i + 1:i + 3].lstrip()
                if depth == 1 and rest[:1] == ":" and re.fullmatch(
                        r"[a-z_0-9]+", lit):
                    keys.add(lit)
                quote, lit = "", ""
            else:
                lit += c
        elif c == "/" and text[i + 1:i + 2] == "/":
            nl = text.find("\n", i)
            if nl == -1:
                return None, -1
            i = nl
        elif c == "/" and text[i + 1:i + 2] == "*":
            close = text.find("*/", i + 2)
            if close == -1:
                return None, -1
            i = close + 1
        elif c in "'\"":
            quote, lit = c, ""
        elif c in "{[":
            depth += 1
        elif c in "}]":
            depth -= 1
            if depth == 0:
                return keys, i
        i += 1
    return None, -1


for m in re.finditer(r"_call\(\s*'([^']+)'\s*(?:,\s*<String,\s*dynamic>\s*(\{))?",
                     dart, re.S):
    key = route_key(m.group(1))
    found = set()
    if m.group(2):
        found, end = _top_level_keys(dart, m.start(2))
        if end == -1:
            sys.exit(f"2: unbalanced body braces after _call('{m.group(1)}')"
                     " - the parser is broken")
    client.setdefault(key, set()).update(found)

# SELF-TEST, because the failure this parser had was silent. `assign` is the
# call site that broke it: its body holds a Dart 3 record type and a key after
# it, so if the three keys below are not all recovered the audit is under-
# reading again and every OK it prints is worthless.
_assign = client.get(route_key("/api/v1/assessments/<id>/assign"), set())
_want = {"applicant_ids", "candidates", "remove"}
if not _want <= _assign:
    sys.exit(f"2: parser self-test failed - /assign body read as {sorted(_assign)},"
             f" missing {sorted(_want - _assign)}")

# the diff
problems = []
for path, sent in sorted(client.items()):
    if path in foreign:
        continue
    if path not in server:
        # A path the client calls that no route declares is its own bug, but
        # dynamic segments make false positives easy - report, do not fail.
        print(f"  ?    {path}  (no matching route found)")
        continue
    read = server[path] | UNIVERSAL
    unread = sent - read
    if unread:
        problems.append((path, sorted(unread), sorted(server[path])))

print()
print("=" * 72)
if not problems:
    print(f"OK  every key the client sends is read by its route "
          f"({len(client)} call sites checked)")
    sys.exit(0)

print(f"FAIL  {len(problems)} route(s) receive keys nothing reads")
for path, unread, reads in problems:
    print(f"\n  {path}")
    print(f"    client sends but server IGNORES: {unread}")
    print(f"    server actually reads          : {reads}")
sys.exit(1)
