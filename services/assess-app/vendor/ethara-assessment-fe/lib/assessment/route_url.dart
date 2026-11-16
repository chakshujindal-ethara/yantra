// Where the assessment section is, as a URL - and back again.
//
// THE ONE PLACE a route becomes a path. Both directions live here, next to
// each other, so a route kind added to `nav.dart` fails to compile until it has
// an address (the switch in [routeToUri] is exhaustive over the sealed class),
// and a path cannot be written that [routeFromUri] does not read back.
//
// The path carries WHERE (section, record, tab); the query carries the page's
// own state (search, filters, page). The split is load-bearing:
// `AssessmentSection` pushes a history entry when the PATH changes and
// rewrites the current one when only the query does, so Back steps between
// pages rather than between keystrokes in a search box.
//
// `/exam/<token>` is the invitation link and its shape is fixed by the Odoo
// module that mails it (`lib/deep_link.dart` reads it before sign-in). It is
// written here in exactly that shape so a reload of a sitting is the same
// request as the email link.
import 'package:flutter/foundation.dart';

import '../services/url_bar_stub.dart'
    if (dart.library.js_interop) '../services/url_bar_web.dart';
import 'nav.dart';

/// A route and the page state riding in its query string.
typedef RouteAt = ({AssessmentRoute route, Map<String, String> query});

/// [r] as a same-origin URL, with [query] as its query string.
///
/// Empty query values are left out, which is how a page says "default".
Uri routeToUri(
  AssessmentRoute r, [
  Map<String, String> query = const <String, String>{},
]) {
  final List<String> path = switch (r) {
    StartHere() => <String>['stages'],
    Analytics() => <String>['dashboard'],
    AssessmentsList() => <String>['assessments'],
    NewAssessment() => <String>['assessments', 'new'],
    AssessmentDetail(:final String id, :final String? tab) => <String>[
      'assessments',
      id,
      ?tab,
    ],
    QuestionBank() => <String>['bank'],
    GeneratorList() => <String>['generators'],
    GeneratorDetail(:final String id, :final String? tab) => <String>[
      'generators',
      id,
      ?tab,
    ],
    ReviewQueue() => <String>['review'],
    ResponsesList() => <String>['responses'],
    ResponseDetail(:final String attemptId, :final String questionId) =>
      <String>['responses', attemptId, questionId],
    AttemptDetail(:final String id) => <String>['attempts', id],
    CandidateDetail(:final String personId) => <String>['candidates', personId],
    CandidatePerformance(:final String personId) => <String>[
      'candidates',
      personId,
      'performance',
    ],
    TagsAdmin() => <String>['tags'],
    FormStudio() => <String>['forms'],
    FormDesigner(:final String id, :final String? tab) => <String>[
      'forms',
      id,
      ?tab,
    ],
    BudgetAdmin() => <String>['budget'],
    LedgerAdmin() => <String>['ledger'],
    SettingsAdmin() => <String>['settings'],
    AccountSettings() => <String>['account'],
    MyAssessments() => <String>['my-assessments'],
    MyPerformance() => <String>['my-performance'],
    // Only the released answer sheet gets its own address. Every other stage
    // is the server's call on reload - the runner resumes wherever the attempt
    // really is - so they all share the invitation link.
    Exam(:final String token, :final ExamStage stage) => <String>[
      'exam',
      token,
      if (stage == ExamStage.answers) 'answers',
    ],
  };
  final Map<String, String> q = <String, String>{
    // The route's generator is the review queue's opening filter; the page
    // reports its live one as `gen`, which wins.
    if (r case ReviewQueue(:final String generatorId?)) 'gen': generatorId,
    ...query,
  }..removeWhere((String _, String v) => v.isEmpty);
  return Uri(
    pathSegments: <String>['', ...path],
    queryParameters: q.isEmpty ? null : q,
  );
}

/// The route [uri] names, or null when it names none.
///
/// Null is the caller's cue to fall back to the role's home. A trailing slash
/// is tolerated; anything else unrecognised is null rather than a guess.
RouteAt? routeFromUri(Uri uri) {
  final List<String> s = uri.pathSegments
      .where((String p) => p.isNotEmpty)
      .toList();
  final Map<String, String> q = Map<String, String>.of(uri.queryParameters);
  final AssessmentRoute? r = switch (s) {
    ['stages'] => const StartHere(),
    ['dashboard'] => const Analytics(),
    ['assessments'] => const AssessmentsList(),
    ['assessments', 'new'] => const NewAssessment(),
    ['assessments', final String id] => AssessmentDetail(id),
    ['assessments', final String id, final String tab] => AssessmentDetail(
      id,
      tab: tab,
    ),
    ['bank'] => const QuestionBank(),
    ['generators'] => const GeneratorList(),
    ['generators', final String id] => GeneratorDetail(id),
    ['generators', final String id, final String tab] => GeneratorDetail(
      id,
      tab: tab,
    ),
    ['review'] => ReviewQueue(generatorId: _take(q, 'gen')),
    ['responses'] => const ResponsesList(),
    ['responses', final String attempt, final String question] =>
      ResponseDetail(attempt, question),
    ['attempts', final String id] => AttemptDetail(id),
    ['candidates', final String id] => CandidateDetail(id),
    ['candidates', final String id, 'performance'] => CandidatePerformance(id),
    ['tags'] => const TagsAdmin(),
    ['forms'] => const FormStudio(),
    ['forms', final String id] => FormDesigner(id),
    ['forms', final String id, final String tab] => FormDesigner(id, tab: tab),
    ['budget'] => const BudgetAdmin(),
    ['ledger'] => const LedgerAdmin(),
    ['settings'] => const SettingsAdmin(),
    ['account'] => const AccountSettings(),
    ['my-assessments'] => const MyAssessments(),
    ['my-performance'] => const MyPerformance(),
    ['exam', final String token] => Exam(token),
    ['exam', final String token, 'answers'] => Exam(
      token,
      stage: ExamStage.answers,
    ),
    _ => null,
  };
  return r == null ? null : (route: r, query: q);
}

/// Removes and returns [key], or null when it is absent or empty.
String? _take(Map<String, String> q, String key) {
  final String? v = q.remove(key);
  return v == null || v.isEmpty ? null : v;
}

/// The address bar, as `AssessmentSection` sees it.
///
/// INERT BY DEFAULT: reads nothing, writes nothing. Only the running app passes
/// [BrowserUrlBar] (`main.dart`), so a test that mounts the section - or the
/// shell - on its own never touches `window.history`, even under
/// `flutter test --platform chrome`. A test that wants to drive the URL
/// subclasses this.
class UrlBar {
  const UrlBar();

  /// The URL to restore from, or null when there is no address bar.
  Uri? get current => null;

  /// Show [url]. [push] adds a history entry; otherwise the current one is
  /// rewritten.
  void write(String url, {required bool push}) {}

  /// Call [onPop] when Back or Forward changes the URL. Returns the
  /// unsubscribe.
  VoidCallback listen(void Function(Uri url) onPop) => () {};
}

/// The real browser's address bar. A no-op off the web.
class BrowserUrlBar extends UrlBar {
  const BrowserUrlBar();

  @override
  Uri? get current => readBrowserUrl();

  @override
  void write(String url, {required bool push}) =>
      writeBrowserUrl(url, push: push);

  @override
  VoidCallback listen(void Function(Uri url) onPop) => onBrowserPop(onPop);
}
