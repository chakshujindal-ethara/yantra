// Every page has an address, and every address reads back as that page.
//
// The owner's report: on Assessments > an assessment > Candidates the address
// bar showed only the host, so a browser reload landed on the Dashboard and the
// assessment reopened on Configuration. `route_url.dart` is the one place a
// route becomes a path and back; this pins that mapping - every route kind,
// with tabs and filters - plus the two edges that matter most: an unknown path
// is null (the caller's cue to open the role's home), and the invitation link
// `/exam/<token>` keeps the exact shape the Odoo module mails and
// `deep_link.dart` reads.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/nav.dart';
import 'package:ethara_assessment/assessment/route_url.dart';
import 'package:ethara_assessment/deep_link.dart';

void main() {
  // (route, the page's query, the address it must have). One row per route
  // kind - `routeToUri`'s switch is exhaustive, so a kind missing here is a
  // kind this test does not cover rather than one with no address.
  final List<(AssessmentRoute, Map<String, String>, String)> table =
      <(AssessmentRoute, Map<String, String>, String)>[
        (const StartHere(), <String, String>{}, '/stages'),
        (const Analytics(), <String, String>{}, '/dashboard'),
        (
          const AssessmentsList(),
          <String, String>{'q': 'evals', 'state': 'done'},
          '/assessments?q=evals&state=done',
        ),
        (const NewAssessment(), <String, String>{}, '/assessments/new'),
        (const AssessmentDetail('116'), <String, String>{}, '/assessments/116'),
        (
          const AssessmentDetail('116', tab: 'candidates'),
          <String, String>{'state': 'not_started', 'page': '2'},
          '/assessments/116/candidates?state=not_started&page=2',
        ),
        (
          const AssessmentDetail('116', tab: 'leaderboard'),
          <String, String>{},
          '/assessments/116/leaderboard',
        ),
        (
          const QuestionBank(),
          <String, String>{'q': 'sql join', 'type': 'mcq', 'archived': '1'},
          '/bank?q=sql+join&type=mcq&archived=1',
        ),
        (const GeneratorList(), <String, String>{}, '/generators'),
        (const GeneratorDetail('108'), <String, String>{}, '/generators/108'),
        (
          const GeneratorDetail('108', tab: 'drafts'),
          <String, String>{},
          '/generators/108/drafts',
        ),
        (const ReviewQueue(), <String, String>{}, '/review'),
        (
          const ReviewQueue(generatorId: '108'),
          <String, String>{},
          '/review?gen=108',
        ),
        (
          const ResponsesList(),
          <String, String>{'asm': '116', 'page': '3', 'size': '50'},
          '/responses?asm=116&page=3&size=50',
        ),
        (
          const ResponseDetail('900', '41'),
          <String, String>{},
          '/responses/900/41',
        ),
        (const AttemptDetail('900'), <String, String>{}, '/attempts/900'),
        (const CandidateDetail('7'), <String, String>{}, '/candidates/7'),
        (
          const CandidatePerformance('7'),
          <String, String>{},
          '/candidates/7/performance',
        ),
        (const TagsAdmin(), <String, String>{}, '/tags'),
        (const FormStudio(), <String, String>{}, '/forms'),
        (const FormDesigner('3'), <String, String>{}, '/forms/3'),
        (
          const FormDesigner('3', tab: 'preview'),
          <String, String>{},
          '/forms/3/preview',
        ),
        (const BudgetAdmin(), <String, String>{}, '/budget'),
        (
          const LedgerAdmin(),
          <String, String>{'page': '4'},
          '/ledger?page=4',
        ),
        (const SettingsAdmin(), <String, String>{}, '/settings'),
        (const AccountSettings(), <String, String>{}, '/account'),
        (
          const MyAssessments(),
          <String, String>{'show': 'completed'},
          '/my-assessments?show=completed',
        ),
        (const MyPerformance(), <String, String>{}, '/my-performance'),
        (const Exam('tok123'), <String, String>{}, '/exam/tok123'),
        (
          const Exam('tok123', stage: ExamStage.answers),
          <String, String>{},
          '/exam/tok123/answers',
        ),
      ];

  group('route <-> URL', () {
    for (final (AssessmentRoute r, Map<String, String> q, String url)
        in table) {
      test('$url round-trips', () {
        expect(routeToUri(r, q).toString(), url);
        final RouteAt? back = routeFromUri(Uri.parse('https://h$url'));
        expect(back, isNotNull);
        expect(back!.route, r);
        expect(back.query, q);
      });
    }

    test('an id that needs escaping survives the trip', () {
      const AssessmentRoute r = AssessmentDetail('A 1/2', tab: 'candidates');
      final Uri u = routeToUri(r);
      expect(u.path, '/assessments/A%201%2F2/candidates');
      expect(routeFromUri(u)!.route, r);
    });

    test('empty query values are left out of the address', () {
      expect(
        routeToUri(const QuestionBank(), <String, String>{'q': '', 'type': ''})
            .toString(),
        '/bank',
      );
    });

    test('the review queue page filter outranks the route one', () {
      // The page reports its live generator filter as `gen`; "every
      // generator" is an empty value, which clears the route's opening one.
      expect(
        routeToUri(
          const ReviewQueue(generatorId: '108'),
          <String, String>{'gen': ''},
        ).toString(),
        '/review',
      );
      expect(
        routeToUri(
          const ReviewQueue(generatorId: '108'),
          <String, String>{'gen': '9'},
        ).toString(),
        '/review?gen=9',
      );
    });

    test('a trailing slash still names the page', () {
      expect(
        routeFromUri(Uri.parse('https://h/assessments/116/candidates/'))!.route,
        const AssessmentDetail('116', tab: 'candidates'),
      );
    });

    for (final String url in <String>[
      '/',
      '/nope',
      '/assessments/116/candidates/extra',
      '/reset-password',
      '/pro_assessment/tok',
      '/exam',
    ]) {
      test('unknown path $url reads as no route (the role home)', () {
        expect(routeFromUri(Uri.parse('https://h$url')), isNull);
      });
    }
  });

  group('the invitation link is untouched', () {
    test('every live stage of a sitting shares /exam/<token>', () {
      for (final ExamStage st in <ExamStage>[
        ExamStage.gate,
        ExamStage.question,
        ExamStage.review,
        ExamStage.complete,
      ]) {
        expect(
          routeToUri(Exam('tok123', stage: st, questionIndex: 4)).toString(),
          '/exam/tok123',
        );
      }
    });

    test('deep_link still reads the token from what the app writes', () {
      for (final ExamStage st in ExamStage.values) {
        final Uri written = Uri.parse(
          'https://assessment.ethara.ai'
          '${routeToUri(Exam('tok123', stage: st))}',
        );
        expect(examTokenFrom(written), 'tok123');
      }
    });

    test('no other address carries an exam token', () {
      for (final (AssessmentRoute r, Map<String, String> q, String _)
          in table) {
        if (r is Exam) continue;
        final Uri u = Uri.parse('https://h${routeToUri(r, q)}');
        expect(examTokenFrom(u), isNull, reason: '$u');
        expect(resetTokenFrom(u), isNull, reason: '$u');
      }
    });
  });

  group('page state rides with the route', () {
    test('a query change is heard by the address bar, not the page', () {
      final AssessmentNav nav = AssessmentNav();
      int rebuilds = 0;
      int urlWrites = 0;
      nav.addListener(() => rebuilds++);
      nav.onQueryChanged = () => urlWrites++;

      nav.setQuery(<String, Object?>{'q': 'sql', 'page': 2, 'none': null});
      expect(nav.query, <String, String>{'q': 'sql', 'page': '2'});
      expect(urlWrites, 1);
      expect(rebuilds, 0);

      nav.setQuery(<String, Object?>{'q': 'sql', 'page': 2});
      expect(urlWrites, 1, reason: 'unchanged is not a change');
    });

    test('Back reopens a page as it was left; a rail click starts it clean',
        () {
      final AssessmentNav nav = AssessmentNav()
        ..replaceRoot(const QuestionBank());
      nav.setQuery(<String, Object?>{'q': 'sql'});
      nav.go(const GeneratorList());
      expect(nav.query, isEmpty);

      nav.back();
      expect(nav.current, const QuestionBank());
      expect(nav.query, <String, String>{'q': 'sql'});

      nav.go(const GeneratorList());
      nav.reset(const QuestionBank());
      expect(nav.query, isEmpty);
    });

    test('a tab is not a new page', () {
      expect(
        pageOf(const AssessmentDetail('116', tab: 'candidates')),
        pageOf(const AssessmentDetail('116', tab: 'config')),
      );
      expect(
        pageOf(const GeneratorDetail('108', tab: 'drafts', focusName: true)),
        pageOf(const GeneratorDetail('108')),
      );
      expect(
        pageOf(const AssessmentDetail('116')),
        isNot(pageOf(const AssessmentDetail('117'))),
      );
    });
  });
}
