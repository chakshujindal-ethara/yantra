// Navigation inside the assessment section.
//
// A CALLBACK STACK, not a router. `AssessmentNav` holds a small stack of route
// objects and the section rebuilds when it changes. That was inherited from
// the host portal this code was ported out of, and it is kept deliberately:
// `go_router` would take over the browser URL, and the one URL that matters -
// an invitation's `/exam/<token>` - is read once at startup by
// `lib/deep_link.dart` and handed to the section as a parameter.
//
// The address bar FOLLOWS this navigator rather than driving it: every route
// has a readable path (`route_url.dart`, both directions in one place), and
// `AssessmentSection` writes it on each move, restores it on reload and turns
// the browser's Back and Forward into moves here. A page's own state - search,
// filters, page number - rides along as [AssessmentNav.query].
//
// A screen asks to go somewhere by calling a method on [AssessmentNav]; the
// section host listens and rebuilds. Deep state (which assessment, which
// question) lives in the route object rather than in a widget, so the back
// button and a rebuild both land in the same place.
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';

import 'domain/models.dart';

/// Where the assessment section currently is.
///
/// VALUE EQUALITY, not identity. The navigator keeps a history and refuses to
/// push the page it is already on; without `==` that check only held for the
/// fieldless routes the rail builds as `const`, so opening the same generator
/// twice from two different links stacked two identical entries and Back
/// appeared to do nothing. Routes carrying fields override both members below;
/// the fieldless ones are equal whenever their types match.
@immutable
sealed class AssessmentRoute {
  const AssessmentRoute();

  @override
  bool operator ==(Object other) => other.runtimeType == runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;
}

class AssessmentsList extends AssessmentRoute {
  const AssessmentsList();
}

class AssessmentDetail extends AssessmentRoute {
  const AssessmentDetail(this.id, {this.tab});
  final String id;
  final String? tab;

  @override
  bool operator ==(Object other) =>
      other is AssessmentDetail && other.id == id && other.tab == tab;

  @override
  int get hashCode => Object.hash(runtimeType, id, tab);
}

class NewAssessment extends AssessmentRoute {
  const NewAssessment();
}

class QuestionBank extends AssessmentRoute {
  const QuestionBank();
}

class GeneratorList extends AssessmentRoute {
  const GeneratorList();
}

// There is deliberately no `NewGenerator` route: creating one asks for nothing
// up front and goes straight to the record. See `GeneratorListScreen._create`.

class GeneratorDetail extends AssessmentRoute {
  const GeneratorDetail(this.id, {this.tab, this.focusName = false});
  final String id;
  final String? tab;

  /// Open with the name ready to type into.
  ///
  /// Set by the ONE caller that has just created the generator. "New generator"
  /// creates the record and comes straight here, so the name it arrives with is
  /// a placeholder nobody chose - and a title the operator has to discover is
  /// editable would be a worse version of the sheet this replaced. Every other
  /// way in leaves the title alone.
  final bool focusName;

  // Part of the identity, not incidental: arriving with the name ready to type
  // into is a different page from arriving to read it, so the two must not
  // collapse into one history entry.
  @override
  bool operator ==(Object other) =>
      other is GeneratorDetail &&
      other.id == id &&
      other.tab == tab &&
      other.focusName == focusName;

  @override
  int get hashCode => Object.hash(runtimeType, id, tab, focusName);
}

class ReviewQueue extends AssessmentRoute {
  const ReviewQueue({this.generatorId});
  final String? generatorId;

  @override
  bool operator ==(Object other) =>
      other is ReviewQueue && other.generatorId == generatorId;

  @override
  int get hashCode => Object.hash(runtimeType, generatorId);
}

class ResponsesList extends AssessmentRoute {
  const ResponsesList();
}

class ResponseDetail extends AssessmentRoute {
  const ResponseDetail(this.attemptId, this.questionId);
  final String attemptId;
  final String questionId;

  @override
  bool operator ==(Object other) =>
      other is ResponseDetail &&
      other.attemptId == attemptId &&
      other.questionId == questionId;

  @override
  int get hashCode => Object.hash(runtimeType, attemptId, questionId);
}

class AttemptDetail extends AssessmentRoute {
  const AttemptDetail(this.id);
  final String id;

  @override
  bool operator ==(Object other) => other is AttemptDetail && other.id == id;

  @override
  int get hashCode => Object.hash(runtimeType, id);
}

/// One CANDIDATE, across every assessment they have sat.
///
/// The counterpart to [AttemptDetail], and deliberately a separate destination
/// rather than a mode of it. An attempt is one sitting: opened from an
/// assessment, the only marks that belong on screen are that assessment's.
/// From All responses the question is a different one - "how has this person
/// done?" - and answering it on the attempt screen would mean one route
/// rendering two different pages depending on how it was reached.
class CandidateDetail extends AssessmentRoute {
  const CandidateDetail(this.personId);
  final String personId;

  @override
  bool operator ==(Object other) =>
      other is CandidateDetail && other.personId == personId;

  @override
  int get hashCode => Object.hash(runtimeType, personId);
}

/// An operator looking at ONE candidate's own performance page.
///
/// The same screen the candidate sees, rendered for somebody else - reached
/// from the dashboard leaderboard. Distinct from [CandidateDetail], which is
/// the operator's own cross-assessment view of that person: this one keeps the
/// candidate's release gate, so an unreleased sitting is excluded from the
/// totals exactly as it is for them.
class CandidatePerformance extends AssessmentRoute {
  const CandidatePerformance(this.personId);
  final String personId;

  @override
  bool operator ==(Object other) =>
      other is CandidatePerformance && other.personId == personId;

  @override
  int get hashCode => Object.hash(runtimeType, personId);
}

class TagsAdmin extends AssessmentRoute {
  const TagsAdmin();
}

/// Form Studio: the forms designed here, listed.
class FormStudio extends AssessmentRoute {
  const FormStudio();
}

/// One form open in the designer. [tab] picks Design or Preview.
class FormDesigner extends AssessmentRoute {
  const FormDesigner(this.id, {this.tab});
  final String id;
  final String? tab;

  // THE ONLY ROUTE WITH FIELDS THAT LACKED THESE, and it shipped that way. The
  // base class compares on `runtimeType` alone, so every FormDesigner was equal
  // to every other - and `go()` drops a route that equals the current one. The
  // effect was not a subtle history artefact: opening a second form from the
  // first DID NOTHING, and so did switching between Design and Preview, because
  // both asked to navigate to a route the navigator believed it was already on.
  @override
  bool operator ==(Object other) =>
      other is FormDesigner && other.id == id && other.tab == tab;

  @override
  int get hashCode => Object.hash(runtimeType, id, tab);
}

class BudgetAdmin extends AssessmentRoute {
  const BudgetAdmin();
}

class LedgerAdmin extends AssessmentRoute {
  const LedgerAdmin();
}

class SettingsAdmin extends AssessmentRoute {
  const SettingsAdmin();
}

/// The signed-in person's own account: currently just their password.
///
/// Reachable from BOTH rails, unlike every other route in this file, which is
/// one portal's or the other's. A candidate needs it more than an operator
/// does - their account is provisioned with a shared default password and this
/// is the only place in the app that can change it.
class AccountSettings extends AssessmentRoute {
  const AccountSettings();
}

/// The orientation page: how the five stages fit together, and where work is
/// waiting. Deliberately the FIRST sidebar item - it is what a new operator
/// opens, and it explains an order the sidebar itself cannot.
class StartHere extends AssessmentRoute {
  const StartHere();
}

/// The admin analytics dashboard: KPIs, funnel, leaderboard, recent activity.
class Analytics extends AssessmentRoute {
  const Analytics();
}

/// The candidate's own list of assessments.
class MyAssessments extends AssessmentRoute {
  const MyAssessments();
}

/// The candidate's own performance analytics. Release-gated: an unreleased
/// attempt contributes its status and nothing about its score.
class MyPerformance extends AssessmentRoute {
  const MyPerformance();
}

/// The exam runtime. [stage] is the gate, a question, the answer sheet, the
/// review pass or the completion card.
class Exam extends AssessmentRoute {
  const Exam(this.token, {this.stage = ExamStage.gate, this.questionIndex = 0});
  final String token;
  final ExamStage stage;
  final int questionIndex;

  @override
  bool operator ==(Object other) =>
      other is Exam &&
      other.token == token &&
      other.stage == stage &&
      other.questionIndex == questionIndex;

  @override
  int get hashCode => Object.hash(runtimeType, token, stage, questionIndex);
}

enum ExamStage { gate, question, answers, review, complete }

/// The page [r] shows, with the tab it is open on set aside.
///
/// A tab switch is a history entry - Back and the address bar follow it - but
/// not a new page. The section keys its scroll view on this, so switching tabs
/// keeps the screen's State (the fetched record, its timers, an edit half-typed
/// on another tab) exactly as the in-screen tab strip always did.
/// `focusName` goes too: it is how a generator was ARRIVED at, not which one.
AssessmentRoute pageOf(AssessmentRoute r) => switch (r) {
  AssessmentDetail(:final String id) => AssessmentDetail(id),
  GeneratorDetail(:final String id) => GeneratorDetail(id),
  FormDesigner(:final String id) => FormDesigner(id),
  _ => r,
};

/// Where an attempt should resume. Returns 1 when every question already has a
/// response, so a completed-but-unsubmitted attempt lands somewhere sensible
/// rather than off the end.
int firstUnanswered(Attempt ev, Assessment asm) {
  for (int i = 0; i < asm.questions.length; i++) {
    if (!ev.resp.containsKey(asm.questions[i].id)) return i + 1;
  }
  return 1;
}

/// Makes the section's navigator reachable from any assessment screen.
///
/// An inherited widget rather than a constructor parameter on all sixteen
/// screens: navigation is ambient here in the same way `Theme` is, and
/// threading it by hand would mean every screen that merely CONTAINS a link
/// has to accept and forward something it does not use itself.
class AssessmentNavScope extends InheritedNotifier<AssessmentNav> {
  const AssessmentNavScope({
    super.key,
    required AssessmentNav nav,
    required super.child,
  }) : super(notifier: nav);

  static AssessmentNav of(BuildContext context) {
    final AssessmentNavScope? scope = context
        .dependOnInheritedWidgetOfExactType<AssessmentNavScope>();
    assert(scope != null, 'No AssessmentNavScope above this widget');
    return scope!.notifier!;
  }

  /// The navigator WITHOUT subscribing to it, or null outside a section.
  ///
  /// For a page reading its query in `initState` or a field initialiser, where
  /// [of] is not allowed, and for the many tests that mount one screen on its
  /// own with no section around it.
  static AssessmentNav? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AssessmentNavScope>()?.notifier;
}

/// `context.nav.assessment(id)` - the assessment section's navigator.
extension AssessmentNavX on BuildContext {
  AssessmentNav get nav => AssessmentNavScope.of(this);

  /// This page's state as the address bar holds it - search, filters, page -
  /// or empty outside a section. Safe in `initState` and `late` initialisers.
  Map<String, String> get navQuery =>
      AssessmentNavScope.maybeRead(this)?.query ?? const <String, String>{};

  /// Put this page's state in the address bar. Rewrites the current entry
  /// rather than adding one, so Back skips filter changes. A null value is
  /// left out, and so is an empty one. Safe to call from `build`: it rewrites
  /// the URL and rebuilds nothing.
  void setNavQuery(Map<String, Object?> q) =>
      AssessmentNavScope.maybeRead(this)?.setQuery(q);
}

/// The assessment section's navigator.
///
/// A HISTORY WITH A CURSOR, not a stack. It was a stack, and `pop()` threw the
/// page away, so there was nothing to go forward TO - and `reset()`, which
/// every rail click and every "back to my assessments" goes through, cleared
/// the whole thing. Between them the user's trail was destroyed on almost
/// every move they made. The browser model is the one people already know:
/// visiting a page truncates the forward branch and appends, and Back and
/// Forward move a cursor over entries that stay put.
///
/// [reset] is kept as the name its call sites already use, but it no longer
/// clears: a rail jump is an ordinary entry, exactly as clicking a link in a
/// site's own navigation is. Only [replaceRoot] starts a fresh trail, and the
/// section's entry point in `assessment_section.dart` is its only caller. The
/// exam boundary used to call it too and does not any more - [go] keeps one
/// entry across that boundary instead, so Back out of a sitting has somewhere
/// to land.
class AssessmentNav extends ChangeNotifier {
  /// Long enough that no real session reaches it, short enough that a tab left
  /// open all day does not hold every page it ever showed.
  static const int maxEntries = 50;

  final List<AssessmentRoute> _history = <AssessmentRoute>[
    const AssessmentsList(),
  ];
  int _cursor = 0;

  /// The page the exam runner was opened FROM, held for the way out.
  ///
  /// Null whenever the trail is not inside a sitting. Cleared on the way out
  /// and by [replaceRoot], so a stale one cannot resurface in a later session.
  AssessmentRoute? _enteredExamFrom;

  /// Each page's own state - search, filters, page - by route.
  ///
  /// BY ROUTE, not by history entry, so Back to a page (in-app or browser)
  /// reopens it filtered as it was left, with no parallel list to keep in step
  /// with the trail surgery [go] does. A rail click starts the page clean
  /// ([reset]). Grows by one small map per distinct page opened with a filter.
  final Map<AssessmentRoute, Map<String, String>> _queries =
      <AssessmentRoute, Map<String, String>>{};

  AssessmentRoute get current => _history[_cursor];

  /// The current page's state, for the address bar and for the page to
  /// restore itself from.
  Map<String, String> get query =>
      _queries[current] ?? const <String, String>{};

  /// Called when the current page's [query] changes.
  ///
  /// NOT [notifyListeners], deliberately. Pages report their filters from
  /// `initState` and `build`, and rebuilding the section from inside a
  /// descendant's build throws. Only the address bar needs to hear this.
  VoidCallback? onQueryChanged;

  /// Record [q] as [at]'s state (default: the current page). A null value is
  /// dropped; anything else is stored as its string.
  void setQuery(Map<String, Object?> q, {AssessmentRoute? at}) {
    final AssessmentRoute r = at ?? current;
    final Map<String, String> next = <String, String>{
      for (final MapEntry<String, Object?> e in q.entries)
        if (e.value != null) e.key: '${e.value}',
    };
    if (mapEquals(next, _queries[r] ?? const <String, String>{})) return;
    if (next.isEmpty) {
      _queries.remove(r);
    } else {
      _queries[r] = next;
    }
    if (r == current) onQueryChanged?.call();
  }

  bool get canGoBack => _cursor > 0;
  bool get canGoForward => _cursor < _history.length - 1;

  /// Where Back would land, or null at the start of the trail.
  AssessmentRoute? get previous => canGoBack ? _history[_cursor - 1] : null;

  /// Where Forward would land, or null at the end of it.
  AssessmentRoute? get next => canGoForward ? _history[_cursor + 1] : null;

  /// Retained: `pop`/`canPop` were this class's original Back and are still
  /// its public API. They are [back] and [canGoBack] now, which differ in the
  /// one way that matters - the page is left in the trail rather than dropped,
  /// so Forward can return to it.
  bool get canPop => canGoBack;

  void pop() => back();

  /// Visits a page, the way following a link does.
  ///
  /// Truncates any forward branch: going back three pages and then somewhere
  /// new abandons what was ahead, because it is no longer a trail anyone
  /// walked. Re-visiting the current page is a no-op rather than a duplicate
  /// entry - otherwise clicking the lit rail row would silently charge the
  /// user a Back press to undo.
  void go(AssessmentRoute r) {
    // THE EXAM IS A BOUNDARY, in both directions.
    //
    // A live attempt has server-side state - a deadline, a lock, a frozen
    // question order - and its own Previous/Next that moves through
    // `/exam/<token>/state`. Letting page history stack alongside that would
    // put two controls on one screen that both say "back" and mean different
    // things, and would offer a candidate who has submitted a Forward button
    // that walks into a closed attempt.
    //
    // ONE ENTRY ACROSS THE BOUNDARY, NOT ZERO. This used to `replaceRoot`,
    // which threw the trail away in both directions, and that was three
    // user-visible bugs rather than a tidy invariant:
    //
    //   * An operator who opened a sitting from Responses lost their whole
    //     trail, and "back to my assessments" then dropped them on the
    //     CANDIDATE portal - a screen an admin did not ask for and had no way
    //     back from.
    //   * A candidate who opened a released sitting from My Performance was
    //     returned to My Assessments, not to the page they tapped from.
    //   * The admin preview's only way out is `nav.back()`
    //     (`screens/exam/exam_screen.dart`), and with an emptied trail
    //     `canGoBack` was false, so the button could never fire. A dead end
    //     with no exit.
    //
    // Keeping the page the runner was entered FROM costs one entry and fixes
    // all three: Back leaves the exam and lands where the user actually came
    // from. The boundary itself is unchanged - the trail still holds no
    // intermediate exam stages, and there is still nothing to walk forward
    // into once the sitting is left.
    //
    // ONE WAY IN IS STILL A DEAD END, and deliberately: a mailed or pasted
    // `/exam/<token>` enters through the section's own `replaceRoot`
    // (`assessment_section.dart`), which has no page to keep because there was
    // none. Right for the invited candidate it was built for; a staff member
    // who opens a candidate's link by URL rather than from the attempt page
    // gets the preview card's Back button with nothing behind it.
    final AssessmentRoute at = current;
    if (r is Exam && at is! Exam) {
      // Entering: keep the page behind it, drop everything else.
      _enteredExamFrom = at;
      _history
        ..clear()
        ..addAll(<AssessmentRoute>[at, r]);
      _cursor = 1;
      notifyListeners();
      return;
    }
    if (r is Exam && at is Exam) {
      // Moving between stages of one sitting: replace, never stack.
      _history[_cursor] = r;
      notifyListeners();
      return;
    }
    if (at is Exam) {
      // Leaving: seed the fresh trail with where the runner was entered from,
      // so Back is the way back rather than a dead control.
      final AssessmentRoute? from = _enteredExamFrom;
      _enteredExamFrom = null;
      _history
        ..clear()
        ..addAll(
          from == null || from == r
              ? <AssessmentRoute>[r]
              : <AssessmentRoute>[from, r],
        );
      _cursor = _history.length - 1;
      notifyListeners();
      return;
    }

    if (r == current) return;

    if (canGoForward) _history.removeRange(_cursor + 1, _history.length);
    _history.add(r);
    if (_history.length > maxEntries) _history.removeAt(0);
    _cursor = _history.length - 1;
    notifyListeners();
  }

  /// A rail-level jump. An ordinary history entry - see the class docstring.
  ///
  /// The page opens CLEAN: a filter left on it earlier is forgotten, the way a
  /// menu click resets a list in Odoo while Back restores it. Not when [r] is
  /// already showing - clicking the lit row does nothing, filters included.
  void reset(AssessmentRoute r) {
    if (r != current) _queries.remove(r);
    go(r);
  }

  /// Starts a fresh trail at [r], discarding what came before.
  ///
  /// For the section's ENTRY only - `assessment_section.dart` is the only
  /// caller. The exam boundary is handled inside [go], which keeps the page
  /// behind the runner rather than clearing. Used anywhere else this would
  /// silently delete the user's history.
  void replaceRoot(AssessmentRoute r) {
    _enteredExamFrom = null;
    _history
      ..clear()
      ..add(r);
    _cursor = 0;
    notifyListeners();
  }

  void back() {
    if (!canGoBack) return;
    _cursor--;
    notifyListeners();
  }

  void forward() {
    if (!canGoForward) return;
    _cursor++;
    notifyListeners();
  }

  // ── Named destinations ─────────────────────────────────────────────────
  //
  // These replace what used to be `Routes.*` URL builders. Same call sites,
  // no URL strings: each route's address is derived in `route_url.dart`.

  void startHere() => reset(const StartHere());
  void analytics() => reset(const Analytics());
  void assessments() => reset(const AssessmentsList());
  void responses() => reset(const ResponsesList());
  void assessment(String id, {String? tab}) =>
      go(AssessmentDetail(id, tab: tab));
  void generator(String id, {String? tab, bool focusName = false}) =>
      go(GeneratorDetail(id, tab: tab, focusName: focusName));
  void formStudio() => reset(const FormStudio());
  void formDesigner(String id, {String? tab}) => go(FormDesigner(id, tab: tab));
  void review({String? gen}) => go(ReviewQueue(generatorId: gen));
  void response(String attemptId, String questionId) =>
      go(ResponseDetail(attemptId, questionId));
  void attempt(String id) => go(AttemptDetail(id));
  void candidate(String personId) => go(CandidateDetail(personId));
  void candidatePerformance(String personId) =>
      go(CandidatePerformance(personId));

  void exam(String token) => go(Exam(token));
  void examQuestion(String token, int index) =>
      go(Exam(token, stage: ExamStage.question, questionIndex: index));
  void examAnswers(String token) => go(Exam(token, stage: ExamStage.answers));
  void examReview(String token) => go(Exam(token, stage: ExamStage.review));
  void examComplete(String token) => go(Exam(token, stage: ExamStage.complete));
}

/// What to CALL a route, for a Back or Forward tooltip.
///
/// Deliberately the rail's own words where a route has a rail row, so the
/// tooltip names the destination the user would otherwise click. Detail routes
/// have no rail row and their record's name lives in the store, which this
/// file cannot see - they get the kind of thing they are, which is enough to
/// answer "where does this take me".
String routeLabel(AssessmentRoute r) => switch (r) {
  StartHere() => 'Stages',
  Analytics() => 'Dashboard',
  AssessmentsList() => 'Assessments',
  NewAssessment() => 'New Assessment',
  AssessmentDetail() => 'the assessment',
  QuestionBank() => 'Question Bank',
  GeneratorList() => 'Generators',
  GeneratorDetail() => 'the generator',
  ReviewQueue() => 'Review Queue',
  ResponsesList() => 'Responses',
  ResponseDetail() => 'the answer',
  AttemptDetail() => 'the attempt',
  CandidateDetail() => 'the candidate',
  CandidatePerformance() => "the candidate's performance",
  TagsAdmin() => 'Tags',
  FormStudio() => 'Form Studio',
  FormDesigner() => 'the form',
  BudgetAdmin() => 'LLM Budget',
  LedgerAdmin() => 'Spend Ledger',
  SettingsAdmin() => 'Settings',
  AccountSettings() => 'Account',
  MyAssessments() => 'My Assessments',
  MyPerformance() => 'My Performance',
  Exam() => 'the exam',
};
