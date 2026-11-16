# Gaps found by review, and the plan

2026-09-15. 31 agents reviewed both repos across five lenses; every finding was
then handed to an adversarial verifier. **16 survived, 10 were refuted.** Only
the survivors are below.

**Update 2026-09-30 (app for backend 19.0.3.24.0): Tier 3's goal shipped without
`MaterialApp.router`.** `lib/assessment/route_url.dart` gives every screen a URL (path =
section, record, tab; query = the page's own state) and `lib/services/url_bar_web.dart`
pushes a history entry when the path changes and follows `popstate`, so Reload, a pasted
deep link and browser Back/Forward all land on the same page and state. Reload and deep
links were checked in a browser; Back/Forward is pinned by
`test/assessment/a_reload_reopens_the_same_page_test.dart`. The rest of this file is the
15 September record.

**Status, updated after the fixes landed.** Every defect below was in the
shipped baseline, but the working tree is no longer clean: Tier 1 #1, #3, #4
and #5 and all of Tier 2 are IMPLEMENTED and uncommitted. Tier 1 #2 needs no
separate change for the in-app path - the Tier 2 fix keeps one entry across the
exam boundary, so `canGoBack` is true when the preview is opened from
`attempt_detail_screen.dart:595` and the existing button works. Tier 3 has NOT
been started; there is no `MaterialApp.router` anywhere in `lib/`. The two
browser-history attempts were rolled back and are not in the tree - only the
patches under `docs/attempts/` remain, for reference. **Every line number quoted
below cites the pre-fix baseline**, so diff the two repos rather than reading
them as current.

The changed files, so a reader can diff rather than re-implement:

* `ethara-assessment-fe`: `lib/assessment/nav.dart` (#1 `FormDesigner`'s
  `==` / `hashCode`; #6 the `_enteredExamFrom` boundary inside `go()`),
  `lib/assessment/widgets/history_bar.dart` (#3 the `ModalRoute.isCurrent`
  guard), and the tests under `test/assessment/`. The other dirty files in this
  repo - `lib/assessment/state/app_store.dart` and
  `lib/assessment/screens/admin/generator_detail_screen.dart` - were unrelated
  generator-sizing work, not navigation. **That dirty-file list is a 2026-09-15
  snapshot and is no longer the working tree**: a later review round left about
  twenty more files uncommitted in this repo. Read it as "these are the
  navigation files", not as "these are the only changes here".
* `ethara-etp`: `custom_addons/assessments_be_v2/models/studio_form.py` (#5, the
  `candidate_app_base_url` read dropped) and
  `custom_addons/assessments_be_v2/tests/test_password_reset.py` (#4, five new
  tests, three of them over what the mail actually contains, the template
  render, and the mail row). That repo also carries the password-reset fix
  itself in `controllers/api/auth.py` and `services/app_origins.py` - the
  "fixed helper" #4 refers to - plus unrelated work in `services/vertex.py`,
  `controllers/api/write.py` and `__manifest__.py`.

---

## First: why both browser-history attempts failed

Not for the reason I gave you. I blamed a `dartify()` int/double mismatch. That
was wrong. The real cause:

**Flutter Web's engine already owns `window.history`, and it actively deletes
entries it does not recognise.**

This app is a `MaterialApp` with `home:`, which puts the engine in
`SingleEntryBrowserHistory`. Its `onPopState`
(`flutter_web_sdk/lib/_engine/engine/navigation/history.dart:317-352`)
recognises exactly two state shapes, `{origin: true}` and `{flutter: true}`.
Anything else falls to a final `else` that assumes the user hand-edited the URL
and calls `urlStrategy.go(-1)` to remove the entry.

Every entry my code pushed carried `{etharaNav: true, ...}`. So:

* **"Browser Back jumps to the first item"** - each Back fired a popstate the
  engine did not recognise, so the engine did another `go(-1)`, cascading all the
  way to the origin entry.
* **"Forward arrow does nothing"** - when the cascade reached the origin, the
  engine called `_setupFlutterEntry`, whose `pushState` truncated the forward
  stack. Every pushed entry was gone, and nothing ever re-read `history.state`
  to notice.

One cause, both symptoms. I was a second writer to a stack Flutter already
owns, and no amount of ids, codecs or single-writer discipline *inside my own
layer* could have fixed that. Adopting `MaterialApp.router` is what switches the
engine to `MultiEntriesBrowserHistory` and makes app-owned entries legal - which
is the "real router" step I twice deferred as out of scope. It was the
prerequisite, not the nice-to-have.

---

## Tier 1 - shipped bugs, small diffs, no design decisions

These were independent of any browser work. All but #2 are now in the working
tree; #2 was made unnecessary by Tier 2 for the in-app path.

**1. DONE - `FormDesigner` has no `==` / `hashCode`.** `lib/assessment/nav.dart:193`.
The only route with fields that lacks one, so it inherits the base class's
`runtimeType`-only equality and every `FormDesigner` equals every other. `go()`
returns early on `r == current`, so opening form B from form A **does nothing**,
and switching Design/Preview **does nothing**. I proved this with a throwaway
test: 3 of 3 failed. Fix is five lines mirroring `GeneratorDetail`.

**2. MOSTLY OBSOLETE (#6) - Admin exam preview is a dead end.** `exam_screen.dart:2189` is a button whose
only action is `context.nav.back()`. Entering an `Exam` goes through
`replaceRoot`, which clears the trail, so `canGoBack` is false and the button can
never fire. Point it at a route instead. Tier 2 fixed the in-app path
(`attempt_detail_screen.dart:595` -> `nav.exam` -> `go`, which now keeps the
attempt page behind the runner). A pasted `/exam/<token>` URL still enters
through `assessment_section.dart:148` `replaceRoot(Exam(token))`, so the button
remains dead for a staff member who opens the candidate link by URL rather than
by clicking it.

**3. DONE - The keyboard shortcut navigates the page behind an open dialog.**
`history_bar.dart:60` registers on `HardwareKeyboard` globally, by design, so it
fires regardless of what is on top. One guard:
`if (ModalRoute.of(context)?.isCurrent != true) return false;`

**4. DONE - Reset-password test coverage has a hole the size of the original bug.**
`test_password_reset.py:262` - every test calls `_reset_base_url` in isolation.
Nothing asserts what `_send_reset_link` actually puts in the mail. Reintroduce
the production bug one line below the fixed helper, at `auth.py:530`, and the
whole suite still passes. Also untested: that the template renders
`ctx['reset_link']` at all, and that a mail row is created. Three tests. (Five
landed: those three, plus two over the unconfigured and local-clone fallbacks.)

**5. DONE - `studio_form.py:1308` reads the client origin for Odoo-served paths.**
This is the one I declined to touch for lack of information - the review got the
information. It reads `candidate_app_base_url` (the Flutter host) *before*
`web.base.url`, but every relative path reaching that branch is an Odoo route.
Latent only because that parameter has never been set in production. The fix is
to **drop the client read**, not to point it at `client_app_origin` - doing that
would make it fail on production and on every dev machine. My instinct to leave
it alone was right; the reason I gave was not.

## Tier 2 - the exam boundary

**6. DONE - Entering an exam wipes the operator's whole trail** (`nav.dart:361-364`), and
leaving it drops them on the candidate portal. Same root cause makes a candidate
who opens a released sitting from My Performance land on the wrong screen on the
way back.

Fix without reopening the browser question: keep **one** entry across the
boundary instead of zero. Stash `current` when entering an `Exam`; seed the new
trail with it when leaving. The boundary still holds - a candidate cannot walk
back into the console - but "Back to my assessments" returns where they came
from. This also makes Tier 1 #2 unnecessary for everyone who reaches the runner
by clicking; only the pasted-URL path still enters through `replaceRoot`.

## Tier 3 - browser Back/Forward, if you still want it

Only one route is viable, and it is a real project:

Adopt `MaterialApp.router` with a `RouterDelegate` and
`RouteInformationParser` over `AssessmentRoute`. That hands history to the
engine, which is the only writer it tolerates, and gets the browser's buttons
for free rather than by fighting for them. The route serialization from attempt 2
(`docs/attempts/browser-history-one-model.patch`, the `route_codec.dart` section)
is reusable and was the hard half; it round-tripped all 24 routes.

It also unlocks the thing that has been missing all along - a URL per screen, so
pages can be linked and bookmarked.

**My recommendation: do not start this now.** Tiers 1 and 2 are real user-facing
bugs with small, verifiable diffs. Tier 3 is a week-shaped change to the app's
spine, and I have twice told you something was working when it was not. It
deserves its own session, its own branch, and a browser-driven acceptance test
written *before* the code.

---

## Verification gap that let me ship two broken attempts

`flutter test --platform chrome` does not catch this class of bug. The suite ran
green through both attempts. The tests construct the history object directly and
never mount the app the way `main.dart` does, so the engine's
`SingleEntryBrowserHistory` - the thing that actually broke it - was never in the
picture.

Any future browser-navigation work needs one acceptance test that drives the
**real built bundle** in a **real browser**, pressing the browser's own buttons.
Without it, green means nothing here.
