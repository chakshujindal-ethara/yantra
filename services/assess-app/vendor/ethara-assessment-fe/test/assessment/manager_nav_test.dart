// The read-only Manager's sidebar.
//
// Three roles share the operator console: Admin (full power), Manager
// (read-only) and — through `Portal.member` — the candidate, who gets a
// different rail entirely. `Portal` is binary and reports `admin` for both
// Admin and Manager, because a Manager belongs in the console and the candidate
// surface would be the wrong shell rather than a narrower one. So the narrowing
// is `AccessRole`, and this is where it is pinned.
//
// WHY FILTER THE SOURCE LIST RATHER THAN THE SIDEBAR WIDGET. `_openTab`,
// `_activeTabKey` and `_page` all key off these entries. A row that renders
// with no route behind it — or a route with no row — is the exact drift
// `sidebar_reachable_test` exists to catch, and filtering here keeps all four
// in step by construction.
//
// The rail is NOT the security boundary. Every route re-checks its own group
// server-side; this only decides what is worth drawing, so that a Manager is
// not shown three sections that answer 403.
import 'package:flutter_test/flutter_test.dart';

import 'package:ethara_assessment/assessment/domain/enums.dart';
import 'package:ethara_assessment/assessment/domain/nav_entries.dart';

Set<String> _keys(AccessRole role) =>
    operatorNav(role: role).map((NavEntry e) => e.key).toSet();

void main() {
  group('the operator rail is narrowed by access role', () {
    test('an Admin sees every row', () {
      expect(_keys(AccessRole.admin), <String>{
        'analytics',
        'assessments',
        'generators',
        'review',
        'bank',
        'tags',
        'forms',
        'responses',
        'budget',
        'settings',
      });
    });

    test('a Manager sees exactly the read-only surfaces', () {
      // The set the product asked for: Dashboard, Assessments, Question Bank,
      // Tags, Form Studio, LLM Budget — plus Responses, which is a pure read of
      // data the Dashboard already summarises.
      expect(_keys(AccessRole.manager), <String>{
        'analytics',
        'assessments',
        'bank',
        'tags',
        'forms',
        'responses',
        'budget',
      });
    });

    test('a Manager sees NONE of the three hidden sections', () {
      // Stated as its own assertion rather than left implied by the set above:
      // this is the requirement, and a future row added to the rail must not
      // reach a Manager just because nobody updated the expected set.
      final Set<String> shown = _keys(AccessRole.manager);
      for (final String hidden in <String>['generators', 'review', 'settings']) {
        expect(
          shown,
          isNot(contains(hidden)),
          reason: '$hidden is an authoring or platform surface and a read-only '
              'Manager must not be offered it',
        );
      }
    });

    test('a Manager rail is a strict subset of an Admin rail', () {
      // Catches the opposite mistake: a key that only a Manager gets would be a
      // row with no route, because `_page` is written for the full set.
      expect(
        _keys(AccessRole.manager).difference(_keys(AccessRole.admin)),
        isEmpty,
      );
    });

    test('an unknown role keeps the full rail, not an empty one', () {
      // A client talking to a backend that predates `access_role` must behave
      // exactly as it did before the field existed. Blanking the console on an
      // unrecognised value would turn a payload mismatch into an outage, and
      // the server refuses what it refuses either way.
      expect(_keys(AccessRole.parse(null)), _keys(AccessRole.admin));
      expect(_keys(AccessRole.parse('something-new')), _keys(AccessRole.admin));
    });

    test('order and grouping survive the filter', () {
      // The rail is read top to bottom and Dashboard is the landing screen, so
      // the lit row must be the first one. Filtering a list must not reorder it.
      final List<NavEntry> nav = operatorNav(role: AccessRole.manager);
      expect(nav.first.key, 'analytics');
      expect(nav[1].key, 'assessments');
      expect(
        nav.map((NavEntry e) => e.key).toList(),
        operatorNav(role: AccessRole.admin)
            .map((NavEntry e) => e.key)
            .where(_keys(AccessRole.manager).contains)
            .toList(),
        reason: 'the filtered rail must keep the authored order',
      );
    });

    test('badges still reach the rows that survive', () {
      // Responses keeps its badge; Review Queue would have carried one and is
      // gone, which must not throw or leave a stray entry.
      final List<NavEntry> nav = operatorNav(
        role: AccessRole.manager,
        reviewCount: 5,
        responseCount: 3,
      );
      final NavEntry responses =
          nav.firstWhere((NavEntry e) => e.key == 'responses');
      expect(responses.badge, 3);
      expect(nav.where((NavEntry e) => e.key == 'review'), isEmpty);
    });
  });

  group('a candidate is not a narrow operator', () {
    test('the two rails share no keys', () {
      // A Manager is narrowed WITHIN the console; a candidate gets a different
      // rail. Sharing a key would mean one of the two is being drawn the wrong
      // shell.
      final Set<String> member = memberNav().map((NavEntry e) => e.key).toSet();
      expect(member.intersection(_keys(AccessRole.admin)), isEmpty);
      expect(member.intersection(_keys(AccessRole.manager)), isEmpty);
    });
  });
}
