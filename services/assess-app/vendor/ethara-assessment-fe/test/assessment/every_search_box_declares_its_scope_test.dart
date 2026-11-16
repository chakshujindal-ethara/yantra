// EVERY search box in the admin console is declared: server-backed, or local
// with a reason.
//
// Requirement 2.3 asks that every search box be DOCUMENTED as server-backed.
// This is that document, written as a test rather than as prose, because a table
// in a markdown file cannot notice a twelfth search box being added next month.
// The table below is the artifact; the assertions are what stop it drifting.
//
// WHY IT MATTERS. The defect behind D2/D7 was a search box that filtered rows
// the client had already walked. The client's copy was a corrupted 2,077 of
// 2,538 (offset paging over a non-unique sort key), so the predicate ran over a
// sample: one candidate rendered twice, another could not be found at all. Any
// box left filtering in memory carries the same risk, so each one has to be a
// decision somebody made rather than a default nobody noticed.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where a search box gets its rows.
enum Scope {
  /// The predicate runs on the server, over the whole population.
  server,

  /// The predicate runs in the client, over a bounded set the screen already
  /// holds - and the box SAYS so.
  local,

  /// BOTH, on different axes, because no single answer is available.
  ///
  /// One box, one term, two passes: the server answers the axes it can
  /// (names, titles), the client refines over the rows in hand for the axes
  /// it alone can build (rendered, redacted text). Declared as its own scope
  /// rather than as `server` because the local half is still bounded and the
  /// box still has to say which half is which - and rather than as `local`
  /// because calling it local would understate what it now reaches.
  hybrid,
}

class Box {
  const Box(this.file, this.hint, this.scope, this.why);

  /// Relative to `lib/`.
  final String file;

  /// The `hint:` string, which is what identifies a box across edits. Line
  /// numbers drift on every insertion above them; a hint is the thing an
  /// operator actually reads.
  final String hint;
  final Scope scope;
  final String why;
}

/// THE DECLARATION. One row per search box in the app.
const List<Box> kBoxes = <Box>[
  // ── Server-backed ────────────────────────────────────────────────────────
  Box(
    'assessment/screens/admin/assessment_detail_screen.dart',
    'Search people',
    Scope.server,
    '/api/v1/users, paged. Was already server-backed: the picker has to be able '
        'to offer somebody who has never sat an assessment.',
  ),
  Box(
    'assessment/screens/admin/assessment_detail_screen.dart',
    'Find a candidate',
    Scope.server,
    '/api/v1/assessments/<id>/candidates, paged. THE D7 FIX: this filtered the '
        'console-wide attempts walk, which is the corrupted sample.',
  ),
  Box(
    'assessment/screens/admin/assessment_list_screen.dart',
    'Search every assessment',
    Scope.server,
    '/api/v1/assessments?search. The route accepted it; nothing sent it.',
  ),
  Box(
    'assessment/screens/admin/bank_screen.dart',
    'Search the whole bank',
    Scope.server,
    '/api/v1/bank?search. A bank runs to thousands of questions.',
  ),
  Box(
    'assessment/screens/admin/generator_list_screen.dart',
    'Search every generator',
    Scope.server,
    '/api/v1/generators?search. api_client.generators() was dropping the '
        'parameter, so this one needed the client fixed first.',
  ),

  // ── Declared hybrid ──────────────────────────────────────────────────────
  Box(
    'assessment/screens/admin/responses_screen.dart',
    'Search answers, or a candidate anywhere',
    Scope.hybrid,
    'TWO PASSES over one term. The server answers assessment, candidate and '
        'question via /api/v1/responses?search - the same three axes Odoo own '
        'response search view offers - and those rows are unioned into the '
        'cache before the local pass runs. The local pass alone can match the '
        'RENDERED, REDACTED answer text, because the redaction is a '
        'client-side transform and a second copy of those rules on the server '
        'is the duplication that caused this defect. Sending the term to the '
        'server INSTEAD would have broken answer-text search outright. The '
        'chip beside the box names which half reaches what.',
  ),

  // ── Declared local ───────────────────────────────────────────────────────
  Box(
    'assessment/screens/admin/dashboard_screen.dart',
    'Search candidate or assessment',
    Scope.local,
    'A dashboard panel, over the rows that panel was given. It is a summary of '
        'a sample by construction, not a way to look a record up.',
  ),
  Box(
    'assessment/screens/admin/dashboard_screen.dart',
    'Search assessments',
    Scope.local,
    'Same: a dashboard panel over its own rows. The Assessments screen is the '
        'server-backed way to find one.',
  ),
  Box(
    'assessment/screens/admin/dashboard_screen.dart',
    'Search candidates',
    Scope.local,
    'The leaderboard panel, which is already a server-ranked top slice with its '
        'own total.',
  ),
  Box(
    'assessment/screens/admin/form_studio_screen.dart',
    'Search forms',
    Scope.local,
    'Forms are a small bounded set walked in full at boot, with no cap to '
        'exceed.',
  ),
  Box(
    'assessment/screens/admin/form_studio_screen.dart',
    'Search question types',
    Scope.local,
    'The question TYPES are a compile-time enum. There is no server population '
        'to be wrong about.',
  ),
];

/// Every `SearchField(...)` call site in `lib/`, as (file, hint).
List<({String file, String hint})> found() {
  final Directory lib = Directory('lib');
  final List<({String file, String hint})> out =
      <({String file, String hint})>[];
  for (final FileSystemEntity e in lib.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    // The widget's own declaration is not a call site.
    if (e.path.endsWith('widgets/controls.dart')) continue;
    final List<String> lines = e.readAsLinesSync();
    for (int i = 0; i < lines.length; i++) {
      if (!lines[i].contains('SearchField(')) continue;
      String hint = '';
      for (int j = i; j < i + 8 && j < lines.length; j++) {
        final RegExpMatch? m = RegExp(r"hint:\s*'([^']*)'").firstMatch(lines[j]);
        if (m != null) {
          hint = m.group(1)!;
          break;
        }
      }
      out.add((file: e.path.replaceFirst('lib/', ''), hint: hint));
    }
  }
  return out;
}

void main() {
  test('every search box in the app is declared here', () {
    final List<({String file, String hint})> live = found();
    expect(live, isNotEmpty, reason: 'the extraction itself must work');

    final Set<String> declared = <String>{
      for (final Box b in kBoxes) '${b.file}|${b.hint}',
    };
    final Set<String> actual = <String>{
      for (final ({String file, String hint}) f in live) '${f.file}|${f.hint}',
    };

    expect(
      actual.difference(declared),
      isEmpty,
      reason: 'a search box exists that nobody classified. Add it to kBoxes as '
          'Scope.server, or as Scope.local WITH the reason it cannot be - '
          'requirement 2.3 is that the answer is written down',
    );
    expect(
      declared.difference(actual),
      isEmpty,
      reason: 'kBoxes names a search box that no longer exists, or whose hint '
          'text changed - the declaration has to track the code',
    );
  });

  test('every server-backed box is debounced', () {
    // A box wired straight to `onChanged` is one request per keystroke. Against
    // a pool that sheds load at capacity, a five-letter search from three
    // operators is fifteen requests nobody asked for.
    // HYBRID COUNTS. Its local half runs per keystroke, which is free, but its
    // server half is a request like any other - and a box that is only
    // PARTLY server-backed is exactly the one where the debounce is easy to
    // forget, because the screen feels responsive without it.
    for (final Box b in kBoxes.where(
      (Box b) => b.scope == Scope.server || b.scope == Scope.hybrid,
    )) {
      final String src = File('lib/${b.file}').readAsStringSync();
      expect(
        src.contains('milliseconds: 250'),
        isTrue,
        reason: '${b.file} sends a search term to the server and does not '
            'debounce at 250ms',
      );
    }
  });

  test('every box that is not purely server-backed states why', () {
    // Hybrid is included: half of it is still a bounded local pass, so it owes
    // the same explanation a fully local box does.
    for (final Box b in kBoxes.where(
      (Box b) => b.scope == Scope.local || b.scope == Scope.hybrid,
    )) {
      expect(
        b.why.length,
        greaterThan(40),
        reason: '${b.hint} does not run entirely on the server. Requirement '
            '2.3 allows that only as a decision with a reason attached',
      );
    }
  });

  test('the Responses box names the rows it can see', () {
    // Property 3: a surface showing a bounded sample states the population size
    // and that the view is partial.
    //
    // The box is now HYBRID, so the thing to pin changed with it: the old
    // label named only the loaded rows, which was honest while that was all
    // the box could reach and became misleading the moment a term also went
    // to the server. What must hold is that BOTH halves are named - the rows
    // the text pass can see, and the population the server pass covers - so an
    // operator is never sent away from a search that would have worked.
    final String src = File(
      'lib/assessment/screens/admin/responses_screen.dart',
    ).readAsStringSync();
    expect(
      src.contains(r"store.searchResponses("),
      isTrue,
      reason: 'the term must reach the server, or a candidate past the walk '
          'cap is unfindable - the 400-row defect',
    );
    expect(
      src.contains('answer text searched in'),
      isTrue,
      reason: 'the chip must say which half of the term reaches what',
    );
    expect(
      src.contains(r"people and assessments searched in all"),
      isTrue,
      reason: 'and must say the server half covers the whole population',
    );
    expect(
      src.contains(r'${s.responsesTotal}'),
      isTrue,
      reason: "the server's own total belongs beside the box, or the operator "
          'has no way to know what the sample is a sample of',
    );
  });
}
