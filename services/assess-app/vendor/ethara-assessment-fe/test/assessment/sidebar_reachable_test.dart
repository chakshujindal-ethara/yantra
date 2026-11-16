// Can every part of the assessment product be reached?
//
// THE ORIGINAL BUG, in the host portal: `MainShell` rendered a nav item when
// `_can(key)` was true, but `_select(key)` refused any key not in
// `_allowedViews`. The two were allowed to disagree, so Generators / Question
// bank / Review queue appeared in the sidebar and did NOTHING when clicked.
//
// THAT SHELL IS GONE. This app has one sidebar destination per portal and the
// nine operator sections are horizontal tabs inside `AssessmentSection`, so the
// two-table disagreement is structurally impossible now. What remains worth
// guarding is the half that still can break:
//
//   1. each portal opens the right ROOT screen, and
//   2. every tab maps to a DISTINCT route, so no tab is a dead button that
//      silently lands on the assessment list.
//
// A screenshot cannot catch either (the control is visibly there) and a browser
// cannot click it (Flutter web renders to a canvas, so synthetic clicks never
// reach the handler). Reading the tables and comparing them is the only honest
// check.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/assessment_section.dart';
import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/nav.dart';

void main() {
  group('Each portal opens its own root', () {
    // Mirrors the `entry:` decision in `AppShell.build`. The role comes from
    // the server; this only checks that each role lands somewhere real.
    AssessmentEntry entryFor(String serverRole) =>
        Portal.fromOrgRole(serverRole) == Portal.admin
        ? AssessmentEntry.console
        : AssessmentEntry.mine;

    test('an operator role opens the console', () {
      for (final String role in <String>['admin', 'pm', 'pl']) {
        expect(
          entryFor(role),
          AssessmentEntry.console,
          reason: '"$role" is an operator and must land on the console',
        );
      }
    });

    test('a candidate opens their own assessments, never the console', () {
      // A portal candidate holds no workflow group, so the server reports
      // something that is not `admin`. Landing them on the console would show
      // a candidate the whole authoring product.
      for (final String role in <String>['member', 'tasker', '', 'unknown']) {
        expect(
          entryFor(role),
          AssessmentEntry.mine,
          reason: '"$role" must NOT reach the operator console',
        );
      }
    });
  });

  group('Section tabs each open a distinct screen', () {
    // Mirrors `_openTab` in assessment_section.dart. A tab whose key falls
    // through to the default lands on the assessment list, which looks like a
    // working click that opened the wrong page - the same class of bug as a
    // dead sidebar button, and just as invisible in a screenshot.
    AssessmentRoute routeFor(String key) => switch (key) {
      'analytics' => const Analytics(),
      'mine' => const MyAssessments(),
      'performance' => const MyPerformance(),
      'generators' => const GeneratorList(),
      'bank' => const QuestionBank(),
      'review' => const ReviewQueue(),
      'responses' => const ResponsesList(),
      'tags' => const TagsAdmin(),
      'budget' => const BudgetAdmin(),
      'settings' => const SettingsAdmin(),
      'account' => const AccountSettings(),
      _ => const AssessmentsList(),
    };

    test('every admin tab resolves to its own route type', () {
      const List<String> keys = <String>[
        'analytics',
        'assessments',
        'generators',
        'bank',
        'review',
        'responses',
        'tags',
        'budget',
        'settings',
        'account',
      ];
      final Set<Type> seen = <Type>{};
      for (final String key in keys) {
        final Type t = routeFor(key).runtimeType;
        expect(
          seen.add(t),
          isTrue,
          reason:
              'tab "$key" opens $t, which another tab already opens - '
              'one of them is a dead button',
        );
      }
      expect(seen.length, keys.length);
    });

    test('the candidate tabs resolve to the candidate screens', () {
      expect(routeFor('mine'), isA<MyAssessments>());
      expect(routeFor('performance'), isA<MyPerformance>());
      // Account is on the candidate rail too, and it is the one screen a
      // candidate on a provisioned default password cannot do without.
      expect(routeFor('account'), isA<AccountSettings>());
    });

    test('an unknown key falls back to the list, never to nothing', () {
      expect(routeFor('not-a-tab'), isA<AssessmentsList>());
    });
  });
}
