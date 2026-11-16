// The sidebar navigation: what it lists, how it groups, and what it badges.
//
// These sections used to be a horizontal TabStrip. Moving them into the rail
// means the nav list is now DATA, so the parts worth guarding are the shape of
// that data and the promise that its keys still route.
import 'package:flutter_test/flutter_test.dart';
import 'package:ethara_assessment/assessment/domain/nav_entries.dart';

void main() {
  group('The operator rail lists every section, once', () {
    test('every section is present', () {
      // Nothing may quietly drop out of the nav when it moves from a tab strip
      // to a rail: a section with no way to reach it is a deleted feature.
      final Set<String> keys = operatorNav().map((NavEntry e) => e.key).toSet();
      // 'scoring' is deliberately absent: the grading pipeline was its own
      // destination, and every fact it showed is per-candidate on the
      // assessment's attempts table (state, answered, score, result, released,
      // and an "N awaiting" badge from `subjective.pending`).
      expect(keys, <String>{
        'assessments',
        'analytics',
        'generators',
        'bank',
        'review',
        'responses',
        'tags',
        'forms',
        'budget',
        'settings',
      });
    });

    test('Account is reached from the name card, not from a rail row', () {
      // Not a deletion: `_openTab('account')` still routes, and the sidebar's
      // name card is what calls it - see `_Sidebar` in `app_shell.dart` and
      // the click-path test in `password_change_test.dart`. Asserted here
      // because putting the row back would give the app two ways to the same
      // page, and the rail is the wrong one: every other row is a part of the
      // product, and this is a form about the person holding the session.
      expect(
        operatorNav().map((NavEntry e) => e.key),
        isNot(contains('account')),
      );
      expect(
        memberNav().map((NavEntry e) => e.key),
        isNot(contains('account')),
      );
    });

    test('the spend ledger is NOT a rail destination', () {
      // It is one click from LLM budget, which is where "what did we pay for"
      // is already being asked, and the two link to each other both ways.
      expect(
        operatorNav().map((NavEntry e) => e.key),
        isNot(contains('ledger')),
      );
    });

    test('no key appears twice', () {
      final List<String> keys = operatorNav()
          .map((NavEntry e) => e.key)
          .toList();
      expect(
        keys.length,
        keys.toSet().length,
        reason: 'a duplicated key would light two rows for one page',
      );
    });

    test('the daily destinations sit above every heading', () {
      // Dashboard and Assessments are the front door. Under a category heading
      // they read as a subsection of that category.
      //
      // Dashboard LEADS because it is where an admin lands after signing in -
      // the lit row should be the page they are looking at. The orientation
      // page ("Stages") left the rail entirely; the dashboard links to it.
      final List<NavEntry> nav = operatorNav();
      expect(nav.first.key, 'analytics');
      expect(nav[1].key, 'assessments');
      for (final NavEntry e in nav.take(2)) {
        expect(e.group, isEmpty, reason: '${e.key} must sit above any heading');
      }
    });

    test('Stages is reached from the dashboard, not from a rail row', () {
      // It was "Docs" and it sat under PLATFORM, which put a page ABOUT the
      // five sidebar sections into the list of sidebar sections. It is a pair
      // with the dashboard now - "Go to Stages" there, "Go to Dashboard" back,
      // each in the same slot on its page - so putting the row back would give
      // one page two front doors and re-file it as a product section.
      //
      // The KEY still routes (`_openTab('start')`), because both buttons go
      // through the same navigator the rail does.
      expect(
        operatorNav().map((NavEntry e) => e.key),
        isNot(contains('start')),
      );
    });

    test('groups appear in contiguous blocks', () {
      // The rail draws a heading whenever the group CHANGES, so a group that
      // reappears later would render its heading twice.
      final List<String> groups = operatorNav()
          .map((NavEntry e) => e.group)
          .where((String g) => g.isNotEmpty)
          .toList();
      final List<String> collapsed = <String>[];
      for (final String g in groups) {
        if (collapsed.isEmpty || collapsed.last != g) collapsed.add(g);
      }
      expect(
        collapsed.length,
        collapsed.toSet().length,
        reason: 'each group must be one contiguous run',
      );
    });
  });

  group('Badges mark work waiting, never totals', () {
    test('nothing is badged when there is no work', () {
      // A "0" beside every row is wallpaper and reads as a broken counter.
      expect(operatorNav().where((NavEntry e) => e.badge > 0), isEmpty);
    });

    test('only the two actionable rows can carry a badge', () {
      final List<NavEntry> nav = operatorNav(reviewCount: 5, responseCount: 3);
      final Map<String, int> badged = <String, int>{
        for (final NavEntry e in nav)
          if (e.badge > 0) e.key: e.badge,
      };
      expect(badged, <String, int>{'review': 5, 'responses': 3});
    });
  });

  group('The candidate rail is its own, much shorter, list', () {
    test('a candidate sees their own destinations and no operator section', () {
      final Set<String> keys = memberNav().map((NavEntry e) => e.key).toSet();
      expect(keys, <String>{'mine', 'performance'});
      // The operator sections must not leak into a candidate's rail: several
      // of them are refused by the server for a candidate token, so showing
      // them would offer a click that can only fail.
      //
      // The two rails now share NO key at all. Account used to be the one
      // deliberate exception, and it stopped being one when it moved to the
      // name card - which is on both rails, so the candidate who needs it most
      // still has it. Nothing else may join it here.
      expect(
        keys.intersection(operatorNav().map((NavEntry e) => e.key).toSet()),
        isEmpty,
      );
    });

    test('the candidate rows carry no group headings', () {
      expect(memberNav().every((NavEntry e) => e.group.isEmpty), isTrue);
    });
  });
}
